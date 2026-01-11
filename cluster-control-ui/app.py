from __future__ import annotations

import concurrent.futures
import json
import os
import re
import socket
import sqlite3
import struct
import subprocess
import threading
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

from flask import (
    Flask,
    Response,
    jsonify,
    render_template,
    request,
    stream_with_context,
)
import time as _time

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
DATA_DIR = Path(os.environ.get("CLUSTER_UI_DATA_DIR", "/nfs/imagegen"))  # Shared storage
DEPLOYMENT_HISTORY_DB = DATA_DIR / "deployment_history.db"


def _init_deployment_history_db():
    """Initialize the deployment history database."""
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(DEPLOYMENT_HISTORY_DB), timeout=5)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS deployments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                deployment_type TEXT NOT NULL,  -- 'llm' or 'imagegen'
                action TEXT NOT NULL,           -- 'deploy', 'delete', 'scale', 'start', 'stop'
                model_name TEXT,
                model_display TEXT,
                model_hf_id TEXT,
                status TEXT NOT NULL,           -- 'success' or 'failed'
                message TEXT,
                details TEXT,                   -- JSON with extra details
                user TEXT
            )
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_deployments_timestamp ON deployments(timestamp DESC)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_deployments_type ON deployments(deployment_type)")
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"Warning: Could not initialize deployment history DB: {e}")


