"""Tests de H1: deteccion de driver muerto (driver_alive) y su exposicion en /activity.json."""
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

import pytest

import server
# Fixtures y utilidades del servidor base y de /activity.json: se reusan, no se duplican.
from test_server import env, http_request, occupied_port, start, _advance_until_dead  # noqa: F401
from test_server_activity import streams, write_status, get_activity, STREAM_4  # noqa: F401

NOW = datetime(2026, 10, 27, 22, 40, 0, tzinfo=timezone.utc)
STARTED = "2026-10-27T22:10:03.512Z"
STARTED_DT = datetime(2026, 10, 27, 22, 10, 3, 512000, tzinfo=timezone.utc)


def _iso(dt):
    """UTC con milisegundos y Z, como lo escribe el driver."""
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _status_driver(**driver):
    return {"globalStatus": "RUNNING", "driver": driver}


def _write_running_status(env, **driver):
    data = {"globalStatus": "RUNNING", "driver": driver}
    env["status"].write_text(json.dumps(data), encoding="utf-8")


# ------------------------------------------------------------ driver_alive

def test_driver_alive_sin_pid():
    assert server.driver_alive({}, None, NOW) == (None, None)


def test_driver_alive_pid_muerto_por_fallback():
    r = server.driver_alive({}, 123, NOW, pid_alive=lambda p: False)
    assert r == (False, "pid_muerto")


def test_driver_alive_prefiere_el_pid_del_status():
    vistos = []

    def pid_alive(p):
        vistos.append(p)
        return True

    server.driver_alive({"driver": {"pid": 77}}, 123, NOW, pid_alive=pid_alive,
                        start_time=lambda p: None)
    assert vistos == [77]


def test_driver_alive_pid_reutilizado():
    status = _status_driver(pid=77, processStartedAt=STARTED)
    r = server.driver_alive(status, None, NOW, pid_alive=lambda p: True,
                            start_time=lambda p: STARTED_DT + timedelta(seconds=5))
    assert r == (False, "pid_reutilizado")


def test_driver_alive_hora_de_inicio_dentro_de_2s():
    status = _status_driver(pid=77, processStartedAt=STARTED)
    r = server.driver_alive(status, None, NOW, pid_alive=lambda p: True,
                            start_time=lambda p: STARTED_DT + timedelta(seconds=1.5))
    assert r == (True, None)


def test_driver_alive_sin_hora_legible_omite_la_prueba():
    status = _status_driver(pid=77, processStartedAt=STARTED)
    r = server.driver_alive(status, None, NOW, pid_alive=lambda p: True,
                            start_time=lambda p: None)
    assert r == (True, None)


def test_driver_alive_heartbeat_vencido_con_30s():
    def alive(seconds):
        status = _status_driver(pid=77, heartbeatAt=_iso(NOW - timedelta(seconds=seconds)),
                                heartbeatSeconds=30)
        return server.driver_alive(status, None, NOW, pid_alive=lambda p: True,
                                   start_time=lambda p: None)

    assert alive(121) == (False, "heartbeat_vencido")
    assert alive(119) == (True, None)


def test_driver_alive_heartbeat_con_60s():
    def alive(seconds):
        status = _status_driver(pid=77, heartbeatAt=_iso(NOW - timedelta(seconds=seconds)),
                                heartbeatSeconds=60)
        return server.driver_alive(status, None, NOW, pid_alive=lambda p: True,
                                   start_time=lambda p: None)

    assert alive(181) == (False, "heartbeat_vencido")
    assert alive(179) == (True, None)


def test_driver_alive_excepcion_de_ctypes_no_rompe():
    def boom(p):
        raise OSError("ctypes")

    status = _status_driver(pid=77, processStartedAt=STARTED)
    r = server.driver_alive(status, None, NOW, pid_alive=lambda p: True, start_time=boom)
    assert r == (True, None)


