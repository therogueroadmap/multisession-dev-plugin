"""Genera tests/fixtures/stream-dashboard-ola1.jsonl a partir de un stream real.

Uso:
    python -I tests/fixtures/build_stream_fixture.py --source <stream.jsonl> --out <fixture.jsonl>

Lee el stream real en binario, linea a linea (nunca lo vuelca), selecciona un
subconjunto representativo, lo anonimiza y agrega una cola sintetica con los casos
limite. Es determinista: dos corridas producen bytes identicos.
"""
import argparse
import json
import re
import sys

LIMITE_BYTES = 80 * 1024

RUTA_DEMO = "C:\\repo\\demo"


def compacto(obj):
    """Serializa en JSON compacto conservando los caracteres no ASCII (incluido U+FFFD).

    Un sustituto suelto (surrogate) no es UTF-8 valido: se reemplaza por "?" y no tumba la corrida.
    """
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8", "replace")


def truncar(texto, largo):
    if isinstance(texto, str) and len(texto) > largo:
        return texto[:largo]
    return texto


def nombre_base(ruta):
    return re.split(r"[\\/]", ruta)[-1]


def anonimizar_objeto(obj):
    """Ruta absoluta de output_file -> C:\\repo\\demo\\<nombre base>."""
    if obj.get("output_file"):
        obj["output_file"] = RUTA_DEMO + "\\" + nombre_base(obj["output_file"])
    return obj


# Reglas de anonimizado propias de cada proyecto real. No se versionan: viven en un archivo local
# (por defecto tests/fixtures/anonymize-rules.local.json, ignorado por git) con esta forma:
#   {"path_regex": "<regex sobre la linea serializada; grupo 1 = D:\\ | D:/ | /d/>",
#    "branch": "<rama real>", "substitutions": [["<real>", "<neutro>"], ...]}
# Sin ese archivo main() se niega a generar (salvo --sin-reglas): solo regiria el anonimizado estructural.
REGLAS_LOCALES = __file__.rsplit("build_stream_fixture.py", 1)[0] + "anonymize-rules.local.json"
DESTINO_RUTA = {b"D:\\\\": b"C:\\\\repo\\\\demo", b"D:/": b"C:/repo/demo", b"/d/": b"/c/repo/demo"}
RAMA_DEMO = b"feature/DEMO-1"


def cargar_reglas(ruta=REGLAS_LOCALES):
    # Tolerante a proposito: importar el modulo sin el JSON no debe fallar. Quien genera el fixture
    # (main) exige el archivo o el flag --sin-reglas antes de escribir nada.
    try:
        with open(ruta, encoding="utf-8") as f:
            datos = json.load(f)
    except FileNotFoundError:
        datos = {}
    patron = datos.get("path_regex")
    ruta_real = re.compile(patron.encode("utf-8")) if patron else re.compile(rb"(?!)(D:/|/d/|D:\\\\)")
    rama = datos.get("branch", "").encode("utf-8")
    sustituciones = [(a.encode("utf-8"), b.encode("utf-8")) for a, b in datos.get("substitutions", [])]
    return ruta_real, rama, sustituciones


RUTA_REAL, RAMA_REAL, SUSTITUCIONES = cargar_reglas()


def anonimizar_linea(linea):
    linea = RUTA_REAL.sub(lambda m: DESTINO_RUTA[m.group(1)], linea)
    if RAMA_REAL:
        linea = linea.replace(RAMA_REAL, RAMA_DEMO)
    for original, reemplazo in SUSTITUCIONES:
        linea = linea.replace(original, reemplazo)
    return linea


def anonimizar_texto(texto):
    """Anonimiza un valor de texto antes de truncarlo, para que un corte no deje un fragmento real.

    Serializa el valor, aplica anonimizar_linea sobre los bytes y lo vuelve a leer, asi las barras
    de JSON se tratan igual que en la linea completa.
    """
    if not isinstance(texto, str):
        return texto
    return json.loads(anonimizar_linea(compacto(texto)))


# Letras latinas acentuadas que el fixture degrada a U+FFFD para ejercitar el caso.
LETRAS_ACENTUADAS = "\u00e1\u00e9\u00ed\u00f3\u00fa\u00fc\u00f1\u00c1\u00c9\u00cd\u00d3\u00da\u00dc\u00d1"


def degradar_acentos(obj):
    """Degrada a U+FFFD las letras latinas acentuadas de la descripcion de los eventos system.

    Emula la perdida de acentos que el spec atribuye a la captura del driver (seccion Encoding),
    para que el fixture ejercite ese caso. El stream real trae UTF-8 correcto en estas
    descripciones; los U+FFFD reales estan solo en resultados de herramientas, que el fixture
    descarta. Solo se tocan las letras acentuadas: otros caracteres no ASCII, como los puntos
    suspensivos (U+2026) y la raya (U+2014), se conservan. El prompt del assistant queda intacto.
    """
    desc = obj.get("description")
    if obj.get("type") == "system" and isinstance(desc, str):
        obj["description"] = "".join("\ufffd" if c in LETRAS_ACENTUADAS else c for c in desc)
    return obj


