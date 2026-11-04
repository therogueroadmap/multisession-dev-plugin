"""Tests de final_review.py y de GET /final-review.json (Ola 2a, Task 2)."""
import http.client
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "dashboard"))

import final_review  # noqa: E402
# Fixtures y utilidades del servidor base: se reusan, no se duplican.
from test_server import env, http_request, occupied_port, start  # noqa: E402,F401

TABLA_REAL = """## Findings

| # | Severidad | Ubicación | Descripción | Escenario de fallo | Fix sugerido | Estado |
|---|---|---|---|---|---|---|
| 1 | MINOR | `scripts/plan-session-driver.ps1` | La guarda `$killedOk` solo mira el proceso principal. | x | y | Plausible. |
| 2 | MINOR | `scripts/plan-session-driver.ps1` | La espera del backoff ocurre **antes** de decidir. | x | y | Confirmado. |
| 3 | MINOR (cobertura) | `tests/PlanSessionDriver.Tests.ps1` | Ningún test comprueba que se restaure el `reason`. | x | y | Confirmado. |
| 4 | Riesgo abierto (no es un defecto del código) | `assets/dashboard.html` | El paso Q no se ejecutó. | x | y | Pendiente. |
"""

FORMATO_CIERRE = """**Veredicto:** Aprobado con observaciones

| # | Severidad | Ubicación | Descripción | Fix sugerido |
|---|---|---|---|---|
| 1 | CRITICAL | a.py | primero | f1 |
| 2 | **IMPORTANT** | b.py | segundo | f2 |
| 3 | MINOR | c.py | tercero | f3 |
"""

VACIO = {"CRITICAL": 0, "IMPORTANT": 0, "MINOR": 0}


# ---------------------------------------------------------------- parser

def test_tabla_real_cuenta_severidades_con_sufijo_y_descarta_otras():
    res = final_review.parse_final_review(TABLA_REAL)
    assert res["counts"] == {"CRITICAL": 0, "IMPORTANT": 0, "MINOR": 3}
    assert len(res["findings"]) == 3
    assert all(f["severity"] == "MINOR" for f in res["findings"])
    assert res["findings"][0]["title"] == "La guarda `$killedOk` solo mira el proceso principal."
    assert res["verdict"] is None


def test_formato_del_prompt_de_cierre():
    res = final_review.parse_final_review(FORMATO_CIERRE)
    assert res["verdict"] == "Aprobado con observaciones"
    assert res["counts"] == {"CRITICAL": 1, "IMPORTANT": 1, "MINOR": 1}
    assert [f["severity"] for f in res["findings"]] == ["CRITICAL", "IMPORTANT", "MINOR"]
    assert [f["title"] for f in res["findings"]] == ["primero", "segundo", "tercero"]


def test_encabezados_numerados_sin_tabla_y_veredicto_en_el_encabezado():
    texto = ("## Veredicto: PASS con observaciones\n\n"
             "### 1. MINOR. Un heartbeat vencido detiene el polling\n\ntexto\n\n"
             "### 2. IMPORTANT. Otro\n\ntexto\n")
    res = final_review.parse_final_review(texto)
    assert res["verdict"] == "PASS con observaciones"
    assert res["counts"] == {"CRITICAL": 0, "IMPORTANT": 1, "MINOR": 1}
    assert res["findings"][0] == {"severity": "MINOR",
                                  "title": "Un heartbeat vencido detiene el polling"}


def test_veredicto_es_el_primer_parrafo_bajo_el_encabezado():
    texto = ("## Veredicto\n\n"
             "**APROBADO CON OBSERVACIONES.** No hay findings\n"
             "CRITICAL ni IMPORTANT.\n\n"
             "Otro párrafo.\n")
    res = final_review.parse_final_review(texto)
    assert res["verdict"] == "**APROBADO CON OBSERVACIONES.** No hay findings CRITICAL ni IMPORTANT."


def test_sin_estructura_solo_raw():
    res = final_review.parse_final_review(
        "# Revisión\n\n**F1 — IMPORTANT — server.py:337** texto libre")
    assert res["counts"] is None
    assert res["findings"] == []
    assert res["verdict"] is None


def test_tabla_vacia_cuenta_ceros():
    res = final_review.parse_final_review("| # | Severidad | Ubicación | Descripción |\n|---|---|---|---|\n")
    assert res["counts"] == VACIO
    assert res["findings"] == []


def test_severidad_en_minusculas_no_cuenta():
    texto = ("| # | Severidad | Ubicación | Descripción |\n|---|---|---|---|\n"
             "| 1 | minor | a | b |\n"
             "| 2 | **CRITICAL** | a | b |\n")
    res = final_review.parse_final_review(texto)
    assert res["counts"]["MINOR"] == 0
    assert res["counts"]["CRITICAL"] == 1


def test_review_file_name():
    assert final_review.review_file_name(
        {"phase": {"finalReviewFile": ".final-review-x.md"}, "planFile": "C:\\a\\b.md"}
    ) == ".final-review-x.md"
    assert final_review.review_file_name(
        {"planFile": "C:\\x\\docs\\superpowers\\plans\\2026-10-27-falso.md"}
    ) == ".final-review-2026-10-27-falso.md"
    assert final_review.review_file_name(
        {"planFile": "docs/plans/plan.v2.md"}) == ".final-review-plan.v2.md"
    assert final_review.review_file_name({}) is None


# ---------------------------------------------------------------- load_final_review y endpoint

def _get(port, path="/final-review.json"):
    code, headers, body = http_request(port, path)
    return code, headers, json.loads(body)


