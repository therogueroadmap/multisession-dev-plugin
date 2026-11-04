"""Base de pytest del dashboard: ruta de los modulos y fixture del stream recortado."""
import sys
from pathlib import Path

import pytest

RAIZ = Path(__file__).resolve().parents[2]

# Los modulos viven en scripts/dashboard y no son un paquete: se importan por nombre.
sys.path.insert(0, str(RAIZ / "scripts" / "dashboard"))


@pytest.fixture
def fixture_path():
    """Ruta al stream real recortado y anonimizado (ver tests/fixtures/build_stream_fixture.py)."""
    return RAIZ / "tests" / "fixtures" / "stream-dashboard-ola1.jsonl"