def preparar(obj):
    return degradar_acentos(anonimizar_objeto(obj))


def reducir_assistant_agent(obj):
    bloques = []
    for bloque in obj.get("message", {}).get("content", []):
        if isinstance(bloque, dict) and bloque.get("type") == "tool_use" and bloque.get("name") == "Agent":
            entrada = bloque.get("input", {})
            bloques.append({
                "type": bloque.get("type"),
                "id": bloque.get("id"),
                "name": bloque.get("name"),
                "input": {k: entrada[k] for k in ("description", "subagent_type", "run_in_background") if k in entrada},
            })
    return {
        "type": obj.get("type"),
        "timestamp": obj.get("timestamp"),
        "parent_tool_use_id": obj.get("parent_tool_use_id"),
        "session_id": obj.get("session_id"),
        "message": {"content": bloques},
    }


def stub_portador(tipo, timestamp, largo_original):
    if tipo == "assistant":
        bloque = {"type": "text", "text": "[recortado]"}
    else:
        bloque = {"type": "tool_result", "tool_use_id": "recortado",
                  "content": "[recortado %d bytes]" % largo_original}
    return {"type": tipo, "message": {"role": tipo, "content": [bloque]},
            "parent_tool_use_id": None, "timestamp": timestamp}


def seleccionar(source):
    """Una pasada sobre el stream.

    Devuelve ({nro_linea: (bytes_serializados, portador)}, set de task_id de los local_agent).

    portador = (nro_linea, tipo, timestamp, largo_original) de la ultima linea user/assistant
    vista antes de la linea seleccionada, o None.
    """
    elegidas = {}
    portador = None
    agentes = set()
    bash_vistos = []
    primer_progress = {}
    ultimo_progress = {}
    ultimo_rate = None
    ultimo_result = None
    primer_tool_progress = None
    init_visto = False
    vcs_visto = False

    with open(source, "rb") as f:
        for nro, cruda in enumerate(f, 1):
            linea = cruda.rstrip(b"\r\n")
            if not linea:
                continue
            try:
                obj = json.loads(linea)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue
            tipo = obj.get("type")
            sub = obj.get("subtype")

            if tipo in ("user", "assistant"):
                if tipo == "assistant" and b'"name":"Agent"' in linea:
                    elegidas[nro] = (compacto(reducir_assistant_agent(obj)), None)
                portador = (nro, tipo, obj.get("timestamp"), len(linea))
                continue

            def tomar(o, nro=nro, portador=portador):
                elegidas[nro] = (compacto(preparar(o)), portador)

            if tipo == "system" and sub == "init" and not init_visto:
                init_visto = True
                tomar({"type": tipo, "subtype": sub, "session_id": obj.get("session_id"),
                       "model": obj.get("model"), "tools": []})
            elif tipo == "system" and sub == "task_started":
                if obj.get("task_type") == "local_agent":
                    agentes.add(obj.get("task_id"))
                    obj.pop("prompt", None)
                    tomar(obj)
                elif obj.get("task_type") == "local_bash" and len(bash_vistos) < 3:
                    bash_vistos.append(obj.get("task_id"))
                    obj["description"] = truncar(anonimizar_texto(obj.get("description")), 120)
                    obj.pop("prompt", None)
                    tomar(obj)
            elif tipo == "system" and sub == "task_updated":
                if obj.get("task_id") in agentes:
                    tomar(obj)
            elif tipo == "system" and sub == "task_notification":
                tid = obj.get("task_id")
                if tid in agentes or tid in bash_vistos:
                    anonimizar_objeto(obj)
                    if tid in agentes:
                        obj["output_file"] = truncar(anonimizar_texto(obj.get("output_file")), 80)
                    obj["summary"] = truncar(anonimizar_texto(obj.get("summary")), 80)
                    tomar(obj)
            elif tipo == "system" and sub == "task_progress":
                tid = obj.get("task_id")
                if tid in agentes:
                    nuevo = (nro, obj, portador)
                    primer_progress.setdefault(tid, nuevo)
                    ultimo_progress[tid] = nuevo
            elif tipo == "rate_limit_event":
                ultimo_rate = (nro, obj, portador)
            elif tipo == "system" and sub == "vcs_state_changed" and not vcs_visto:
                vcs_visto = True
                tomar(obj)
            elif tipo == "tool_progress" and primer_tool_progress is None:
                primer_tool_progress = (nro, obj, portador)
            elif tipo == "result":
                ultimo_result = (nro, {
                    "type": obj.get("type"), "subtype": obj.get("subtype"),
                    "is_error": obj.get("is_error"), "total_cost_usd": obj.get("total_cost_usd"),
                    "session_id": obj.get("session_id"), "result": truncar(anonimizar_texto(obj.get("result")), 200),
                }, portador)

    pendientes = list(primer_progress.values()) + list(ultimo_progress.values())
    pendientes += [x for x in (ultimo_rate, primer_tool_progress, ultimo_result) if x]
    for nro, obj, por in pendientes:
        elegidas[nro] = (compacto(preparar(obj)), por)
    return elegidas, agentes


