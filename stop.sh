#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<USAGE
Usage: ./stop.sh [-y] [service...]

Stop the given services (default: all). Stopping everything also removes the
containers (docker compose down).

Options:
  -y, --yes      don't ask before stopping CloudCLI (required when not run
                 from a terminal)

$SERVICES_HELP

Examples:
  ./stop.sh                  # stop everything (asks first, CloudCLI included)
  ./stop.sh proxy            # stop the containers, keep CloudCLI running
  ./stop.sh whoami           # stop a single container
USAGE
}

ASSUME_YES=false
NAMES=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    -y|--yes) ASSUME_YES=true ;;
    -*) die_usage "Unknown option: $arg" ;;
    *) NAMES+=("$arg") ;;
  esac
done

load_env
parse_services "${NAMES[@]}"
mapfile -t PROXY < <(selected_proxy)

# Ask before changing anything.
if selected cloudcli; then
  confirm_cloudcli stop
fi

STATUS=0
if [ ${#PROXY[@]} -gt 0 ]; then
  proxy_stop "$ALL_SELECTED" "${PROXY[@]}" || STATUS=1
  RUNNING="$(compose_snapshot | awk -F'|' '$3 == "running" { print $1 }')"
  if selected oauth2-proxy && grep -qx traefik <<<"$RUNNING"; then
    warn "traefik is still running: every request fails its login check until oauth2-proxy is back"
    hint "./start.sh oauth2-proxy"
  fi
  if selected traefik && ! selected cloudcli; then
    warn "the site is unreachable until traefik is started again"
    hint "./start.sh traefik"
  fi
fi
if selected cloudcli; then
  cloudcli_stop || STATUS=1
fi
exit "$STATUS"
