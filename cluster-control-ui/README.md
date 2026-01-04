# Cluster Control UI

A lightweight Flask web app that runs on the control-plane host (outside the Kubernetes cluster) and exposes buttons to execute `~/bin/start-k8s-cluster.sh` and `~/bin/stop-k8s-cluster.sh`. Output streams live in the browser while the script is running, buttons disable to prevent concurrent runs, and a history of recent executions remains visible.

## Features
- Minimal HTML UI with “Start”/“Stop”/“Check” buttons that disable while a command is in-flight.
- Live log streaming directly from the underlying script plus a command history once it finishes.
- Optional automated health checks that stream output from `check-k8s-cluster.sh`.
- Configurable script paths, sudo usage, and history length via environment variables.
- Works with `sudo` so long as you grant passwordless sudo to the scripts (recommended via `/etc/sudoers.d/cluster-ui`).

## Quick Start
```bash
cd ~/cluster-control-ui
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export FLASK_APP=app.py
export CLUSTER_UI_SECRET="choose-a-random-secret"
# Optional overrides:
# export K8S_START_SCRIPT=/home/doran/bin/start-k8s-cluster.sh
# export K8S_STOP_SCRIPT=/home/doran/bin/stop-k8s-cluster.sh
# export K8S_CHECK_SCRIPT=/home/doran/bin/check-k8s-cluster.sh
# export K8S_UI_USE_SUDO=1
# export CLUSTER_UI_AUTO_CHECK_SECONDS=900
flask run --host 0.0.0.0 --port 8080
```
Then visit `http://<control-plane-ip>:8080/` from your browser.

## Environment Variables
| Variable | Default | Description |
| --- | --- | --- |
| `K8S_START_SCRIPT` | `~/bin/start-k8s-cluster.sh` | Path to the start script. |
| `K8S_STOP_SCRIPT` | `~/bin/stop-k8s-cluster.sh` | Path to the stop script. |
| `K8S_CHECK_SCRIPT` | `~/bin/check-k8s-cluster.sh` | Path to the health check script. |
| `K8S_UI_USE_SUDO` | `1` | If set to `0`, the UI will not prefix commands with `sudo`. |
| `K8S_UI_HISTORY` | `10` | Number of previous runs to display. |
| `CLUSTER_UI_AUTO_CHECK_SECONDS` | `0` | Interval (seconds) for automated health checks. `0` disables auto-checking. |
| `CLUSTER_UI_SECRET` | `cluster-ui-dev-secret` | Flask secret for session/flash data (set this in production). |
| `PORT` | `8080` | Port when running via `python app.py`. |

## Passwordless sudo (recommended)
Add a sudoers entry (run `sudo visudo -f /etc/sudoers.d/cluster-ui`):
```
doran ALL=(ALL) NOPASSWD: /home/doran/bin/start-k8s-cluster.sh, /home/doran/bin/stop-k8s-cluster.sh, /home/doran/bin/check-k8s-cluster.sh
```
Adjust the username/path as needed. This lets the web app invoke the scripts without prompting for a password.

## Systemd service example
Create `/etc/systemd/system/cluster-control-ui.service`:
```ini
[Unit]
Description=Cluster Control UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=doran
Group=doran
WorkingDirectory=/home/doran/dgx-spark-toolkit/cluster-control-ui

# Environment
Environment=FLASK_APP=app.py
Environment=CLUSTER_UI_SECRET=replace-me-with-random-string
Environment=PYTHONUNBUFFERED=1

# Command
ExecStart=/home/doran/dgx-spark-toolkit/cluster-control-ui/.venv/bin/flask run --host 0.0.0.0 --port 8085

# Restart behavior
Restart=on-failure
RestartSec=5
StartLimitBurst=5
StartLimitIntervalSec=60

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/doran/dgx-spark-toolkit/cluster-control-ui
PrivateTmp=true

# Resource limits (optional)
MemoryMax=512M
CPUQuota=100%

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cluster-control-ui.service
```

### Managing the service

```bash
# Check status
sudo systemctl status cluster-control-ui.service

# Stop the service
sudo systemctl stop cluster-control-ui.service

# Start the service
sudo systemctl start cluster-control-ui.service

# Restart the service
sudo systemctl restart cluster-control-ui.service

# View logs (follow live)
sudo journalctl -u cluster-control-ui.service -f

# View last 50 log lines
sudo journalctl -u cluster-control-ui.service -n 50

# Disable from starting at boot
sudo systemctl disable cluster-control-ui.service
```

Default port is 8085; adjust firewall rules accordingly.

## Security Notes
- This UI intentionally does **not** implement authentication. Restrict network access (e.g., SSH tunnel or VPN) or place it behind a reverse proxy with auth.
- Anyone with access to the UI can run privileged scripts; protect the service accordingly.

## Health Check Script
The root of this repository provides `../scripts/check-k8s-cluster.sh`, a read-only helper that runs `kubectl cluster-info`, enumerates nodes, gathers pod/service summaries for key namespaces, and prints GPU inventory via `nvidia-smi`. Copy or symlink it into `~/bin` (or point `K8S_CHECK_SCRIPT` directly at the repo copy) and grant passwordless sudo so the **Check Cluster** button can execute it. Set `CLUSTER_UI_AUTO_CHECK_SECONDS` to a non-zero value if you want the UI to trigger the script periodically in the background.
