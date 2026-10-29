# Shared helpers for start.sh, stop.sh, restart.sh, status.sh, logs.sh and
# install-cloudcli-service.sh. Source it, don't run it.

LIB_FILE="$(realpath "${BASH_SOURCE[0]}")"
cd "$(dirname "$LIB_FILE")"

# --- Output --------------------------------------------------------------

if [ -t 1 ]; then
  GREEN=$'\e[32m' RED=$'\e[31m' YELLOW=$'\e[33m' BOLD=$'\e[1m' DIM=$'\e[2m' RESET=$'\e[0m'
else
  GREEN='' RED='' YELLOW='' BOLD='' DIM='' RESET=''
fi

ok()      { echo "  ${GREEN}✔${RESET} $*"; }
warn()    { echo "  ${YELLOW}!${RESET} $*"; }
err()     { echo "  ${RED}✘${RESET} $*"; }
hint()    { echo "    ${DIM}→ $*${RESET}"; }
section() { echo; echo "${BOLD}$*${RESET}"; }
die()     { echo "${RED}Error:${RESET} $*" >&2; exit 1; }

# Unknown options/services: print the problem plus a pointer to --help.
die_usage() {
  echo "${RED}Error:${RESET} $1" >&2
  echo "Run ./$(basename "$0") --help for usage." >&2
  exit 2
}

# --- Config --------------------------------------------------------------

load_env() {
  if [ ! -f ".env" ] || [ ! -r ".env" ]; then
    die ".env file is missing or not readable (copy .env.example to .env)"
  fi
  set -a
  source .env
  set +a

  # Keep the port in sync with docker-compose.yml (cloudcli-init, traefik-conf).
  # Both can be overridden from .env or the environment, e.g. for testing.
  CLOUDCLI_PORT="${CLOUDCLI_PORT:-3010}"
  CLOUDCLI_SERVICE="${CLOUDCLI_SERVICE:-cloudcli.service}"

  # Extra env for CloudCLI and everything it spawns (claude credentials, tool
  # tokens, ...). Kept outside the repo; used when present, CloudCLI starts
  # without it otherwise.
  CLOUDCLI_ENV_FILE="$(realpath -m "${CLOUDCLI_ENV_FILE:-$HOME/.config/cloudcli/.env}")"

  CLOUDCLI_DATA_DIR="$(realpath -m "$CLOUDCLI_DATA_DIR")"
  PIDFILE="$CLOUDCLI_DATA_DIR/cloudcli.pid"
  LOGFILE="$CLOUDCLI_DATA_DIR/cloudcli.log"
  DBFILE="$CLOUDCLI_DATA_DIR/auth.db"
  LOG_ROTATE_BYTES=$((10 * 1024 * 1024))
}

# --- Service selection ---------------------------------------------------

PROXY_SERVICES=(traefik oauth2-proxy whoami)
ALL_SERVICES=(cloudcli "${PROXY_SERVICES[@]}")

SERVICES_HELP="Services:
  cloudcli       CloudCLI on the host (port 3010)
  traefik        TLS + reverse proxy
  oauth2-proxy   login page / auth check
  whoami         test route at /whoami

Groups:
  all            every service (the default when none is given)
  proxy          traefik oauth2-proxy whoami"

