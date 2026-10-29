#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<USAGE
Usage: ./status.sh [-v] [service...]

Check the given services (default: all). Exits non-zero if any check fails.

Options:
  -v, --verbose  also print the CloudCLI log tail and docker compose ps

$SERVICES_HELP

Examples:
  ./status.sh                # everything, plus the public endpoint
  ./status.sh cloudcli       # CloudCLI and its boot service only
USAGE
}

VERBOSE=false
NAMES=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    -v|--verbose) VERBOSE=true ;;
    -*) die_usage "Unknown option: $arg" ;;
    *) NAMES+=("$arg") ;;
  esac
done

load_env
parse_services "${NAMES[@]}"
mapfile -t PROXY < <(selected_proxy)

FAILURES=0
fail() { err "$@"; FAILURES=$((FAILURES + 1)); }

CLOUDCLI_OK=true
if selected cloudcli; then
  # 1. CloudCLI process, port and health.
  section "CloudCLI"
  if PID="$(cloudcli_pid)"; then
    read -r ETIME RSS < <(ps -o etime=,rss= -p "$PID")
    ok "running (pid $PID, $(cloudcli_managed_by), uptime $ETIME, rss $((RSS / 1024)) MiB)"
    if ss -ltn "sport = :$CLOUDCLI_PORT" 2>/dev/null | grep -q LISTEN; then
      ok "listening on port $CLOUDCLI_PORT"
    else
      fail "nothing listening on port $CLOUDCLI_PORT"
      CLOUDCLI_OK=false
    fi
    if cloudcli_healthy; then
      ok "health check passed (http://127.0.0.1:$CLOUDCLI_PORT/health)"
    else
      fail "health check failed (http://127.0.0.1:$CLOUDCLI_PORT/health)"
      hint "./logs.sh cloudcli, then ./restart.sh cloudcli"
      CLOUDCLI_OK=false
    fi
  else
    if [ -f "$PIDFILE" ]; then
      fail "not running (stale pid file, pid $(cat "$PIDFILE") is gone)"
    else
      fail "not running"
    fi
    hint "./start.sh cloudcli"
    CLOUDCLI_OK=false
  fi

  # 2. Boot-time systemd user service, if installed.
  section "CloudCLI boot service"
  if cloudcli_service_installed; then
    ENABLED="$(systemctl --user is-enabled "$CLOUDCLI_SERVICE" 2>/dev/null)"
    if [ "$ENABLED" = enabled ]; then
      ok "$CLOUDCLI_SERVICE enabled (starts on boot)"
    else
      fail "$CLOUDCLI_SERVICE is $ENABLED"
      hint "./install-cloudcli-service.sh"
    fi
    if cloudcli_service_active; then
      ok "$CLOUDCLI_SERVICE active"
    elif cloudcli_pid >/dev/null; then
      warn "cloudcli runs outside the service, so it isn't restarted if it crashes"
      hint "./restart.sh cloudcli (moves it under the service)"
    else
      warn "$CLOUDCLI_SERVICE is $(systemctl --user is-active "$CLOUDCLI_SERVICE" 2>/dev/null)"
    fi
    if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ]; then
      ok "linger enabled for $USER (runs at boot without a login)"
    else
      fail "linger disabled for $USER, so the service only runs while you're logged in"
      hint "sudo loginctl enable-linger $USER"
    fi
  else
    warn "not installed, so cloudcli won't start on boot"
    hint "./install-cloudcli-service.sh"
  fi
fi

# 3. Docker Compose services.
if [ ${#PROXY[@]} -gt 0 ] || selected cloudcli; then
  section "Docker Compose"
  if ! PS_OUT="$(docker compose ps -a --format '{{.Service}}|{{.State}}|{{.Health}}|{{.ExitCode}}' 2>&1)"; then
    fail "docker compose ps failed: $PS_OUT"
  else
    CHECK=("${PROXY[@]}")
    selected cloudcli && CHECK+=(cloudcli-init)
    for svc in "${CHECK[@]}"; do
      line="$(printf '%s\n' "$PS_OUT" | awk -F'|' -v s="$svc" '$1 == s')"
      IFS='|' read -r _ STATE HEALTH EXIT_CODE <<<"$line"
      if [ "$svc" = cloudcli-init ]; then
        # One-shot job that registers CloudCLI's first user.
        if [ -z "$line" ]; then
          warn "$svc: hasn't run since the last full stop (runs on ./start.sh cloudcli)"
        elif [ "$STATE" = exited ] && [ "$EXIT_CODE" = 0 ]; then
          ok "$svc: completed"
        elif [ "$STATE" = running ]; then
          warn "$svc: still running (waiting for cloudcli to become healthy)"
        else
          fail "$svc: $STATE (exit $EXIT_CODE)"
          hint "./logs.sh cloudcli-init"
        fi
      elif [ -z "$line" ]; then
        fail "$svc: stopped (no container)"
        hint "./start.sh $svc"
      elif [ "$STATE" = running ] && { [ -z "$HEALTH" ] || [ "$HEALTH" = healthy ]; }; then
        ok "$svc: running${HEALTH:+ ($HEALTH)}"
      elif [ "$STATE" = running ]; then
        fail "$svc: running but $HEALTH"
        hint "./logs.sh $svc"
      elif [ "$STATE" = restarting ]; then
        fail "$svc: restarting over and over (crash loop?)"
        hint "./logs.sh $svc"
      else
        fail "$svc: stopped${EXIT_CODE:+ (exit $EXIT_CODE)}"
        hint "./start.sh $svc"
      fi
    done
  fi
fi

# 4. End-to-end through Traefik (TLS + oauth2-proxy), pinned to this host.
if selected traefik; then
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
    fail "$URL -> HTTP ${CODE:-no response}"
    hint "./status.sh proxy, ./logs.sh traefik"
  fi
fi

# 5. Log tail when CloudCLI is unhealthy, or on request.
if selected cloudcli && { [ "$CLOUDCLI_OK" = false ] || [ "$VERBOSE" = true ]; } && [ -f "$LOGFILE" ]; then
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