def _record_deployment(
    deployment_type: str,
    action: str,
    model_name: str = None,
    model_display: str = None,
    model_hf_id: str = None,
    status: str = "success",
    message: str = None,
    details: dict = None
):
    """Record a deployment action to history."""
    try:
        conn = sqlite3.connect(str(DEPLOYMENT_HISTORY_DB), timeout=5)
        conn.execute("""
            INSERT INTO deployments 
            (timestamp, deployment_type, action, model_name, model_display, model_hf_id, status, message, details, user)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            datetime.utcnow().isoformat(),
            deployment_type,
            action,
            model_name,
            model_display,
            model_hf_id,
            status,
            message,
            json.dumps(details) if details else None,
            os.environ.get("USER", "unknown")
        ))
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"Warning: Could not record deployment: {e}")


def _get_deployment_history(deployment_type: str = None, limit: int = 50) -> List[Dict]:
    """Get deployment history."""
    try:
        conn = sqlite3.connect(str(DEPLOYMENT_HISTORY_DB), timeout=5)
        conn.row_factory = sqlite3.Row
        
        if deployment_type:
            rows = conn.execute(
                "SELECT * FROM deployments WHERE deployment_type = ? ORDER BY timestamp DESC LIMIT ?",
                (deployment_type, limit)
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM deployments ORDER BY timestamp DESC LIMIT ?",
                (limit,)
            ).fetchall()
        
        conn.close()
        return [dict(row) for row in rows]
    except Exception:
        return []


# Initialize deployment history DB on startup
_init_deployment_history_db()

app = Flask(
    __name__,
    template_folder=str(BASE_DIR / "templates"),
    static_folder=str(STATIC_DIR),
    static_url_path="/static"
)
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
SLEEP_SCRIPT = Path(os.environ.get("K8S_SLEEP_SCRIPT", "~/dgx-spark-toolkit/scripts/sleep-cluster.sh")).expanduser()
USE_SUDO = os.environ.get("K8S_UI_USE_SUDO", "1") not in {"0", "false", "False"}

# Wake-on-LAN configuration (native implementation)
WOL_NODES = {
    "spark-2959": {
        "mac": os.environ.get("WOL_SPARK_2959_MAC", "4c:bb:47:2e:29:59"),
        "ip": os.environ.get("WOL_SPARK_2959_IP", "192.168.86.38"),
    },
    "spark-ba63": {
        "mac": os.environ.get("WOL_SPARK_BA63_MAC", "4c:bb:47:2c:ba:63"),
        "ip": os.environ.get("WOL_SPARK_BA63_IP", "192.168.86.39"),
    },
}
WOL_BROADCAST = os.environ.get("WOL_BROADCAST", "192.168.86.255")
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

# Load remote metrics script from external file
METRICS_SCRIPT_FILE = STATIC_DIR / "metrics_collector.py"
REMOTE_METRICS_SCRIPT = METRICS_SCRIPT_FILE.read_text() if METRICS_SCRIPT_FILE.exists() else ""


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
        latest_action=_latest_entry({"Start", "Stop", "Sleep"}),
        start_script=str(START_SCRIPT),
        stop_script=str(STOP_SCRIPT),
        sleep_script=str(SLEEP_SCRIPT),
        use_sudo=USE_SUDO,
        running=RUN_STATE["running"],
        status_hosts=HOST_LIST,
        tracking_default=TRACKING_DEFAULT,
        wol_nodes=WOL_NODES,
    )


def _resolve_action(action: str):
    """Resolve script-based actions (start, stop, sleep only)."""
    if action == "start":
        return "Start", START_SCRIPT
    if action == "stop":
        return "Stop", STOP_SCRIPT
    if action == "sleep":
        return "Sleep", SLEEP_SCRIPT
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


# --------------------------------------------------------------------------
# Native Kubernetes Cluster Status Collection
# --------------------------------------------------------------------------

KUBECTL_TIMEOUT = _int_env("KUBECTL_TIMEOUT", 5)
CLUSTER_STATUS_NAMESPACES = [
    ns.strip()
    for ns in os.environ.get(
        "CLUSTER_STATUS_NAMESPACES",
        "default,llm-inference,image-gen,kubernetes-dashboard,longhorn-system,metallb-system,kube-system,gpu-operator,network-operator,ray-system,ingress-nginx"
    ).split(",")
    if ns.strip()
]


def _run_kubectl(args: List[str], timeout: int = None) -> tuple[bool, str]:
    """Run kubectl command and return (success, output)."""
    timeout = timeout or KUBECTL_TIMEOUT
    try:
        result = subprocess.run(
            ["kubectl"] + args,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if result.returncode == 0:
            return True, result.stdout.strip()
        return False, result.stderr.strip() or result.stdout.strip()
    except subprocess.TimeoutExpired:
        return False, "Command timed out"
    except FileNotFoundError:
        return False, "kubectl not found"
    except Exception as exc:
        return False, str(exc)


def _collect_cluster_status() -> Dict[str, object]:
    """Collect comprehensive Kubernetes cluster status."""
    status = {
        "collected": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ok": False,
        "api_server": {"healthy": False, "message": ""},
        "nodes": [],
        "namespaces": {},
        "summary": {
            "total_pods": 0,
            "running_pods": 0,
            "pending_pods": 0,
            "failed_pods": 0,
            "total_services": 0,
            "total_deployments": 0,
            "ready_deployments": 0,
        },
    }

    # Check API server health
    ok, output = _run_kubectl(["get", "--raw", "/healthz"], timeout=3)
    if ok and output.strip().lower() == "ok":
        status["api_server"]["healthy"] = True
        status["api_server"]["message"] = "API server healthy"
    else:
        status["api_server"]["message"] = output or "API server unreachable"
        return status

    # Get nodes
    ok, output = _run_kubectl([
        "get", "nodes", "-o",
        "jsonpath={range .items[*]}{.metadata.name},{.status.conditions[?(@.type==\"Ready\")].status},{.status.nodeInfo.kubeletVersion},{.status.nodeInfo.osImage},{.status.allocatable.cpu},{.status.allocatable.memory},{.status.conditions[?(@.type==\"Ready\")].lastHeartbeatTime}{\"\\n\"}{end}"
    ])
    if ok:
        for line in output.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split(",")
            if len(parts) >= 7:
                status["nodes"].append({
                    "name": parts[0],
                    "ready": parts[1] == "True",
                    "version": parts[2],
                    "os": parts[3],
                    "cpu": parts[4],
                    "memory": parts[5],
                    "last_heartbeat": parts[6],
                })

    # Get pods summary across all namespaces
    ok, output = _run_kubectl([
        "get", "pods", "-A", "-o",
        "jsonpath={range .items[*]}{.metadata.namespace},{.status.phase}{\"\\n\"}{end}"
    ])
    if ok:
        for line in output.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split(",")
            if len(parts) >= 2:
                status["summary"]["total_pods"] += 1
                phase = parts[1].lower()
                if phase == "running":
                    status["summary"]["running_pods"] += 1
                elif phase == "pending":
                    status["summary"]["pending_pods"] += 1
                elif phase in ("failed", "error"):
                    status["summary"]["failed_pods"] += 1

    # Get services count
    ok, output = _run_kubectl(["get", "svc", "-A", "--no-headers"])
    if ok:
        status["summary"]["total_services"] = len([l for l in output.split("\n") if l.strip()])

    # Get deployments summary
    ok, output = _run_kubectl([
        "get", "deployments", "-A", "-o",
        "jsonpath={range .items[*]}{.status.replicas},{.status.readyReplicas}{\"\\n\"}{end}"
    ])
    if ok:
        for line in output.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split(",")
            status["summary"]["total_deployments"] += 1
            if len(parts) >= 2 and parts[0] == parts[1] and parts[0]:
                status["summary"]["ready_deployments"] += 1

    # Get detailed namespace info for configured namespaces
    for ns in CLUSTER_STATUS_NAMESPACES:
        ns_data = {"pods": [], "services": [], "deployments": []}

        # Pods in namespace
        ok, output = _run_kubectl([
            "get", "pods", "-n", ns, "-o",
            "jsonpath={range .items[*]}{.metadata.name},{.status.phase},{.status.containerStatuses[0].ready},{.status.containerStatuses[0].restartCount},{.spec.containers[0].image}{\"\\n\"}{end}"
        ])
        if ok:
            for line in output.strip().split("\n"):
                if not line.strip():
                    continue
                parts = line.split(",")
                if len(parts) >= 5:
                    ns_data["pods"].append({
                        "name": parts[0],
                        "phase": parts[1],
                        "ready": parts[2] == "true",
                        "restarts": int(parts[3]) if parts[3].isdigit() else 0,
                        "image": parts[4].split("/")[-1][:40],  # Short image name
                    })

        # Services in namespace
        ok, output = _run_kubectl([
            "get", "svc", "-n", ns, "-o",
            "jsonpath={range .items[*]}{.metadata.name},{.spec.type},{.spec.clusterIP},{.status.loadBalancer.ingress[0].ip}{\"\\n\"}{end}"
        ])
        if ok:
            for line in output.strip().split("\n"):
                if not line.strip():
                    continue
                parts = line.split(",")
                if len(parts) >= 3:
                    ns_data["services"].append({
                        "name": parts[0],
                        "type": parts[1],
                        "cluster_ip": parts[2],
                        "external_ip": parts[3] if len(parts) > 3 and parts[3] else None,
                    })

        # Deployments in namespace
        ok, output = _run_kubectl([
            "get", "deployments", "-n", ns, "-o",
            "jsonpath={range .items[*]}{.metadata.name},{.status.replicas},{.status.readyReplicas},{.status.availableReplicas}{\"\\n\"}{end}"
        ])
        if ok:
            for line in output.strip().split("\n"):
                if not line.strip():
                    continue
                parts = line.split(",")
                if len(parts) >= 2:
                    replicas = int(parts[1]) if parts[1].isdigit() else 0
                    ready = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0
                    ns_data["deployments"].append({
                        "name": parts[0],
                        "replicas": replicas,
                        "ready": ready,
                        "available": int(parts[3]) if len(parts) > 3 and parts[3].isdigit() else 0,
                    })

        if ns_data["pods"] or ns_data["services"] or ns_data["deployments"]:
            status["namespaces"][ns] = ns_data

    status["ok"] = True
    return status


@app.route("/cluster-status", methods=["GET"])
def cluster_status():
    """Get current cluster status snapshot."""
    return jsonify(_collect_cluster_status())


# --------------------------------------------------------------------------
# Kubernetes Node and Workload Operations
# --------------------------------------------------------------------------

def _run_kubectl_action(args: List[str], timeout: int = 30) -> tuple[bool, str]:
    """Run kubectl action command and return (success, output)."""
    try:
        result = subprocess.run(
            ["kubectl"] + args,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        output = result.stdout.strip()
        if result.returncode != 0:
            output = result.stderr.strip() or output or "Command failed"
        return result.returncode == 0, output
    except subprocess.TimeoutExpired:
        return False, "Command timed out"
    except FileNotFoundError:
        return False, "kubectl not found"
    except Exception as exc:
        return False, str(exc)


@app.route("/node/<node_name>/cordon", methods=["POST"])
def cordon_node(node_name: str):
    """Cordon a node (mark as unschedulable)."""
    ok, output = _run_kubectl_action(["cordon", node_name])
    return jsonify({"success": ok, "message": output})


@app.route("/node/<node_name>/uncordon", methods=["POST"])
def uncordon_node(node_name: str):
    """Uncordon a node (mark as schedulable)."""
    ok, output = _run_kubectl_action(["uncordon", node_name])
    return jsonify({"success": ok, "message": output})


@app.route("/node/<node_name>/drain", methods=["POST"])
def drain_node(node_name: str):
    """Drain a node (evict all pods)."""
    ok, output = _run_kubectl_action([
        "drain", node_name,
        "--ignore-daemonsets",
        "--delete-emptydir-data",
        "--force",
        "--grace-period=30"
    ], timeout=120)
    return jsonify({"success": ok, "message": output})


@app.route("/deployment/<namespace>/<name>/restart", methods=["POST"])
def restart_deployment(namespace: str, name: str):
    """Restart a deployment by triggering a rollout restart."""
    ok, output = _run_kubectl_action([
        "rollout", "restart", "deployment", name, "-n", namespace
    ])
    return jsonify({"success": ok, "message": output})


@app.route("/deployment/<namespace>/<name>/scale", methods=["POST"])
def scale_deployment(namespace: str, name: str):
    """Scale a deployment to specified replicas."""
    data = request.get_json() or {}
    replicas = data.get("replicas", 1)
    ok, output = _run_kubectl_action([
        "scale", "deployment", name, "-n", namespace, f"--replicas={replicas}"
    ])
    return jsonify({"success": ok, "message": output})


@app.route("/pod/<namespace>/<name>/delete", methods=["POST"])
def delete_pod(namespace: str, name: str):
    """Delete a pod (triggers restart if managed by deployment)."""
    ok, output = _run_kubectl_action([
        "delete", "pod", name, "-n", namespace, "--grace-period=30"
    ])
    return jsonify({"success": ok, "message": output})


@app.route("/pod/<namespace>/<name>/logs", methods=["GET"])
def get_pod_logs(namespace: str, name: str):
    """Get logs from a pod. Optional query params: container, tail, previous."""
    container = request.args.get("container", "")
    tail = request.args.get("tail", "200")
    previous = request.args.get("previous", "false") == "true"
    
    cmd = ["logs", name, "-n", namespace, f"--tail={tail}"]
    if container:
        cmd.extend(["-c", container])
    if previous:
        cmd.append("--previous")
    
    ok, output = _run_kubectl(cmd, timeout=30)
    if ok:
        return jsonify({"success": True, "logs": output, "pod": name, "namespace": namespace})
    else:
        return jsonify({"success": False, "error": output, "pod": name, "namespace": namespace})


@app.route("/pod/<namespace>/<name>/containers", methods=["GET"])
def get_pod_containers(namespace: str, name: str):
    """Get list of containers in a pod."""
    ok, output = _run_kubectl([
        "get", "pod", name, "-n", namespace,
        "-o", "jsonpath={range .spec.containers[*]}{.name}{\"\\n\"}{end}"
    ])
    if ok:
        containers = [c.strip() for c in output.strip().split("\n") if c.strip()]
        return jsonify({"success": True, "containers": containers, "pod": name})
    else:
        return jsonify({"success": False, "error": output, "containers": []})


@app.route("/pod/<namespace>/<name>/exec", methods=["POST"])
def exec_pod_command(namespace: str, name: str):
    """Execute a command in a pod container."""
    data = request.get_json() or {}
    container = data.get("container", "")
    command = data.get("command", "")
    
    if not command:
        return jsonify({"success": False, "error": "No command provided"})
    
    # Build kubectl exec command
    cmd = ["exec", name, "-n", namespace]
    if container:
        cmd.extend(["-c", container])
    cmd.append("--")
    
    # Parse command - support simple shell commands
    # For safety, wrap in sh -c if it contains shell metacharacters
    if any(c in command for c in ['|', '&', ';', '>', '<', '$', '`', '"', "'"]):
        cmd.extend(["sh", "-c", command])
    else:
        cmd.extend(command.split())
    
    try:
        result = subprocess.run(
            ["kubectl"] + cmd,
            capture_output=True,
            text=True,
            timeout=60
        )
        return jsonify({
            "success": result.returncode == 0,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exit_code": result.returncode,
            "command": command,
            "pod": name,
            "namespace": namespace
        })
    except subprocess.TimeoutExpired:
        return jsonify({"success": False, "error": "Command timed out (60s limit)"})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})


# --------------------------------------------------------------------------
# Native Wake-on-LAN Implementation
# --------------------------------------------------------------------------

def _send_wol_packet(mac_address: str, broadcast: str = None) -> tuple[bool, str]:
    """Send a Wake-on-LAN magic packet to the specified MAC address."""
    broadcast = broadcast or WOL_BROADCAST
    
    # Parse MAC address
    mac_address = mac_address.replace(":", "").replace("-", "").upper()
    if len(mac_address) != 12:
        return False, f"Invalid MAC address format: {mac_address}"
    
    try:
        mac_bytes = bytes.fromhex(mac_address)
    except ValueError:
        return False, f"Invalid MAC address: {mac_address}"
    
    # Build magic packet: 6 bytes of 0xFF followed by MAC address repeated 16 times
    magic_packet = b'\xff' * 6 + mac_bytes * 16
    
    try:
        # Send via UDP broadcast
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.sendto(magic_packet, (broadcast, 9))
        sock.close()
        return True, f"WoL packet sent to {':'.join(mac_address[i:i+2] for i in range(0, 12, 2))}"
    except Exception as exc:
        return False, f"Failed to send WoL packet: {exc}"


def _check_host_reachable(ip: str, timeout: int = 2) -> bool:
    """Check if a host is reachable via ping."""
    try:
        result = subprocess.run(
            ["ping", "-c", "1", "-W", str(timeout), ip],
            capture_output=True,
            timeout=timeout + 1,
        )
        return result.returncode == 0
    except Exception:
        return False


@app.route("/wake", methods=["POST"])
def wake_cluster():
    """Wake cluster nodes using native Wake-on-LAN."""
    data = request.get_json() or {}
    target = data.get("target", "all")  # "all", "control", "worker", or specific node name
    
    results = []
    nodes_to_wake = []
    
    if target == "all":
        nodes_to_wake = list(WOL_NODES.keys())
    elif target == "control":
        nodes_to_wake = ["spark-2959"]
    elif target == "worker":
        nodes_to_wake = ["spark-ba63"]
    elif target in WOL_NODES:
        nodes_to_wake = [target]
    else:
        return jsonify({"success": False, "message": f"Unknown target: {target}", "results": []})
    
    # Wake control plane first (if included)
    if "spark-2959" in nodes_to_wake:
        node_info = WOL_NODES["spark-2959"]
        ok, msg = _send_wol_packet(node_info["mac"])
        results.append({
            "node": "spark-2959",
            "mac": node_info["mac"],
            "success": ok,
            "message": msg,
        })
    
    # Then wake worker
    if "spark-ba63" in nodes_to_wake:
        node_info = WOL_NODES["spark-ba63"]
        ok, msg = _send_wol_packet(node_info["mac"])
        results.append({
            "node": "spark-ba63",
            "mac": node_info["mac"],
            "success": ok,
            "message": msg,
        })
    
    all_success = all(r["success"] for r in results)
    return jsonify({
        "success": all_success,
        "message": "Wake-on-LAN packets sent" if all_success else "Some WoL packets failed",
        "results": results,
    })


@app.route("/wake/status", methods=["GET"])
def wake_status():
    """Check the wake status of cluster nodes."""
    status = {}
    for node_name, node_info in WOL_NODES.items():
        reachable = _check_host_reachable(node_info["ip"])
        status[node_name] = {
            "ip": node_info["ip"],
            "mac": node_info["mac"],
            "reachable": reachable,
            "status": "online" if reachable else "offline",
        }
    return jsonify(status)


@app.route("/cluster-status-stream", methods=["GET"])
def cluster_status_stream():
    """SSE endpoint for real-time cluster status streaming."""
    def generate():
        while True:
            data = _collect_cluster_status()
            yield f"data: {json.dumps(data)}\n\n"
            _time.sleep(3)  # Cluster status every 3 seconds (less frequent than host metrics)

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.route("/host-metrics-stream", methods=["GET"])
def host_metrics_stream():
    """SSE endpoint for real-time host metrics streaming."""
    def generate():
        while True:
            if not HOST_LIST:
                yield f"data: {json.dumps([])}\n\n"
            else:
                workers = min(len(HOST_LIST), 4)
                with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
                    data = list(executor.map(_collect_host_metrics, HOST_LIST))
                yield f"data: {json.dumps(data)}\n\n"
            _time.sleep(1)

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


# --------------------------------------------------------------------------
# LLM Deployment Management (Multi-Model Support)
# --------------------------------------------------------------------------

NEMOTRON_NAMESPACE = "llm-inference"
NEMOTRON_DEPLOYMENT_DIR = Path(os.environ.get(
    "NEMOTRON_DEPLOYMENT_DIR",
    "/home/doran/dgx-spark-toolkit/deployments/nemotron"
))

# vLLM service endpoints
VLLM_DISTRIBUTED_IP = os.environ.get("VLLM_DISTRIBUTED_IP", "192.168.86.203")
VLLM_DISTRIBUTED_PORT = os.environ.get("VLLM_DISTRIBUTED_PORT", "8081")
LITELLM_IP = os.environ.get("LITELLM_IP", "192.168.86.204")
LITELLM_PORT = os.environ.get("LITELLM_PORT", "4000")
LITELLM_API_KEY = os.environ.get("LITELLM_API_KEY", "sk-litellm-master-1234")

# Model configuration
MODEL_CONFIG_FILE = NEMOTRON_DEPLOYMENT_DIR / "model-configs.yaml"


def _load_model_configs() -> Dict[str, object]:
    """Load model configurations from YAML file."""
    if not MODEL_CONFIG_FILE.exists():
        return {"models": {}, "default_model": "nemotron-nano-30b"}
    
    try:
        import yaml
        with open(MODEL_CONFIG_FILE, "r") as f:
            return yaml.safe_load(f) or {"models": {}, "default_model": "nemotron-nano-30b"}
    except ImportError:
        # Fallback: basic parsing without PyYAML
        return {
            "models": {
                "nemotron-nano-30b": {
                    "name": "nemotron-nano-30b",
                    "display_name": "Nemotron-3 Nano 30B",
                    "huggingface_id": "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16",
                    "size_gb": 60,
                    "distributed": True,
                    "min_gpus": 2,
                },
                "qwen-image-2512": {
                    "name": "qwen-image-2512",
                    "display_name": "Qwen-Image-2512 (Vision)",
                    "huggingface_id": "Qwen/Qwen-Image-2512",
                    "size_gb": 41,
                    "distributed": False,
                    "min_gpus": 1,
                },
                "qwen2.5-32b": {
                    "name": "qwen2.5-32b",
                    "display_name": "Qwen2.5-32B-Instruct",
                    "huggingface_id": "Qwen/Qwen2.5-32B-Instruct",
                    "size_gb": 65,
                    "distributed": True,
                    "min_gpus": 2,
                },
            },
            "default_model": "nemotron-nano-30b"
        }
    except Exception:
        return {"models": {}, "default_model": "nemotron-nano-30b"}


def _get_nemotron_status() -> Dict[str, object]:
    """Get comprehensive LLM deployment status (supports multiple models)."""
    status = {
        "mode": "not_deployed",  # "distributed", "single", "not_deployed"
        "current_model": None,
        "current_model_display": None,
        "current_model_hf_id": None,
        "ray_cluster": None,
        "ray_job": None,
        "pods": [],
        "services": [],
        "vllm_health": None,
        "litellm_health": None,
        "endpoints": {
            "vllm": f"http://{VLLM_DISTRIBUTED_IP}:{VLLM_DISTRIBUTED_PORT}",
            "litellm": f"http://{LITELLM_IP}:{LITELLM_PORT}",
            "ray_dashboard": f"http://{VLLM_DISTRIBUTED_IP}:8265",
        },
    }
    
    # Get current model from RayJob labels/annotations
    ok, output = _run_kubectl([
        "get", "rayjob", "vllm-serve", "-n", NEMOTRON_NAMESPACE,
        "-o", "jsonpath={.metadata.labels.vllm\\.model},{.metadata.annotations.vllm\\.model-id},{.metadata.annotations.vllm\\.display-name}"
    ])
    if ok and output.strip():
        parts = output.split(",")
        status["current_model"] = parts[0] if parts else None
        status["current_model_hf_id"] = parts[1] if len(parts) > 1 else None
        status["current_model_display"] = parts[2] if len(parts) > 2 else parts[0] if parts else None
    
    # Check RayCluster
    ok, output = _run_kubectl([
        "get", "raycluster", "vllm-cluster", "-n", NEMOTRON_NAMESPACE,
        "-o", "jsonpath={.status.state},{.status.availableWorkerReplicas},{.status.desiredWorkerReplicas}"
    ])
    if ok and output.strip():
        parts = output.split(",")
        status["ray_cluster"] = {
            "state": parts[0] if parts else "unknown",
            "available_workers": int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0,
            "desired_workers": int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0,
        }
        status["mode"] = "distributed"
    
    # Check RayJob
    ok, output = _run_kubectl([
        "get", "rayjob", "vllm-serve", "-n", NEMOTRON_NAMESPACE,
        "-o", "jsonpath={.status.jobStatus},{.status.jobDeploymentStatus}"
    ])
    if ok and output.strip():
        parts = output.split(",")
        status["ray_job"] = {
            "status": parts[0] if parts else "unknown",
            "deployment_status": parts[1] if len(parts) > 1 else "unknown",
        }
    
    # Check if distributed is stopped (workers scaled to 0)
    if status["mode"] == "distributed" and status.get("ray_cluster"):
        if status["ray_cluster"].get("desired_workers", 1) == 0:
            status["mode"] = "distributed_stopped"
    
    # Check for single-node deployment if no RayCluster
    if status["mode"] == "not_deployed":
        ok, output = _run_kubectl([
            "get", "deployment", "nemotron-vllm", "-n", NEMOTRON_NAMESPACE,
            "-o", "jsonpath={.spec.replicas},{.status.readyReplicas}"
        ])
        if ok and output.strip():
            parts = output.split(",")
            spec_replicas = int(parts[0]) if parts[0].isdigit() else 0
            ready = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
            # Deployment exists - check if it's running or stopped
            status["single_deployment"] = {
                "replicas": spec_replicas,
                "ready": ready,
            }
            if spec_replicas > 0:
                status["mode"] = "single"
            else:
                status["mode"] = "single_stopped"
    
    # Get Ray pods
    ok, output = _run_kubectl([
        "get", "pods", "-n", NEMOTRON_NAMESPACE,
        "-l", "ray-cluster=vllm-cluster",
        "-o", "jsonpath={range .items[*]}{.metadata.name},{.status.phase},{.spec.nodeName},{.metadata.labels.ray-node-type}{\"\\n\"}{end}"
    ])
    if ok:
        for line in output.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split(",")
            if len(parts) >= 4:
                status["pods"].append({
                    "name": parts[0],
                    "phase": parts[1],
                    "node": parts[2],
                    "type": parts[3],  # head or worker
                })
    
    # Get related services
    ok, output = _run_kubectl([
        "get", "svc", "-n", NEMOTRON_NAMESPACE,
        "-o", "jsonpath={range .items[*]}{.metadata.name},{.spec.type},{.status.loadBalancer.ingress[0].ip},{.spec.ports[0].port}{\"\\n\"}{end}"
    ])
    if ok:
        for line in output.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split(",")
            if len(parts) >= 3:
                status["services"].append({
                    "name": parts[0],
                    "type": parts[1],
                    "external_ip": parts[2] if parts[2] else None,
                    "port": parts[3] if len(parts) > 3 else None,
                })
    
    # Check vLLM health
    try:
        req = urllib.request.Request(
            f"http://{VLLM_DISTRIBUTED_IP}:{VLLM_DISTRIBUTED_PORT}/health",
            method="GET"
        )
        with urllib.request.urlopen(req, timeout=3) as resp:
            status["vllm_health"] = {
                "healthy": resp.status == 200,
                "status_code": resp.status,
            }
    except urllib.error.URLError:
        status["vllm_health"] = {"healthy": False, "error": "Connection refused"}
    except Exception as e:
        status["vllm_health"] = {"healthy": False, "error": str(e)}
    
    # Check LiteLLM health
    try:
        req = urllib.request.Request(
            f"http://{LITELLM_IP}:{LITELLM_PORT}/health/readiness",
            method="GET"
        )
        with urllib.request.urlopen(req, timeout=3) as resp:
            status["litellm_health"] = {
                "healthy": resp.status == 200,
                "status_code": resp.status,
            }
    except urllib.error.URLError:
        status["litellm_health"] = {"healthy": False, "error": "Connection refused"}
    except Exception as e:
        status["litellm_health"] = {"healthy": False, "error": str(e)}
    
    return status


@app.route("/nemotron/status", methods=["GET"])
def nemotron_status():
    """Get LLM deployment status."""
    return jsonify(_get_nemotron_status())


@app.route("/nemotron/models", methods=["GET"])
def list_models():
    """List available model presets."""
    config = _load_model_configs()
    models = config.get("models", {})
    default = config.get("default_model", "nemotron-nano-30b")
    
    # Get current deployed model
    status = _get_nemotron_status()
    current = status.get("current_model")
    
    return jsonify({
        "models": models,
        "default_model": default,
        "current_model": current,
    })


@app.route("/nemotron/deploy/distributed", methods=["POST"])
def nemotron_deploy_distributed():
    """Deploy LLM in distributed mode using KubeRay (supports model selection)."""
    data = request.get_json() or {}
    model_name = data.get("model")
    
    # Load model configs
    config = _load_model_configs()
    models = config.get("models", {})
    default_model = config.get("default_model", "nemotron-nano-30b")
    
    # Use default if not specified
    if not model_name:
        model_name = default_model
    
    # Validate model
    if model_name not in models:
        return jsonify({
            "success": False,
            "message": f"Unknown model: {model_name}. Available: {', '.join(models.keys())}",
        })
    
    model_config = models[model_name]
    model_display = model_config.get("display_name", model_name)
    
    # Check if switching models (allow redeploy with different model)
    status = _get_nemotron_status()
    current_model = status.get("current_model")
    
    if status["mode"] == "distributed" and current_model == model_name:
        return jsonify({
            "success": False,
            "message": f"{model_display} is already deployed. Delete first to redeploy.",
        })
    
    results = []
    
    # Step 1: Delete single-node deployment if exists
    if status["mode"] == "single":
        ok, output = _run_kubectl_action([
            "delete", "deployment", "nemotron-vllm", "-n", NEMOTRON_NAMESPACE,
            "--ignore-not-found"
        ])
        results.append({"step": "delete_single", "success": ok, "output": output})
    
    # Step 2: ALWAYS delete existing RayJob to ensure fresh deployment with new model
    # RayJob is immutable - must delete and recreate to change the model
    ok, output = _run_kubectl_action([
        "delete", "rayjob", "vllm-serve", "-n", NEMOTRON_NAMESPACE,
        "--ignore-not-found", "--wait=true", "--timeout=60s"
    ])
    results.append({"step": "delete_old_job", "success": ok, "output": output})
    
    # Step 3: Apply RayCluster
    raycluster_file = NEMOTRON_DEPLOYMENT_DIR / "raycluster-vllm.yaml"
    if not raycluster_file.exists():
        return jsonify({
            "success": False,
            "message": f"RayCluster manifest not found: {raycluster_file}",
        })
    
    ok, output = _run_kubectl_action(["apply", "-f", str(raycluster_file)], timeout=30)
    results.append({"step": "apply_raycluster", "success": ok, "output": output})
    if not ok:
        return jsonify({"success": False, "message": "Failed to apply RayCluster", "results": results})
    
    # Step 4: Generate vLLM serve job for the selected model
    # ALWAYS regenerate to ensure correct model is used
    # Write to DATA_DIR (NFS) since systemd ProtectSystem=strict makes /home read-only
    servejob_file = DATA_DIR / "vllm-serve-job-generated.yaml"
    
    # Generate the job YAML with model-specific configuration
    try:
        hf_id = model_config.get("huggingface_id", "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16")
        vllm_args = model_config.get("vllm_args", {})
        dtype = vllm_args.get("dtype", "bfloat16")
        tp_size = vllm_args.get("tensor_parallel_size", 1)
        pp_size = vllm_args.get("pipeline_parallel_size", 2)
        max_model_len = vllm_args.get("max_model_len", 4096)
        gpu_util = vllm_args.get("gpu_memory_utilization", 0.85)
        enforce_eager = vllm_args.get("enforce_eager", True)
        trust_remote = model_config.get("requires_trust_remote_code", True)
        
        trust_flag = "'--trust-remote-code'," if trust_remote else ""
        eager_flag = "'--enforce-eager'" if enforce_eager else ""
        
        job_yaml = f'''# RayJob to start vLLM server on the Ray cluster
# Auto-generated for model: {model_display}
# Model: {hf_id}
apiVersion: ray.io/v1
kind: RayJob
metadata:
  name: vllm-serve
  namespace: llm-inference
  labels:
    app.kubernetes.io/name: vllm-distributed
    app.kubernetes.io/component: inference-server
    vllm.model: "{model_name}"
  annotations:
    vllm.model-id: "{hf_id}"
    vllm.display-name: "{model_display}"
spec:
  shutdownAfterJobFinishes: false
  clusterSelector:
    ray.io/cluster: vllm-cluster
  entrypoint: |
    python -c "
    import ray
    import subprocess
    import sys
    import time
    
    ray.init(address='auto')
    
    print('Waiting for Ray cluster to be ready...')
    min_gpus = {pp_size}
    for i in range(60):
        nodes = ray.nodes()
        ready_nodes = [n for n in nodes if n['Alive']]
        gpu_count = sum(n.get('Resources', {{}}).get('GPU', 0) for n in ready_nodes)
        print(f'Ready nodes: {{len(ready_nodes)}}, GPUs: {{gpu_count}}')
        if gpu_count >= min_gpus:
            print('Cluster ready! Starting vLLM...')
            break
        time.sleep(5)
    else:
        print('Timeout waiting for cluster')
        sys.exit(1)
    
    cmd = [
        'vllm', 'serve', '{hf_id}',
        '--host', '0.0.0.0',
        '--port', '8081',
        {trust_flag}
        '--dtype', '{dtype}',
        '--distributed-executor-backend', 'ray',
        '--tensor-parallel-size', '{tp_size}',
        '--pipeline-parallel-size', '{pp_size}',
        '--max-model-len', '{max_model_len}',
        '--gpu-memory-utilization', '{gpu_util}',
        '--download-dir', '/models',
        {eager_flag}
    ]
    
    print(f'Running: {{\\\" \\\".join(cmd)}}')
    subprocess.run(cmd)
    "
  runtimeEnvYAML: |
    env_vars:
      HF_HOME: /models/.cache
      TRANSFORMERS_CACHE: /models/.cache
      HF_HUB_CACHE: /models/.cache/hub
      VLLM_USE_CUDA_GRAPH: "0"
      NCCL_SOCKET_IFNAME: "^lo,docker"
      NCCL_IB_DISABLE: "1"
      NCCL_DEBUG: "WARN"
      NCCL_P2P_DISABLE: "1"
      GLOO_SOCKET_IFNAME: "enP7s7,enp1s0f1np1"
      NCCL_NET: "Socket"
  submitterPodTemplate:
    spec:
      containers:
        - name: job-submitter
          image: avarok/vllm-dgx-spark:v11
          imagePullPolicy: IfNotPresent
          env:
            - name: HF_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token-secret
                  key: HF_TOKEN
          resources:
            requests:
              cpu: "1"
              memory: "4Gi"
            limits:
              cpu: "2"
              memory: "8Gi"
      restartPolicy: Never
'''
        
        with open(servejob_file, 'w') as f:
            f.write(job_yaml)
        
        results.append({
            "step": "generate_job_yaml",
            "success": True,
            "output": f"Generated job YAML for {model_display} ({hf_id})"
        })
    except Exception as e:
        results.append({"step": "generate_job_yaml", "success": False, "output": str(e)})
    
    # Apply the generated job file
    if servejob_file.exists():
        ok, output = _run_kubectl_action(["apply", "-f", str(servejob_file)], timeout=30)
        results.append({"step": "apply_servejob", "success": ok, "output": output})
    
    # Step 5: Apply distributed service
    service_file = NEMOTRON_DEPLOYMENT_DIR / "service-distributed.yaml"
    if service_file.exists():
        ok, output = _run_kubectl_action(["apply", "-f", str(service_file)], timeout=30)
        results.append({"step": "apply_service", "success": ok, "output": output})
    
    success = all(r["success"] for r in results)
    
    # Record deployment to history
    _record_deployment(
        deployment_type="llm",
        action="deploy",
        model_name=model_name,
        model_display=model_display,
        model_hf_id=model_config.get("huggingface_id"),
        status="success" if success else "failed",
        message=f"Deploying {model_display}",
        details={"results": results}
    )
    
    return jsonify({
        "success": success,
        "message": f"Deploying {model_display}. Ray cluster will start shortly.",
        "model": model_name,
        "model_display": model_display,
        "results": results,
    })


@app.route("/nemotron/deploy/single", methods=["POST"])
def nemotron_deploy_single():
    """Deploy Nemotron in single-node mode."""
    status = _get_nemotron_status()
    results = []
    
    # Step 1: Delete distributed deployment if exists
    if status["mode"] == "distributed":
        # Delete RayJob
        ok, output = _run_kubectl_action([
            "delete", "rayjob", "vllm-serve", "-n", NEMOTRON_NAMESPACE,
            "--ignore-not-found"
        ])
        results.append({"step": "delete_rayjob", "success": ok, "output": output})
        
        # Delete RayCluster
        ok, output = _run_kubectl_action([
            "delete", "raycluster", "vllm-cluster", "-n", NEMOTRON_NAMESPACE,
            "--ignore-not-found"
        ])
        results.append({"step": "delete_raycluster", "success": ok, "output": output})
    
    # Step 2: Apply single-node deployment
    single_file = NEMOTRON_DEPLOYMENT_DIR / "deployment-single-node.yaml"
    if not single_file.exists():
        return jsonify({
            "success": False,
            "message": f"Single-node manifest not found: {single_file}",
        })
    
    ok, output = _run_kubectl_action(["apply", "-f", str(single_file)], timeout=30)
    results.append({"step": "apply_single", "success": ok, "output": output})
    
    # Step 3: Apply standard service
    service_file = NEMOTRON_DEPLOYMENT_DIR / "service.yaml"
    if service_file.exists():
        ok, output = _run_kubectl_action(["apply", "-f", str(service_file)], timeout=30)
        results.append({"step": "apply_service", "success": ok, "output": output})
    
    return jsonify({
        "success": all(r["success"] for r in results),
        "message": "Single-node deployment initiated.",
        "results": results,
    })


@app.route("/nemotron/delete", methods=["POST"])
def nemotron_delete():
    """Delete Nemotron deployment (both distributed and single-node)."""
    results = []
    
    # Delete RayJob
    ok, output = _run_kubectl_action([
        "delete", "rayjob", "vllm-serve", "-n", NEMOTRON_NAMESPACE,
        "--ignore-not-found"
    ])
    results.append({"step": "delete_rayjob", "success": ok, "output": output})
    
    # Delete RayCluster
    ok, output = _run_kubectl_action([
        "delete", "raycluster", "vllm-cluster", "-n", NEMOTRON_NAMESPACE,
        "--ignore-not-found"
    ])
    results.append({"step": "delete_raycluster", "success": ok, "output": output})
    
    # Delete single-node deployment
    ok, output = _run_kubectl_action([
        "delete", "deployment", "nemotron-vllm", "-n", NEMOTRON_NAMESPACE,
        "--ignore-not-found"
    ])
    results.append({"step": "delete_single", "success": ok, "output": output})
    
    # Note: Keep namespace, PVC, secrets, and LiteLLM intact
    
    return jsonify({
        "success": all(r["success"] for r in results),
        "message": "Nemotron deployment deleted. Namespace, PVC, secrets, and LiteLLM retained.",
        "results": results,
    })


@app.route("/nemotron/stop", methods=["POST"])
def nemotron_stop():
    """Stop Nemotron deployment (scale to 0 without deleting)."""
    status = _get_nemotron_status()
    results = []
    
    if status["mode"] == "not_deployed":
        return jsonify({
            "success": False,
            "message": "No deployment to stop.",
        })
    
    if status["mode"] == "distributed":
        # For distributed: Delete the RayJob (stops vLLM serve) but keep RayCluster
        ok, output = _run_kubectl_action([
            "delete", "rayjob", "vllm-serve", "-n", NEMOTRON_NAMESPACE,
            "--ignore-not-found"
        ])
        results.append({"step": "delete_rayjob", "success": ok, "output": output})
        
        # Scale down RayCluster workers to 0
        ok, output = _run_kubectl_action([
            "patch", "raycluster", "vllm-cluster", "-n", NEMOTRON_NAMESPACE,
            "--type=json", "-p", '[{"op": "replace", "path": "/spec/workerGroupSpecs/0/replicas", "value": 0}, {"op": "replace", "path": "/spec/workerGroupSpecs/0/minReplicas", "value": 0}]'
        ])
        results.append({"step": "scale_workers", "success": ok, "output": output})
        
        message = "Distributed deployment stopped. RayCluster retained but scaled to 0 workers."
    else:
        # For single-node: Scale deployment to 0
        ok, output = _run_kubectl_action([
            "scale", "deployment", "nemotron-vllm", "-n", NEMOTRON_NAMESPACE,
            "--replicas=0"
        ])
        results.append({"step": "scale_single", "success": ok, "output": output})
        message = "Single-node deployment stopped (scaled to 0 replicas)."
    
    return jsonify({
        "success": all(r["success"] for r in results),
        "message": message,
        "results": results,
    })


@app.route("/nemotron/start", methods=["POST"])
def nemotron_start():
    """Start a stopped Nemotron deployment (scale back up)."""
    status = _get_nemotron_status()
    results = []
    
    if status["mode"] == "not_deployed":
        return jsonify({
            "success": False,
            "message": "No deployment to start. Deploy first using Distributed or Single Node.",
        })
    
    if status["mode"] in ("distributed", "single"):
        return jsonify({
            "success": False,
            "message": "Deployment is already running.",
        })
    
    if status["mode"] == "distributed_stopped":
        # Scale RayCluster workers back to 1
        ok, output = _run_kubectl_action([
            "patch", "raycluster", "vllm-cluster", "-n", NEMOTRON_NAMESPACE,
            "--type=json", "-p", '[{"op": "replace", "path": "/spec/workerGroupSpecs/0/replicas", "value": 1}, {"op": "replace", "path": "/spec/workerGroupSpecs/0/minReplicas", "value": 1}]'
        ])
        results.append({"step": "scale_workers", "success": ok, "output": output})
        
        # Delete existing RayJob first (it may be in Succeeded/Failed state)
        ok, output = _run_kubectl_action([
            "delete", "rayjob", "vllm-serve", "-n", NEMOTRON_NAMESPACE,
            "--ignore-not-found"
        ])
        results.append({"step": "delete_old_rayjob", "success": ok, "output": output})
        
        # Re-apply the vLLM serve job
        serve_file = NEMOTRON_DEPLOYMENT_DIR / "vllm-serve-job.yaml"
        if serve_file.exists():
            ok, output = _run_kubectl_action(["apply", "-f", str(serve_file)], timeout=30)
            results.append({"step": "apply_serve_job", "success": ok, "output": output})
        else:
            results.append({"step": "apply_serve_job", "success": False, "output": f"Job file not found: {serve_file}"})
        
        message = "Distributed deployment starting. Workers scaled to 1 and vLLM serve job submitted."
        
    elif status["mode"] == "single_stopped":
        # Scale single-node deployment back to 1
        ok, output = _run_kubectl_action([
            "scale", "deployment", "nemotron-vllm", "-n", NEMOTRON_NAMESPACE,
            "--replicas=1"
        ])
        results.append({"step": "scale_single", "success": ok, "output": output})
        message = "Single-node deployment starting (scaled to 1 replica)."
    else:
        return jsonify({
            "success": False,
            "message": f"Unknown deployment state: {status['mode']}",
        })
    
    return jsonify({
        "success": all(r["success"] for r in results),
        "message": message,
        "results": results,
    })


@app.route("/nemotron/restart", methods=["POST"])
def nemotron_restart():
    """Restart vLLM serve job (delete and re-apply)."""
    status = _get_nemotron_status()
    results = []
    
    if status["mode"] not in ("distributed", "distributed_stopped"):
        return jsonify({
            "success": False,
            "message": "Restart only available for distributed deployment.",
        })
    
    # Delete existing RayJob
    ok, output = _run_kubectl_action([
        "delete", "rayjob", "vllm-serve", "-n", NEMOTRON_NAMESPACE,
        "--ignore-not-found"
    ])
    results.append({"step": "delete_rayjob", "success": ok, "output": output})
    
    # Re-apply the vLLM serve job
    serve_file = NEMOTRON_DEPLOYMENT_DIR / "vllm-serve-job.yaml"
    if serve_file.exists():
        ok, output = _run_kubectl_action(["apply", "-f", str(serve_file)], timeout=30)
        results.append({"step": "apply_serve_job", "success": ok, "output": output})
    else:
        results.append({"step": "apply_serve_job", "success": False, "output": f"Job file not found: {serve_file}"})
    
    return jsonify({
        "success": all(r["success"] for r in results),
        "message": "vLLM serve job restarted. Model loading may take several minutes.",
        "results": results,
    })


@app.route("/nemotron/health", methods=["GET"])
def nemotron_health():
    """Check vLLM and LiteLLM health endpoints."""
    health = {"vllm": None, "litellm": None, "models": None}
    
    # Check vLLM health
    try:
        req = urllib.request.Request(
            f"http://{VLLM_DISTRIBUTED_IP}:{VLLM_DISTRIBUTED_PORT}/health",
            method="GET"
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            health["vllm"] = {
                "healthy": resp.status == 200,
                "status_code": resp.status,
                "endpoint": f"http://{VLLM_DISTRIBUTED_IP}:{VLLM_DISTRIBUTED_PORT}",
            }
    except urllib.error.URLError as e:
        health["vllm"] = {"healthy": False, "error": str(e.reason)}
    except Exception as e:
        health["vllm"] = {"healthy": False, "error": str(e)}
    
    # Check LiteLLM health
    try:
        req = urllib.request.Request(
            f"http://{LITELLM_IP}:{LITELLM_PORT}/health/readiness",
            method="GET"
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            health["litellm"] = {
                "healthy": resp.status == 200,
                "status_code": resp.status,
                "endpoint": f"http://{LITELLM_IP}:{LITELLM_PORT}",
            }
    except urllib.error.URLError as e:
        health["litellm"] = {"healthy": False, "error": str(e.reason)}
    except Exception as e:
        health["litellm"] = {"healthy": False, "error": str(e)}
    
    # Get available models from vLLM
    if health["vllm"] and health["vllm"].get("healthy"):
        try:
            req = urllib.request.Request(
                f"http://{VLLM_DISTRIBUTED_IP}:{VLLM_DISTRIBUTED_PORT}/v1/models",
                method="GET"
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                import json as _json
                data = _json.loads(resp.read().decode())
                health["models"] = [m.get("id") for m in data.get("data", [])]
        except Exception:
            pass
    
    return jsonify(health)


@app.route("/nemotron/logs", methods=["GET"])
def nemotron_logs():
    """Get logs from Ray head pod."""
    lines = request.args.get("lines", "100")
    
    # Get head pod name
    ok, output = _run_kubectl([
        "get", "pods", "-n", NEMOTRON_NAMESPACE,
        "-l", "ray-node-type=head",
        "-o", "jsonpath={.items[0].metadata.name}"
    ])
    
    if not ok or not output.strip():
        return jsonify({"success": False, "logs": "", "error": "Head pod not found"})
    
    pod_name = output.strip()
    ok, logs = _run_kubectl_action([
        "logs", pod_name, "-n", NEMOTRON_NAMESPACE, f"--tail={lines}"
    ], timeout=30)
    
    return jsonify({
        "success": ok,
        "pod": pod_name,
        "logs": logs if ok else "",
        "error": logs if not ok else None,
    })


@app.route("/deployment/history", methods=["GET"])
def deployment_history():
    """Get deployment history for all or specific deployment types."""
    deployment_type = request.args.get("type")  # 'llm', 'imagegen', or None for all
    limit = int(request.args.get("limit", 50))
    
    history = _get_deployment_history(deployment_type, limit)
    
    return jsonify({
        "success": True,
        "history": history,
        "count": len(history),
    })


@app.route("/nemotron/litellm/restart", methods=["POST"])
def nemotron_litellm_restart():
    """Restart LiteLLM proxy deployment."""
    ok, output = _run_kubectl_action([
        "rollout", "restart", "deployment", "litellm-proxy", "-n", NEMOTRON_NAMESPACE
    ])
    return jsonify({"success": ok, "message": output})


# --------------------------------------------------------------------------
# LLM Chat API (via LiteLLM proxy or direct vLLM)
# --------------------------------------------------------------------------

@app.route("/llm/chat", methods=["POST"])
def llm_chat():
    """Send a chat completion request via LiteLLM proxy."""
    data = request.get_json() or {}
    
    messages = data.get("messages", [])
    model = data.get("model", "nemotron")  # LiteLLM model alias
    max_tokens = data.get("max_tokens", 1024)
    temperature = data.get("temperature", 0.7)
    use_litellm = data.get("use_litellm", True)
    
    if not messages:
        return jsonify({"success": False, "error": "No messages provided"})
    
    # Choose endpoint
    if use_litellm:
        url = f"http://{LITELLM_IP}:{LITELLM_PORT}/v1/chat/completions"
    else:
        url = f"http://{VLLM_DISTRIBUTED_IP}:{VLLM_DISTRIBUTED_PORT}/v1/chat/completions"
    
    payload = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
    }
    
    headers = {"Content-Type": "application/json"}
    if use_litellm:
        headers["Authorization"] = f"Bearer {LITELLM_API_KEY}"
    
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers=headers,
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=180) as response:
            result = json.loads(response.read().decode())
            content = result.get("choices", [{}])[0].get("message", {}).get("content", "")
            usage = result.get("usage", {})
            return jsonify({
                "success": True,
                "content": content,
                "usage": usage,
                "model": result.get("model", model),
            })
    except urllib.error.HTTPError as e:
        error_body = e.read().decode() if e.fp else str(e)
        return jsonify({"success": False, "error": f"HTTP {e.code}: {error_body}"})
    except urllib.error.URLError as e:
        return jsonify({"success": False, "error": f"Connection failed: {e.reason}"})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})


@app.route("/llm/chat/stream", methods=["POST"])
def llm_chat_stream():
    """Stream chat completion response via SSE."""
    data = request.get_json() or {}
    
    messages = data.get("messages", [])
    model = data.get("model", "nemotron")
    max_tokens = data.get("max_tokens", 1024)
    temperature = data.get("temperature", 0.7)
    use_litellm = data.get("use_litellm", True)
    
    if not messages:
        def error_gen():
            yield f"data: {json.dumps({'error': 'No messages provided'})}\n\n"
        return Response(error_gen(), mimetype="text/event-stream")
    
    # Choose endpoint
    if use_litellm:
        url = f"http://{LITELLM_IP}:{LITELLM_PORT}/v1/chat/completions"
    else:
        url = f"http://{VLLM_DISTRIBUTED_IP}:{VLLM_DISTRIBUTED_PORT}/v1/chat/completions"
    
    payload = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": True,
    }
    
    headers = {"Content-Type": "application/json"}
    if use_litellm:
        headers["Authorization"] = f"Bearer {LITELLM_API_KEY}"
    
    def generate():
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode(),
                headers=headers,
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=300) as response:
                for line in response:
                    line = line.decode().strip()
                    if line.startswith("data: "):
                        yield f"{line}\n\n"
                        if line == "data: [DONE]":
                            break
        except Exception as e:
            yield f"data: {json.dumps({'error': str(e)})}\n\n"
    
    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.route("/llm/models/available", methods=["GET"])
def llm_models_available():
    """Get models available in LiteLLM."""
    result = {"litellm": [], "vllm": []}
    
    # Try LiteLLM
    try:
        req = urllib.request.Request(f"http://{LITELLM_IP}:{LITELLM_PORT}/v1/models")
        req.add_header("Authorization", f"Bearer {LITELLM_API_KEY}")
        with urllib.request.urlopen(req, timeout=5) as response:
            data = json.loads(response.read().decode())
            result["litellm"] = [m.get("id") for m in data.get("data", [])]
    except Exception:
        pass
    
    # Try vLLM direct
    try:
        req = urllib.request.Request(f"http://{VLLM_DISTRIBUTED_IP}:{VLLM_DISTRIBUTED_PORT}/v1/models")
        with urllib.request.urlopen(req, timeout=5) as response:
            data = json.loads(response.read().decode())
            result["vllm"] = [m.get("id") for m in data.get("data", [])]
    except Exception:
        pass
    
    return jsonify(result)


# --------------------------------------------------------------------------
# Image Generation Deployment
# --------------------------------------------------------------------------

IMAGEGEN_NAMESPACE = "image-gen"
IMAGEGEN_DEPLOYMENT_DIR = Path(os.environ.get(
    "IMAGEGEN_DEPLOYMENT_DIR",
    "~/dgx-spark-toolkit/deployments/image-gen"
)).expanduser()
IMAGEGEN_LB_IP = os.environ.get("IMAGEGEN_LB_IP", "192.168.86.210")

# Available image generation models
IMAGEGEN_MODELS = {
    "qwen-image-2512": {
        "name": "qwen-image-2512",
        "display_name": "Qwen-Image-2512",
        "huggingface_id": "Qwen/Qwen-Image-2512",
        "description": "Qwen's text-to-image generation model - 2512px output",
        "size_gb": 41,
        "min_vram_gb": 48,
    },
    "stable-diffusion-xl": {
        "name": "stable-diffusion-xl",
        "display_name": "Stable Diffusion XL",
        "huggingface_id": "stabilityai/stable-diffusion-xl-base-1.0",
        "description": "Stability AI's SDXL - high quality 1024px images",
        "size_gb": 12,
        "min_vram_gb": 16,
    },
    "flux2-dev": {
        "name": "flux2-dev",
        "display_name": "FLUX.2 Dev",
        "huggingface_id": "black-forest-labs/FLUX.2-dev",
        "description": "FLUX.2 high-quality model - requires HF auth & license",
        "size_gb": 34,
        "min_vram_gb": 24,
        "gated": True,
    },
    "sd35-medium": {
        "name": "sd35-medium",
        "display_name": "SD 3.5 Medium",
        "huggingface_id": "stabilityai/stable-diffusion-3.5-medium",
        "description": "Stable Diffusion 3.5 Medium - requires HF auth",
        "size_gb": 18,
        "min_vram_gb": 16,
        "gated": True,
    },
}


# Direct access to image generation history (works even when service is down)
# NFS shared storage - accessible from both nodes
IMAGEGEN_STORAGE_DIR = Path(os.environ.get(
    "IMAGEGEN_STORAGE_DIR", 
    "/nfs/imagegen"  # NFS shared storage
))
IMAGEGEN_DB_PATH = IMAGEGEN_STORAGE_DIR / "history.db"

# Legacy fallback paths (for migration period)
IMAGEGEN_LEGACY_PATHS = [
    Path("/data/models/image-gen/generated_images"),  # Local hostPath
]
IMAGEGEN_REMOTE_NODE = os.environ.get("IMAGEGEN_REMOTE_NODE", "spark-ba63")
IMAGEGEN_REMOTE_PATH = os.environ.get("IMAGEGEN_REMOTE_PATH", "/data/models/image-gen/generated_images")


def _imagegen_db_connect() -> Optional[sqlite3.Connection]:
    """Connect to the image generation history database (local)."""
    if not IMAGEGEN_DB_PATH.exists():
        return None
    try:
        conn = sqlite3.connect(str(IMAGEGEN_DB_PATH), timeout=5)
        conn.row_factory = sqlite3.Row
        return conn
    except Exception:
        return None


def _imagegen_remote_query(sql: str) -> List[Dict]:
    """Query the remote node's SQLite database via SSH."""
    try:
        cmd = [
            "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            IMAGEGEN_REMOTE_NODE,
            f"sqlite3 -json {IMAGEGEN_REMOTE_PATH}/history.db \"{sql}\""
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout)
        return []
    except Exception:
        return []


def _imagegen_get_history(limit: int = 50, offset: int = 0, model: str = "") -> List[Dict]:
    """Get generation history from both local and remote databases."""
    all_results = []
    
    # Local database
    conn = _imagegen_db_connect()
    if conn:
        try:
            query = "SELECT * FROM generations"
            params = []
            if model:
                query += " WHERE model = ?"
                params.append(model)
            query += " ORDER BY timestamp DESC"
            
            cursor = conn.execute(query, params)
            for row in cursor.fetchall():
                record = dict(row)
                record["_source"] = "local"
                all_results.append(record)
        except Exception:
            pass
        finally:
            conn.close()
    
    # Remote database
    where_clause = f"WHERE model = '{model}'" if model else ""
    remote_sql = f"SELECT * FROM generations {where_clause} ORDER BY timestamp DESC"
    remote_rows = _imagegen_remote_query(remote_sql)
    for row in remote_rows:
        row["_source"] = "remote"
        all_results.append(row)
    
    # Deduplicate by ID (in case of sync) and sort by timestamp
    seen_ids = set()
    unique_results = []
    for r in all_results:
        if r.get("id") not in seen_ids:
            seen_ids.add(r.get("id"))
            unique_results.append(r)
    
    # Sort by timestamp descending
    unique_results.sort(key=lambda x: x.get("timestamp", ""), reverse=True)
    
    # Apply offset/limit
    return unique_results[offset:offset + limit]


def _imagegen_get_stats() -> Dict:
    """Get generation statistics from both local and remote databases."""
    by_model = {}
    total = 0
    
    # Local database
    conn = _imagegen_db_connect()
    if conn:
        try:
            total += conn.execute("SELECT COUNT(*) FROM generations").fetchone()[0]
            rows = conn.execute("""
                SELECT model, COUNT(*) as count, AVG(generation_time_ms) as avg_time_ms
                FROM generations GROUP BY model
            """).fetchall()
            
            for row in rows:
                model = row["model"]
                if model not in by_model:
                    by_model[model] = {"count": 0, "total_time": 0}
                by_model[model]["count"] += row["count"]
                by_model[model]["total_time"] += (row["avg_time_ms"] or 0) * row["count"]
        except Exception:
            pass
        finally:
            conn.close()
    
    # Remote database
    remote_rows = _imagegen_remote_query(
        "SELECT model, COUNT(*) as count, AVG(generation_time_ms) as avg_time_ms FROM generations GROUP BY model"
    )
    for row in remote_rows:
        model = row.get("model")
        if model:
            if model not in by_model:
                by_model[model] = {"count": 0, "total_time": 0}
            count = row.get("count", 0)
            avg_time = row.get("avg_time_ms", 0) or 0
            by_model[model]["count"] += count
            by_model[model]["total_time"] += avg_time * count
            total += count
    
    # Calculate final averages
    for model in by_model:
        count = by_model[model]["count"]
        by_model[model]["avg_time_ms"] = by_model[model]["total_time"] / count if count > 0 else 0
        del by_model[model]["total_time"]
    
    return {"total_generations": total, "by_model": by_model}


def _imagegen_get_metadata(gen_id: str) -> Optional[Dict]:
    """Get metadata for a specific generation from local or remote database."""
    # Try local first
    conn = _imagegen_db_connect()
    if conn:
        try:
            cursor = conn.execute("SELECT * FROM generations WHERE id = ?", (gen_id,))
            row = cursor.fetchone()
            if row:
                result = dict(row)
                result["_source"] = "local"
                return result
        except Exception:
            pass
        finally:
            conn.close()
    
    # Try remote
    remote_rows = _imagegen_remote_query(f"SELECT * FROM generations WHERE id = '{gen_id}'")
    if remote_rows:
        result = remote_rows[0]
        result["_source"] = "remote"
        return result
    
    return None


def _imagegen_get_image_path(gen_id: str) -> Optional[Path]:
    """Get the path to a generated image file (local only)."""
    # Try common extensions and date-based paths
    for ext in [".png", ".jpg", ".jpeg", ".webp"]:
        # Direct path
        path = IMAGEGEN_STORAGE_DIR / f"{gen_id}{ext}"
        if path.exists():
            return path
        # Date-based subdirectories
        for subdir in IMAGEGEN_STORAGE_DIR.iterdir():
            if subdir.is_dir():
                path = subdir / f"{gen_id}{ext}"
                if path.exists():
                    return path
    return None


def _imagegen_get_remote_image(gen_id: str) -> Optional[bytes]:
    """Fetch image from remote node via SSH."""
    try:
        # Find the image on remote
        find_cmd = [
            "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            IMAGEGEN_REMOTE_NODE,
            f"find {IMAGEGEN_REMOTE_PATH} -name '{gen_id}.*' -type f | head -1"
        ]
        result = subprocess.run(find_cmd, capture_output=True, text=True, timeout=10)
        if result.returncode != 0 or not result.stdout.strip():
            return None
        
        remote_path = result.stdout.strip()
        
        # Fetch the image
        cat_cmd = [
            "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            IMAGEGEN_REMOTE_NODE,
            f"cat '{remote_path}'"
        ]
        result = subprocess.run(cat_cmd, capture_output=True, timeout=30)
        if result.returncode == 0:
            return result.stdout
        return None
    except Exception:
        return None


def _get_imagegen_status() -> Dict[str, object]:
    """Get image generation deployment status."""
    result = {
        "deployed": False,
        "ready": False,
        "model": None,
        "replicas": 0,
        "ready_replicas": 0,
        "pods": [],
        "endpoint": None,
    }
    
    try:
        # Check deployment
        proc = subprocess.run(
            ["kubectl", "get", "deployment", "image-gen", "-n", IMAGEGEN_NAMESPACE,
             "-o", "jsonpath={.status.replicas},{.status.readyReplicas},{.spec.template.spec.containers[0].env[?(@.name=='MODEL_NAME')].value}"],
            capture_output=True, text=True, timeout=10
        )
        if proc.returncode == 0 and proc.stdout:
            parts = proc.stdout.split(",")
            if len(parts) >= 2:
                result["deployed"] = True
                result["replicas"] = int(parts[0]) if parts[0] else 0
                result["ready_replicas"] = int(parts[1]) if parts[1] else 0
                result["model"] = parts[2] if len(parts) > 2 and parts[2] else "qwen-image-2512"
                result["ready"] = result["ready_replicas"] > 0
        
        # Get pods
        proc = subprocess.run(
            ["kubectl", "get", "pods", "-n", IMAGEGEN_NAMESPACE,
             "-l", "app=image-gen", "-o", "jsonpath={range .items[*]}{.metadata.name},{.status.phase},{.spec.nodeName}\n{end}"],
            capture_output=True, text=True, timeout=10
        )
        if proc.returncode == 0:
            for line in proc.stdout.strip().split("\n"):
                if line:
                    parts = line.split(",")
                    if len(parts) >= 2:
                        result["pods"].append({
                            "name": parts[0],
                            "status": parts[1],
                            "node": parts[2] if len(parts) > 2 else "",
                        })
        
        # Get service endpoint
        proc = subprocess.run(
            ["kubectl", "get", "svc", "image-gen", "-n", IMAGEGEN_NAMESPACE,
             "-o", "jsonpath={.status.loadBalancer.ingress[0].ip}"],
            capture_output=True, text=True, timeout=10
        )
        if proc.returncode == 0 and proc.stdout:
            result["endpoint"] = f"http://{proc.stdout}"
        
    except Exception as e:
        result["error"] = str(e)
    
    return result


@app.route("/imagegen/status", methods=["GET"])
def imagegen_status():
    """Get image generation deployment status."""
    return jsonify(_get_imagegen_status())


@app.route("/imagegen/models", methods=["GET"])
def imagegen_models():
    """List available image generation models."""
    status = _get_imagegen_status()
    return jsonify({
        "models": IMAGEGEN_MODELS,
        "current_model": status.get("model"),
        "deployed": status.get("deployed", False),
    })


@app.route("/imagegen/deploy", methods=["POST"])
@app.route("/imagegen/deploy/<mode>", methods=["POST"])
def imagegen_deploy(mode=None):
    """Deploy image generation service."""
    data = request.get_json() or {}
    
    model_name = data.get("model", "qwen-image-2512")
    replicas = data.get("replicas", 2)
    
    if model_name not in IMAGEGEN_MODELS:
        return jsonify({"success": False, "error": f"Unknown model: {model_name}"})
    
    try:
        # Create namespace
        namespace_file = IMAGEGEN_DEPLOYMENT_DIR / "namespace.yaml"
        if namespace_file.exists():
            subprocess.run(["kubectl", "apply", "-f", str(namespace_file)], 
                         capture_output=True, timeout=30)
        
        # Create ConfigMap with server code
        server_file = IMAGEGEN_DEPLOYMENT_DIR / "server.py"
        if server_file.exists():
            subprocess.run([
                "kubectl", "create", "configmap", "image-gen-server",
                f"--namespace={IMAGEGEN_NAMESPACE}",
                f"--from-file=server.py={server_file}",
                "--dry-run=client", "-o", "yaml"
            ], capture_output=True, timeout=30)
            
            proc = subprocess.run([
                "kubectl", "create", "configmap", "image-gen-server",
                f"--namespace={IMAGEGEN_NAMESPACE}",
                f"--from-file=server.py={server_file}",
                "--dry-run=client", "-o", "yaml"
            ], capture_output=True, text=True, timeout=30)
            
            if proc.returncode == 0:
                apply_proc = subprocess.run(
                    ["kubectl", "apply", "-f", "-"],
                    input=proc.stdout, capture_output=True, text=True, timeout=30
                )
        
        # Create model config
        subprocess.run([
            "kubectl", "create", "configmap", "image-gen-config",
            f"--namespace={IMAGEGEN_NAMESPACE}",
            f"--from-literal=MODEL_NAME={model_name}",
            "--dry-run=client", "-o", "yaml"
        ], capture_output=True, timeout=30)
        
        proc = subprocess.run([
            "kubectl", "create", "configmap", "image-gen-config",
            f"--namespace={IMAGEGEN_NAMESPACE}",
            f"--from-literal=MODEL_NAME={model_name}",
            "--dry-run=client", "-o", "yaml"
        ], capture_output=True, text=True, timeout=30)
        
        if proc.returncode == 0:
            subprocess.run(
                ["kubectl", "apply", "-f", "-"],
                input=proc.stdout, capture_output=True, text=True, timeout=30
            )
        
        # Apply deployment with model substitution
        deployment_file = IMAGEGEN_DEPLOYMENT_DIR / "deployment.yaml"
        if deployment_file.exists():
            with open(deployment_file) as f:
                deployment_yaml = f.read()
            
            # Substitute model name and replicas
            deployment_yaml = deployment_yaml.replace(
                'value: "qwen-image-2512"',
                f'value: "{model_name}"'
            )
            deployment_yaml = deployment_yaml.replace(
                'replicas: 2',
                f'replicas: {replicas}'
            )
            
            proc = subprocess.run(
                ["kubectl", "apply", "-f", "-"],
                input=deployment_yaml, capture_output=True, text=True, timeout=60
            )
            if proc.returncode != 0:
                return jsonify({"success": False, "error": proc.stderr})
        
        # Apply service
        service_file = IMAGEGEN_DEPLOYMENT_DIR / "service.yaml"
        if service_file.exists():
            subprocess.run(["kubectl", "apply", "-f", str(service_file)],
                         capture_output=True, timeout=30)
        
        return jsonify({
            "success": True,
            "message": f"Deploying {model_name} with {replicas} replicas",
            "model": IMAGEGEN_MODELS.get(model_name, {}),
        })
        
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})


