"""Valida el fixture recortado del stream real (tests/fixtures/stream-dashboard-ola1.jsonl)."""
import importlib.util
import json
import re
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "fixtures" / "build_stream_fixture.py"

# Fuente sintetica minima: solo task_started local_bash, sin ningun local_agent.
FUENTE_SIN_AGENTE = (
    b'{"type":"system","subtype":"init","session_id":"s1","model":"m"}\n'
    b'{"type":"system","subtype":"task_started","task_id":"b1","run_id":"r1",'
    b'"description":"ls","task_type":"local_bash"}\n'
)

# Igual que la anterior, mas un task_started local_agent para superar el chequeo de fuente.
FUENTE_CON_AGENTE = FUENTE_SIN_AGENTE + (
    b'{"type":"system","subtype":"task_started","task_id":"a1","run_id":"r1",'
    b'"description":"Spec review T1","task_type":"local_agent"}\n'
)


def _cargar_script():
    """Importa build_stream_fixture.py como modulo para llamar a main(argv)."""
    spec = importlib.util.spec_from_file_location("build_stream_fixture", SCRIPT)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo


def _bytes(fixture_path):
    return fixture_path.read_bytes()


def _lineas_json(fixture_path):
    """Lineas completas parseables; las invalidas o a medias se descartan."""
    salida = []
    for linea in _bytes(fixture_path).split(b"\n")[:-1]:
        try:
            salida.append(json.loads(linea))
        except ValueError:
            pass
    return salida


def test_fixture_es_chico(fixture_path):
    assert len(_bytes(fixture_path)) < 80 * 1024


def test_fixture_termina_a_medias(fixture_path):
    datos = _bytes(fixture_path)
    assert not datos.endswith(b"\n")
    ultima = datos.split(b"\n")[-1]
    assert ultima.startswith(b'{"type":"system","subtype":"task_updated","task_id":"syn-t9"')


def test_fixture_tiene_los_nueve_local_agent_reales(fixture_path):
    agentes = [o for o in _lineas_json(fixture_path)
               if o.get("subtype") == "task_started" and o.get("task_type") == "local_agent"
               and str(o.get("task_id", "")).startswith("a")]
    assert len(agentes) == 9


def test_fixture_tiene_ruido_local_bash(fixture_path):
    bash = [o for o in _lineas_json(fixture_path)
            if o.get("subtype") == "task_started" and o.get("task_type") == "local_bash"]
    assert len(bash) == 3


def test_fixture_tiene_cuota_commit_y_heartbeat(fixture_path):
    lineas = _lineas_json(fixture_path)
    assert len([o for o in lineas if o.get("type") == "rate_limit_event"]) == 1
    assert len([o for o in lineas if o.get("subtype") == "vcs_state_changed"]) == 1
    assert len([o for o in lineas if o.get("type") == "tool_progress"]) == 1


def test_fixture_tiene_byte_invalido(fixture_path):
    assert b"Revisi\xe9n" in _bytes(fixture_path)


def test_fixture_conserva_fffd_real(fixture_path):
    assert "invitaci\ufffdn".encode() in _bytes(fixture_path)


def test_fixture_sin_prompts(fixture_path):
    assert b'"prompt":' not in _bytes(fixture_path)


def test_fixture_anonimizado(fixture_path):
    datos = _bytes(fixture_path)
    assert b"D:\\\\TRABAJO" not in datos
    assert b"feature/DEMO-1" in datos


def _terminos_privados(ruta_reglas):
    """Valores reales a prohibir segun el formato documentado en build_stream_fixture.py."""
    datos = json.loads(Path(ruta_reglas).read_text(encoding="utf-8"))
    terminos = [datos.get("branch", "")] + [par[0] for par in datos.get("substitutions", [])]
    return [t.encode("utf-8") for t in terminos if t]


def _terminos_presentes(contenido, ruta_reglas):
    """Literales de branch/substitutions presentes, mas la primera coincidencia de path_regex si la hay."""
    presentes = [t for t in _terminos_privados(ruta_reglas) if t in contenido]
    patron = json.loads(Path(ruta_reglas).read_text(encoding="utf-8")).get("path_regex")
    if patron:
        coincidencia = re.search(patron.encode("utf-8"), contenido)
        if coincidencia:
            presentes.append(coincidencia.group(0))
    return presentes


