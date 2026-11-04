"""Tests de la ruta /activity.json de scripts/dashboard/server.py."""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest

import server
import stream_activity as sa
# Fixtures y utilidades del servidor base: se reusan, no se duplican.
from test_server import env, http_request, occupied_port, start  # noqa: F401

STREAM_4 = "session-4-20261015-154320.stream.jsonl"
STREAM_3 = "session-3-20261015-154320.stream.jsonl"
LOG_3 = "session-3-20261015-154320.log"
SESSION_4 = {"iter": 4, "streamFile": STREAM_4, "live": True}


def write_status(env, current="default", history="default", global_status="RUNNING"):
    if current == "default":
        current = {"iter": 4, "streamFile": STREAM_4}
    if history == "default":
        history = [{"iter": 3, "streamFile": STREAM_3, "logPath": LOG_3}]
    data = {"globalStatus": global_status, "currentSession": current, "history": history}
    env["status"].write_text(json.dumps(data), encoding="utf-8")


@pytest.fixture
def streams(env, fixture_path):
    """Copia byte a byte el fixture a logs/ con los dos nombres de sesion."""
    raw = fixture_path.read_bytes()
    for name in (STREAM_4, STREAM_3):
        (env["logs"] / name).write_bytes(raw)
    write_status(env)
    return raw


def get_activity(run, query=""):
    code, headers, body = http_request(run.port, "/activity.json" + query)
    return code, headers, json.loads(body.decode("utf-8"))


def cold_view(raw, session):
    """Vista de una lectura en frio sobre los mismos bytes, pasada por JSON."""
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "s.jsonl"
        p.write_bytes(raw)
        st = sa.new_state()
        sa.read_incremental(st, p)
        view = json.loads(json.dumps(sa.to_view(st, datetime.now(timezone.utc), session)))
        view["driver"] = {"alive": None, "reason": None}  # el servidor lo agrega; sin --driver-pid
        return view


# ------------------------------------------------------------- resolucion

def test_activity_sin_parametro_usa_current(streams, start):
    run = start()
    code, _, view = get_activity(run)
    assert code == 200
    assert view["session"] == SESSION_4
    assert len(view["bars"]) == 11


def test_activity_sesion_pasada(streams, start):
    run = start()
    code, _, view = get_activity(run, "?session=3")
    assert code == 200
    assert view["session"] == {"iter": 3, "streamFile": STREAM_3, "live": False}
    t9 = next(t for t in view["tasks"] if t["code"] == "T9")
    assert t9["stages"][0]["state"] == "unclosed"


def test_activity_sin_current_usa_ultima_de_history(env, streams, start):
    write_status(env, current=None)
    run = start()
    _, _, view = get_activity(run)
    assert view["session"]["iter"] == 3
    assert view["session"]["live"] is False


def test_activity_sin_stream(env, streams, start):
    write_status(env, current={"iter": 4}, history=[{"iter": 3, "logPath": LOG_3}])
    run = start()
    assert get_activity(run)[2]["available"] is False
    assert get_activity(run, "?session=3")[2]["available"] is False
    assert get_activity(run, "?session=99")[2]["available"] is False
    env["status"].unlink()
    code, _, view = get_activity(run)
    assert code == 200
    assert view["available"] is False


def test_activity_stream_inexistente_en_logs(env, streams, start):
    (env["logs"] / STREAM_4).unlink()
    run = start()
    assert get_activity(run)[2]["available"] is False


UNICODE_DIGIT_NAME = "session-\u0663-20261015-154320.stream.jsonl"


@pytest.mark.parametrize("nombre", [
    "../status.json",
    "..\\status.json",
    "sub/session-4-20261015-154320.stream.jsonl",
    "C:/x.stream.jsonl",
    STREAM_4 + "\n",
    STREAM_4.upper(),
    "",
    4,
    UNICODE_DIGIT_NAME,
])
def test_activity_nombre_fuera_de_patron(env, streams, start, nombre):
    if isinstance(nombre, str) and not nombre.isascii():
        # el archivo existe: el rechazo debe venir de la regex y no de su ausencia
        try:
            (env["logs"] / nombre).write_bytes(streams)
        except OSError:
            pass  # el sistema de archivos no admite el nombre: la prueba sigue valida
    write_status(env, current={"iter": 4, "streamFile": nombre})
    run = start()
    code, _, view = get_activity(run)
    assert code == 200
    assert view["available"] is False


def test_activity_session_invalida(streams, start):
    run = start()
    assert get_activity(run, "?session=abc")[0] == 400
    assert get_activity(run, "?session=")[0] == 400
    assert get_activity(run, "?session=-1")[0] == 400
    assert get_activity(run, "?session=" + "9" * 5000)[0] == 400


@pytest.mark.parametrize("query", [
    "?session=%D9%A3",
    "?session=1.5",
    "?session=%2B1",
    "?session=",
    "?session=abc&session=3",
])
def test_activity_session_invalida_variantes(streams, start, query):
    run = start()
    assert get_activity(run, query)[0] == 400


def test_activity_driver_muerto_no_live(streams, start):
    proc = subprocess.Popen([sys.executable, "-c", "pass"])
    proc.wait(10)
    # idle_minutes alto y reloj falso: el bucle de run() no apaga el servidor
    run = start(driver_pid=proc.pid)
    _, _, view = get_activity(run)
    assert view["session"]["live"] is False


