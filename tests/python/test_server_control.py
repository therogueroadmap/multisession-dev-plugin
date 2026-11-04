"""Tests de H2b: canal POST /control/<accion> del servidor (token, Origin, validacion, CSP y reposo)."""
import http.client
import json
import threading
import time

import pytest

import server
# Fixtures y utilidades del servidor base: se reusan, no se duplican.
from test_server import env, http_request, occupied_port, start, _advance_until_dead  # noqa: F401

TOKEN = "ab" * 32
CONTROL_FILE = ".driver-control.json"

SET_PARAMS_VALIDOS = {
    "model": "claude-sonnet-5-5[1m]",
    "levelEffort": "low",
    "closeEffort": "max",
    "maxTransientRetries": 0,
    "retryBackoffSeconds": 3600,
    "livenessTimeoutMinutes": 5,
    "maxCostUsd": 12.5,
    "awaitDecisionMinutes": 0,
}


def post(port, path, body=b"{}", *, token=TOKEN, origin="auto", ctype="application/json",
         host=None, length=None):
    """POST crudo con http.client; devuelve (status, headers, cuerpo JSON o bytes)."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        conn.putrequest("POST", path, skip_host=True, skip_accept_encoding=True)
        conn.putheader("Host", host if host is not None else f"127.0.0.1:{port}")
        if origin == "auto":
            origin = f"http://127.0.0.1:{port}"
        if origin is not None:
            conn.putheader("Origin", origin)
        if token is not None:
            conn.putheader("X-Control-Token", token)
        if ctype is not None:
            conn.putheader("Content-Type", ctype)
        conn.putheader("Content-Length", str(len(body)) if length is None else length)
        conn.endheaders(body)
        resp = conn.getresponse()
        raw = resp.read()
        try:
            data = json.loads(raw.decode("utf-8"))
        except ValueError:
            data = raw
        return resp.status, resp.headers, data
    finally:
        conn.close()


def _files_bajo(root):
    return [p for p in root.rglob("*") if p.is_file()]


def test_canal_deshabilitado_403(start, env):
    run = start()
    status, headers, data = post(run.port, "/control/pause")
    assert status == 403
    assert data == {"error": "control deshabilitado"}
    assert headers["Cache-Control"] == "no-store"
    assert not (env["tmp"] / CONTROL_FILE).exists()


def test_control_host_ajeno_403(start):
    run = start(control_token=TOKEN)
    status, _, _ = post(run.port, "/control/pause", host=f"evil.example:{run.port}")
    assert status == 403


def test_rutas_desconocidas_404(start):
    run = start(control_token=TOKEN)
    for path in ("/control/x", "/control/pause/extra", "/status.json"):
        status, _, data = post(run.port, path)
        assert status == 404, path
        assert data == {"error": "accion desconocida"}, path


def test_origin_403_y_localhost_aceptado(start):
    run = start(control_token=TOKEN)
    for origin in (None, "http://evil.example", f"http://127.0.0.1:{run.port + 1}"):
        status, _, data = post(run.port, "/control/pause", origin=origin)
        assert status == 403, origin
        assert data == {"error": "origen no permitido"}, origin
    status, _, _ = post(run.port, "/control/pause", origin=f"http://localhost:{run.port}")
    assert status == 202


def test_token_ausente_o_malo_403(start):
    run = start(control_token=TOKEN)
    for token in (None, "cd" * 32):
        status, _, data = post(run.port, "/control/pause", token=token)
        assert status == 403
        assert data == {"error": "token invalido"}


def test_content_type_415(start, env):
    run = start(control_token=TOKEN)
    status, _, data = post(run.port, "/control/pause", ctype="text/plain")
    assert status == 415
    assert data == {"error": "content-type no admitido"}
    assert not (env["tmp"] / CONTROL_FILE).exists()
    status, _, _ = post(run.port, "/control/pause", ctype="application/json; charset=utf-8")
    assert status == 202


def test_tamano_413_y_length_invalido_400(start):
    run = start(control_token=TOKEN)
    status, _, data = post(run.port, "/control/pause", b"x" * 16385)
    assert status == 413
    assert data == {"error": "cuerpo demasiado grande"}
    status, _, data = post(run.port, "/control/pause", b"", length="abc")
    assert status == 400
    assert data == {"error": "content-length invalido", "field": None}


def test_json_invalido_400(start):
    run = start(control_token=TOKEN)
    for body in (b"{", b"[]"):
        status, _, data = post(run.port, "/control/pause", body)
        assert status == 400, body
        assert data == {"error": "cuerpo invalido", "field": None}, body


def test_json_anidado_400(start):
    run = start(control_token=TOKEN)
    status, _, data = post(run.port, "/control/pause", b"[" * 5000)
    assert status == 400
    assert data == {"error": "cuerpo invalido", "field": None}
    # el servidor sigue en pie
    assert http_request(run.port, "/status.json")[0] == 200


def test_pause_resume_stop_202_y_archivo(start, env):
    run = start(control_token=TOKEN)
    path = env["tmp"] / CONTROL_FILE
    for action in ("pause", "resume", "stop"):
        status, _, data = post(run.port, f"/control/{action}")
        assert status == 202
        assert list(data) == ["id"]
        order = json.loads(path.read_text(encoding="utf-8"))
        assert order["action"] == action
        assert order["params"] == {}
        assert order["id"] == data["id"]
        path.unlink()


def test_set_params_202(start, env):
    run = start(control_token=TOKEN)
    status, _, data = post(run.port, "/control/set-params",
                           json.dumps(SET_PARAMS_VALIDOS).encode("utf-8"))
    assert status == 202
    order = json.loads((env["tmp"] / CONTROL_FILE).read_text(encoding="utf-8"))
    assert order["action"] == "set-params"
    assert order["params"] == SET_PARAMS_VALIDOS
    assert order["id"] == data["id"]


def test_set_params_invalido_400_con_campo(start):
    run = start(control_token=TOKEN)
    status, _, data = post(run.port, "/control/set-params", b'{"maxCostUsd": 5000}')
    assert status == 400
    assert data == {"error": "parametro invalido", "field": "maxCostUsd"}
    status, _, data = post(run.port, "/control/set-params", b'{"maxCostUsd": 1' + b'0' * 400 + b'}')
    assert status == 400
    assert data == {"error": "parametro invalido", "field": "maxCostUsd"}


def test_answer_202_y_archivo(start, env):
    run = start(control_token=TOKEN)
    status, _, data = post(run.port, "/control/answer",
                           json.dumps({"text": "usa A\ncon ñ"}).encode("utf-8"))
    assert status == 202
    order = json.loads((env["tmp"] / CONTROL_FILE).read_text(encoding="utf-8"))
    assert order["action"] == "answer"
    assert order["params"] == {"text": "usa A\ncon ñ"}
    assert order["id"] == data["id"]


def test_answer_invalido_400(start, env):
    run = start(control_token=TOKEN)
    status, _, data = post(run.port, "/control/answer",
                           json.dumps({"text": "a\x07b"}).encode("utf-8"))
    assert status == 400
    assert data == {"error": "parametro invalido", "field": "text"}
    assert not (env["tmp"] / CONTROL_FILE).exists()


def test_retry_y_open_202(start, env):
    run = start(control_token=TOKEN)
    path = env["tmp"] / CONTROL_FILE
    status, _, _ = post(run.port, "/control/retry", b'{"mode": "level"}')
    assert status == 202
    order = json.loads(path.read_text(encoding="utf-8"))
    assert (order["action"], order["params"]) == ("retry", {"mode": "level"})
    path.unlink()
    status, _, _ = post(run.port, "/control/open", b'{"target": "log", "iter": 1}')
    assert status == 202
    order = json.loads(path.read_text(encoding="utf-8"))
    assert (order["action"], order["params"]) == ("open", {"target": "log", "iter": 1})


def test_open_iter_invalido_400(start):
    run = start(control_token=TOKEN)
    status, _, data = post(run.port, "/control/open", b'{"target": "log", "iter": 0}')
    assert status == 400
    assert data == {"error": "parametro invalido", "field": "iter"}


def test_answer_cuerpo_grande_413(start):
    run = start(control_token=TOKEN)
    body = json.dumps({"text": "€" * 6000}, ensure_ascii=False).encode("utf-8")
    assert len(body) > 16384
    status, _, data = post(run.port, "/control/answer", body)
    assert status == 413
    assert data == {"error": "cuerpo demasiado grande"}


def test_answer_4000_no_ascii_cabe_en_el_cuerpo(start):
    run = start(control_token=TOKEN)
    body = json.dumps({"text": "€" * 4000}, ensure_ascii=False).encode("utf-8")
    assert 8192 < len(body) <= 16384
    status, _, _ = post(run.port, "/control/answer", body)
    assert status == 202


def test_409_con_id(start):
    run = start(control_token=TOKEN)
    status, _, first = post(run.port, "/control/pause")
    assert status == 202
    status, _, data = post(run.port, "/control/stop")
    assert status == 409
    assert data == {"error": "orden pendiente", "id": first["id"]}


def test_token_no_aparece_en_archivos(start, env):
    run = start(control_token=TOKEN)
    assert post(run.port, "/control/pause")[0] == 202
    assert post(run.port, "/control/pause", token="cd" * 32)[0] == 403
    assert post(run.port, "/control/pause")[0] == 409
    archivos = _files_bajo(env["tmp"])
    nombres = {p.name for p in archivos}
    assert CONTROL_FILE in nombres and server.ENDPOINT_FILE in nombres
    for p in archivos:
        assert TOKEN.encode("utf-8") not in p.read_bytes(), p


def test_concurrencia_un_solo_202(start):
    run = start(control_token=TOKEN)
    barrier = threading.Barrier(8)
    codes = []

    def worker():
        barrier.wait(5)
        codes.append(post(run.port, "/control/pause")[0])

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(10)
    assert sorted(codes) == [202] + [409] * 7


def test_csp_y_nosniff(start):
    run = start(control_token=TOKEN)
    for path in ("/", "/status.json"):
        _, headers, _ = http_request(run.port, path)
        assert headers["Content-Security-Policy"] == server.CSP
        assert headers["X-Content-Type-Options"] == "nosniff"
    status, headers, _ = post(run.port, "/control/pause", token="cd" * 32)
    assert status == 403
    assert headers["Content-Security-Policy"] == server.CSP
    assert headers["X-Content-Type-Options"] == "nosniff"


@pytest.mark.parametrize("estado", ["PAUSED", "AWAITING"])
def test_reposo_estados_vivos(env, start, estado):
    env["status"].write_text(json.dumps({"globalStatus": estado}), encoding="utf-8")
    run = start(idle_minutes=1, driver_pid=123, pid_alive=lambda p: True)
    run.clock[0] += 10 * 3600
    time.sleep(0.2)
    assert run.thread.is_alive()
    env["status"].write_text('{"globalStatus":"DONE"}', encoding="utf-8")
    _advance_until_dead(run, 120)
    assert run.result == [0]


def test_post_pospone_apagado(env, start):
    env["status"].write_text('{"globalStatus":"DONE"}', encoding="utf-8")
    run = start(idle_minutes=1)
    time.sleep(0.2)
    run.clock[0] += 50
    status, _, _ = post(run.port, "/control/pause")  # touch en t=50
    assert status == 403
    run.clock[0] += 11  # 61 s desde el inicio, 11 desde la peticion
    time.sleep(0.2)
    assert run.thread.is_alive()
    _advance_until_dead(run, 31)


def test_parse_args_lee_token_del_entorno(monkeypatch):
    base = ["--status", "s.json", "--logs", "l", "--assets", "a"]
    assert server.parse_args(base, environ={"DRIVER_DASHBOARD_TOKEN": TOKEN}).control_token == TOKEN
    assert server.parse_args(base, environ={"DRIVER_DASHBOARD_TOKEN": "corto"}).control_token is None
    assert server.parse_args(base, environ={}).control_token is None
    monkeypatch.setenv("DRIVER_DASHBOARD_TOKEN", TOKEN)
    assert server.parse_args(base).control_token == TOKEN
    monkeypatch.delenv("DRIVER_DASHBOARD_TOKEN")
    assert server.parse_args(base).control_token is None
