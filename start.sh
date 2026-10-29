#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<USAGE
Usage: ./start.sh [service...]

Start the given services (default: all). Services that are already running
are left alone; use ./restart.sh to restart them.

$SERVICES_HELP

Examples:
  ./start.sh                 # start everything that isn't running
  ./start.sh cloudcli        # start only CloudCLI
  ./start.sh traefik         # also starts oauth2-proxy, which traefik needs
USAGE
}

NAMES=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    -*) die_usage "Unknown option: $arg" ;;
    *) NAMES+=("$arg") ;;
  esac
done

load_env
parse_services "${NAMES[@]}"
mapfile -t PROXY < <(selected_proxy)

STATUS=0
# CloudCLI first: traefik routes to it.
if selected cloudcli; then
  cloudcli_start || STATUS=1
fi
if [ ${#PROXY[@]} -gt 0 ]; then
  proxy_start "${PROXY[@]}" || STATUS=1
fi
if [ "${CLOUDCLI_STARTED:-false}" = true ]; then
  run_cloudcli_init || STATUS=1
fi
exit "$STATUS"
