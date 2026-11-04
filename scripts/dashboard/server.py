"""Servidor HTTP del dashboard del driver (biblioteca estandar).

Sirve .driver-status.json, los logs de .driver-logs/, la revision final y assets/dashboard.html.
Recibe ordenes POST /control/<accion> (token, Origin y una sola orden pendiente) y solo las
escribe en .driver-control.json: nunca lanza procesos ni ejecuta la orden.
Se ata solo a 127.0.0.1, cae a puertos de respaldo si el pedido esta ocupado,
publica su puerto en .driver-dashboard.json y se apaga solo por inactividad.
"""
import argparse
import ctypes
import hmac
import json
import os
import random
import re
import socket
import sys
import threading
import time
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
from pathlib import Path
from typing import Callable

# Sin depender de que Python agregue la carpeta del script (falla con -I o -P).
sys.path.insert(0, str(Path(__file__).resolve().parent))
from stream_activity import State, new_state, read_incremental, to_view
from final_review import load_final_review
from control_channel import (BODY_MAX, RETRIES, RETRY_DELAY, ROUTE_RE, _retry, parse_token,
                             pending_id, validate_control, write_control)

# Siempre con fullmatch (nunca con $, que acepta un salto de linea final).
LOG_NAME_RE = re.compile(r"session-\d+-(\d{8}-\d{6}|r\d+-\d{8}-\d{6})\.(log|err\.log)", re.ASCII)
STREAM_NAME_RE = re.compile(r"session-\d+-(\d{8}-\d{6}|r\d+-\d{8}-\d{6})\.stream\.jsonl", re.ASCII)
FALLBACK_RANGE = range(20000, 30000)
FALLBACK_COUNT = 10
TAIL_MAX = 500
ENDPOINT_FILE = ".driver-dashboard.json"
HOST = "127.0.0.1"
HTML_NAME = "dashboard.html"
DRAIN_MAX = 1 << 20
# Estados en los que el driver sigue vivo aunque no avance: no corren el reloj de reposo.
LIVE_STATUSES = ("RUNNING", "PAUSED", "AWAITING")
CSP = ("default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
       "connect-src 'self'; frame-ancestors 'none'")


@dataclass
class Config:
    status_path: Path
    logs_dir: Path
    assets_dir: Path
    port: int = 8787
    idle_minutes: float = 120
    driver_pid: int | None = None
    control_token: str | None = None


def parse_args(argv: list[str] | None = None, environ=None) -> Config:
    p = argparse.ArgumentParser(description="Servidor del dashboard del driver")
    p.add_argument("--status", required=True, type=Path)
    p.add_argument("--logs", required=True, type=Path)
    p.add_argument("--assets", required=True, type=Path)
    p.add_argument("--port", type=int, default=8787)
    p.add_argument("--idle-minutes", type=float, default=120)
    p.add_argument("--driver-pid", type=int, default=None)
    a = p.parse_args(argv)
    # El token solo viaja por el entorno: la linea de comandos es visible para otros procesos.
    token = parse_token((os.environ if environ is None else environ).get("DRIVER_DASHBOARD_TOKEN"))
    return Config(status_path=a.status, logs_dir=a.logs, assets_dir=a.assets,
                  port=a.port, idle_minutes=a.idle_minutes, driver_pid=a.driver_pid,
                  control_token=token)


# ------------------------------------------------------------------ puertos

class PortUnavailableError(RuntimeError):
    pass


def candidate_ports(port: int, rng: random.Random | None = None) -> list[int]:
    rng = rng or random.Random()
    pool = [p for p in FALLBACK_RANGE if p != port]
    return [port] + rng.sample(pool, FALLBACK_COUNT)


class DashboardHTTPServer(ThreadingHTTPServer):
    # En Windows SO_REUSEADDR deja tomar un puerto ya ocupado: se desactiva.
    allow_reuse_address = False
    daemon_threads = True

    def server_bind(self):
        if sys.platform == "win32":
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        # Se salta HTTPServer.server_bind (usa socket.getfqdn, DNS lento): va directo a TCPServer.
        super(HTTPServer, self).server_bind()
        self.server_name = HOST
        self.server_port = self.server_address[1]