@app.route("/imagegen/delete", methods=["POST"])
def imagegen_delete():
    """Delete image generation deployment."""
    try:
        subprocess.run([
            "kubectl", "delete", "deployment", "image-gen",
            "-n", IMAGEGEN_NAMESPACE, "--ignore-not-found"
        ], capture_output=True, timeout=60)
        
        subprocess.run([
            "kubectl", "delete", "svc", "image-gen", "image-gen-internal", "image-gen-headless",
            "-n", IMAGEGEN_NAMESPACE, "--ignore-not-found"
        ], capture_output=True, timeout=30)
        
        subprocess.run([
            "kubectl", "delete", "configmap", "image-gen-server", "image-gen-config",
            "-n", IMAGEGEN_NAMESPACE, "--ignore-not-found"
        ], capture_output=True, timeout=30)
        
        return jsonify({"success": True, "message": "Image generation deployment deleted"})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})


@app.route("/imagegen/scale", methods=["POST"])
def imagegen_scale():
    """Scale image generation deployment."""
    data = request.get_json() or {}
    replicas = data.get("replicas", 2)
    
    try:
        proc = subprocess.run([
            "kubectl", "scale", "deployment", "image-gen",
            "-n", IMAGEGEN_NAMESPACE, f"--replicas={replicas}"
        ], capture_output=True, text=True, timeout=30)
        
        if proc.returncode != 0:
            return jsonify({"success": False, "error": proc.stderr})
        
        return jsonify({"success": True, "message": f"Scaled to {replicas} replicas"})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})


