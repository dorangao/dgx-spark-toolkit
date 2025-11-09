#!/usr/bin/env bash
set -euo pipefail

# Config via .env or environment
PREPULL_MODELS="${PREPULL_MODELS:-gpt-oss:20b}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

# Up
docker compose up -d

# Optional: pre-pull Ollama models (idempotent)
if [ -n "$PREPULL_MODELS" ]; then
  IFS=',' read -r -a MODELS <<<"$PREPULL_MODELS"
  for m in "${MODELS[@]}"; do
    echo "[stack] ensuring model: $m"
    docker compose exec -T ollama sh -lc "ollama list | grep -q '^\s*${m}\s' || ollama pull ${m}" || true
  done
fi

# Health pings
echo "[stack] waiting for Open WebUI..."
for i in {1..60}; do
  if curl -fsS "http://127.0.0.1:${WEBUI_PORT:-12000}" >/dev/null 2>&1; then
    echo "[stack] Open WebUI is up at http://localhost:${WEBUI_PORT:-12000}"
    break
  fi
  sleep 1
done

echo "[stack] Gateway check..."
curl -fsS "http://127.0.0.1:${OPENAI_PORT:-8000}/v1/models" \
  -H "Authorization: Bearer ${OPENAI_TEST_KEY:-sk-local-123}" >/dev/null 2>&1 || true

echo "[stack] status:"
docker compose ps