# parse_services NAME... - sets SELECTED (ordered as in ALL_SERVICES) and
# ALL_SELECTED=true when every service is included.
parse_services() {
  local want=() name svc
  [ $# -eq 0 ] && set -- all
  for name in "$@"; do
    case "$name" in
      all)   want+=("${ALL_SERVICES[@]}") ;;
      proxy) want+=("${PROXY_SERVICES[@]}") ;;
      *)
        if [[ " ${ALL_SERVICES[*]} " == *" $name "* ]]; then
          want+=("$name")
        else
          die_usage "Unknown service: $name (valid: ${ALL_SERVICES[*]}, all, proxy)"
        fi
        ;;
    esac
  done
  SELECTED=()
  for svc in "${ALL_SERVICES[@]}"; do
    [[ " ${want[*]} " == *" $svc "* ]] && SELECTED+=("$svc")
  done
  ALL_SELECTED=false
  [ ${#SELECTED[@]} -eq ${#ALL_SERVICES[@]} ] && ALL_SELECTED=true
  return 0
}

selected() { [[ " ${SELECTED[*]} " == *" $1 "* ]]; }

# Selected Docker Compose services, one per line.
selected_proxy() {
  local svc
  for svc in "${SELECTED[@]}"; do
    [ "$svc" != cloudcli ] && echo "$svc"
  done
  return 0
}

# --- CloudCLI --------------------------------------------------------------

# Prints the pid of the running CloudCLI; fails if it isn't running.
cloudcli_pid() {
  local pid
  [ -f "$PIDFILE" ] || return 1
  pid="$(cat "$PIDFILE")"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  echo "$pid"
}

cloudcli_healthy() {
  curl -sf --max-time 5 "http://127.0.0.1:$CLOUDCLI_PORT/health" >/dev/null 2>&1
}

cloudcli_service_installed() {
  systemctl --user cat "$CLOUDCLI_SERVICE" >/dev/null 2>&1
}

cloudcli_service_active() {
  systemctl --user is-active --quiet "$CLOUDCLI_SERVICE" 2>/dev/null
}

# How the running CloudCLI was started: "systemd service" or "start.sh".
cloudcli_managed_by() {
  if cloudcli_service_active; then echo "systemd service"; else echo "start.sh"; fi
}

# True when this script runs inside a CloudCLI terminal, i.e. stopping
# CloudCLI also kills this script.
inside_cloudcli() {
  local target p
  target="$(cloudcli_pid)" || return 1
  p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    [ "$p" = "$target" ] && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  return 1
}

# Keep one old copy once the log passes LOG_ROTATE_BYTES. Runs before every
# start (also from the systemd unit's ExecStartPre).
rotate_cloudcli_log() {
  if [ -f "$LOGFILE" ] && [ "$(stat -c %s "$LOGFILE")" -gt "$LOG_ROTATE_BYTES" ]; then
    mv -f "$LOGFILE" "$LOGFILE.1"
  fi
}

cloudcli_wait_healthy() {
  local _
  for _ in $(seq 1 30); do
    cloudcli_healthy && return 0
    sleep 1
  done
  err "cloudcli: did not become healthy within 30s"
  hint "./logs.sh cloudcli"
  return 1
}

# Stop the process directly (not via systemd), waiting up to 10s.
_cloudcli_kill() {
  local pid _
  pid="$(cloudcli_pid)" || return 0
  kill "$pid"
  for _ in $(seq 1 10); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$PIDFILE"
}

_cloudcli_start_nohup() {
  local cmd
  if command -v cloudcli >/dev/null 2>&1; then
    cmd=(cloudcli)
  else
    cmd=(npx -y @cloudcli-ai/cloudcli)
  fi
  mkdir -p "$CLOUDCLI_DATA_DIR"
  rotate_cloudcli_log
  # Same env the systemd unit gets through EnvironmentFile=.
  if [ -r "$CLOUDCLI_ENV_FILE" ]; then
    set -a
    source "$CLOUDCLI_ENV_FILE"
    set +a
  fi
  SERVER_PORT="$CLOUDCLI_PORT" DATABASE_PATH="$DBFILE" \
  IS_PLATFORM=true \
  VITE_IS_PLATFORM=true \
    nohup "${cmd[@]}" >>"$LOGFILE" 2>&1 </dev/null &
  echo $! >"$PIDFILE"
}

# Start CloudCLI unless it is already running. Sets CLOUDCLI_STARTED.
cloudcli_start() {
  local pid
  CLOUDCLI_STARTED=false
  if pid="$(cloudcli_pid)"; then
    ok "cloudcli: already running (pid $pid, $(cloudcli_managed_by))"
    return 0
  fi
  if cloudcli_service_installed; then
    systemctl --user start "$CLOUDCLI_SERVICE"
  else
    _cloudcli_start_nohup
  fi
  cloudcli_wait_healthy || return 1
  CLOUDCLI_STARTED=true
  ok "cloudcli: started (pid $(cloudcli_pid), $(cloudcli_managed_by))"
}

cloudcli_stop() {
  local pid
  if ! pid="$(cloudcli_pid)"; then
    ok "cloudcli: already stopped"
    return 0
  fi
  if cloudcli_service_active; then
    systemctl --user stop "$CLOUDCLI_SERVICE"
  else
    _cloudcli_kill
  fi
  ok "cloudcli: stopped (was pid $pid)"
}

# Stop + start. A CloudCLI started by start.sh is moved under the systemd
# service when that is installed.
_cloudcli_restart_now() {
  if cloudcli_service_installed; then
    if cloudcli_service_active; then
      systemctl --user restart "$CLOUDCLI_SERVICE"
    else
      _cloudcli_kill
      systemctl --user start "$CLOUDCLI_SERVICE"
    fi
  else
    _cloudcli_kill
    _cloudcli_start_nohup
  fi
  cloudcli_wait_healthy
}

# Sets CLOUDCLI_STARTED=true when it restarted in the foreground.
cloudcli_restart() {
  CLOUDCLI_STARTED=false
  if ! cloudcli_pid >/dev/null; then
    cloudcli_start
    return
  fi
  if inside_cloudcli; then
    # Stopping CloudCLI kills this script with it, so hand the restart to a
    # process that outlives it: systemd itself, or a detached session.
    if cloudcli_service_active; then
      systemctl --user restart --no-block "$CLOUDCLI_SERVICE"
    else
      setsid -f bash -c 'source "$1" && load_env && _cloudcli_restart_now' _ "$LIB_FILE" \
        >>"$LOGFILE" 2>&1 </dev/null
    fi
    warn "cloudcli: restarting in the background, this terminal will disconnect"
    hint "reconnect, then ./status.sh cloudcli"
    return 0
  fi
  _cloudcli_restart_now || return 1
  CLOUDCLI_STARTED=true
  ok "cloudcli: restarted (pid $(cloudcli_pid), $(cloudcli_managed_by))"
}

# confirm_cloudcli VERB - ask before stopping/restarting a running CloudCLI.
# Skipped with ASSUME_YES=true; refuses without a terminal to ask on.
confirm_cloudcli() {
  local msg answer
  cloudcli_pid >/dev/null || return 0
  [ "${ASSUME_YES:-false}" = true ] && return 0
  msg="This will $1 cloudcli and drop all live terminal sessions."
  if inside_cloudcli; then
    msg+=" This terminal runs inside cloudcli and will close too."
  fi
  if [ ! -t 0 ]; then
    die "$msg Refusing without a terminal to confirm on; pass -y to go ahead."
  fi
  read -r -p "${YELLOW}${msg}${RESET} Continue? [y/N] " answer
  if [[ ! "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo "Aborted, nothing was changed."
    exit 1
  fi
}

# --- Docker Compose -----------------------------------------------------------

compose() { docker compose --progress quiet "$@"; }

# "service|container-id|state" for every container of the project.
compose_snapshot() {
  docker compose ps -a --format '{{.Service}}|{{.ID}}|{{.State}}' 2>/dev/null
}

# snapshot_get SNAPSHOT SERVICE - prints "id|state" (empty when no container).
snapshot_get() {
  printf '%s\n' "$1" | awk -F'|' -v s="$2" '$1 == s { print $2 "|" $3 }'
}

# oauth2-proxy bind-mounts .htpasswd; if it's missing, Docker silently creates
# an empty directory in its place.
require_htpasswd() {
  if [ ! -f ".htpasswd" ] || [ ! -r ".htpasswd" ]; then
    die ".htpasswd file is missing or not readable (create it with: htpasswd -c .htpasswd <user>)"
  fi
}

# report_compose BEFORE AFTER VERB REQUESTED... - one line per proxy service
# that was requested or changed (e.g. pulled in as a dependency).
report_compose() {
  local before="$1" after="$2" verb="$3"; shift 3
  local svc b a b_id b_state a_id a_state requested
  for svc in "${PROXY_SERVICES[@]}"; do
    requested=false
    [[ " $* " == *" $svc "* ]] && requested=true
    b="$(snapshot_get "$before" "$svc")"; a="$(snapshot_get "$after" "$svc")"
    IFS='|' read -r b_id b_state <<<"$b"
    IFS='|' read -r a_id a_state <<<"$a"
    [ "$requested" = false ] && [ "$b" = "$a" ] && continue

    case "$verb" in
      start)
        if [ "$a_state" != running ]; then
          err "$svc: failed to start (${a_state:-no container})"
          hint "./logs.sh $svc"
        elif [ "$b_state" = running ] && [ "$b_id" = "$a_id" ]; then
          ok "$svc: already running"
        elif [ "$b_state" = running ]; then
          ok "$svc: recreated (its configuration changed)"
        elif [ "$requested" = true ]; then
          ok "$svc: started"
        else
          ok "$svc: started (dependency)"
        fi
        ;;
      stop)
        if [ "$b_state" != running ]; then
          ok "$svc: already stopped"
        else
          ok "$svc: stopped"
        fi
        ;;
      restart)
        if [ "$a_state" = running ]; then
          ok "$svc: restarted"
        else
          err "$svc: failed to restart (${a_state:-no container})"
          hint "./logs.sh $svc"
        fi
        ;;
    esac
  done
}