@app.route("/imagegen/logs", methods=["GET"])
def imagegen_logs():
    """Get logs from image generation pods."""
    lines = request.args.get("lines", "100")
    
    try:
        # Get first pod name
        proc = subprocess.run([
            "kubectl", "get", "pods", "-n", IMAGEGEN_NAMESPACE,
            "-l", "app=image-gen", "-o", "jsonpath={.items[0].metadata.name}"
        ], capture_output=True, text=True, timeout=10)
        
        if proc.returncode != 0 or not proc.stdout:
            return jsonify({"success": False, "error": "No pods found"})
        
        pod_name = proc.stdout.strip()
        
        proc = subprocess.run([
            "kubectl", "logs", pod_name, "-n", IMAGEGEN_NAMESPACE, f"--tail={lines}"
        ], capture_output=True, text=True, timeout=30)
        
        return jsonify({
            "success": True,
            "pod": pod_name,
            "logs": proc.stdout,
        })
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})


@app.route("/imagegen/health", methods=["GET"])
def imagegen_health():
    """Check image generation service health."""
    status = _get_imagegen_status()
    
    if not status.get("endpoint"):
        return jsonify({
            "healthy": False,
            "error": "No endpoint available",
            "status": status,
        })
    
    try:
        url = f"{status['endpoint']}/api/health"
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read().decode())
            return jsonify({
                "healthy": True,
                "response": data,
                "status": status,
            })
    except Exception as e:
        return jsonify({
            "healthy": False,
            "error": str(e),
            "status": status,
        })


