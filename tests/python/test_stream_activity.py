"""Pruebas del lector del stream (scripts/dashboard/stream_activity.py)."""
import json
import time
from datetime import datetime, timezone

import pytest

import stream_activity as sa

UTC = timezone.utc
NOW = datetime(2026, 10, 15, 21, 0, tzinfo=UTC)
TS = "2026-10-15T20:00:00.000Z"


def _linea(**campos):
    return json.dumps(campos, separators=(",", ":")).encode("utf-8") + b"\n"


def _started(task_id, description, subagent_type=None, task_type="local_agent", **extra):
    campos = {"type": "system", "subtype": "task_started", "task_id": task_id,
              "description": description, "task_type": task_type}
    if subagent_type:
        campos["subagent_type"] = subagent_type
    campos.update(extra)
    return _linea(**campos)


def _updated(task_id, **patch):
    return _linea(type="system", subtype="task_updated", task_id=task_id, patch=patch)


def _usuario(ts):
    return (b'{"type":"user","message":{"role":"user","content":[]},"timestamp":"'
            + ts.encode() + b'"}\n')


@pytest.fixture
def cargado(fixture_path):
    st = sa.new_state()
    sa.read_incremental(st, fixture_path)
    return st, sa.to_view(st, NOW)


def _barra(view, bar_id):
    return next(b for b in view["bars"] if b["id"] == bar_id)


def _barra_por_desc(view, descripcion):
    return next(b for b in view["bars"] if b["description"] == descripcion)


def _tarea(view, codigo):
    return next(t for t in view["tasks"] if t["code"] == codigo)


def test_barras_reales_y_sinteticas(cargado):
    _, view = cargado
    ids = [b["id"] for b in view["bars"]]
    assert len(ids) == 11
    assert ids[0].startswith("a7ae7083827d0f7e0")
    assert ids[1].startswith("aa9458814b89c8ab5")
    assert ids[-2:] == ["syn-otras", "syn-t9"]


def test_barra_impl_t4(cargado):
    _, view = cargado
    b = _barra(view, "a7ae7083827d0f7e0")
    assert b["task"] == "T4"
    assert b["role"] == "impl"
    assert b["subagentType"] == "implementer"
    assert b["startedAt"] == "2026-10-15T19:44:46.154Z"
    assert b["endedAt"] == "2026-10-15T19:59:39.853Z"
    assert b["status"] == "completed"
    assert b["tokens"] == 214911
    assert b["toolUses"] == 63
    assert b["lastTool"] == "Bash"


def test_roles_reales(cargado):
    _, view = cargado
    esperado = {
        "Spec review T6": "spec",
        "Quality review T6": "quality",
        "Fix T6 test transaccional": "fix",
        "Re-review calidad T4": "quality",
        "Re-review 2 calidad T4": "quality",
    }
    for descripcion, rol in esperado.items():
        assert _barra_por_desc(view, descripcion)["role"] == rol


def test_tarea_t4(cargado):
    _, view = cargado
    t4 = _tarea(view, "T4")
    assert [s["role"] for s in t4["stages"]] == ["impl", "spec", "quality", "quality", "quality"]
    assert [s["state"] for s in t4["stages"]] == ["ok", "ok", "ko", "ko", "ok"]
    assert t4["cycles"] == 2
    assert t4["reworkAlert"] is False
    assert t4["done"] is True


def test_tarea_t6(cargado):
    _, view = cargado
    t6 = _tarea(view, "T6")
    assert [(s["role"], s["state"]) for s in t6["stages"]] == [
        ("impl", "ok"), ("spec", "ko"), ("quality", "ko"), ("fix", "ok")]
    assert t6["cycles"] == 1
    assert t6["done"] is False


def test_acento_roto(cargado):
    _, view = cargado
    assert _barra(view, "aa9458814b89c8ab5")["description"] == "Implementar T6 alta invitaci�n"
    assert _barra(view, "syn-otras")["description"] == "Revisi�n general del nivel"


def test_otras(cargado):
    _, view = cargado
    b = _barra(view, "syn-otras")
    assert b["task"] == "otras"
    assert b["role"] == "other"
    assert b["startedAt"] == "2026-10-15T20:20:00.000Z"
    assert b["endedAt"] == "2026-10-15T20:21:00.000Z"
    assert b["status"] == "completed"
    assert view["tasks"][-1]["code"] == "otras"


