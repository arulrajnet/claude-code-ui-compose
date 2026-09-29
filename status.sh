#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [ ! -f ".env" ] || [ ! -r ".env" ]; then
  echo ".env file is missing or not readable" >&2
  exit 1
fi

set -a
source .env
set +a

# Keep in sync with start.sh, docker-compose.yml and install-cloudcli-service.sh.
CLOUDCLI_PORT=3010
SERVICE_NAME=cloudcli.service

PIDFILE="$CLOUDCLI_DATA_DIR/cloudcli.pid"
LOGFILE="$CLOUDCLI_DATA_DIR/cloudcli.log"

if [ -t 1 ]; then
  GREEN=$'\e[32m' RED=$'\e[31m' YELLOW=$'\e[33m' BOLD=$'\e[1m' RESET=$'\e[0m'
else
  GREEN='' RED='' YELLOW='' BOLD='' RESET=''
fi

FAILURES=0
ok()   { echo "  ${GREEN}✔${RESET} $*"; }
fail() { echo "  ${RED}✘${RESET} $*"; FAILURES=$((FAILURES + 1)); }
warn() { echo "  ${YELLOW}!${RESET} $*"; }
section() { echo; echo "${BOLD}$*${RESET}"; }

# 1. CloudCLI process, port and health.
section "CloudCLI"
CLOUDCLI_OK=true
if [ -f "$PIDFILE" ]; then
  PID="$(cat "$PIDFILE")"
  if kill -0 "$PID" 2>/dev/null; then
    read -r ETIME RSS < <(ps -o etime=,rss= -p "$PID")
    ok "process running (pid $PID, uptime $ETIME, rss $((RSS / 1024)) MiB)"
  else
    fail "stale pid file: pid $PID is not running"
    CLOUDCLI_OK=false
  fi
else
  fail "not running (no pid file at $PIDFILE)"
  CLOUDCLI_OK=false
fi

if ss -ltn "sport = :$CLOUDCLI_PORT" 2>/dev/null | grep -q LISTEN; then
  ok "listening on port $CLOUDCLI_PORT"
else
  fail "nothing listening on port $CLOUDCLI_PORT"
  CLOUDCLI_OK=false
fi

if curl -sf --max-time 5 "http://127.0.0.1:$CLOUDCLI_PORT/health" >/dev/null 2>&1; then
  ok "health check passed (http://127.0.0.1:$CLOUDCLI_PORT/health)"
else
  fail "health check failed (http://127.0.0.1:$CLOUDCLI_PORT/health)"
  CLOUDCLI_OK=false
fi

# 2. Boot-time systemd user service, if installed.
section "CloudCLI service (start on boot)"
if systemctl --user cat "$SERVICE_NAME" >/dev/null 2>&1; then
  ENABLED="$(systemctl --user is-enabled "$SERVICE_NAME" 2>/dev/null)"
  ACTIVE="$(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null)"
  if [ "$ENABLED" = enabled ]; then ok "$SERVICE_NAME enabled"; else fail "$SERVICE_NAME is $ENABLED"; fi
  if [ "$ACTIVE" = active ]; then
    ok "$SERVICE_NAME active"
  else
    warn "$SERVICE_NAME is $ACTIVE (cloudcli may have been started by start.sh instead)"
  fi
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ]; then
    ok "linger enabled for $USER (service starts at boot without login)"
  else
    fail "linger disabled for $USER, run: sudo loginctl enable-linger $USER"
  fi
else
  warn "not installed (run ./install-cloudcli-service.sh)"
fi

# 3. Docker Compose services.
section "Docker Compose"
PS_OUT="$(docker compose ps -a --format '{{.Service}}|{{.State}}|{{.Health}}|{{.ExitCode}}' 2>&1)"
if [ $? -ne 0 ]; then
  fail "docker compose ps failed: $PS_OUT"
else
  for svc in $(docker compose config --services); do
    line="$(printf '%s\n' "$PS_OUT" | awk -F'|' -v s="$svc" '$1 == s')"
    IFS='|' read -r _ STATE HEALTH EXIT_CODE <<<"$line"
    if [ -z "$line" ]; then
      fail "$svc: no container"
    elif [ "$svc" = cloudcli-init ]; then
      # One-shot job that registers CloudCLI's first user.
      if [ "$STATE" = exited ] && [ "$EXIT_CODE" = 0 ]; then
        ok "$svc: completed (exit 0)"
      elif [ "$STATE" = running ]; then
        warn "$svc: still running (waiting for cloudcli?)"
      else
        fail "$svc: $STATE (exit $EXIT_CODE)"
      fi
    elif [ "$STATE" = running ] && { [ -z "$HEALTH" ] || [ "$HEALTH" = healthy ]; }; then
      ok "$svc: running${HEALTH:+ ($HEALTH)}"
    else
      fail "$svc: $STATE${HEALTH:+ ($HEALTH)}"
    fi
  done
fi

# 4. End-to-end through Traefik (TLS + oauth2-proxy), pinned to this host.
section "Public endpoint"
URL="https://$SERVER_FQDN/oauth2/sign_in"
CURL_ARGS=(-s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$SERVER_FQDN:443:127.0.0.1")
CODE="$(curl "${CURL_ARGS[@]}" -k "$URL" 2>/dev/null)"
if [[ "$CODE" =~ ^[23] ]]; then
  ok "$URL -> HTTP $CODE"
  if curl "${CURL_ARGS[@]}" "$URL" >/dev/null 2>&1; then
    ok "TLS certificate is trusted"
  else
    warn "TLS certificate is not trusted (Traefik default cert? Let's Encrypt HTTP challenge needs port 80)"
  fi
else
  fail "$URL -> HTTP ${CODE:-no response} (Traefik routing problem?)"
fi

# 5. Log tail when something is wrong, or on request.
if { [ "$CLOUDCLI_OK" = false ] || [ "$VERBOSE" = true ]; } && [ -f "$LOGFILE" ]; then
  section "Last 20 lines of $LOGFILE"
  tail -n 20 "$LOGFILE"
fi
if [ "$VERBOSE" = true ]; then
  section "docker compose ps"
  docker compose ps -a
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "${GREEN}All checks passed.${RESET}"
else
  echo "${RED}$FAILURES check(s) failed.${RESET}"
  exit 1
fi
