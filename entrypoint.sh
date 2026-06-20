#!/usr/bin/env bash
set -uo pipefail

INTERVAL_HOURS="${INTERVAL_HOURS:-24}"
WEB_PORT="${WEB_PORT:-8080}"

if [[ "$(stat -c %d /app/reports)" == "$(stat -c %d /app)" ]]; then
  echo "WARNING: /app/reports does not look like a mounted volume — reports will be LOST when this container is removed. Mount ./reports:/app/reports to persist them. Continuing anyway." >&2
fi

python3 /app/web/server.py --port "$WEB_PORT" --report-dir /app/reports &
WEB_PID=$!
trap 'kill "$WEB_PID" 2>/dev/null; exit 0' TERM INT

while true; do
  echo "=== Scan starting at $(date -u) ==="
  /app/scan.sh || echo "scan.sh exited non-zero (alerts found or error) — continuing loop" >&2
  echo "Sleeping ${INTERVAL_HOURS}h until next scan..."
  sleep "$(( INTERVAL_HOURS * 3600 ))" &
  wait $!
done