def test_campos_ausentes(cargado):
    _, view = cargado
    b = _barra(view, "syn-t9")
    assert b["task"] == "T9"
    assert b["role"] == "other"
    assert b["subagentType"] is None
    assert b["tokens"] is None
    assert b["toolUses"] is None
    assert b["lastTool"] is None
    assert b["endedAt"] is None


def test_orden_numerico_de_tareas(cargado):
    _, view = cargado
    assert [t["code"] for t in view["tasks"]] == ["T4", "T6", "T9", "otras"]


def test_live_y_sin_cierre(cargado):
    st, view = cargado
    assert view["live"] == ["syn-t9"]
    assert _tarea(view, "T9")["stages"][0]["state"] == "run"
    sin_cierre = sa.to_view(st, NOW, {"iter": 3, "streamFile": "x", "live": False})
    assert _tarea(sin_cierre, "T9")["stages"][0]["state"] == "unclosed"
    assert sin_cierre["session"] == {"iter": 3, "streamFile": "x", "live": False}


def test_linea_a_medias(cargado, fixture_path):
    st, view = cargado
    assert st.pending.startswith(b'{"type":"system","subtype":"task_updated","task_id":"syn-t9"')
    assert view["stats"]["bytes"] == fixture_path.stat().st_size


def test_stats(cargado, fixture_path):
    _, view = cargado
    lineas = [l for l in fixture_path.read_bytes().split(b"\n")[:-1] if l.strip()]
    assert view["stats"]["events"] + view["stats"]["skipped"] == len(lineas)
    assert view["stats"]["skipped"] >= 2


def test_commits(cargado):
    _, view = cargado
    assert view["commits"] == [{"at": "2026-10-15T20:07:34.047Z", "branch": "feature/DEMO-1"}]


def test_quota(cargado):
    _, view = cargado
    q = view["quota"]
    assert q["fiveHour"] == {"utilization": 0.75, "resetsAt": "2026-10-15T22:30:00.000Z"}
    assert q["sevenDay"] == {"utilization": 0.68, "resetsAt": "2026-10-16T01:00:00.000Z"}
    assert q["observedAt"] == "2026-10-15T20:18:59.766Z"


def test_last_event_at(cargado):
    _, view = cargado
    assert view["lastEventAt"] == "2026-10-15T20:21:00.000Z"


def test_sin_cuota_es_null():
    st = sa.new_state()
    sa.feed(st, _usuario(TS))
    assert sa.to_view(st, NOW)["quota"] is None
    sa.feed(st, _linea(type="rate_limit_event", rate_limit_info={
        "unifiedWindows": {"five_hour": {"utilization": 0.1, "resetsAt": 1792103400}}}))
    q = sa.to_view(st, NOW)["quota"]
    assert q["fiveHour"] == {"utilization": 0.1, "resetsAt": "2026-10-15T22:30:00.000Z"}
    assert q["sevenDay"] is None


def test_rate_limit_sin_ventanas_no_cambia_cuota():
    st = sa.new_state()
    sa.feed(st, _linea(type="rate_limit_event", rate_limit_info={"status": "allowed"}))
    assert st.quota is None
    assert st.events == 1


@pytest.mark.parametrize("no_finito", [float("nan"), float("inf"), float("-inf")])
def test_numeros_no_finitos_se_saltan(no_finito):
    st = sa.new_state()
    sa.feed(st, _linea(type="rate_limit_event", rate_limit_info={
        "unifiedWindows": {"five_hour": {"utilization": 0.1, "resetsAt": 1792103400}}}))
    antes = st.quota
    assert antes is not None
    sa.feed(st, _linea(type="rate_limit_event", rate_limit_info={
        "unifiedWindows": {"five_hour": {"utilization": no_finito, "resetsAt": 1792103400}}}))
    assert st.skipped == 1
    assert st.quota == antes
    json.dumps(sa.to_view(st, NOW), allow_nan=False)


