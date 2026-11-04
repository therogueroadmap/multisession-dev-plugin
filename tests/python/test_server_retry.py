"""Tests de los nombres de reintento (session-N-rK-<sello>) en server.py (Ola 1b, D1)."""
import json

import server
# Fixtures y utilidades del servidor base: se reusan, no se duplican.
from test_server import env, http_request, occupied_port, start  # noqa: F401

STREAM_ORIG = "session-1-20261027-101010.stream.jsonl"
STREAM_R1 = "session-1-r1-20261027-101111.stream.jsonl"


def test_nombres_de_reintento_en_la_lista_blanca():
    for nombre in ("session-3-r1-20261027-101010.log",
                   "session-3-r12-20261027-101010.err.log",
                   "session-1-20261021-141941.log"):
        assert server.LOG_NAME_RE.fullmatch(nombre) is not None, nombre
    assert server.STREAM_NAME_RE.fullmatch("session-3-r1-20261027-101010.stream.jsonl") is not None
    for nombre in ("session-3-r1.log",
                   "session-3-r-20261027-101010.log",
                   "session-3-rx-20261027-101010.log",
                   "session-3-r1-20261027-101010.log\n",
                   "session-3-r1-20261027-101010.txt"):
        assert server.LOG_NAME_RE.fullmatch(nombre) is None, nombre
        assert server.STREAM_NAME_RE.fullmatch(nombre) is None, nombre


def test_logs_sirve_el_log_de_un_reintento(env, start):
    nombre = "session-2-r1-20261027-101010.log"
    (env["logs"] / nombre).write_bytes(b"reintento\n")
    run = start()
    code, _, body = http_request(run.port, "/logs/" + nombre)
    assert code == 200
    assert body == b"reintento\n"


def test_activity_toma_el_ultimo_intento_y_tolera_claves_nuevas(env, fixture_path, start):
    raw = fixture_path.read_bytes()
    (env["logs"] / STREAM_ORIG).write_bytes(raw)
    (env["logs"] / STREAM_R1).write_bytes(raw)
    data = {
        "globalStatus": "FAILED",
        "currentSession": None,
        "history": [
            {"iter": 1, "streamFile": STREAM_ORIG, "attempt": 0},
            {"iter": 1, "streamFile": STREAM_R1, "attempt": 1, "failureKind": "transient",
             "failureMatch": "http_5xx", "resumedSessionId": "id-1",
             "priorCause": "exit_no_cero", "transientRetries": 1},
        ],
        "notification": {"sentAt": "2026-10-27T23:00:00.0000000-04:00", "toast": "ok",
                         "webhook": "omitido", "webhookHost": None},
    }
    env["status"].write_text(json.dumps(data), encoding="utf-8")
    run = start()
    code, _, body = http_request(run.port, "/activity.json?session=1")
    assert code == 200
    view = json.loads(body.decode("utf-8"))
    assert view["session"]["streamFile"] == STREAM_R1
    code, _, _ = http_request(run.port, "/status.json")
    assert code == 200
