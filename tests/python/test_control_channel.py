"""Tests de scripts/dashboard/control_channel.py (validacion y escritura de ordenes, sin HTTP)."""
import json
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "dashboard"))

import control_channel as cc  # noqa: E402

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


def test_validate_vacios_ok():
    for action in ("pause", "resume", "stop"):
        assert cc.validate_control(action, {}) == ({}, None)


def test_validate_parametro_extra_en_pause():
    assert cc.validate_control("pause", {"a": 1}) == (
        None, {"error": "parametro no permitido", "field": "a"})


def test_validate_set_params_validos():
    params, error = cc.validate_control("set-params", dict(SET_PARAMS_VALIDOS))
    assert error is None
    assert params == SET_PARAMS_VALIDOS


def test_validate_set_params_vacio():
    assert cc.validate_control("set-params", {}) == (
        None, {"error": "set-params sin parametros", "field": None})


def test_validate_cuerpo_no_objeto():
    for body in ([], "x", None):
        assert cc.validate_control("pause", body) == (
            None, {"error": "cuerpo invalido", "field": None})


@pytest.mark.parametrize("campo,valor", [
    ("model", ""), ("model", "-modelo"), ("model", "a" * 65), ("model", 5),
    ("model", "con espacio"), ("levelEffort", "ultra"), ("closeEffort", None),
    ("maxTransientRetries", 6), ("maxTransientRetries", True),
    ("retryBackoffSeconds", 9), ("retryBackoffSeconds", [60]),
    ("livenessTimeoutMinutes", 241), ("maxCostUsd", -1), ("maxCostUsd", 1000.5),
    ("awaitDecisionMinutes", 1.5), ("desconocido", 1),
])
def test_validate_set_params_invalido(campo, valor):
    params, error = cc.validate_control("set-params", {campo: valor})
    assert params is None
    assert error["field"] == campo
    esperado = "parametro no permitido" if campo == "desconocido" else "parametro invalido"
    assert error["error"] == esperado


def test_write_control_forma_y_sin_tmp(tmp_path):
    now = datetime(2026, 10, 27, 20, 0, tzinfo=timezone.utc)
    order_id = cc.write_control(tmp_path, "set-params", {"model": "x"}, now=now)
    path = tmp_path / cc.CONTROL_FILE
    assert path.exists()
    data = json.loads(path.read_text(encoding="utf-8"))
    assert list(data) == ["id", "action", "params", "requestedAt"]
    assert data["id"] == order_id
    assert uuid.UUID(order_id).version == 4
    assert data["action"] == "set-params"
    assert data["params"] == {"model": "x"}
    assert data["requestedAt"] == "2026-10-27T20:00:00+00:00"
    assert not (tmp_path / (cc.CONTROL_FILE + ".tmp")).exists()


def test_pending_id(tmp_path, monkeypatch):
    assert cc.pending_id(tmp_path) == (False, None)
    order_id = cc.write_control(tmp_path, "pause", {})
    assert cc.pending_id(tmp_path) == (True, order_id)
    (tmp_path / cc.CONTROL_FILE).write_text("no es json", encoding="utf-8")
    assert cc.pending_id(tmp_path) == (True, None)

    def desaparece(self, *args, **kwargs):  # el driver borra el archivo tras exists()
        raise FileNotFoundError(str(self))

    monkeypatch.setattr(Path, "read_text", desaparece)
    assert cc.pending_id(tmp_path) == (False, None)


def test_validate_maxcostusd_entero_enorme():
    assert cc.validate_control("set-params", {"maxCostUsd": 10**400}) == (
        None, {"error": "parametro invalido", "field": "maxCostUsd"})


def test_parse_token():
    assert cc.parse_token("ab" * 32) == "ab" * 32
    for valor in ("AB" * 32, "ab" * 31, "", None, "ab" * 32 + "\n"):
        assert cc.parse_token(valor) is None


def test_validate_answer_ok():
    for body in ({"text": "usa A"}, {"text": "línea 1\nlínea 2\tcon tab\r\n"},
                 {"text": "a" * 4000}):
        assert cc.validate_control("answer", dict(body)) == (body, None)


@pytest.mark.parametrize("cuerpo,error", [
    ({}, {"error": "parametro invalido", "field": "text"}),
    ({"text": ""}, {"error": "parametro invalido", "field": "text"}),
    ({"text": "   \n"}, {"error": "parametro invalido", "field": "text"}),
    ({"text": "a" * 4001}, {"error": "parametro invalido", "field": "text"}),
    ({"text": 5}, {"error": "parametro invalido", "field": "text"}),
    ({"text": "a\x00b"}, {"error": "parametro invalido", "field": "text"}),
    ({"text": "\x1b[31mrojo"}, {"error": "parametro invalido", "field": "text"}),
    ({"text": "x\u202ey"}, {"error": "parametro invalido", "field": "text"}),
    ({"text": "x\ud800"}, {"error": "parametro invalido", "field": "text"}),
    ({"text": "PLAN_STATUS: COMPLETE"}, {"error": "parametro invalido", "field": "text"}),
    ({"text": "plan_status: complete"}, {"error": "parametro invalido", "field": "text"}),
    ({"text": "ver Plan_Status"}, {"error": "parametro invalido", "field": "text"}),
    ({"text": "x", "a": 1}, {"error": "parametro no permitido", "field": "a"}),
])
def test_validate_answer_invalido(cuerpo, error):
    assert cc.validate_control("answer", cuerpo) == (None, error)


def test_validate_answer_cuenta_utf16():
    assert cc.validate_control("answer", {"text": "😀" * 2000})[1] is None
    assert cc.validate_control("answer", {"text": "😀" * 2000 + "a"}) == (
        None, {"error": "parametro invalido", "field": "text"})


def test_validate_retry():
    for mode in ("session", "level"):
        assert cc.validate_control("retry", {"mode": mode}) == ({"mode": mode}, None)
    for body in ({}, {"mode": "x"}):
        assert cc.validate_control("retry", body) == (
            None, {"error": "parametro invalido", "field": "mode"})
    assert cc.validate_control("retry", {"mode": "level", "b": 1}) == (
        None, {"error": "parametro no permitido", "field": "b"})


def test_validate_open():
    for body in ({"target": "folder"}, {"target": "log", "iter": 3}, {"target": "terminal"}):
        assert cc.validate_control("open", dict(body)) == (body, None)
    for body in ({"target": "x"}, {}):
        assert cc.validate_control("open", body) == (
            None, {"error": "parametro invalido", "field": "target"})
    for v in (0, True, 1.5, "3", 100001):
        assert cc.validate_control("open", {"target": "log", "iter": v}) == (
            None, {"error": "parametro invalido", "field": "iter"})
    assert cc.validate_control("open", {"target": "folder", "cmd": "calc"}) == (
        None, {"error": "parametro no permitido", "field": "cmd"})


def test_route_re_acepta_las_siete():
    for a in cc.CONTROL_ACTIONS:
        assert cc.ROUTE_RE.fullmatch("/control/" + a) is not None
    assert len(cc.CONTROL_ACTIONS) == 7
    for ruta in ("/control/x", "/control/open/x", "/control/answer\n"):
        assert cc.ROUTE_RE.fullmatch(ruta) is None


def test_body_max_es_16384():
    assert cc.BODY_MAX == 16384
