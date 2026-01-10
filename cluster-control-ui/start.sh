#!/usr/bin/env bash
#
# Start the Cluster Control UI development server
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Default settings
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
DEBUG="${DEBUG:-1}"

# Check for virtual environment
if [[ -d ".venv" ]]; then
    log_info "Activating virtual environment..."
    source .venv/bin/activate
elif [[ -d "venv" ]]; then
    log_info "Activating virtual environment..."
    source venv/bin/activate
fi

# Install dependencies if needed
if ! python3 -c "import flask" 2>/dev/null; then
    log_warn "Flask not found, installing dependencies..."
    pip install -q -r requirements.txt
fi

# Kill any existing instance
if pgrep -f "python.*app.py" > /dev/null; then
    log_warn "Stopping existing instance..."
    pkill -f "python.*app.py" 2>/dev/null || true
    sleep 2
fi

log_info "Starting Cluster Control UI..."
log_info "  URL: http://${HOST}:${PORT}"
log_info "  Debug: ${DEBUG}"
echo ""

# Export Flask settings
export FLASK_APP=app.py
export FLASK_DEBUG=$DEBUG

# Run the app
exec python3 app.py
