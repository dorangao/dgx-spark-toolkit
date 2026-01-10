#!/usr/bin/env bash
#
# Stop the Cluster Control UI server
#
set -euo pipefail

if pgrep -f "python.*app.py" > /dev/null; then
    echo "Stopping Cluster Control UI..."
    pkill -f "python.*app.py"
    echo "✅ Stopped"
else
    echo "No running instance found"
fi