def test_activity_sin_driver_pid_sigue_live(streams, start):
    run = start(driver_pid=None)
    assert get_activity(run)[2]["session"]["live"] is True


def test_activity_driver_vivo_sigue_live(streams, start):
    run = start(driver_pid=os.getpid())
    assert get_activity(run)[2]["session"]["live"] is True


def test_activity_no_store(streams, start):
    run = start()
    _, headers, _ = http_request(run.port, "/activity.json")
    assert headers["Cache-Control"] == "no-store"
    assert headers["Content-Type"] == "application/json; charset=utf-8"


# ----------------------------------------------------------------- errores

def test_activity_oserror(streams, start, monkeypatch):
    original = server.ActivityCache.get_view
    errores = [PermissionError("denegado"), FileNotFoundError("transitorio")]

    def flaky(self, *args, **kwargs):
        if errores:
            raise errores.pop(0)
        return original(self, *args, **kwargs)

    monkeypatch.setattr(server.ActivityCache, "get_view", flaky)
    run = start()
    for _ in range(2):
        code, _, view = get_activity(run)
        assert code == 200
        assert view["available"] is False
    code, _, view = get_activity(run)
    assert code == 200
    assert view["available"] is True
    assert len(view["bars"]) == 11


# ------------------------------------------------------------- incremental

def test_activity_incremental(env, streams, start):
    raw = streams
    path = env["logs"] / STREAM_4
    mitad = len(raw) // 2
    path.write_bytes(raw[:mitad])
    run = start()
    primera = get_activity(run)[2]
    assert primera["stats"]["bytes"] == mitad
    with open(path, "ab") as f:
        f.write(raw[mitad:])
    segunda = get_activity(run)[2]
    assert segunda["stats"]["bytes"] > primera["stats"]["bytes"]
    assert segunda == cold_view(raw, SESSION_4)


def test_activity_archivo_encoge(env, streams, start):
    raw = streams
    path = env["logs"] / STREAM_4
    run = start()
    assert get_activity(run)[2]["stats"]["bytes"] == len(raw)
    corto = b"\n".join(raw.split(b"\n")[:20]) + b"\n"
    path.write_bytes(corto)
    view = get_activity(run)[2]
    assert view["stats"]["bytes"] == len(corto)
    assert view == cold_view(corto, SESSION_4)


def test_activity_concurrente(env, streams, start):
    raw = streams
    path = env["logs"] / STREAM_4
    lineas = raw.split(b"\n")
    inicio = b"\n".join(lineas[:30]) + b"\n"
    resto = lineas[30:]
    path.write_bytes(inicio)
    run = start()
    resultados = []
    fallos = []
    lock = threading.Lock()
    # 8 lectores y el escritor arrancan a la vez; el timeout evita esperas indefinidas
    arranque = threading.Barrier(9, timeout=10)

    def lector():
        try:
            arranque.wait()
            previo = -1
            for _ in range(10):
                code, _, view = get_activity(run)
                with lock:
                    resultados.append((code, view.get("available")))
                    if view.get("available"):
                        actual = view["stats"]["bytes"]
                        if actual < previo:
                            fallos.append(AssertionError(
                                f"stats.bytes decrece: {actual} < {previo}"))
                        previo = actual
        except BaseException as exc:  # noqa: BLE001
            with lock:
                fallos.append(exc)

    def escritor():
        try:
            arranque.wait()
            with open(path, "ab") as f:
                for i, linea in enumerate(resto):
                    ultima = i == len(resto) - 1
                    f.write(linea if ultima else linea + b"\n")
                    f.flush()
                    time.sleep(0)  # cede el procesador entre lineas
        except BaseException as exc:  # noqa: BLE001
            with lock:
                fallos.append(exc)

    hilos = [threading.Thread(target=lector, daemon=True) for _ in range(8)]
    hilos.append(threading.Thread(target=escritor, daemon=True))
    for h in hilos:
        h.start()
    for h in hilos:
        h.join(timeout=30)
    assert not any(h.is_alive() for h in hilos), "hilos colgados"
    assert not fallos, fallos
    assert len(resultados) == 80
    assert all(r == (200, True) for r in resultados)
    assert path.read_bytes() == raw
    assert get_activity(run)[2] == cold_view(raw, SESSION_4)


# ------------------------------------------------------------- unidades

def test_resolve_session_defensivo():
    assert server.resolve_session([], None) is None
    assert server.resolve_session({"currentSession": 5, "history": "x"}, None) is None
    assert server.resolve_session({"history": [1, None, {"iter": "3"}]}, 3) is None
    ok = server.resolve_session(
        {"globalStatus": "RUNNING", "currentSession": {"iter": 2, "streamFile": "a"}}, None)
    assert ok == ({"iter": 2, "streamFile": "a", "live": True}, "a")


def test_resolve_session_ultima_entrada_del_iter():
    status = {"globalStatus": "RUNNING", "currentSession": None, "history": [
        {"iter": 3, "streamFile": "primera"}, {"iter": 3, "streamFile": "segunda"}]}
    session, stream = server.resolve_session(status, 3)
    assert stream == "segunda"
    assert session["live"] is False
