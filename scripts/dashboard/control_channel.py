"""Canal de control del dashboard: validacion de ordenes y escritura de .driver-control.json.

Modulo puro (solo biblioteca estandar, sin HTTP): server.py solo despacha. El servidor
nunca ejecuta la orden; la deja en un archivo y el driver la lee y responde en control.last.
Acciones: pause, resume, stop, set-params y, desde 2c, answer, retry y open.
"""
import json
import math
import os
import re
import time
import unicodedata
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

CONTROL_FILE = ".driver-control.json"
CONTROL_ACTIONS = ("pause", "resume", "stop", "set-params", "answer", "retry", "open")
ROUTE_RE = re.compile(r"/control/(pause|resume|stop|set-params|answer|retry|open)")  # siempre fullmatch
BODY_MAX = 16384
TOKEN_RE = re.compile(r"[0-9a-f]{64}")  # fullmatch (nunca $, que acepta un salto de linea final)
MODEL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9.\-\[\]]{0,63}")  # fullmatch
EFFORTS = ("low", "medium", "high", "xhigh", "max")
INT_RANGES = {"maxTransientRetries": (0, 5), "retryBackoffSeconds": (10, 3600),
              "livenessTimeoutMinutes": (5, 240), "awaitDecisionMinutes": (0, 1440)}
COST_RANGE = (0, 1000)
SET_PARAMS_KEYS = ("model", "levelEffort", "closeEffort", "maxTransientRetries",
                   "retryBackoffSeconds", "livenessTimeoutMinutes", "maxCostUsd",
                   "awaitDecisionMinutes")
ANSWER_MAX = 4000  # unidades UTF-16, como String.length en JS y [string].Length en .NET
RETRY_MODES = ("session", "level")
OPEN_TARGETS = ("folder", "log", "terminal")
ITER_RANGE = (1, 100000)
# controles bidireccionales (U+202A-202E y U+2066-2069): permiten disfrazar el texto de la respuesta
BIDI_CONTROLS = frozenset(chr(c) for c in (*range(0x202A, 0x202F), *range(0x2066, 0x206A)))
# (requeridas, opcionales) de las acciones con parametros que no son set-params
ACTION_KEYS = {"answer": (("text",), ()), "retry": (("mode",), ()),
               "open": (("target",), ("iter",))}
RETRIES = 3
RETRY_DELAY = 0.05


def _retry(fn: Callable, exceptions: tuple, retries: int, delay: float):
    """Ejecuta fn; ante `exceptions` reintenta hasta `retries` veces y propaga la ultima."""
    for attempt in range(retries + 1):
        try:
            return fn()
        except exceptions:
            if attempt == retries:
                raise
            time.sleep(delay)


def parse_token(value) -> str | None:
    """El token del driver (64 hex en minusculas); cualquier otro valor deja el canal deshabilitado."""
    if isinstance(value, str) and TOKEN_RE.fullmatch(value):
        return value
    return None


def _is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _value_ok(key: str, value) -> bool:
    if key == "model":
        return isinstance(value, str) and MODEL_RE.fullmatch(value) is not None
    if key in ("levelEffort", "closeEffort"):
        return isinstance(value, str) and value in EFFORTS
    if key in INT_RANGES:
        lo, hi = INT_RANGES[key]
        return _is_int(value) and lo <= value <= hi
    if key == "maxCostUsd":
        if not (_is_int(value) or isinstance(value, float)):
            return False
        try:
            return math.isfinite(value) and COST_RANGE[0] <= value <= COST_RANGE[1]
        except OverflowError:  # un entero enorme no cabe en un float: es invalido, no un fallo
            return False
    return False


def answer_text_ok(text) -> bool:
    """Texto de una respuesta al driver: no vacio, <= ANSWER_MAX unidades UTF-16 y sin controles."""
    if not isinstance(text, str):
        return False
    # primero los surrogates sueltos: encode los rechazaria con una excepcion
    if any("\ud800" <= ch <= "\udfff" for ch in text):
        return False
    if text.strip() == "":
        return False
    if len(text.encode("utf-16-le")) // 2 > ANSWER_MAX:
        return False
    for ch in text:
        if unicodedata.category(ch) == "Cc" and ch not in "\t\n\r":
            return False
        if ch in BIDI_CONTROLS:
            return False
    return "PLAN_STATUS" not in text.upper()


def _action_value_ok(key: str, value) -> bool:
    if key == "text":
        return answer_text_ok(value)
    if key == "mode":
        return isinstance(value, str) and value in RETRY_MODES
    if key == "target":
        return isinstance(value, str) and value in OPEN_TARGETS
    if key == "iter":
        return _is_int(value) and ITER_RANGE[0] <= value <= ITER_RANGE[1]
    return False


def validate_control(action: str, body) -> tuple[dict | None, dict | None]:
    """(params, None) si la orden es valida; (None, error) si no. No mira el estado del driver."""
    if not isinstance(body, dict):
        return None, {"error": "cuerpo invalido", "field": None}
    if action in ACTION_KEYS:
        required, optional = ACTION_KEYS[action]
        for key, value in body.items():
            if key not in required + optional:
                return None, {"error": "parametro no permitido", "field": key}
            if not _action_value_ok(key, value):
                return None, {"error": "parametro invalido", "field": key}
        for key in required:
            if key not in body:
                return None, {"error": "parametro invalido", "field": key}
        return dict(body), None
    if action != "set-params":
        for key in body:
            return None, {"error": "parametro no permitido", "field": key}
        return {}, None
    for key, value in body.items():
        if key not in SET_PARAMS_KEYS:
            return None, {"error": "parametro no permitido", "field": key}
        if not _value_ok(key, value):
            return None, {"error": "parametro invalido", "field": key}
    if not body:
        return None, {"error": "set-params sin parametros", "field": None}
    return dict(body), None


def pending_id(folder: Path) -> tuple[bool, str | None]:
    """(existe, id) de la orden pendiente; id es None si el archivo no se puede leer."""
    path = Path(folder) / CONTROL_FILE
    if not path.exists():
        return False, None
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError:  # el driver la consumio entre exists() y la lectura
        return False, None
    except (OSError, ValueError):
        return True, None
    order_id = data.get("id") if isinstance(data, dict) else None
    return True, order_id if isinstance(order_id, str) else None


def write_control(folder: Path, action: str, params: dict, now: datetime | None = None) -> str:
    """Escribe la orden con .tmp + os.replace y devuelve su id. Ante un fallo borra el .tmp."""
    data = {"id": str(uuid.uuid4()), "action": action, "params": params,
            "requestedAt": (now or datetime.now(timezone.utc)).isoformat()}
    folder = Path(folder)
    path = folder / CONTROL_FILE
    tmp = folder / (CONTROL_FILE + ".tmp")
    try:
        tmp.write_text(json.dumps(data), encoding="utf-8")
        _retry(lambda: os.replace(tmp, path), (PermissionError,), RETRIES, RETRY_DELAY)
    except Exception:
        try:  # no dejar el .tmp huerfano; el error original se propaga igual
            tmp.unlink()
        except OSError:
            pass
        raise
    return data["id"]