def test_fixture_sin_terminos_privados(fixture_path):
    modulo = _cargar_script()
    if not Path(modulo.REGLAS_LOCALES).exists():
        pytest.skip("no existe anonymize-rules.local.json")
    assert _terminos_presentes(_bytes(fixture_path), modulo.REGLAS_LOCALES) == []


def test_deteccion_de_terminos_privados(tmp_path):
    reglas = tmp_path / "reglas.json"
    reglas.write_text(json.dumps({"branch": "rama-de-prueba",
                                  "substitutions": [["termino-de-prueba", "neutro"]]}),
                      encoding="utf-8")
    assert _terminos_presentes(b"x termino-de-prueba y", reglas) == [b"termino-de-prueba"]
    assert _terminos_presentes(b"x rama-de-prueba y", reglas) == [b"rama-de-prueba"]
    assert _terminos_presentes(b"solo neutro", reglas) == []


def test_main_sin_reglas_falla_y_no_escribe(tmp_path, monkeypatch, capsys):
    modulo = _cargar_script()
    monkeypatch.setattr(modulo, "REGLAS_LOCALES", str(tmp_path / "no-existe.json"))
    fuente = tmp_path / "fuente.jsonl"
    fuente.write_bytes(FUENTE_CON_AGENTE)
    salida = tmp_path / "salida.jsonl"

    assert modulo.main(["--source", str(fuente), "--out", str(salida)]) != 0
    assert not salida.exists()
    err = capsys.readouterr().err
    assert "no-existe.json" in err and "path_regex" in err


def test_main_con_flag_sin_reglas_genera_y_avisa(tmp_path, monkeypatch, capsys):
    modulo = _cargar_script()
    monkeypatch.setattr(modulo, "REGLAS_LOCALES", str(tmp_path / "no-existe.json"))
    fuente = tmp_path / "fuente.jsonl"
    fuente.write_bytes(FUENTE_CON_AGENTE)
    salida = tmp_path / "salida.jsonl"

    assert modulo.main(["--source", str(fuente), "--out", str(salida), "--sin-reglas"]) == 0
    assert salida.exists()
    assert "AVISO" in capsys.readouterr().err


def test_main_devuelve_1_si_supera_el_limite(tmp_path, monkeypatch, capsys):
    modulo = _cargar_script()
    monkeypatch.setattr(modulo, "LIMITE_BYTES", 100)
    fuente = tmp_path / "fuente.jsonl"
    fuente.write_bytes(FUENTE_CON_AGENTE)
    salida = tmp_path / "salida.jsonl"

    assert modulo.main(["--source", str(fuente), "--out", str(salida), "--sin-reglas"]) == 1
    assert not salida.exists()
    assert "limite" in capsys.readouterr().err


def test_main_devuelve_1_sin_local_agent(tmp_path, capsys):
    modulo = _cargar_script()
    fuente = tmp_path / "fuente.jsonl"
    fuente.write_bytes(FUENTE_SIN_AGENTE)
    salida = tmp_path / "salida.jsonl"

    assert modulo.main(["--source", str(fuente), "--out", str(salida), "--sin-reglas"]) == 1
    assert not salida.exists()
    assert "local_agent" in capsys.readouterr().err


def test_main_reglas_vacias_devuelve_2_y_no_escribe(tmp_path, monkeypatch, capsys):
    modulo = _cargar_script()
    reglas = tmp_path / "reglas.json"
    reglas.write_text("{}", encoding="utf-8")
    monkeypatch.setattr(modulo, "REGLAS_LOCALES", str(reglas))
    fuente = tmp_path / "fuente.jsonl"
    fuente.write_bytes(FUENTE_CON_AGENTE)
    salida = tmp_path / "salida.jsonl"

    assert modulo.main(["--source", str(fuente), "--out", str(salida)]) == 2
    assert not salida.exists()
    assert "path_regex" in capsys.readouterr().err


def test_deteccion_de_path_regex_ficticio(tmp_path):
    reglas = tmp_path / "reglas.json"
    reglas.write_text(json.dumps({"path_regex": r"D:/FICTICIO/[a-z]+"}), encoding="utf-8")
    assert _terminos_presentes(b"ruta D:/FICTICIO/proyecto fin", reglas) == [b"D:/FICTICIO/proyecto"]
    assert _terminos_presentes(b"solo neutro", reglas) == []