def bind_server(config: Config, handler_cls, candidates: list[int]) -> DashboardHTTPServer:
    tried = []
    for port in candidates:
        try:
            return DashboardHTTPServer((HOST, port), handler_cls)
        except (OSError, OverflowError):  # OverflowError: puerto fuera de 0-65535
            tried.append(port)
    raise PortUnavailableError(
        f"No se pudo abrir ningun puerto en {HOST}. Puertos probados: {tried}. "
        "Revisa los rangos excluidos con: netsh int ipv4 show excludedportrange protocol=tcp")


# ---------------------------------------------------------- archivos y reintentos

def write_endpoint_file(status_path: Path, port: int, pid: int, started_at: str) -> Path:
    path = status_path.parent / ENDPOINT_FILE
    tmp = path.with_name(path.name + ".tmp")
    try:
        tmp.write_text(json.dumps({"port": port, "pid": pid, "startedAt": started_at}),
                       encoding="utf-8")
        _retry(lambda: os.replace(tmp, path), (PermissionError,), RETRIES, RETRY_DELAY)
    except Exception:
        try:  # no dejar el .tmp huerfano; el error original se propaga igual
            tmp.unlink()
        except OSError:
            pass
        raise
    return path


def remove_endpoint_file(status_path: Path) -> None:
    """Borra el archivo solo si lo escribio este proceso."""
    path = status_path.parent / ENDPOINT_FILE
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        if data.get("pid") == os.getpid():
            path.unlink()
    except (OSError, ValueError, AttributeError):
        pass


def read_status_bytes(status_path: Path, retries: int = RETRIES,
                      delay: float = RETRY_DELAY) -> bytes | None:
    """Bytes del status; None si no existe o sigue ilegible tras los reintentos."""
    def attempt():
        with open(status_path, "rb") as f:
            raw = f.read()
        json.loads(raw.decode("utf-8-sig"))
        return raw

    try:
        return _retry(attempt, (OSError, ValueError), retries, delay)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        return None


def tail_lines(path: Path, n: int) -> bytes:
    """Ultimas n lineas, leyendo bloques de 8 KB desde el final."""
    with open(path, "rb") as f:
        pos = f.seek(0, os.SEEK_END)
        data = b""
        while pos > 0:
            step = min(8192, pos)
            pos -= step
            f.seek(pos)
            data = f.read(step) + data
            body = data[:-1] if data.endswith(b"\n") else data
            if body.count(b"\n") >= n:
                break
    trailing = data.endswith(b"\n")
    lines = data.split(b"\n")
    if trailing:
        lines.pop()
    out = b"\n".join(lines[-n:])
    return out + b"\n" if trailing and lines else out


# --------------------------------------------------------------------- pids

_K32 = None


def _kernel32():
    global _K32
    if _K32 is None:
        from ctypes import wintypes
        k = ctypes.WinDLL("kernel32", use_last_error=True)
        k.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        k.OpenProcess.restype = wintypes.HANDLE
        k.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        k.GetExitCodeProcess.restype = wintypes.BOOL
        k.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        k.GetProcessTimes.restype = wintypes.BOOL
        k.CloseHandle.argtypes = [wintypes.HANDLE]
        k.CloseHandle.restype = wintypes.BOOL
        _K32 = k
    return _K32


def _win_open_process(pid: int) -> int:
    return _kernel32().OpenProcess(0x1000, False, pid) or 0  # PROCESS_QUERY_LIMITED_INFORMATION


def _win_last_error() -> int:
    return ctypes.get_last_error()