def cola_sintetica():
    """Casos limite agregados al final. S4 y S10 se escriben a mano en bytes."""
    stub_u1 = compacto(stub_portador("user", "2026-10-15T20:20:00.000Z", 120))
    stub_u2 = compacto(stub_portador("user", "2026-10-15T20:21:00.000Z", 120))
    return [
        b'{"type":"mystery_event","foo":1}',
        b'{"type":"system","subtype":"task_started","task_id":"broken"',
        stub_u1,
        # 0xE9 suelto: UTF-8 invalido a proposito
        b'{"type":"system","subtype":"task_started","task_id":"syn-otras","run_id":"syn-run-1",'
        b'"description":"Revisi\xe9n general del nivel","subagent_type":"reviewer","task_type":"local_agent"}',
        b'{"type":"system","subtype":"task_started","task_id":"syn-t9","run_id":"syn-run-2",'
        b'"description":"t9 sin campos","task_type":"local_agent"}',
        b'{"type":"system","subtype":"task_progress","task_id":"syn-t9","run_id":"syn-run-2",'
        b'"description":"t9 sin campos"}',
        b'{"type":"system","subtype":"task_updated","task_id":"syn-otras","run_id":"syn-run-1",'
        b'"patch":{"status":"completed"}}',
        stub_u2,
        b'{"type":"system","subtype":"task_notification","task_id":"syn-otras","run_id":"syn-run-1",'
        b'"status":"completed","output_file":"","summary":"Revision lista"}',
        # linea a medias: sin salto de linea final
        b'{"type":"system","subtype":"task_updated","task_id":"syn-t9","patch":{"status":"compl',
    ]


def construir(source):
    """Devuelve los bytes del fixture, o None si la fuente no tiene ningun task_started local_agent."""
    elegidas, agentes = seleccionar(source)
    if not agentes:
        return None
    salida = []
    emitidos = set()
    for nro in sorted(elegidas):
        contenido, por = elegidas[nro]
        if por is not None and por[0] not in emitidos and por[0] not in elegidas:
            salida.append(anonimizar_linea(compacto(stub_portador(por[1], por[2], por[3]))))
        if por is not None:
            emitidos.add(por[0])
        salida.append(anonimizar_linea(contenido))
        emitidos.add(nro)
    salida.extend(cola_sintetica())
    return b"\n".join(salida)


def reglas_utiles(ruta):
    # Cuenta como "sin reglas" tanto la ausencia del archivo como un JSON que no aporta
    # ninguna de path_regex, branch o substitutions con valor no vacio (p. ej. {}).
    try:
        with open(ruta, encoding="utf-8") as f:
            datos = json.load(f)
    except FileNotFoundError:
        return False
    return any(datos.get(clave) for clave in ("path_regex", "branch", "substitutions"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--sin-reglas", action="store_true",
                        help="genera sin anonymize-rules.local.json (puede dejar rutas y nombres reales)")
    args = parser.parse_args(argv)

    if not reglas_utiles(REGLAS_LOCALES):
        if not args.sin_reglas:
            print("falta el archivo de reglas de anonimizado: %s\n"
                  "Es un JSON con la forma {\"path_regex\": \"<regex>\", \"branch\": \"<rama real>\", "
                  "\"substitutions\": [[\"<real>\", \"<neutro>\"], ...]} (ver comentario en este script).\n"
                  "No se escribio el fixture. Usa --sin-reglas solo si aceptas que queden datos reales."
                  % REGLAS_LOCALES, file=sys.stderr)
            return 2
        print("AVISO: sin reglas locales (%s); el fixture puede contener rutas y nombres reales. "
              "Revisa el fixture antes de versionarlo." % REGLAS_LOCALES, file=sys.stderr)

    datos = construir(args.source)
    if datos is None:
        print("la fuente no tiene ningun task_started local_agent (revisa --source)", file=sys.stderr)
        return 1
    if len(datos) >= LIMITE_BYTES:
        print("el fixture pesa %d bytes (limite %d)" % (len(datos), LIMITE_BYTES), file=sys.stderr)
        return 1
    with open(args.out, "wb") as f:
        f.write(datos)
    print("fixture escrito: %d bytes" % len(datos))
    return 0


if __name__ == "__main__":
    sys.exit(main())
