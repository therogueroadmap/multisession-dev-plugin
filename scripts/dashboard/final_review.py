"""Lectura y parseo defensivo de la revision final (.final-review-<plan>.md), biblioteca estandar.

El parser no asume un formato unico: reconoce tablas con columna Severidad y
encabezados "### N. SEVERIDAD. titulo"; sin estructura reconocible solo
devuelve el texto crudo. Las funciones son puras salvo load_final_review.
"""
import re
from pathlib import Path

SEVERITIES = ("CRITICAL", "IMPORTANT", "MINOR")
# Siempre con fullmatch (nunca con $, que acepta un salto de linea final).
NAME_RE = re.compile(r"\.final-review-[\w.\-]+\.md")
RAW_MAX = 65536        # bytes de raw
READ_MAX = 1 << 20     # bytes que se leen y se parsean
TITLE_MAX = 200        # caracteres de title
FINDINGS_MAX = 200     # entradas de findings
VERDICT_MAX = 500      # caracteres de verdict

_SEV_RE = re.compile(r"(CRITICAL|IMPORTANT|MINOR)\b")
_HEADING_RE = re.compile(r"###\s+\d+\.\s+(CRITICAL|IMPORTANT|MINOR)\.\s+(.+?)\s*$")
_VERDICT_HEADING_RE = re.compile(r"##\s+Veredicto\b\s*:?\s*(.*)$")
_VERDICT_PREFIX = "**Veredicto:**"
_LOCATION_NAMES = ("ubicación", "ubicacion", "descripción", "descripcion")
_DESCRIPTION_NAMES = ("descripción", "descripcion")


def _is_row(line: str) -> bool:
    return len(line) >= 2 and line.startswith("|") and line.endswith("|")


def _cells(line: str) -> list[str]:
    return [c.strip().strip("*`").strip() for c in line[1:-1].split("|")]


def _is_separator(line: str) -> bool:
    return all(ch in "|-: " for ch in line)


def _parse_tables(lines: list[str]) -> tuple[bool, list[dict]]:
    """(hay_encabezado_valido, findings) de las filas de tabla."""
    found_header = False
    findings: list[dict] = []
    in_table = False
    sev_col = title_col = None
    for raw_line in lines:
        line = raw_line.strip()
        if not _is_row(line):
            in_table = False
            sev_col = title_col = None
            continue
        if _is_separator(line):
            continue
        cells = _cells(line)
        if not in_table:
            in_table = True
            lowered = [c.lower() for c in cells]
            if "severidad" in lowered and any(n in lowered for n in _LOCATION_NAMES):
                found_header = True
                sev_col = lowered.index("severidad")
                title_col = next((i for i, c in enumerate(lowered) if c in _DESCRIPTION_NAMES), None)
            continue
        if sev_col is None or sev_col >= len(cells):
            continue
        m = _SEV_RE.match(cells[sev_col])
        if m is None:
            continue
        title = ""
        if title_col is not None and title_col < len(cells):
            title = cells[title_col]
        if not title and sev_col + 1 < len(cells):
            title = cells[sev_col + 1]
        findings.append({"severity": m.group(1), "title": title[:TITLE_MAX]})
    return found_header, findings


def _parse_headings(lines: list[str]) -> list[dict]:
    findings = []
    for line in lines:
        m = _HEADING_RE.match(line)
        if m is not None:
            findings.append({"severity": m.group(1), "title": m.group(2)[:TITLE_MAX]})
    return findings


def _parse_verdict(lines: list[str]) -> str | None:
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(_VERDICT_PREFIX):
            rest = stripped[len(_VERDICT_PREFIX):].strip()
            if rest:
                return rest
    for i, line in enumerate(lines):
        m = _VERDICT_HEADING_RE.match(line.strip())
        if m is None:
            continue
        rest = m.group(1).strip()
        if rest:
            return rest
        paragraph: list[str] = []
        for nxt in lines[i + 1:]:
            nxt = nxt.strip()
            if nxt.startswith("#"):
                break
            if not nxt:
                if paragraph:
                    break
                continue
            paragraph.append(nxt)
        if paragraph:
            return " ".join(paragraph)
    return None


def _counts(findings: list[dict]) -> dict:
    counts = {sev: 0 for sev in SEVERITIES}
    for f in findings:
        counts[f["severity"]] += 1
    return counts


def parse_final_review(text: str) -> dict:
    lines = text.splitlines()
    found_header, findings = _parse_tables(lines)
    counts = None
    if found_header:
        counts = _counts(findings)
    else:
        findings = _parse_headings(lines)
        if findings:
            counts = _counts(findings)
    return {"verdict": _parse_verdict(lines), "counts": counts, "findings": findings}


def review_file_name(status: dict) -> str | None:
    """Nombre del archivo de revision segun el status. No valida: lo hace load_final_review."""
    phase = status.get("phase")
    if isinstance(phase, dict):
        name = phase.get("finalReviewFile")
        if isinstance(name, str) and name:
            return name
    plan = status.get("planFile")
    if isinstance(plan, str) and plan:
        leaf = re.split(r"[/\\]", plan)[-1]
        if leaf.endswith(".md"):
            leaf = leaf[:-len(".md")]
        return ".final-review-" + leaf + ".md"
    return None


def load_final_review(folder: Path, status: dict) -> dict:
    """Lee la revision final dentro de folder. Un OSError distinto de 'no existe' se propaga."""
    name = review_file_name(status)
    if name is None or NAME_RE.fullmatch(name) is None:
        return {"exists": False}
    try:
        with open(folder / name, "rb") as fh:
            data = fh.read(READ_MAX)
    except FileNotFoundError:
        return {"exists": False}
    text = data.decode("utf-8-sig", errors="replace")
    raw = data[:RAW_MAX].decode("utf-8-sig", errors="ignore")
    parsed = parse_final_review(text)
    verdict = parsed["verdict"]
    if verdict is not None:
        verdict = verdict[:VERDICT_MAX]
    return {"exists": True, "verdict": verdict, "counts": parsed["counts"],
            "findings": parsed["findings"][:FINDINGS_MAX], "raw": raw}
