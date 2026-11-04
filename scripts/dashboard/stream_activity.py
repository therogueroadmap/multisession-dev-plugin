"""Lector incremental del stream del driver y modelo de vista del dashboard (biblioteca estandar).

El stream es un .jsonl que crece mientras corre la sesion. `read_incremental` lee solo los
bytes nuevos; `feed` parte por saltos de linea, deja la ultima parte (posible linea a medias)
en `pending` y clasifica cada linea completa. Las lineas user/assistant (las mas pesadas)
no se deserializan: solo se extrae su timestamp con una regex sobre los bytes.
"""
import json
import math
import os
import re
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

PREFIX_RE = re.compile(rb'^\{"type":"([a-z_]+)"(?:,"subtype":"([a-z_]+)")?')
TIMESTAMP_RE = re.compile(rb'"timestamp":"([^"]+)"')
AGENT_MARK = b'"name":"Agent"'
TASK_SUBTYPES = frozenset(
    {"task_started", "task_progress", "task_updated", "task_notification", "vcs_state_changed"}
)
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
TASK_RE = re.compile(r"T(\d+)", re.I)
OTHER_TASK = "otras"
CHUNK = 1 << 20  # bloque de lectura de read_incremental (1 MiB)


@dataclass
class Bar:
    id: str
    task: str
    role: str
    subagentType: str | None
    description: str | None
    startedAt: str | None
    endedAt: str | None = None
    status: str | None = None
    tokens: int | None = None
    toolUses: int | None = None
    lastTool: str | None = None


@dataclass
class State:
    offset: int = 0
    pending: bytes = b""
    last_ts: str | None = None
    agent_ts: dict[str, str] = field(default_factory=dict)
    bars: dict[str, Bar] = field(default_factory=dict)
    commits: list[dict] = field(default_factory=list)
    quota: dict | None = None
    events: int = 0
    skipped: int = 0


def new_state() -> State:
    return State()


# ---------------------------------------------------------------- utilidades

def _task_code(description: str | None) -> str:
    m = TASK_RE.search(description or "")
    return f"T{int(m.group(1))}" if m else OTHER_TASK


def _role(subagent_type: str | None, description: str | None) -> str:
    if subagent_type == "implementer":
        return "impl"
    if subagent_type == "fix-agent":
        return "fix"
    if subagent_type == "reviewer":
        low = (description or "").lower()
        if "spec" in low:
            return "spec"
        if "calidad" in low or "quality" in low:
            return "quality"
    return "other"


def _iso_ms(epoch_ms: int) -> str:
    """Epoch en milisegundos a YYYY-MM-DDTHH:MM:SS.mmmZ (UTC), con aritmetica entera."""
    dt = EPOCH + timedelta(milliseconds=epoch_ms)
    return f"{dt:%Y-%m-%dT%H:%M:%S}.{dt.microsecond // 1000:03d}Z"


def _is_num(v) -> bool:
    # Excluye bool y floats no finitos (NaN, inf): json.dumps los emitiria como NaN/Infinity,
    # que el navegador no parsea. Los int no necesitan isfinite (y math.isfinite
    # desbordaria con enteros enormes).
    if isinstance(v, bool):
        return False
    if isinstance(v, int):
        return True
    return isinstance(v, float) and math.isfinite(v)


def _opt_str(v) -> str | None:
    if v is not None and not isinstance(v, str):
        raise TypeError("se esperaba str")
    return v


def _opt_int(v) -> int | None:
    if v is not None and (not isinstance(v, int) or isinstance(v, bool)):
        raise TypeError("se esperaba int")
    return v


def _req_str(v) -> str:
    if not isinstance(v, str):
        raise TypeError("se esperaba str")
    return v


# ---------------------------------------------------------------- manejadores
# Cada manejador valida los tipos antes de mutar el estado: una linea fallida no deja
# cambios a medias.

def _on_task_started(st: State, ev: dict) -> None:
    if ev.get("task_type") != "local_agent":
        return
    task_id = _req_str(ev.get("task_id"))
    description = _opt_str(ev.get("description"))
    subagent_type = _opt_str(ev.get("subagent_type"))
    tool_use_id = _opt_str(ev.get("tool_use_id"))
    if task_id in st.bars:
        return
    started = st.agent_ts.get(tool_use_id) if tool_use_id else None
    st.bars[task_id] = Bar(
        id=task_id,
        task=_task_code(description),
        role=_role(subagent_type, description),
        subagentType=subagent_type,
        description=description,
        startedAt=started or st.last_ts,
    )