def test_endpoint_inexistente(env, start):
    env["status"].write_text(json.dumps({"globalStatus": "RUNNING", "planFile": "C:\\x\\p.md"}),
                             encoding="utf-8")
    run = start()
    code, headers, data = _get(run.port)
    assert code == 200
    assert data == {"exists": False}
    assert headers["Cache-Control"] == "no-store"


def test_endpoint_desde_phase(env, start):
    env["status"].write_text(json.dumps({"phase": {"finalReviewFile": ".final-review-p.md"}}),
                             encoding="utf-8")
    (env["tmp"] / ".final-review-p.md").write_bytes(FORMATO_CIERRE.encode("utf-8"))
    run = start()
    code, _, data = _get(run.port)
    assert code == 200
    assert data["exists"] is True
    assert data["verdict"] == "Aprobado con observaciones"
    assert data["counts"] == {"CRITICAL": 1, "IMPORTANT": 1, "MINOR": 1}
    assert data["raw"] == FORMATO_CIERRE


def test_endpoint_nombre_invalido_no_sale_de_la_carpeta(env, start):
    carpeta = env["tmp"] / "sub"
    carpeta.mkdir()
    status = carpeta / "status.json"
    status.write_text("{}", encoding="utf-8")
    env["status"] = status
    (env["tmp"] / "secreto.md").write_text("secreto", encoding="utf-8")
    run = start()
    for nombre in ("../secreto.md", ".final-review-x.md/../../secreto.md", ".final-review-a b.md"):
        status.write_text(json.dumps({"phase": {"finalReviewFile": nombre}}), encoding="utf-8")
        code, _, data = _get(run.port)
        assert code == 200, nombre
        assert data == {"exists": False}, nombre


def test_raw_truncado_y_parse_completo(env, start):
    env["status"].write_text(json.dumps({"phase": {"finalReviewFile": ".final-review-p.md"}}),
                             encoding="utf-8")
    texto = ("texto ñ\n" * 12000
             + "\n| # | Severidad | Ubicación | Descripción |\n|---|---|---|---|\n"
             + "| 1 | CRITICAL | a | tarde |\n")
    (env["tmp"] / ".final-review-p.md").write_text(texto, encoding="utf-8")
    assert len(texto.encode("utf-8")) > 65536 + 1000
    run = start()
    code, _, data = _get(run.port)
    assert code == 200
    assert len(data["raw"].encode("utf-8")) <= 65536
    assert data["counts"]["CRITICAL"] == 1


def test_endpoint_status_ilegible_503_y_sin_status(env, start):
    env["status"].write_text("{roto", encoding="utf-8")
    run = start()
    code, _, data = _get(run.port)
    assert code == 503
    assert data == {"error": "status no disponible"}
    env["status"].write_text("{}", encoding="utf-8")
    code, _, data = _get(run.port)
    assert code == 200
    assert data == {"exists": False}


def test_endpoint_host_ajeno_403(start):
    run = start()
    conn = http.client.HTTPConnection("127.0.0.1", run.port, timeout=5)
    try:
        conn.putrequest("GET", "/final-review.json", skip_host=True)
        conn.putheader("Host", f"evil.example:{run.port}")
        conn.endheaders()
        assert conn.getresponse().status == 403
    finally:
        conn.close()


def test_endpoint_error_de_lectura_503(env, start):
    env["status"].write_text(json.dumps({"phase": {"finalReviewFile": ".final-review-p.md"}}),
                             encoding="utf-8")
    (env["tmp"] / ".final-review-p.md").mkdir()
    run = start()
    code, _, data = _get(run.port)
    assert code == 503
    assert data == {"error": "revision final no disponible"}


def test_tabla_de_resumen_ignorada():
    res = final_review.parse_final_review(
        "| Severidad | Cantidad |\n|---|---|\n| CRITICAL | 0 |\n| MINOR | 3 |\n")
    assert res["counts"] is None
    assert res["findings"] == []
    assert res["verdict"] is None


def test_findings_y_veredicto_acotados_counts_completo(tmp_path):
    filas = "".join(f"| {n} | MINOR | a | b |\n" for n in range(250))
    texto = ("**Veredicto:** " + "x" * 600 + "\n\n"
             "| # | Severidad | Ubicación | Descripción |\n|---|---|---|---|\n" + filas)
    (tmp_path / ".final-review-p.md").write_text(texto, encoding="utf-8")
    data = final_review.load_final_review(
        tmp_path, {"phase": {"finalReviewFile": ".final-review-p.md"}})
    assert data["counts"]["MINOR"] == 250
    assert len(data["findings"]) == 200
    assert len(data["verdict"]) == 500


def test_nombre_con_acentos_desde_phase(env, start):
    nombre = ".final-review-2026-10-27-diseño-ñandú.md"
    env["status"].write_text(json.dumps({"phase": {"finalReviewFile": nombre}}),
                             encoding="utf-8")
    (env["tmp"] / nombre).write_bytes(FORMATO_CIERRE.encode("utf-8"))
    run = start()
    code, _, data = _get(run.port)
    assert code == 200
    assert data["exists"] is True
    assert data["counts"] == {"CRITICAL": 1, "IMPORTANT": 1, "MINOR": 1}


def test_nombre_con_acentos_desde_planfile_y_rutas_siguen_rechazadas(tmp_path):
    (tmp_path / ".final-review-2026-10-27-acción.md").write_bytes(FORMATO_CIERRE.encode("utf-8"))
    data = final_review.load_final_review(tmp_path, {"planFile": "docs/plans/2026-10-27-acción.md"})
    assert data["exists"] is True
    for nombre in ("../x.md", ".final-review-a/b.md", ".final-review-a b.md",
                   ".final-review-á\n.md"):
        data = final_review.load_final_review(tmp_path, {"phase": {"finalReviewFile": nombre}})
        assert data == {"exists": False}, nombre