def test_rework_alert():
    datos = _started("i", "Implementar T2", "implementer")
    datos += _updated("i", status="completed", end_time=1792094000000)
    for n in range(3):
        datos += _usuario(f"2026-10-15T20:0{n}:00.000Z")
        datos += _started(f"q{n}", f"Quality review T2 {n}", "reviewer")
        datos += _updated(f"q{n}", status="completed", end_time=1792094000000)
        datos += _usuario(f"2026-10-15T20:0{n}:30.000Z")
        datos += _started(f"f{n}", f"Fix T2 {n}", "fix-agent")
        datos += _updated(f"f{n}", status="completed", end_time=1792094000000)
    st = sa.new_state()
    sa.feed(st, datos)
    t2 = _tarea(sa.to_view(st, NOW), "T2")
    assert t2["cycles"] == 5
    assert t2["reworkAlert"] is True
    assert [s["state"] for s in t2["stages"] if s["role"] == "quality"] == ["ko", "ko", "ko"]


def test_campos_mal_tipados():
    datos = (
        _started("syn-bad", "Implementar T1", "implementer")
        + _linea(type="system", subtype="task_progress", task_id="syn-bad", usage=None)
        + _linea(type="system", subtype="task_updated", task_id="syn-bad", patch="x")
        + _updated("syn-bad", status="completed", end_time="abc")
        + _linea(type="rate_limit_event", rate_limit_info={
            "unifiedWindows": {"five_hour": {"utilization": 0.5, "resetsAt": "pronto"}}})
        + _started("syn-ok", "Implementar T2", "implementer")
    )
    st = sa.new_state()
    sa.feed(st, datos)
    view = sa.to_view(st, NOW)
    assert st.skipped == 4
    assert st.events == 2
    bad = _barra(view, "syn-bad")
    assert bad["endedAt"] is None
    assert bad["status"] is None
    assert bad["tokens"] is None
    assert view["quota"] is None
    assert "syn-ok" in [b["id"] for b in view["bars"]]


def test_done_falso_si_la_ultima_quality_muere():
    datos = (
        _usuario("2026-10-15T20:00:00.000Z")
        + _started("i", "Implementar T5", "implementer")
        + _updated("i", status="completed", end_time=1792094000000)
        + _usuario("2026-10-15T20:01:00.000Z")
        + _started("q", "Quality review T5", "reviewer")
        + _updated("q", status="killed", end_time=1792094100000)
    )
    st = sa.new_state()
    sa.feed(st, datos)
    t5 = _tarea(sa.to_view(st, NOW), "T5")
    assert t5["stages"][-1]["state"] == "ko"
    assert t5["done"] is False


def test_fin_por_end_time_gana():
    datos = (
        _usuario("2026-10-15T20:00:00.000Z")
        + _started("x1", "Implementar T3", "implementer")
        + _usuario("2026-10-15T20:05:00.000Z")
        + _linea(type="system", subtype="task_notification", task_id="x1", status="completed")
        + _updated("x1", status="completed", end_time=1792094379853)
    )
    st = sa.new_state()
    sa.feed(st, datos)
    assert _barra(sa.to_view(st, NOW), "x1")["endedAt"] == "2026-10-15T19:59:39.853Z"


def test_local_bash_no_crea_barras():
    datos = _started("b1", "ls", task_type="local_bash") + _linea(
        type="system", subtype="task_notification", task_id="b1", status="completed")
    st = sa.new_state()
    sa.feed(st, datos)
    view = sa.to_view(st, NOW)
    assert view["bars"] == []
    assert view["tasks"] == []


def test_linea_sin_prefijo_usa_respaldo_json():
    st = sa.new_state()
    sa.feed(st, b'{"subtype":"task_started","type":"system","task_id":"r1",'
                b'"description":"Spec review T5","task_type":"local_agent",'
                b'"subagent_type":"reviewer"}\r\n{"foo":1}\n[1,2]\n\n')
    assert [b.id for b in st.bars.values()] == ["r1"]
    assert st.events == 1
    assert st.skipped == 2