def _on_task_progress(st: State, ev: dict) -> None:
    task_id = _req_str(ev.get("task_id"))
    usage = ev.get("usage")
    if usage is None and "usage" in ev:
        raise TypeError("usage null")
    if usage is not None and not isinstance(usage, dict):
        raise TypeError("usage no es dict")
    tokens = _opt_int(usage.get("total_tokens")) if usage else None
    tool_uses = _opt_int(usage.get("tool_uses")) if usage else None
    last_tool = _opt_str(ev.get("last_tool_name"))
    bar = st.bars.get(task_id)
    if bar is None:
        return
    # Un campo ausente no borra el valor previo [provisional, PA-8].
    if tokens is not None:
        bar.tokens = tokens
    if tool_uses is not None:
        bar.toolUses = tool_uses
    if last_tool is not None:
        bar.lastTool = last_tool


def _on_task_updated(st: State, ev: dict) -> None:
    task_id = _req_str(ev.get("task_id"))
    patch = ev.get("patch")
    if not isinstance(patch, dict):
        raise TypeError("patch no es dict")
    status = _opt_str(patch.get("status"))
    end_time = patch.get("end_time")
    ended = None
    if end_time is not None:
        if not _is_num(end_time):
            raise TypeError("end_time no numerico")
        ended = _iso_ms(int(end_time))
    bar = st.bars.get(task_id)
    if bar is None:
        return
    if status is not None:
        bar.status = status
    if ended is not None:
        bar.endedAt = ended


def _on_task_notification(st: State, ev: dict) -> None:
    task_id = _req_str(ev.get("task_id"))
    status = _opt_str(ev.get("status"))
    bar = st.bars.get(task_id)
    if bar is None:
        return
    if bar.endedAt is None:
        bar.endedAt = st.last_ts
    if bar.status is None:
        bar.status = status


def _on_vcs_state_changed(st: State, ev: dict) -> None:
    if ev.get("kind") != "commit":
        return
    st.commits.append({"at": st.last_ts, "branch": _opt_str(ev.get("branch"))})


def _window(raw) -> dict | None:
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise TypeError("ventana no es dict")
    util = raw.get("utilization")
    resets = raw.get("resetsAt")
    if util is not None and not _is_num(util):
        raise TypeError("utilization no numerico")
    if resets is not None and not _is_num(resets):
        raise TypeError("resetsAt no numerico")
    return {
        "utilization": util,
        "resetsAt": None if resets is None else _iso_ms(round(resets * 1000)),
    }


def _on_rate_limit(st: State, ev: dict) -> None:
    info = ev.get("rate_limit_info")
    if not isinstance(info, dict):
        return
    windows = info.get("unifiedWindows")
    if windows is None:
        return
    if not isinstance(windows, dict):
        raise TypeError("unifiedWindows no es dict")
    st.quota = {
        "fiveHour": _window(windows.get("five_hour")),
        "sevenDay": _window(windows.get("seven_day")),
        "observedAt": st.last_ts,
    }


def _on_tool_progress(st: State, ev: dict) -> None:
    # Solo cuenta en events [provisional, PA-4].
    return


SYSTEM_HANDLERS = {
    "task_started": _on_task_started,
    "task_progress": _on_task_progress,
    "task_updated": _on_task_updated,
    "task_notification": _on_task_notification,
    "vcs_state_changed": _on_vcs_state_changed,
}


# ---------------------------------------------------------------- clasificacion

def _dispatch(st: State, obj: dict) -> bool:
    """Procesa un objeto ya deserializado. Devuelve False si su tipo no se maneja."""
    typ = obj.get("type")
    if typ == "system":
        handler = SYSTEM_HANDLERS.get(obj.get("subtype"))
        if handler is None:
            return False
    elif typ == "rate_limit_event":
        handler = _on_rate_limit
    elif typ == "tool_progress":
        handler = _on_tool_progress
    else:
        return False
    handler(st, obj)
    return True


def _load(line: bytes):
    return json.loads(line.decode("utf-8", errors="replace"))


def _process_conversation(st: State, line: bytes) -> None:
    ts_match = TIMESTAMP_RE.search(line)
    ts = ts_match.group(1).decode("utf-8", errors="replace") if ts_match else st.last_ts
    agent_ids: list[str] = []
    if AGENT_MARK in line:
        obj = _load(line)
        content = obj["message"]["content"]
        if isinstance(content, list):
            for block in content:
                if (
                    isinstance(block, dict)
                    and block.get("type") == "tool_use"
                    and block.get("name") == "Agent"
                    and isinstance(block.get("id"), str)
                ):
                    agent_ids.append(block["id"])
    st.last_ts = ts
    if ts is not None:
        for tool_use_id in agent_ids:
            st.agent_ts[tool_use_id] = ts


