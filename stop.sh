#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PIDFILE="$CLOUDCLI_DATA_DIR/cloudcli.pid"

# Check if CloudCLI is running
CLOUDCLI_RUNNING=false
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  CLOUDCLI_RUNNING=true
fi

# Stop CloudCLI if it is running
if [ "$CLOUDCLI_RUNNING" = true ]; then
  echo "Stopping cloudcli (pid $(cat "$PIDFILE"))..."
  kill "$(cat "$PIDFILE")"
  for _ in $(seq 1 10); do
    kill -0 "$(cat "$PIDFILE")" 2>/dev/null || break
    sleep 1
  done
  kill -9 "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
else
  echo "CloudCLI is not running."
fi

# Stop Docker Compose services
echo "Stopping Docker Compose services..."
docker compose down
echo "Done."
