#!/usr/bin/env bash
#
# Install Cluster Control UI as a systemd service
#
# Usage: sudo ./install.sh [OPTIONS]
#
# Options:
#   --user USER          User to run the service as (default: current user)
#   --port PORT          Port for the service (default: 8085)
#   --install-dir DIR    Installation directory (default: /opt/cluster-control-ui)
#   --uninstall          Remove the installation
#   -h, --help           Show this help message
#
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# Defaults
INSTALL_DIR="/opt/cluster-control-ui"
SERVICE_PORT="8085"
SERVICE_USER="${SUDO_USER:-$(whoami)}"
SERVICE_NAME="cluster-control-ui"
UNINSTALL=false

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat << EOF
Install Cluster Control UI as a systemd service

Usage: sudo $0 [OPTIONS]

Options:
  --user USER          User to run the service as (default: $SERVICE_USER)
  --port PORT          Port for the service (default: $SERVICE_PORT)
  --install-dir DIR    Installation directory (default: $INSTALL_DIR)
  --uninstall          Remove the installation
  -h, --help           Show this help message

Examples:
  sudo $0                           # Install with defaults
  sudo $0 --port 8090               # Install on port 8090
  sudo $0 --install-dir /srv/ui     # Install to custom directory
  sudo $0 --uninstall               # Remove installation
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --user)
            SERVICE_USER="$2"
            shift 2
            ;;
        --port)
            SERVICE_PORT="$2"
            shift 2
            ;;
        --install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Uninstall
if [[ "$UNINSTALL" == "true" ]]; then
    log_step "Uninstalling Cluster Control UI..."
    
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_info "Stopping service..."
        systemctl stop "$SERVICE_NAME"
    fi
    
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_info "Disabling service..."
        systemctl disable "$SERVICE_NAME"
    fi
    
    if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
        log_info "Removing service file..."
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
    fi
    
    if [[ -d "$INSTALL_DIR" ]]; then
        log_info "Removing installation directory: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
    
    log_info "Uninstall complete!"
    exit 0
fi

# Verify source exists
if [[ ! -f "$SCRIPT_DIR/app.py" ]]; then
    log_error "app.py not found in $SCRIPT_DIR"
    log_error "Run this script from the cluster-control-ui directory"
    exit 1
fi

# Verify user exists
if ! id "$SERVICE_USER" &>/dev/null; then
    log_error "User '$SERVICE_USER' does not exist"
    exit 1
fi

SERVICE_GROUP="$(id -gn "$SERVICE_USER")"

log_info "Installing Cluster Control UI"
log_info "  Install directory: $INSTALL_DIR"
log_info "  Service port: $SERVICE_PORT"
log_info "  Service user: $SERVICE_USER"
echo ""

# Step 1: Create installation directory
log_step "Creating installation directory..."
mkdir -p "$INSTALL_DIR"

# Step 2: Copy application files
log_step "Copying application files..."
cp -r "$SCRIPT_DIR/app.py" "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR/templates" "$INSTALL_DIR/"

# Step 3: Create virtual environment
log_step "Creating Python virtual environment..."
python3 -m venv "$INSTALL_DIR/.venv"

# Step 4: Install dependencies
log_step "Installing Python dependencies..."
"$INSTALL_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt"

# Step 5: Generate secret if not exists
SECRET_FILE="$INSTALL_DIR/.secret"
if [[ ! -f "$SECRET_FILE" ]]; then
    log_step "Generating secret key..."
    python3 -c "import secrets; print(secrets.token_hex(32))" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
fi
CLUSTER_UI_SECRET="$(cat "$SECRET_FILE")"

# Step 6: Set ownership
log_step "Setting file ownership..."
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"

# Step 7: Create systemd service
log_step "Creating systemd service..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Cluster Control UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$INSTALL_DIR

# Environment
Environment=FLASK_APP=app.py
Environment=CLUSTER_UI_SECRET=$CLUSTER_UI_SECRET
Environment=PYTHONUNBUFFERED=1

# Command
ExecStart=$INSTALL_DIR/.venv/bin/flask run --host 0.0.0.0 --port $SERVICE_PORT

# Restart behavior
Restart=on-failure
RestartSec=5
StartLimitBurst=5
StartLimitIntervalSec=60

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$INSTALL_DIR
PrivateTmp=true

# Resource limits
MemoryMax=512M
CPUQuota=100%

[Install]
WantedBy=multi-user.target
EOF

# Step 8: Reload and enable service
log_step "Enabling and starting service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# Wait for service to start
sleep 2

# Step 9: Verify service is running
if systemctl is-active --quiet "$SERVICE_NAME"; then
    log_info "Service started successfully!"
else
    log_error "Service failed to start. Check: sudo journalctl -u $SERVICE_NAME -n 50"
    exit 1
fi

echo ""
log_info "=========================================="
log_info "Installation complete!"
log_info "=========================================="
echo ""
log_info "Service URL: http://$(hostname -I | awk '{print $1}'):$SERVICE_PORT"
log_info "Install dir: $INSTALL_DIR"
echo ""
log_info "Management commands:"
echo "  sudo systemctl status $SERVICE_NAME   # Check status"
echo "  sudo systemctl restart $SERVICE_NAME  # Restart"
echo "  sudo systemctl stop $SERVICE_NAME     # Stop"
echo "  sudo journalctl -u $SERVICE_NAME -f   # View logs"
echo ""
log_info "To uninstall:"
echo "  sudo $0 --uninstall"
echo ""

# Development note
log_warn "Development server (port 8080) is separate from this production install (port $SERVICE_PORT)"