@app.route("/imagegen/generate", methods=["POST"])
def imagegen_generate():
    """Generate an image via the deployed service."""
    data = request.get_json() or {}
    prompt = data.get("prompt", "")
    
    if not prompt:
        return jsonify({"success": False, "error": "No prompt provided"})
    
    status = _get_imagegen_status()
    if not status.get("endpoint"):
        return jsonify({"success": False, "error": "Image generation service not available"})
    
    try:
        url = f"{status['endpoint']}/api/generate"
        payload = {
            "prompt": prompt,
            "negative_prompt": data.get("negative_prompt", ""),
            "steps": data.get("steps", 30),
            "guidance_scale": data.get("guidance_scale", 7.5),
            "width": data.get("width"),
            "height": data.get("height"),
            "seed": data.get("seed", -1),
            "return_base64": True,
        }
        
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        
        with urllib.request.urlopen(req, timeout=300) as response:
            result = json.loads(response.read().decode())
            return jsonify(result)
            
    except urllib.error.HTTPError as e:
        error_body = e.read().decode() if e.fp else str(e)
        return jsonify({"success": False, "error": f"HTTP {e.code}: {error_body}"})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})


@app.route("/imagegen/proxy/history", methods=["GET"])
def imagegen_proxy_history():
    """Proxy to image generation history API, with fallback to direct DB access."""
    limit = int(request.args.get("limit", 50))
    offset = int(request.args.get("offset", 0))
    model = request.args.get("model", "")
    
    # Try the service first if available
    status = _get_imagegen_status()
    if status.get("endpoint") and status.get("ready"):
        try:
            url = f"{status['endpoint']}/api/history?limit={limit}&offset={offset}"
            if model:
                url += f"&model={model}"
            
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=10) as response:
                result = json.loads(response.read().decode())
                return jsonify(result)
        except Exception:
            pass  # Fall through to direct access
    
    # Direct database access (works even when service is down)
    history = _imagegen_get_history(limit, offset, model)
    return jsonify({"success": True, "history": history, "source": "direct"})