# Run a compose command, showing its output only when it fails.
compose_quiet() {
  local out
  if ! out="$(compose "$@" 2>&1)"; then
    echo "$out" >&2
    return 1
  fi
}

proxy_start() {
  local before after
  if [[ " $* " == *" oauth2-proxy "* || " $* " == *" traefik "* ]]; then
    require_htpasswd
  fi
  before="$(compose_snapshot)"
  compose_quiet up -d "$@" || return 1
  after="$(compose_snapshot)"
  report_compose "$before" "$after" start "$@"
}

# proxy_stop FULL SERVICE... - FULL=true runs `docker compose down`, which also
# removes the containers and network; otherwise only the named ones stop.
proxy_stop() {
  local full="$1"; shift
  local before after
  before="$(compose_snapshot)"
  if [ "$full" = true ]; then
    compose_quiet down || return 1
  else
    compose_quiet stop "$@" || return 1
  fi
  after="$(compose_snapshot)"
  report_compose "$before" "$after" stop "$@"
}

# Recreate (not just restart) so .env and docker-compose.yml changes apply.
proxy_restart() {
  local before after
  if [[ " $* " == *" oauth2-proxy "* ]]; then
    require_htpasswd
  fi
  before="$(compose_snapshot)"
  compose_quiet up -d --force-recreate --no-deps "$@" || return 1
  after="$(compose_snapshot)"
  report_compose "$before" "$after" restart "$@"
}

# One-shot container that registers CloudCLI's first user; re-run after
# CloudCLI (re)starts. Harmless when the user already exists.
run_cloudcli_init() {
  if compose_quiet up -d cloudcli-init; then
    ok "cloudcli-init: started (registers the first user if needed)"
  else
    err "cloudcli-init: failed to start"
    hint "./logs.sh cloudcli-init"
    return 1
  fi
}