@pytest.fixture
def cortes(fixture_path):
    raw = fixture_path.read_bytes()
    rotos = raw.index(b"\xef\xbf\xbd") + 1
    s10 = raw.index(b'"syn-t9","patch":{"status":"compl') + 10
    return raw, [1, 100, len(raw) // 2, rotos, s10, len(raw) - 1]


def test_equivalencia_por_tramos(cortes):
    raw, posiciones = cortes
    entero = sa.new_state()
    sa.feed(entero, raw)
    esperado = sa.to_view(entero, NOW)
    for corte in posiciones:
        st = sa.new_state()
        sa.feed(st, raw[:corte])
        sa.feed(st, raw[corte:])
        assert sa.to_view(st, NOW) == esperado, corte


def test_equivalencia_read_incremental(fixture_path, tmp_path):
    raw = fixture_path.read_bytes()
    destino = tmp_path / "s.jsonl"
    destino.write_bytes(raw[: len(raw) // 2])
    st = sa.new_state()
    sa.read_incremental(st, destino)
    with open(destino, "ab") as f:
        f.write(raw[len(raw) // 2:])
    sa.read_incremental(st, destino)
    frio = sa.new_state()
    sa.read_incremental(frio, fixture_path)
    assert sa.to_view(st, NOW) == sa.to_view(frio, NOW)


def test_read_incremental_archivo_inexistente(tmp_path):
    st = sa.new_state()
    sa.read_incremental(st, tmp_path / "no-existe.jsonl")
    assert st.offset == 0
    assert sa.to_view(st, NOW)["bars"] == []


def test_truncado_reinicia_estado(fixture_path, tmp_path):
    raw = fixture_path.read_bytes()
    completas = raw.split(b"\n")[:-1]
    corto = b"\n".join(completas[: len(completas) // 2]) + b"\n"
    destino = tmp_path / "s.jsonl"
    destino.write_bytes(raw)
    st = sa.new_state()
    sa.read_incremental(st, destino)
    assert st.offset == len(raw)

    destino.write_bytes(corto)  # truncado: mas chico que el offset viejo
    sa.read_incremental(st, destino)
    frio = sa.new_state()
    sa.read_incremental(frio, destino)
    assert sa.to_view(st, NOW) == sa.to_view(frio, NOW)
    assert sa.to_view(st, NOW)["stats"]["bytes"] == len(corto)

    destino.write_bytes(corto + raw)  # crece mas alla del offset viejo: no debe empezar a mitad de linea
    sa.read_incremental(st, destino)
    frio = sa.new_state()
    sa.read_incremental(frio, destino)
    assert sa.to_view(st, NOW) == sa.to_view(frio, NOW)
    assert sa.to_view(st, NOW)["stats"]["bytes"] == len(corto) + len(raw)


def _vuelta(base, n):
    lineas = []
    for linea in base:
        if b'"task_id"' in linea and linea.endswith(b"}"):
            try:
                obj = json.loads(linea.decode("utf-8", errors="replace"))
            except ValueError:
                lineas.append(linea)
                continue
            obj["task_id"] = f"{obj['task_id']}-{n}"
            lineas.append(json.dumps(obj, separators=(",", ":")).encode("utf-8"))
        else:
            lineas.append(linea)
    return lineas


def _conversacion(i):
    relleno = "x" * 3000
    return (
        f'{{"type":"assistant","timestamp":"2026-10-15T20:{i % 60:02d}:00.000Z",'
        f'"message":{{"content":[{{"type":"text","text":"{relleno}"}}]}}}}'
    ).encode()


def test_rendimiento(fixture_path, tmp_path):
    base = [l for l in fixture_path.read_bytes().split(b"\n")[:-1] if l]
    destino = tmp_path / "grande.jsonl"
    vueltas = 0
    with open(destino, "wb") as f:
        escrito = 0
        while escrito < 4 * 1024 * 1024:
            for i, linea in enumerate(_vuelta(base, vueltas)):
                f.write(_conversacion(i) + b"\n")
                f.write(linea + b"\n")
                escrito += len(linea) + 3100
            vueltas += 1
    assert destino.stat().st_size >= 4 * 1024 * 1024

    st = sa.new_state()
    t0 = time.perf_counter()
    sa.read_incremental(st, destino)
    sa.to_view(st, NOW)
    frio = time.perf_counter() - t0
    assert frio < 1.0, frio
    assert st.events > 0

    tiempos = []
    for _ in range(3):  # el minimo de 3 corridas absorbe pausas ajenas al lector
        with open(destino, "ab") as f:
            f.write(_conversacion(1) + b"\n")
            f.write(base[2] + b"\n")
        t0 = time.perf_counter()
        sa.read_incremental(st, destino)
        sa.to_view(st, NOW)
        tiempos.append(time.perf_counter() - t0)
    incremental = min(tiempos)
    assert incremental < 0.05, incremental