def test_driver_alive_status_sin_bloque_driver():
    assert server.driver_alive({"globalStatus": "RUNNING"}, 5, NOW,
                               pid_alive=lambda p: True) == (True, None)
    assert server.driver_alive([], 5, NOW, pid_alive=lambda p: True) == (True, None)


# --------------------------------------------------------------- utilidades

def test_parse_iso_formatos():
    for valor in (STARTED, "2026-10-27T22:10:03.5120000-04:00", "2026-10-27T22:10:03"):
        parsed = server._parse_iso(valor)
        assert isinstance(parsed, datetime)
        assert parsed.tzinfo is not None
    assert server._parse_iso(STARTED) == STARTED_DT
    assert server._parse_iso("2026-10-27T22:10:03.5120000-04:00") == \
        datetime(2026, 10, 28, 2, 10, 3, 512000, tzinfo=timezone.utc)
    assert server._parse_iso("x") is None
    assert server._parse_iso(None) is None
    assert server._parse_iso(5) is None


@pytest.mark.skipif(sys.platform != "win32", reason="GetProcessTimes solo en Windows")
def test_process_start_time_real():
    antes = datetime.now(timezone.utc)
    proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(5)"])
    try:
        despues = datetime.now(timezone.utc)
        t = server.process_start_time(proc.pid)
        assert t is not None
        assert antes - timedelta(seconds=2) <= t <= despues + timedelta(seconds=2)
    finally:
        proc.kill()
        proc.wait(10)


# ------------------------------------------------------------ /activity.json

def test_activity_expone_driver_vivo(streams, start):
    run = start(driver_pid=os.getpid())
    _, _, view = get_activity(run)
    assert view["driver"] == {"alive": True, "reason": None}


def test_activity_driver_muerto_expone_motivo(streams, start):
    proc = subprocess.Popen([sys.executable, "-c", "pass"])
    proc.wait(10)
    run = start(driver_pid=proc.pid)
    _, _, view = get_activity(run)
    assert view["driver"] == {"alive": False, "reason": "pid_muerto"}
    assert view["session"]["live"] is False


def test_activity_no_disponible_tambien_expone_driver(env, streams, start):
    write_status(env, current=None, history=[])
    run = start(driver_pid=os.getpid())
    _, _, view = get_activity(run)
    assert view["available"] is False
    assert view["driver"]["alive"] is True


def test_activity_heartbeat_vencido_apaga_live(env, streams, start):
    viejo = datetime.now(timezone.utc) - timedelta(minutes=10)
    data = {"globalStatus": "RUNNING",
            "currentSession": {"iter": 4, "streamFile": STREAM_4},
            "history": [],
            "driver": {"pid": os.getpid(), "heartbeatAt": _iso(viejo), "heartbeatSeconds": 30}}
    env["status"].write_text(json.dumps(data), encoding="utf-8")
    run = start()
    _, _, view = get_activity(run)
    assert view["driver"]["reason"] == "heartbeat_vencido"
    assert view["session"]["live"] is False


# ---------------------------------------------------------------------- run

def test_run_se_apaga_con_heartbeat_vencido(env, start):
    viejo = datetime.now(timezone.utc) - timedelta(minutes=10)
    _write_running_status(env, pid=os.getpid(), heartbeatAt=_iso(viejo), heartbeatSeconds=30)
    run = start(idle_minutes=1, pid_alive=lambda p: True)
    _advance_until_dead(run, 61)
    assert run.result == [0]


def test_run_no_se_apaga_con_heartbeat_fresco(env, start):
    _write_running_status(env, pid=os.getpid(), heartbeatAt=_iso(datetime.now(timezone.utc)),
                          heartbeatSeconds=30)
    run = start(idle_minutes=1, pid_alive=lambda p: True)
    run.clock[0] += 10 * 3600
    time.sleep(0.2)
    assert run.thread.is_alive()
    env["status"].write_text('{"globalStatus":"DONE"}', encoding="utf-8")
    _advance_until_dead(run, 120)
