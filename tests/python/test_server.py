"""Tests de scripts/dashboard/server.py (servidor base, sin /activity.json)."""
import http.client
import json
import os
import random
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "dashboard"))

import server  # noqa: E402

HTML = "<html><body>dashboard-test</body></html>"
LOG_OK = "session-1-20261021-141941.log"
ERR_OK = "session-1-20261021-141941.err.log"
STREAM = "session-1-20261021-141941.stream.jsonl"


# ---------------------------------------------------------------- fixtures

@pytest.fixture
def occupied_port():
    """Puerto de 127.0.0.1 ocupado por un socket propio del test."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    s.listen()
    yield s.getsockname()[1]
    s.close()


@pytest.fixture
def env(tmp_path):
    logs = tmp_path / "logs"
    assets = tmp_path / "assets"
    logs.mkdir()
    assets.mkdir()
    (assets / "dashboard.html").write_text(HTML, encoding="utf-8")
    status = tmp_path / "status.json"
    status.write_text('{"globalStatus":"RUNNING","x":1}', encoding="utf-8")
    return {"tmp": tmp_path, "status": status, "logs": logs, "assets": assets}


class Running:
    """Instancia de run() en un hilo, con reloj falso y parada garantizada."""

    def __init__(self, config, clock, **kwargs):
        self.config = config
        self.clock = clock
        self.result = []
        self.error = []
        self.ready = threading.Event()

        def target():
            try:
                self.result.append(server.run(
                    config, clock=lambda: clock[0], poll_seconds=0.01,
                    ready=self.ready, **kwargs))
            except BaseException as exc:  # noqa: BLE001
                self.error.append(exc)

        self.thread = threading.Thread(target=target, daemon=True)
        self.thread.start()
        self.port = None

    def wait_ready(self):
        """Espera ready; se llama despues de registrar la instancia para el teardown."""
        assert self.ready.wait(5), f"run() no llego a ready. error del hilo: {self.error!r}"
        endpoint = self.config.status_path.parent / server.ENDPOINT_FILE
        self.port = json.loads(endpoint.read_text(encoding="utf-8"))["port"]

    def stop(self):
        if not self.thread.is_alive():
            return
        self.config.status_path.write_text('{"globalStatus":"DONE"}', encoding="utf-8")
        deadline = time.monotonic() + 5
        while self.thread.is_alive() and time.monotonic() < deadline:
            self.clock[0] += 1_000_000
            self.thread.join(0.05)
        assert not self.thread.is_alive(), "el hilo de run() no se detuvo"


@pytest.fixture
def start(env, occupied_port):
    runs = []

    def _start(*, port=None, idle_minutes=120, driver_pid=None, control_token=None, **kwargs):
        config = server.Config(
            status_path=env["status"], logs_dir=env["logs"], assets_dir=env["assets"],
            port=occupied_port if port is None else port,
            idle_minutes=idle_minutes, driver_pid=driver_pid, control_token=control_token)
        run = Running(config, [0.0], **kwargs)
        runs.append(run)  # registrado antes de esperar: el teardown lo para aunque falle
        run.wait_ready()
        return run

    yield _start
    for r in runs:
        r.stop()


@pytest.fixture
def running(start):
    return start()


def http_request(port, path, method="GET"):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        conn.request(method, path)
        resp = conn.getresponse()
        return resp.status, resp.headers, resp.read()
    finally:
        conn.close()


def make_config(env, **kw):
    return server.Config(status_path=env["status"], logs_dir=env["logs"],
                         assets_dir=env["assets"], **kw)


# ------------------------------------------------------------------ puertos

def test_respaldo_si_el_puerto_esta_ocupado(running, occupied_port):
    assert running.port != occupied_port
    assert 20000 <= running.port <= 29999


def test_no_comparte_puerto_ocupado(env, occupied_port):
    config = make_config(env)
    handler = server.make_handler(config, server.IdleWatch(60, time.monotonic))
    with pytest.raises(server.PortUnavailableError):
        server.bind_server(config, handler, [occupied_port])


def test_puerto_fuera_de_rango_cae_al_respaldo(env):
    config = make_config(env)
    handler = server.make_handler(config, server.IdleWatch(60, time.monotonic))
    srv = server.bind_server(config, handler, [70000, -1, 0])
    try:
        assert srv.server_port > 0
    finally:
        srv.server_close()


def test_sin_puertos_sale_con_codigo_y_netsh(env, occupied_port, monkeypatch, capsys):
    extra = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    extra.bind(("127.0.0.1", 0))
    extra.listen()
    try:
        monkeypatch.setattr(server, "candidate_ports",
                            lambda port, rng=None: [occupied_port, extra.getsockname()[1]])
        code = server.main(["--status", str(env["status"]), "--logs", str(env["logs"]),
                            "--assets", str(env["assets"])])
    finally:
        extra.close()
    assert code != 0
    assert "excludedportrange" in capsys.readouterr().err


def test_candidate_ports():
    ports = server.candidate_ports(8787, random.Random(1))
    assert len(ports) == 11
    assert ports[0] == 8787
    assert all(p in server.FALLBACK_RANGE for p in ports[1:])
    assert len(set(ports)) == 11


def test_server_name_sin_dns(env, monkeypatch):
    def boom(*a, **k):
        raise AssertionError("getfqdn no debe llamarse")
    monkeypatch.setattr(socket, "getfqdn", boom)
    config = make_config(env)
    handler = server.make_handler(config, server.IdleWatch(60, time.monotonic))
    srv = server.bind_server(config, handler, [0])
    try:
        assert srv.server_name == "127.0.0.1"
        assert srv.server_port > 0
    finally:
        srv.server_close()
    assert srv.socket.fileno() == -1


# ------------------------------------------------------------------ endpoint

def test_endpoint_file(running, env):
    path = env["tmp"] / server.ENDPOINT_FILE
    data = json.loads(path.read_text(encoding="utf-8"))
    assert isinstance(data["port"], int)
    assert data["pid"] == os.getpid()
    datetime.fromisoformat(data["startedAt"])
    assert not (env["tmp"] / (server.ENDPOINT_FILE + ".tmp")).exists()


def test_endpoint_file_ajeno_no_se_borra(env):
    path = env["tmp"] / server.ENDPOINT_FILE
    path.write_text(json.dumps({"port": 1, "pid": os.getpid() + 1, "startedAt": "x"}))
    server.remove_endpoint_file(env["status"])
    assert path.exists()
    path.write_text(json.dumps({"port": 1, "pid": os.getpid(), "startedAt": "x"}))
    server.remove_endpoint_file(env["status"])
    assert not path.exists()
    server.remove_endpoint_file(env["status"])  # inexistente: no falla
    path.write_text("no es json")
    server.remove_endpoint_file(env["status"])  # ilegible: no falla
    assert path.exists()


def test_os_replace_reintenta(env, monkeypatch):
    real = os.replace
    calls = []

    def flaky(src, dst):
        calls.append(1)
        if len(calls) <= 2:
            raise PermissionError("bloqueado")
        return real(src, dst)

    monkeypatch.setattr(os, "replace", flaky)
    path = server.write_endpoint_file(env["status"], 1234, os.getpid(), "2026-10-27T00:00:00+00:00")
    assert len(calls) == 3
    assert path.exists()
    assert json.loads(path.read_text(encoding="utf-8"))["port"] == 1234


def test_write_endpoint_file_borra_tmp_si_replace_agota(env, monkeypatch):
    def always_locked(src, dst):
        raise PermissionError("bloqueado")

    monkeypatch.setattr(os, "replace", always_locked)
    with pytest.raises(PermissionError):
        server.write_endpoint_file(env["status"], 1234, os.getpid(), "2026-10-27T00:00:00+00:00")
    assert not (env["tmp"] / (server.ENDPOINT_FILE + ".tmp")).exists()
    assert not (env["tmp"] / server.ENDPOINT_FILE).exists()


def test_write_endpoint_file_borra_tmp_si_la_escritura_falla(env, monkeypatch):
    real = Path.write_text

    def partial(self, data, *args, **kwargs):
        real(self, data[:5], *args, **kwargs)
        raise OSError("disco lleno")

    monkeypatch.setattr(Path, "write_text", partial)
    with pytest.raises(OSError):
        server.write_endpoint_file(env["status"], 1234, os.getpid(), "2026-10-27T00:00:00+00:00")
    assert not (env["tmp"] / (server.ENDPOINT_FILE + ".tmp")).exists()


def test_arranca_con_modo_aislado(env):
    script = Path(server.__file__)
    proc = subprocess.run([sys.executable, "-I", str(script), "--help"],
                          capture_output=True, text=True, timeout=30)
    assert proc.returncode == 0, proc.stderr


# --------------------------------------------------------------- /status.json

def test_status_json(running, env):
    status, headers, body = http_request(running.port, "/status.json")
    assert status == 200
    assert body == env["status"].read_bytes()
    assert headers["Content-Type"] == "application/json; charset=utf-8"
    assert headers["Cache-Control"] == "no-store"
    assert headers["Content-Length"] == str(len(body))


def test_status_json_sin_archivo(running, env):
    env["status"].unlink()
    status, _, body = http_request(running.port, "/status.json")
    assert status == 200
    assert body == b"{}"


def test_status_json_ilegible_503(running, env):
    env["status"].write_text("{roto", encoding="utf-8")
    status, _, body = http_request(running.port, "/status.json")
    assert status == 503
    assert json.loads(body) == {"error": "status no disponible"}


def test_status_reintenta(tmp_path, monkeypatch):
    p = tmp_path / "status.json"
    p.write_bytes(b'{"a":1}')
    real_open = open
    calls = []

    def flaky(*args, **kwargs):
        calls.append(1)
        if len(calls) <= 2:
            raise PermissionError("bloqueado")
        return real_open(*args, **kwargs)

    monkeypatch.setattr(server, "open", flaky, raising=False)
    assert server.read_status_bytes(p, retries=3, delay=0) == b'{"a":1}'
    assert len(calls) == 3


def test_status_sin_archivo_es_none(tmp_path):
    assert server.read_status_bytes(tmp_path / "nada.json") is None


# ---------------------------------------------------------------------- logs

def test_logs_permitido(running, env):
    (env["logs"] / LOG_OK).write_bytes(b"hola log\n")
    (env["logs"] / ERR_OK).write_bytes(b"hola err\n")
    status, headers, body = http_request(running.port, "/logs/" + LOG_OK)
    assert (status, body) == (200, b"hola log\n")
    assert headers["Content-Type"] == "text/plain; charset=utf-8"
    status, _, body = http_request(running.port, "/logs/" + ERR_OK)
    assert (status, body) == (200, b"hola err\n")


def test_logs_lista_blanca(running, env):
    (env["logs"] / "otro.txt").write_bytes(b"x")
    (env["logs"] / STREAM).write_bytes(b"x")
    (env["logs"] / "session-1-x.log").write_bytes(b"x")
    for path in ("/logs/../status.json", "/logs/..%2Fstatus.json", "/logs/otro.txt",
                 "/logs/" + STREAM, "/logs/session-1-x.log"):
        status, _, _ = http_request(running.port, path)
        assert status == 404, path


def test_logs_inexistente(running):
    status, _, _ = http_request(running.port, "/logs/" + LOG_OK)
    assert status == 404


def test_logs_tail(running, env):
    lines = "".join(f"linea {i}\n" for i in range(600))
    (env["logs"] / LOG_OK).write_bytes(lines.encode("utf-8"))
    status, _, body = http_request(running.port, f"/logs/{LOG_OK}?tail=5")
    assert status == 200
    assert body.decode().splitlines() == [f"linea {i}" for i in range(595, 600)]
    status, _, body = http_request(running.port, f"/logs/{LOG_OK}?tail=1000")
    assert status == 200
    assert len(body.decode().splitlines()) == 500
    for bad in ("0", "x", "", "-3", "1.5", "9" * 5000):
        status, _, _ = http_request(running.port, f"/logs/{LOG_OK}?tail={bad}")
        assert status == 400, bad
    status, _, body = http_request(running.port, f"/logs/{LOG_OK}?tail=999999999")
    assert status == 200
    assert len(body.decode().splitlines()) == 500


def test_tail_lines_sin_salto_final(tmp_path):
    p = tmp_path / "f.log"
    p.write_bytes(b"a\nb\nc")
    assert server.tail_lines(p, 2) == b"b\nc"


def test_tail_lines_con_salto_final_y_bloques(tmp_path):
    p = tmp_path / "f.log"
    p.write_bytes(b"".join(f"linea {i}\n".encode() for i in range(5000)))
    out = server.tail_lines(p, 3)
    assert out == b"linea 4997\nlinea 4998\nlinea 4999\n"
    assert server.tail_lines(p, 99999).count(b"\n") == 5000


def test_regex_fullmatch():
    assert server.LOG_NAME_RE.fullmatch(LOG_OK + "\n") is None
    assert server.LOG_NAME_RE.fullmatch(LOG_OK) is not None


# ----------------------------------------------------------------- HTML y 405

def test_raiz_y_otras_rutas(running):
    for path in ("/", "/cualquier/cosa"):
        status, headers, body = http_request(running.port, path)
        assert status == 200
        assert headers["Content-Type"] == "text/html; charset=utf-8"
        assert body.decode("utf-8") == HTML


def test_html_faltante(running, env):
    (env["assets"] / "dashboard.html").unlink()
    status, headers, body = http_request(running.port, "/")
    assert status == 500
    assert headers["Content-Type"].startswith("text/plain")
    assert "dashboard.html no encontrado" in body.decode("utf-8")


@pytest.mark.parametrize("method,path", [
    ("DELETE", "/"), ("PUT", "/x"),
    ("PATCH", "/x"), ("HEAD", "/"), ("OPTIONS", "/"),
])
def test_405(running, method, path):
    status, headers, _ = http_request(running.port, path, method)
    assert status == 405
    assert headers["Allow"] == "GET, POST"
    assert headers["Cache-Control"] == "no-store"


def _request_con_host(port, host, method="GET"):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        conn.putrequest(method, "/status.json", skip_host=True)
        if host is not None:
            conn.putheader("Host", host)
        conn.endheaders()
        return conn.getresponse().status
    finally:
        conn.close()


def test_host_ajeno_403(running):
    for host in (f"evil.example:{running.port}", "127.0.0.1:1", None):
        assert _request_con_host(running.port, host) == 403
        assert _request_con_host(running.port, host, "POST") == 403


def test_host_local_permitido(running):
    for host in (f"127.0.0.1:{running.port}", f"localhost:{running.port}",
                 f"LOCALHOST:{running.port}"):
        assert _request_con_host(running.port, host) == 200


# ------------------------------------------------------------------- inactividad

def test_idlewatch_reglas():
    t = [0.0]
    w = server.IdleWatch(100, lambda: t[0])
    t[0] = 500
    assert w.should_exit(False) is False
    t[0] = 0
    assert w.should_exit(True) is False  # since = 0
    t[0] = 50
    w.touch()
    t[0] = 149
    assert w.should_exit(True) is False
    t[0] = 150
    assert w.should_exit(True) is True
    t[0] = 160
    assert w.should_exit(False) is False  # reinicia since
    t[0] = 200
    assert w.should_exit(True) is False  # since = 200
    t[0] = 299
    assert w.should_exit(True) is False
    t[0] = 300
    assert w.should_exit(True) is True


def _wait_dead(run, seconds=2):
    run.thread.join(seconds)
    assert not run.thread.is_alive()


def _advance_until_dead(run, step, seconds=5):
    """Adelanta el reloj hasta que el hilo muera; no depende de cuando ocurra el sondeo."""
    deadline = time.monotonic() + seconds
    while run.thread.is_alive() and time.monotonic() < deadline:
        run.clock[0] += step
        run.thread.join(0.05)
    assert not run.thread.is_alive()


def test_apagado_por_inactividad(env, start):
    env["status"].write_text('{"globalStatus":"DONE"}', encoding="utf-8")
    run = start(idle_minutes=1)
    _advance_until_dead(run, 61)
    assert run.result == [0]
    assert not run.error
    assert not (env["tmp"] / server.ENDPOINT_FILE).exists()


def test_driver_muerto_activa_el_reloj(env, start):
    env["status"].write_text('{"globalStatus":"RUNNING"}', encoding="utf-8")
    run = start(idle_minutes=1, driver_pid=123, pid_alive=lambda p: False)
    _advance_until_dead(run, 61)
    assert run.result == [0]


def test_running_con_driver_vivo_no_se_apaga(env, start):
    env["status"].write_text('{"globalStatus":"RUNNING"}', encoding="utf-8")
    run = start(idle_minutes=1, driver_pid=123, pid_alive=lambda p: True)
    run.clock[0] += 10 * 3600
    time.sleep(0.2)
    assert run.thread.is_alive()
    env["status"].write_text('{"globalStatus":"DONE"}', encoding="utf-8")
    _advance_until_dead(run, 120)
    assert run.result == [0]


def test_las_peticiones_posponen_el_apagado(env, start):
    env["status"].write_text('{"globalStatus":"DONE"}', encoding="utf-8")
    run = start(idle_minutes=1)
    time.sleep(0.2)
    run.clock[0] += 50
    http_request(run.port, "/status.json")  # touch en t=50
    run.clock[0] += 30  # 80 s desde el inicio, 30 desde la peticion
    time.sleep(0.2)
    assert run.thread.is_alive()
    _advance_until_dead(run, 31)


# ---------------------------------------------------------------------- pids

def test_is_pid_alive():
    assert server.is_pid_alive(os.getpid()) is True
    proc = subprocess.Popen([sys.executable, "-c", "pass"])
    proc.wait()
    assert server.is_pid_alive(proc.pid) is False


@pytest.mark.skipif(sys.platform != "win32", reason="solo Windows")
def test_is_pid_alive_access_denied(monkeypatch):
    monkeypatch.setattr(server, "_win_open_process", lambda pid: 0)
    monkeypatch.setattr(server, "_win_last_error", lambda: 5)
    assert server.is_pid_alive(4) is True
    monkeypatch.setattr(server, "_win_last_error", lambda: 87)
    assert server.is_pid_alive(4) is False


# ---------------------------------------------------------------------- args

def test_parse_args_defaults(tmp_path):
    cfg = server.parse_args(["--status", "s.json", "--logs", "l", "--assets", "a"])
    assert cfg.port == 8787
    assert cfg.idle_minutes == 120
    assert cfg.driver_pid is None
    assert cfg.status_path == Path("s.json")
    cfg = server.parse_args(["--status", "s", "--logs", "l", "--assets", "a",
                             "--port", "9000", "--idle-minutes", "0.5", "--driver-pid", "42"])
    assert (cfg.port, cfg.idle_minutes, cfg.driver_pid) == (9000, 0.5, 42)
