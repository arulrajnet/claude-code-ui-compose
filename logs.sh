#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<USAGE
Usage: ./logs.sh [-n LINES] [--no-follow] [service...]

Show the last LINES (default 100) log lines of the given services (default:
all), then keep following. With more than one service, the logs are merged
into one stream and every line is prefixed with its service. Ctrl-C to stop.

CloudCLI logs to cloudcli.log in CLOUDCLI_DATA_DIR (see .env)
(one rotated copy is kept as cloudcli.log.1); containers log to Docker.

Options:
  -n, --lines N  number of lines to show first (default 100)
  --no-follow    print and exit instead of following

$SERVICES_HELP
  cloudcli-init  the one-shot first-user registration job

Examples:
  ./logs.sh cloudcli
  ./logs.sh -n 500 --no-follow cloudcli | less
  ./logs.sh proxy
USAGE
}

LINES=100
FOLLOW=true
NAMES=()
WITH_INIT=false
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n|--lines)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || die_usage "$1 needs a number"
      LINES="$2"; shift ;;
    --no-follow) FOLLOW=false ;;
    cloudcli-init) WITH_INIT=true ;;
    -*) die_usage "Unknown option: $1" ;;
    *) NAMES+=("$1") ;;
  esac
  shift
done

load_env
if [ ${#NAMES[@]} -eq 0 ] && [ "$WITH_INIT" = true ]; then
  SELECTED=()
else
  parse_services "${NAMES[@]}"
fi
mapfile -t CONTAINERS < <(selected_proxy)
[ "$WITH_INIT" = true ] && CONTAINERS+=(cloudcli-init)

STREAMS=("${CONTAINERS[@]}")
selected cloudcli && STREAMS=(cloudcli "${STREAMS[@]}")
[ ${#STREAMS[@]} -gt 0 ] || exit 0

# With several services, prefix every line with its service name, padded to
# the longest one so the columns line up.
WIDTH=0
for svc in "${STREAMS[@]}"; do
  [ ${#svc} -gt "$WIDTH" ] && WIDTH=${#svc}
done
prefix() {
  if [ ${#STREAMS[@]} -gt 1 ]; then
    sed -u "s/^/$(printf "%-${WIDTH}s" "$1") | /"
  else
    cat
  fi
}

stream() {
  local svc="$1" args=(-n "$LINES")
  if [ "$svc" = cloudcli ]; then
    if [ ! -f "$LOGFILE" ] && [ "$FOLLOW" = false ]; then
      warn "cloudcli: no log yet at $LOGFILE" >&2
      return 0
    fi
    # -F keeps following across restarts and log rotation.
    [ "$FOLLOW" = true ] && args+=(-F)
    tail "${args[@]}" "$LOGFILE" 2>/dev/null | prefix "$svc"
  else
    args=(--no-log-prefix --tail "$LINES")
    [ "$FOLLOW" = true ] && args+=(-f)
    docker compose logs "${args[@]}" "$svc" 2>&1 | prefix "$svc"
  fi
}

if [ "$FOLLOW" = false ]; then
  for svc in "${STREAMS[@]}"; do
    stream "$svc"
  done
  exit 0
fi

# Follow all streams at once. Each runs in its own process group (set -m) so
# Ctrl-C can stop exactly those, without touching whatever started this script.
set -m
GROUPS_=()
for svc in "${STREAMS[@]}"; do
  stream "$svc" &
  GROUPS_+=("$!")
done
set +m
stop_streams() {
  trap - INT TERM
  local g
  for g in "${GROUPS_[@]}"; do
    kill -TERM -- "-$g" 2>/dev/null || true
  done
  exit 0
}
trap stop_streams INT TERM
wait