def _process_line(st: State, line: bytes) -> bool:
    """Clasifica y maneja una linea completa. True si cuenta como evento, False si se omite."""
    m = PREFIX_RE.match(line)
    typ = m.group(1).decode("ascii") if m else None
    sub = m.group(2).decode("ascii") if m and m.group(2) else None
    if typ in ("user", "assistant"):
        _process_conversation(st, line)
        return True
    fast = (
        typ in ("rate_limit_event", "tool_progress")
        or (typ == "system" and sub in TASK_SUBTYPES)
    )
    if fast:
        obj = _load(line)
        return isinstance(obj, dict) and _dispatch(st, obj)
    if m and not (typ == "system" and sub is None):
        # Tipo reconocible pero no manejado (init, result, mystery_event...).
        return False
    # Sin prefijo reconocible (otro orden de claves, espacios): respaldo con json.loads.
    obj = _load(line)
    return isinstance(obj, dict) and _dispatch(st, obj)


def feed(state: State, data: bytes) -> None:
    buf = state.pending + data
    parts = buf.split(b"\n")
    state.pending = parts.pop()
    for line in parts:
        if line.endswith(b"\r"):
            line = line[:-1]
        if not line:
            continue
        try:
            counted = _process_line(state, line)
        except Exception:
            counted = False
        if counted:
            state.events += 1
        else:
            state.skipped += 1


def read_incremental(state: State, path: Path) -> None:
    """Lee los bytes nuevos desde `state.offset` en bloques de CHUNK.

    Si el archivo es mas chico que `state.offset` (truncado o reescrito), el estado se
    reinicia EN SITIO y se lee desde 0. El servidor cachea este mismo objeto, por eso no
    se sustituye por uno nuevo: se copian los campos de `new_state()` sobre `state`.
    """
    try:
        f = open(path, "rb")
    except FileNotFoundError:
        return
    with f:
        if os.fstat(f.fileno()).st_size < state.offset:
            state.__dict__.update(new_state().__dict__)
        f.seek(state.offset)
        while True:
            data = f.read(CHUNK)
            if not data:
                break
            state.offset += len(data)
            feed(state, data)


# ---------------------------------------------------------------- vista

def _task_sort_key(code: str) -> tuple[int, int]:
    if code == OTHER_TASK:
        return (1, 0)
    return (0, int(code[1:]))


def _stage_states(ordered: list[Bar], session: dict | None) -> list[str]:
    running = session is None or bool(session.get("live", True))
    states = []
    for i, bar in enumerate(ordered):
        later = ordered[i + 1:]
        if bar.role in ("spec", "quality") and any(
            b.role == "fix" or b.role == bar.role for b in later
        ):
            states.append("ko")
        elif bar.endedAt is not None:
            states.append("ok" if bar.status in (None, "completed") else "ko")
        else:
            states.append("run" if running else "unclosed")
    return states


def _build_task(code: str, bars: list[tuple[int, Bar]], session: dict | None) -> dict:
    ordered = [b for _, b in sorted(bars, key=lambda p: (p[1].startedAt or "", p[0]))]
    states = _stage_states(ordered, session)
    stages = [
        {"role": b.role, "label": b.description, "state": s, "barId": b.id}
        for b, s in zip(ordered, states)
    ]
    fixes = sum(1 for b in ordered if b.role == "fix")
    repeats = sum(
        max(0, sum(1 for b in ordered if b.role == role) - 1) for role in ("spec", "quality")
    )
    cycles = fixes + repeats
    last = ordered[-1]
    return {
        "code": code,
        "stages": stages,
        "cycles": cycles,
        "reworkAlert": cycles > 2,
        "done": last.role == "quality" and states[-1] == "ok",
    }


def to_view(state: State, now: datetime, session: dict | None = None) -> dict:
    # `now` no alimenta ningun campo en 1a; se conserva por contrato del spec [PA-5].
    groups: dict[str, list[tuple[int, Bar]]] = {}
    for idx, bar in enumerate(state.bars.values()):
        groups.setdefault(bar.task, []).append((idx, bar))
    tasks = [
        _build_task(code, groups[code], session)
        for code in sorted(groups, key=_task_sort_key)
    ]
    return {
        "available": True,
        "session": session,
        "stats": {"bytes": state.offset, "events": state.events, "skipped": state.skipped},
        "lastEventAt": state.last_ts,
        "tasks": tasks,
        "bars": [asdict(b) for b in state.bars.values()],
        "live": [b.id for b in state.bars.values() if b.endedAt is None],
        "commits": list(state.commits),
        "quota": state.quota,
    }