def is_pid_alive(pid: int) -> bool:
    if sys.platform == "win32":
        # Nunca os.kill en Windows: con senal 0 llama a TerminateProcess y mata el proceso.
        from ctypes import wintypes
        handle = _win_open_process(pid)
        if not handle:
            return _win_last_error() == 5  # ERROR_ACCESS_DENIED: vivo pero sin permiso
        try:
            code = wintypes.DWORD()
            if not _kernel32().GetExitCodeProcess(handle, ctypes.byref(code)):
                return False
            return code.value == 259  # STILL_ACTIVE
        finally:
            _kernel32().CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _parse_iso(value) -> datetime | None:
    """ISO 8601 a datetime con zona. Acepta Z, desfase y 1-7 decimales; sin zona -> UTC."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    m = re.fullmatch(r"(.*?T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(.*)", text)
    if m is None:
        return None
    head, frac, tail = m.groups()
    # fromisoformat solo admite 3 o 6 decimales en versiones antiguas: se normaliza a 6
    text = head + ("." + frac[:6].ljust(6, "0") if frac else "") + tail
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


_FILETIME_EPOCH_DIFF = 116444736000000000  # 100 ns entre 1601-01-01 y 1970-01-01


def process_start_time(pid: int) -> datetime | None:
    """Hora de creacion del proceso (UTC). None fuera de Windows o ante cualquier fallo."""
    if sys.platform != "win32":
        return None
    try:
        from ctypes import wintypes
        handle = _win_open_process(pid)
        if not handle:
            return None
        try:
            created, exited, kernel, user = (wintypes.FILETIME() for _ in range(4))
            if not _kernel32().GetProcessTimes(handle, ctypes.byref(created), ctypes.byref(exited),
                                               ctypes.byref(kernel), ctypes.byref(user)):
                return None
            ticks = (created.dwHighDateTime << 32) | created.dwLowDateTime
        finally:
            _kernel32().CloseHandle(handle)
        return datetime.fromtimestamp((ticks - _FILETIME_EPOCH_DIFF) / 1e7, tz=timezone.utc)
    except (OSError, ValueError, OverflowError, AttributeError):
        return None


START_TOLERANCE_S = 2.0
HEARTBEAT_DEFAULT_S = 30
HEARTBEAT_MIN_LIMIT_S = 120


def driver_alive(status, fallback_pid, now: datetime, *, pid_alive=None,
                 start_time=None) -> tuple[bool | None, str | None]:
    """(vivo, motivo) del driver. None si no hay PID que comprobar; nunca lanza."""
    pid_alive = pid_alive or is_pid_alive
    start_time = start_time or process_start_time
    block = status.get("driver") if isinstance(status, dict) else None
    if not isinstance(block, dict):
        block = {}
    pid = block.get("pid")
    if not isinstance(pid, int) or isinstance(pid, bool):
        pid = fallback_pid
    if pid is None:
        return None, None
    try:
        if not pid_alive(pid):
            return False, "pid_muerto"
    except Exception:  # noqa: BLE001
        pass
    try:
        started = _parse_iso(block.get("processStartedAt"))
        if started is not None:
            actual = start_time(pid)
            if actual is not None and abs((actual - started).total_seconds()) > START_TOLERANCE_S:
                return False, "pid_reutilizado"
    except Exception:  # noqa: BLE001
        pass
    try:
        beat = _parse_iso(block.get("heartbeatAt"))
        if beat is not None:
            secs = block.get("heartbeatSeconds")
            if not isinstance(secs, (int, float)) or isinstance(secs, bool) or secs <= 0:
                secs = HEARTBEAT_DEFAULT_S
            limit = max(3 * secs, HEARTBEAT_MIN_LIMIT_S)
            if (now - beat).total_seconds() > limit:
                return False, "heartbeat_vencido"
    except Exception:  # noqa: BLE001
        pass
    return True, None


# --------------------------------------------------------------- inactividad

class IdleWatch:
    """Regla B-1: apagar cuando la condicion de reposo lleva idle_seconds sin peticiones."""

    def __init__(self, idle_seconds: float, clock: Callable[[], float]):
        self.idle_seconds = idle_seconds
        self.clock = clock
        self.last_request = float("-inf")
        self.since: float | None = None

    def touch(self) -> None:
        self.last_request = self.clock()

    def should_exit(self, idle_condition: bool) -> bool:
        if not idle_condition:
            self.since = None
            return False
        now = self.clock()
        if self.since is None:
            self.since = now
        return now - max(self.since, self.last_request) >= self.idle_seconds


# ----------------------------------------------------------------- actividad

class ActivityCache:
    """Un State incremental por stream; un lock por ruta serializa lectura y vista."""

    def __init__(self):
        self._guard = threading.Lock()  # solo protege la creacion de entradas
        self._entries: dict[str, tuple[threading.Lock, list[State]]] = {}

    def _entry(self, key: str) -> tuple[threading.Lock, list[State]]:
        with self._guard:
            entry = self._entries.get(key)
            if entry is None:
                entry = self._entries[key] = (threading.Lock(), [new_state()])
            return entry

    def get_view(self, stream_path: Path, now: datetime, session: dict) -> dict:
        lock, holder = self._entry(str(stream_path.absolute()))
        with lock:  # la lectura es acotada por el tamano del archivo: sin espera indefinida
            if stream_path.stat().st_size < holder[0].offset:
                holder[0] = new_state()  # el archivo se trunco o se reemplazo
            read_incremental(holder[0], stream_path)
            return to_view(holder[0], now, session)


def _is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def resolve_session(status, session_param: int | None) -> tuple[dict, str | None] | None:
    """Sesion pedida (o la vigente) como ({iter, streamFile, live}, streamFile); None si no existe.

    streamFile sale solo del campo streamFile de la entrada elegida, nunca de logPath.
    """
    if not isinstance(status, dict):
        return None
    current = status.get("currentSession")
    history = status.get("history")
    live_global = status.get("globalStatus") == "RUNNING"
    entry, live = None, False
    if isinstance(current, dict) and _is_int(current.get("iter")) and (
            session_param is None or current["iter"] == session_param):
        entry, live = current, live_global
    elif isinstance(history, list):
        for item in reversed(history):
            if isinstance(item, dict) and _is_int(item.get("iter")) and (
                    session_param is None or item["iter"] == session_param):
                entry = item
                break
    if entry is None:
        return None
    stream = entry.get("streamFile")
    stream = stream if isinstance(stream, str) else None
    return {"iter": entry["iter"], "streamFile": stream, "live": live}, stream


# ------------------------------------------------------------------ handler

def make_handler(config: Config, idle: IdleWatch,
                 cache: "ActivityCache | None" = None) -> type[BaseHTTPRequestHandler]:
    activity = cache if cache is not None else ActivityCache()
    control_lock = threading.Lock()  # une la comprobacion de orden pendiente y la escritura

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):  # el proceso corre sin ventana
            pass

        def _send(self, status: int, ctype: str, body: bytes, extra: dict | None = None):
            try:
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Security-Policy", CSP)
                self.send_header("X-Content-Type-Options", "nosniff")
                for k, v in (extra or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)
            except ConnectionError:
                pass

        def _text(self, status: int, text: str):
            self._send(status, "text/plain; charset=utf-8", text.encode("utf-8"))

        def _host_ok(self) -> bool:
            # Cierra el DNS rebinding: un dominio ajeno que resuelve a 127.0.0.1 llega con su Host.
            port = self.server.server_port
            host = (self.headers.get("Host") or "").lower()
            if host in (f"127.0.0.1:{port}", f"localhost:{port}"):
                return True
            self._text(403, "host no permitido")
            return False

        def do_GET(self):
            idle.touch()
            if not self._host_ok():
                return
            parts = urllib.parse.urlsplit(self.path)
            if parts.path == "/status.json":
                self._status()
            elif parts.path.startswith("/logs/"):
                self._log(urllib.parse.unquote(parts.path[len("/logs/"):]), parts.query)
            elif parts.path == "/activity.json":
                self._activity(parts.query)
            elif parts.path == "/final-review.json":
                self._final_review()
            else:
                self._html()

        def _final_review(self):
            status = _read_status(config)
            if status is None:
                if config.status_path.exists():
                    return self._json(503, {"error": "status no disponible"})
                return self._json(200, {"exists": False})
            try:
                data = load_final_review(config.status_path.parent, status)
            except OSError:
                return self._json(503, {"error": "revision final no disponible"})
            self._json(200, data)

        def _status(self):
            raw = read_status_bytes(config.status_path)
            if raw is not None:
                body, code = raw, 200
            elif not config.status_path.exists():
                body, code = b"{}", 200
            else:
                body, code = b'{"error":"status no disponible"}', 503
            self._send(code, "application/json; charset=utf-8", body)

        def _log(self, name: str, query: str):
            if LOG_NAME_RE.fullmatch(name) is None:
                return self._text(404, "no encontrado")
            path = config.logs_dir / name
            tail = None
            qs = urllib.parse.parse_qs(query, keep_blank_values=True)
            if "tail" in qs:
                raw = qs["tail"][0]
                # len > 9 se rechaza antes de int(): int() falla con mas de 4300 digitos
                if not (raw.isascii() and raw.isdigit()) or len(raw) > 9 or int(raw) < 1:
                    return self._text(400, "tail debe ser un entero >= 1")
                tail = min(int(raw), TAIL_MAX)
            try:
                body = tail_lines(path, tail) if tail else path.read_bytes()
            except OSError:
                return self._text(404, "no encontrado")
            self._send(200, "text/plain; charset=utf-8", body)

        def _json(self, status: int, data: dict):
            self._send(status, "application/json; charset=utf-8",
                       json.dumps(data).encode("utf-8"))

        def _activity(self, query: str):
            session_param = None
            qs = urllib.parse.parse_qs(query, keep_blank_values=True)
            if "session" in qs:
                raw = qs["session"][0]
                # misma proteccion que tail: solo digitos ASCII y longitud acotada antes de int()
                if not (raw.isascii() and raw.isdigit()) or len(raw) > 9:
                    return self._json(400, {"error": "session invalida"})
                session_param = int(raw)
            now = datetime.now(timezone.utc)
            status = _read_status(config)
            alive, why = driver_alive(status or {}, config.driver_pid, now)
            unavailable = {"available": False, "driver": {"alive": alive, "reason": why}}
            if status is None:
                return self._json(200, unavailable)
            resolved = resolve_session(status, session_param)
            if resolved is None:
                return self._json(200, unavailable)
            session, name = resolved
            if name is None or STREAM_NAME_RE.fullmatch(name) is None:
                return self._json(200, unavailable)
            # con el driver muerto la sesion ya no esta en vivo aunque el status diga RUNNING
            session["live"] = session["live"] and alive is not False
            try:
                view = activity.get_view(config.logs_dir / name, datetime.now(timezone.utc),
                                         session)
            except OSError:  # archivo ausente o con acceso transitorio denegado
                return self._json(200, unavailable)
            view["driver"] = {"alive": alive, "reason": why}
            self._json(200, view)

        def _html(self):
            try:
                body = (config.assets_dir / HTML_NAME).read_bytes()
            except OSError:
                return self._text(500, "dashboard.html no encontrado")
            self._send(200, "text/html; charset=utf-8", body)

        def _content_length(self) -> int | None:
            # misma proteccion que tail: solo digitos ASCII y longitud acotada antes de int()
            raw = self.headers.get("Content-Length")
            if raw is not None and raw.isascii() and raw.isdigit() and len(raw) <= 9:
                return int(raw)
            return None

        def _drain(self, length: int | None) -> bytes | None:
            if length is not None and 0 < length <= DRAIN_MAX:
                try:
                    return self.rfile.read(length)
                except OSError:
                    return None
            return None

        def _not_allowed(self):
            idle.touch()
            self._drain(self._content_length())  # vaciar el cuerpo evita un reset al responder
            if not self._host_ok():
                return
            self._send(405, "text/plain; charset=utf-8", "metodo no permitido".encode("utf-8"),
                       {"Allow": "GET, POST"})

        def _control_post(self):
            idle.touch()
            length = self._content_length()
            body = self._drain(length)  # leer el cuerpo antes de rechazar evita el reset
            if not self._host_ok():
                return
            match = ROUTE_RE.fullmatch(urllib.parse.urlsplit(self.path).path)
            if match is None:
                return self._json(404, {"error": "accion desconocida"})
            port = self.server.server_port
            origin = (self.headers.get("Origin") or "").lower()
            if origin not in (f"http://127.0.0.1:{port}", f"http://localhost:{port}"):
                return self._json(403, {"error": "origen no permitido"})
            token = config.control_token
            if token is None:
                return self._json(403, {"error": "control deshabilitado"})
            given = self.headers.get("X-Control-Token")
            if given is None or not hmac.compare_digest(given.encode("utf-8"),
                                                        token.encode("utf-8")):
                return self._json(403, {"error": "token invalido"})
            ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if ctype != "application/json":
                return self._json(415, {"error": "content-type no admitido"})
            if length is None:
                return self._json(400, {"error": "content-length invalido", "field": None})
            if length > BODY_MAX:
                return self._json(413, {"error": "cuerpo demasiado grande"})
            try:
                data = json.loads((body or b"").decode("utf-8"))
            except (ValueError, RecursionError):  # UnicodeDecodeError es un ValueError
                return self._json(400, {"error": "cuerpo invalido", "field": None})
            params, error = validate_control(match.group(1), data)
            if error is not None:
                return self._json(400, error)
            folder = config.status_path.parent
            with control_lock:
                exists, order_id = pending_id(folder)
                if exists:
                    return self._json(409, {"error": "orden pendiente", "id": order_id})
                try:
                    order_id = write_control(folder, match.group(1), params)
                except OSError:
                    return self._json(503, {"error": "no se pudo escribir la orden"})
            self._json(202, {"id": order_id})

        do_POST = _control_post
        do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _not_allowed

    return Handler


# ---------------------------------------------------------------- ciclo de vida

def _read_status(config: Config) -> dict | None:
    raw = read_status_bytes(config.status_path)
    if raw is None:
        return None
    try:
        data = json.loads(raw.decode("utf-8-sig"))
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def run(config: Config, *, clock=time.monotonic, pid_alive=is_pid_alive,
        poll_seconds: float = 5.0, candidates: list[int] | None = None,
        ready: threading.Event | None = None) -> int:
    idle = IdleWatch(config.idle_minutes * 60, clock)
    httpd = bind_server(config, make_handler(config, idle, ActivityCache()),
                        candidates or candidate_ports(config.port))
    thread = None
    try:
        started_at = datetime.now(timezone.utc).isoformat()
        write_endpoint_file(config.status_path, httpd.server_port, os.getpid(), started_at)
        thread = threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.1},
                                  daemon=True)
        thread.start()
        if ready is not None:
            ready.set()
        while True:
            status = _read_status(config)
            alive, _ = driver_alive(status or {}, config.driver_pid, datetime.now(timezone.utc),
                                    pid_alive=pid_alive)
            idle_condition = (status or {}).get("globalStatus") not in LIVE_STATUSES or alive is False
            if idle.should_exit(idle_condition):
                break
            time.sleep(poll_seconds)
    except KeyboardInterrupt:
        pass  # PA-11: salida limpia
    finally:
        if thread is not None:
            httpd.shutdown()
            thread.join()
        httpd.server_close()
        remove_endpoint_file(config.status_path)
    return 0


def main(argv: list[str] | None = None) -> int:
    config = parse_args(argv)
    try:
        return run(config)
    except PortUnavailableError as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
