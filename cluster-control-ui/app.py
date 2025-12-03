from __future__ import annotations

import concurrent.futures
import json
import os
import re
import subprocess
import threading
from datetime import datetime
from pathlib import Path
from typing import Dict, List
import textwrap

from flask import (
    Flask,
    Response,
    jsonify,
    render_template,
    stream_with_context,
)

BASE_DIR = Path(__file__).resolve().parent
app = Flask(__name__, template_folder=str(BASE_DIR / "templates"))
app.secret_key = os.environ.get("CLUSTER_UI_SECRET", "cluster-ui-dev-secret")

def _int_env(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value is None:
        return default
    try:
        return int(value)
    except ValueError:
        return default

def _bool_env(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value not in {"0", "false", "False", "no", "No", "", None}

START_SCRIPT = Path(os.environ.get("K8S_START_SCRIPT", "~/dgx-spark-toolkit/scripts/start-k8s-cluster.sh")).expanduser()
STOP_SCRIPT = Path(os.environ.get("K8S_STOP_SCRIPT", "~/dgx-spark-toolkit/scripts/stop-k8s-cluster.sh")).expanduser()
CHECK_SCRIPT = Path(os.environ.get("K8S_CHECK_SCRIPT", "~/dgx-spark-toolkit/scripts/check-k8s-cluster.sh")).expanduser()
USE_SUDO = os.environ.get("K8S_UI_USE_SUDO", "1") not in {"0", "false", "False"}
MAX_HISTORY = _int_env("K8S_UI_HISTORY", 10)
HOST_LIST = [
    host.strip()
    for host in os.environ.get("CLUSTER_UI_HOSTS", "spark-2959,spark-ba63").split(",")
    if host.strip()
]
SSH_BINARY = os.environ.get("CLUSTER_UI_SSH", "ssh")
SSH_TIMEOUT = _int_env("CLUSTER_UI_STATUS_TIMEOUT", 6)
TRACKING_DEFAULT = _bool_env("CLUSTER_UI_TRACKING_DEFAULT", False)
AUTO_CHECK_SECONDS = _int_env("CLUSTER_UI_AUTO_CHECK_SECONDS", 0)
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
RUN_HISTORY: List[Dict[str, str]] = []
RUN_LOCK = threading.Lock()
RUN_STATE = {"running": False, "label": "", "command": ""}
REMOTE_METRICS_SCRIPT = textwrap.dedent(
    """
import json
import subprocess
import time


def _safe_float(value, default=None):
    if value is None:
        return default
    text = str(value).strip().strip("[]")
    if not text or text.upper() == "N/A":
        return default
    text = text.replace("%", "").replace("MiB", "").strip()
    try:
        return float(text)
    except ValueError:
        return default


def _cpu_usage():
    def _read():
        with open("/proc/stat", "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("cpu "):
                    parts = [int(x) for x in line.split()[1:]]
                    total = sum(parts)
                    idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
                    return total, idle
        return 0, 0

    total1, idle1 = _read()
    time.sleep(0.2)
    total2, idle2 = _read()
    delta_total = total2 - total1
    if delta_total <= 0:
        return 0.0
    delta_idle = idle2 - idle1
    usage = (1 - (delta_idle / delta_total)) * 100.0
    return max(0.0, min(usage, 100.0))


def _memory_usage():
    info = {}
    with open("/proc/meminfo", "r", encoding="utf-8") as fh:
        for line in fh:
            if ":" not in line:
                continue
            key, rest = line.split(":", 1)
            parts = rest.strip().split()
            if parts:
                info[key.strip()] = int(parts[0])
    total_kb = info.get("MemTotal", 0)
    available_kb = info.get("MemAvailable", info.get("MemFree", 0))
    used_kb = max(total_kb - available_kb, 0)
    return {
        "total_mb": int(total_kb / 1024) if total_kb else 0,
        "used_mb": int(used_kb / 1024),
        "percent": round((used_kb / total_kb) * 100, 1) if total_kb else 0.0,
    }


def _gpu_usage():
    cmd = [
        "nvidia-smi",
        "--query-gpu=index,name,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu",
        "--format=csv,noheader,nounits",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=2)
    except FileNotFoundError:
        return [], "nvidia-smi not found"
    except Exception as exc:
        return [], str(exc)
    lines = [line.strip() for line in result.stdout.strip().splitlines() if line.strip()]
    gpus = []
    for line in lines:
        parts = [part.strip() for part in line.split(",")]
        if len(parts) < 7:
            continue
        try:
            gpus.append(
                {
                    "index": int(parts[0]),
                    "name": parts[1],
                    "util": _safe_float(parts[2], 0.0),
                    "memory_util": _safe_float(parts[3], 0.0),
                    "memory_used": _safe_float(parts[4]),
                    "memory_total": _safe_float(parts[5]),
                    "temperature": _safe_float(parts[6]),
                }
            )
        except ValueError:
            continue
    return gpus, None


payload = {
    "cpu": {"percent": round(_cpu_usage(), 1)},
    "memory": _memory_usage(),
    "collected": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
gpus, gpu_error = _gpu_usage()
payload["gpus"] = gpus
payload["gpu_error"] = gpu_error
print(json.dumps(payload))
"""
).strip()


def _script_command(path: Path) -> List[str]:
    cmd = []
    script = str(path)
    if USE_SUDO:
        cmd.append("sudo")
    cmd.append(script)
    return cmd

def _strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def _run_stream(label: str, script_path: Path):
    if not script_path.exists():
        raise FileNotFoundError(f"{script_path} not found")

    command = _script_command(script_path)

    def generate():
        start = datetime.utcnow()
        output_lines: List[str] = []
        proc = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        RUN_STATE.update({"running": True, "label": label, "command": " ".join(command)})
        try:
            if proc.stdout is not None:
                for line in proc.stdout:
                    output_lines.append(line)
                    yield line
            proc.wait()
            finished = datetime.utcnow()
            entry = {
                "label": label,
                "command": " ".join(command),
                "returncode": str(proc.returncode or 0),
                "stdout": _strip_ansi("".join(output_lines)).strip(),
                "stderr": "",
                "started": start.strftime("%Y-%m-%d %H:%M:%S UTC"),
                "finished": finished.strftime("%Y-%m-%d %H:%M:%S UTC"),
            }
            _record_history(entry)
            yield f"\n[{label}] Completed with exit code {proc.returncode}\n"
        finally:
            RUN_STATE.update({"running": False, "label": "", "command": ""})

    return stream_with_context(generate())


def _record_history(entry: Dict[str, str]) -> None:
    RUN_HISTORY.insert(0, entry)
    if len(RUN_HISTORY) > MAX_HISTORY:
        del RUN_HISTORY[MAX_HISTORY:]


def _latest_entry(labels) -> Dict[str, str] | None:
    targets = set(labels)
    for entry in RUN_HISTORY:
        if entry.get("label") in targets:
            return entry
    return None


def _collect_host_metrics(hostname: str) -> Dict[str, object]:
    result: Dict[str, object] = {"host": hostname, "ok": False}
    if not hostname:
        result["error"] = "Empty hostname"
        return result

    try:
        proc = subprocess.run(
            [
                SSH_BINARY,
                "-o",
                "BatchMode=yes",
                "-o",
                f"ConnectTimeout={SSH_TIMEOUT}",
                hostname,
                "python3",
                "-",
            ],
            capture_output=True,
            text=True,
            timeout=SSH_TIMEOUT + 3,
            input=REMOTE_METRICS_SCRIPT,
        )
    except Exception as exc:  # pragma: no cover - best effort diagnostics
        result["error"] = str(exc)
        return result

    if proc.returncode != 0:
        stderr = proc.stderr.strip()
        stdout = proc.stdout.strip()
        result["error"] = stderr or stdout or "SSH command failed"
        return result

    try:
        payload = json.loads(proc.stdout.strip() or "{}")
    except json.JSONDecodeError:
        result["error"] = "Invalid metrics payload"
        return result

    result.update(payload)
    result["ok"] = True
    return result


@app.route("/", methods=["GET"])
def index():
    return render_template(
        "index.html",
        history=RUN_HISTORY,
        latest_run=RUN_HISTORY[0] if RUN_HISTORY else None,
        latest_action=_latest_entry({"Start", "Stop"}),
        latest_check=_latest_entry({"Check"}),
        start_script=str(START_SCRIPT),
        stop_script=str(STOP_SCRIPT),
        check_script=str(CHECK_SCRIPT),
        use_sudo=USE_SUDO,
        running=RUN_STATE["running"],
        status_hosts=HOST_LIST,
        tracking_default=TRACKING_DEFAULT,
        auto_check_seconds=AUTO_CHECK_SECONDS,
    )


def _resolve_action(action: str):
    if action == "start":
        return "Start", START_SCRIPT
    if action == "stop":
        return "Stop", STOP_SCRIPT
    if action == "check":
        return "Check", CHECK_SCRIPT
    raise ValueError("Unknown action")


@app.route("/run/<action>", methods=["POST"])
def run_action(action: str):
    try:
        label, target = _resolve_action(action)
    except ValueError:
        return Response("Unknown action", status=400, mimetype="text/plain")

    with RUN_LOCK:
        if RUN_STATE["running"]:
            return Response("Another command is currently running", status=409, mimetype="text/plain")
        stream = _run_stream(label, target)

    return Response(stream, mimetype="text/plain")


@app.route("/host-metrics", methods=["GET"])
def host_metrics():
    if not HOST_LIST:
        return jsonify([])

    workers = min(len(HOST_LIST), 4)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        data = list(executor.map(_collect_host_metrics, HOST_LIST))
    return jsonify(data)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), debug=False)
