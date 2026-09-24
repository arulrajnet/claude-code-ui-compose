#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Validate the .htpasswd file exists and is readable
if [ ! -f ".htpasswd" ] || [ ! -r ".htpasswd" ]; then
  echo ".htpasswd file is missing or not readable" >&2
  exit 1
fi

# Validate the .env file exists and is readable
if [ ! -f ".env" ] || [ ! -r ".env" ]; then
  echo ".env file is missing or not readable" >&2
  exit 1
fi

RESTART_CLOUDCLI=false
for arg in "$@"; do
  case "$arg" in
    --restart-cloudcli) RESTART_CLOUDCLI=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

set -a
source .env
set +a

# Keep in sync with docker-compose.yml (cloudcli-init) and traefik-conf.yaml.
CLOUDCLI_PORT=3010

PIDFILE="$CLOUDCLI_DATA_DIR/cloudcli.pid"
LOGFILE="$CLOUDCLI_DATA_DIR/cloudcli.log"
DBFILE="$CLOUDCLI_DATA_DIR/auth.db"

mkdir -p "$CLOUDCLI_DATA_DIR"

CLOUDCLI_RUNNING=false
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  CLOUDCLI_RUNNING=true
fi

if [ "$CLOUDCLI_RUNNING" = true ] && [ "$RESTART_CLOUDCLI" = false ]; then
  # Live terminal sessions are attached to this process over WebSocket;
  # killing it drops them. Only restart when explicitly asked to.
  echo "cloudcli already running (pid $(cat "$PIDFILE")), leaving it alone (pass --restart-cloudcli to restart it)."
else
  # 1. Stop any CloudCLI instance from a previous run.
  if [ "$CLOUDCLI_RUNNING" = true ]; then
    OLD_PID="$(cat "$PIDFILE")"
    echo "Stopping previous cloudcli (pid $OLD_PID)..."
    kill "$OLD_PID"
    for _ in $(seq 1 10); do
      kill -0 "$OLD_PID" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$OLD_PID" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"

  # 2. Start CloudCLI standalone on the host.
  if command -v cloudcli >/dev/null 2>&1; then
    CLOUDCLI_CMD=(cloudcli)
  else
    CLOUDCLI_CMD=(npx -y @cloudcli-ai/cloudcli)
  fi

  echo "Starting cloudcli on port $CLOUDCLI_PORT..."
  SERVER_PORT="$CLOUDCLI_PORT" DATABASE_PATH="$DBFILE" \
  IS_PLATFORM=true \
  VITE_IS_PLATFORM=true \
    nohup "${CLOUDCLI_CMD[@]}" >"$LOGFILE" 2>&1 &
  echo $! >"$PIDFILE"
fi

# 3. Wait for it to become healthy.
echo "Waiting for cloudcli to become healthy..."
for _ in $(seq 1 30); do
  curl -sf "http://127.0.0.1:$CLOUDCLI_PORT/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf "http://127.0.0.1:$CLOUDCLI_PORT/health" >/dev/null 2>&1 || {
  echo "cloudcli did not become healthy, see $LOGFILE" >&2
  exit 1
}

# 4. (Re)start the Docker Compose stack.
echo "Restarting docker compose services..."
docker compose down
docker compose up -d

echo "Done."
