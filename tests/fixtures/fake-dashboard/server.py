"""Servidor falso del dashboard para los tests del lanzador (solo biblioteca estandar).

Se llama server.py a proposito: Start-DriverDashboard reconoce un servidor previo
por 'server.py' en la linea de comandos.

Modo por variable de entorno FAKE_DASHBOARD_MODE: ok (default), silent, crash, silent_child.
silent_child: como silent, pero antes lanza un hijo (dormido 300 s) y escribe su pid en
<carpeta del status>/fake-child.pid.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--status", required=True)
    parser.add_argument("--logs", required=True)
    parser.add_argument("--assets", required=True)
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--idle-minutes", type=int, default=120)
    parser.add_argument("--driver-pid", type=int, required=True)
    args = parser.parse_args()

    status_dir = os.path.dirname(os.path.abspath(args.status))
    with open(os.path.join(status_dir, "fake-server-args.json"), "w", encoding="utf-8") as f:
        json.dump(dict(vars(args), cwd=os.getcwd()), f)

    mode = os.environ.get("FAKE_DASHBOARD_MODE", "ok")
    if mode == "crash":
        sys.stderr.write("fallo simulado del servidor\n")
        sys.stderr.flush()
        sys.exit(3)

    if mode == "silent_child":
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"])
        pid_path = os.path.join(status_dir, "fake-child.pid")
        with open(pid_path + ".tmp", "w", encoding="utf-8") as f:
            f.write(str(child.pid))
        os.replace(pid_path + ".tmp", pid_path)

    if mode == "ok":
        info = {
            "port": args.port,
            "pid": os.getpid(),
            "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        info_path = os.path.join(status_dir, ".driver-dashboard.json")
        tmp_path = info_path + ".tmp"
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(info, f)
        os.replace(tmp_path, info_path)

    deadline = time.time() + 300
    while time.time() < deadline:
        time.sleep(1)


if __name__ == "__main__":
    main()