@app.route("/imagegen/proxy/stats", methods=["GET"])
def imagegen_proxy_stats():
    """Proxy to image generation stats API, with fallback to direct DB access."""
    # Try the service first if available
    status = _get_imagegen_status()
    if status.get("endpoint") and status.get("ready"):
        try:
            url = f"{status['endpoint']}/api/stats"
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=10) as response:
                result = json.loads(response.read().decode())
                return jsonify(result)
        except Exception:
            pass  # Fall through to direct access
    
    # Direct database access (works even when service is down)
    stats = _imagegen_get_stats()
    return jsonify({"success": True, "stats": stats, "source": "direct"})


@app.route("/imagegen/proxy/image/<gen_id>", methods=["GET"])
def imagegen_proxy_image(gen_id: str):
    """Proxy to get a generated image, with fallback to direct file access."""
    # Try the service first if available
    status = _get_imagegen_status()
    if status.get("endpoint") and status.get("ready"):
        try:
            url = f"{status['endpoint']}/api/image/{gen_id}"
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=10) as response:
                image_data = response.read()
                return Response(image_data, mimetype="image/png")
        except Exception:
            pass  # Fall through to direct access
    
    # Try local file access first
    image_path = _imagegen_get_image_path(gen_id)
    if image_path and image_path.exists():
        ext = image_path.suffix.lower()
        mimetypes = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}
        mimetype = mimetypes.get(ext, "image/png")
        
        with open(image_path, "rb") as f:
            return Response(f.read(), mimetype=mimetype)
    
    # Try remote node
    remote_data = _imagegen_get_remote_image(gen_id)
    if remote_data:
        return Response(remote_data, mimetype="image/png")
    
    return jsonify({"success": False, "error": "Image not found"}), 404


