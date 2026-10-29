#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<USAGE
Usage: ./restart.sh [-y] [service...]

Restart the given services (default: all). Containers are recreated, so
changes to .env and docker-compose.yml take effect. Services that aren't
running are started.

Options:
  -y, --yes      don't ask before restarting CloudCLI (required when not run
                 from a terminal)

$SERVICES_HELP

Examples:
  ./restart.sh oauth2-proxy  # e.g. after editing .htpasswd
  ./restart.sh proxy         # all containers, CloudCLI untouched
  ./restart.sh cloudcli      # asks first: drops live terminal sessions
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

if selected cloudcli; then
  confirm_cloudcli restart
fi

STATUS=0
# Containers first: when run from a CloudCLI terminal, restarting CloudCLI
# ends this script.
if [ ${#PROXY[@]} -gt 0 ]; then
  proxy_restart "${PROXY[@]}" || STATUS=1
fi
if selected cloudcli; then
  cloudcli_restart || STATUS=1
fi
if [ "${CLOUDCLI_STARTED:-false}" = true ]; then
  run_cloudcli_init || STATUS=1
fi
exit "$STATUS"