@app.route("/imagegen/proxy/image/<gen_id>/metadata", methods=["GET"])
def imagegen_proxy_image_metadata(gen_id: str):
    """Proxy to get image metadata, with fallback to direct DB access."""
    # Try the service first if available
    status = _get_imagegen_status()
    if status.get("endpoint") and status.get("ready"):
        try:
            url = f"{status['endpoint']}/api/image/{gen_id}/metadata"
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=10) as response:
                result = json.loads(response.read().decode())
                return jsonify(result)
        except Exception:
            pass  # Fall through to direct access
    
    # Direct database access (works even when service is down)
    metadata = _imagegen_get_metadata(gen_id)
    if metadata:
        return jsonify({"success": True, "metadata": metadata, "source": "direct"})
    
    return jsonify({"success": False, "error": "Metadata not found"})


# --------------------------------------------------------------------------
# Kubernetes Dashboard Token
# --------------------------------------------------------------------------

@app.route("/k8s-dashboard/token", methods=["GET"])
def k8s_dashboard_token():
    """Get the Kubernetes Dashboard admin token."""
    try:
        result = subprocess.run(
            ["kubectl", "get", "secret", "dashboard-admin-token", "-n", "kubernetes-dashboard",
             "-o", "jsonpath={.data.token}"],
            capture_output=True,
            text=True,
            timeout=10
        )
        if result.returncode == 0 and result.stdout:
            import base64
            token = base64.b64decode(result.stdout).decode('utf-8')
            return jsonify({"success": True, "token": token})
        else:
            return jsonify({"success": False, "error": result.stderr or "Token not found"})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), debug=False)
