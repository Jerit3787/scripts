#!/usr/bin/env bash
# CAIDPS Teardown & Factory Reset
# Reverses a CAIDPS installation made by IDPS-WebServer/setup.sh, so a server can be
# re-installed from scratch (end-to-end install testing).
#
# Usage:
#   curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/reset.sh | bash
#   curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/reset.sh | bash -s -- --yes --purge-packages
#
# Options:
#   --yes               Do not ask for confirmation (for scripted test runs)
#   --purge-packages    Also uninstall cloudflared, Node.js, Docker and whiptail. Off by default:
#                       they may have been installed before CAIDPS, and purging Docker deletes
#                       every image, container and volume on the machine (/var/lib/docker).
#   --dir PATH          A CAIDPS install outside /opt/caidps to remove (must contain scripts/serve.sh)
#   --project NAME      Compose project to use when deploy/.env is missing (default: read it, else caidps)
#
set -u

main() {

if [ -t 1 ]; then
  BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; RESET=""
fi

ASSUME_YES=0
PURGE_PACKAGES=0
EXTRA_DIR=""
PROJECT_OVERRIDE=""
KIND_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --purge-packages) PURGE_PACKAGES=1 ;;
    --dir)
      [ $# -ge 2 ] || { echo -e "${RED}[error] --dir needs a path${RESET}" >&2; exit 2; }
      EXTRA_DIR="$2"; shift ;;
    --project)
      [ $# -ge 2 ] || { echo -e "${RED}[error] --project needs a name${RESET}" >&2; exit 2; }
      PROJECT_OVERRIDE="$2"; shift ;;
    --kind)
      [ $# -ge 2 ] || { echo -e "${RED}[error] --kind needs containers or systemd${RESET}" >&2; exit 2; }
      case "$2" in
        containers|systemd) KIND_OVERRIDE="$2" ;;
        *) echo -e "${RED}[error] --kind must be containers or systemd${RESET}" >&2; exit 2 ;;
      esac
      shift ;;
    -h|--help)
      echo "Usage: reset.sh [--yes] [--purge-packages] [--dir PATH] [--project NAME] [--kind containers|systemd]"
      echo "  --yes             no confirmation prompt (scripted runs)"
      echo "  --purge-packages  also uninstall cloudflared, Node.js, Docker (and ALL Docker data), whiptail"
      echo "  --dir PATH        also remove a CAIDPS install at PATH"
      echo "  --project NAME    compose project when deploy/.env is missing or unreadable"
      echo "  --kind KIND       force the install kind when metadata is missing (containers|systemd)"
      exit 0 ;;
    *) echo -e "${RED}[error] Unknown option: $1${RESET}" >&2; exit 2 ;;
  esac
  shift
done
[ "${CAIDPS_RESET_CONFIRM:-}" = "yes" ] && ASSUME_YES=1

# The user CAIDPS was installed for (the installer runs as them, or with sudo on their behalf).
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  ACTUAL_USER="${SUDO_USER}"
  ACTUAL_HOME="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6)"
  [ -n "${ACTUAL_HOME}" ] || ACTUAL_HOME="$(eval echo "~${SUDO_USER}")"
else
  ACTUAL_USER="$(id -un)"
  ACTUAL_HOME="${HOME}"
fi

if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
  echo -e "${RED}[error] Root privileges (or sudo) are required to remove the service and system files.${RESET}" >&2
  exit 1
fi

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

# Run a command as the installing user (their Cloudflare login, not root's).
as_user() {
  if [ "$(id -u)" -eq 0 ] && [ "$ACTUAL_USER" != "root" ]; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$ACTUAL_USER" -- "$@"
    else
      sudo -u "$ACTUAL_USER" -H "$@"
    fi
  else
    "$@"
  fi
}

as_postgres() {
  if [ "$(id -u)" -eq 0 ]; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u postgres -- "$@"
    else
      su -s /bin/sh postgres -c "$(printf '%q ' "$@")"
    fi
  else
    sudo -u postgres "$@"
  fi
}

# The app's local PostgreSQL install lives on the default local socket/port; ignore any inherited PG* target.
as_postgres_local() {
  ( unset PGHOST PGPORT PGDATABASE PGUSER; as_postgres "$@" )
}

# CAIDPS processes, matched on their command line.
PROCESSES=("uvicorn app:app" "proxy.server" "scripts/serve.sh" "cloudflared tunnel" "-m hostd")

# This script and the shells that started it: never signalled. Run as `bash -c "$(curl …)"`, the
# shell's own command line contains this whole script, so a bare `pkill -f` would match it.
ANCESTORS=" $$ "
pid=$$
while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ -r "/proc/$pid/status" ]; do
  pid="$(awk '/^PPid:/ {print $2}' "/proc/$pid/status")"
  ANCESTORS="${ANCESTORS}${pid} "
done

is_self() {   # is_self <pid>: this script, a shell that started it, one of its own subshells,
              # or a process already gone (the $(pgrep …) subshell that listed itself)
  local first=""
  case "$ANCESTORS" in *" $1 "*) return 0 ;; esac
  IFS= read -r -d '' first < "/proc/$1/cmdline" 2>/dev/null   # /proc files report size 0: read, don't test -s
  [ -n "$first" ] || return 0
  cmp -s "/proc/$1/cmdline" "/proc/$$/cmdline" 2>/dev/null
}

stop_matching() {   # stop_matching <pattern> <signal>
  local p
  for p in $(pgrep -f "$1" 2>/dev/null); do
    is_self "$p" && continue
    as_root kill "-$2" "$p" 2>/dev/null || true
  done
}

still_running() {   # any CAIDPS process left, other than this script and its parents
  local pattern p
  for pattern in "${PROCESSES[@]}"; do
    for p in $(pgrep -f "$pattern" 2>/dev/null); do
      is_self "$p" && continue
      return 0
    done
  done
  return 1
}

# A directory is removed only if it is a CAIDPS checkout.
is_caidps_dir() {
  [ -n "$1" ] && [ -d "$1" ] && [ -f "$1/scripts/serve.sh" ] && [ -d "$1/prototype/backend" ]
}

# Installs to remove: the default locations, the one the `caidps` command points at, and --dir.
INSTALL_DIRS=()
add_dir() {
  local d="$1" existing
  is_caidps_dir "$d" || return 0
  d="$(cd "$d" && pwd -P)"
  for existing in "${INSTALL_DIRS[@]+"${INSTALL_DIRS[@]}"}"; do
    [ "$existing" = "$d" ] && return 0
  done
  INSTALL_DIRS+=("$d")
}
add_dir "/opt/caidps"
add_dir "${ACTUAL_HOME}/caidps"
for link in /usr/local/bin/caidps "${ACTUAL_HOME}/.local/bin/caidps"; do
  if [ -L "$link" ]; then
    target="$(readlink -f "$link" 2>/dev/null || readlink "$link" 2>/dev/null || true)"
    [ -n "$target" ] && add_dir "$(dirname "$(dirname "$target")")"
  fi
done
if [ -n "$EXTRA_DIR" ]; then
  if is_caidps_dir "$EXTRA_DIR"; then
    add_dir "$EXTRA_DIR"
  else
    echo -e "${RED}[error] --dir ${EXTRA_DIR} is not a CAIDPS install (no scripts/serve.sh); nothing removed.${RESET}" >&2
    exit 2
  fi
fi

CONTAINERS="juice-shop vulnbank medivault dvna cicd-goat"
CF_DIRS=("${ACTUAL_HOME}/.cloudflared" "/etc/cloudflared")
[ "${ACTUAL_HOME}" = "/root" ] || CF_DIRS+=("/root/.cloudflared")

install_kind() {
  local d="$1" envf="$1/deploy/.env" project suffix
  if [ -n "$KIND_OVERRIDE" ]; then echo "$KIND_OVERRIDE"; return 0; fi
  if [ -f "$envf" ]; then
    if ! as_root test -r "$envf"; then
      echo -e "${RED}[error] ${envf} is not readable even with sudo; use --kind containers|systemd.${RESET}" >&2
      return 1
    fi
    if as_root grep -q '^CAIDPS_INSTALL=containers' "$envf" 2>/dev/null; then echo containers; return 0; fi
    if as_root grep -q '^CAIDPS_COMPOSE_PROJECT=..*' "$envf" 2>/dev/null; then echo containers; return 0; fi
    if as_root grep -q '^CAIDPS_INSTALL=systemd' "$envf" 2>/dev/null; then echo systemd; return 0; fi
  fi
  if [ -n "$PROJECT_OVERRIDE" ]; then echo containers; return 0; fi

  project="$(install_project "$d")" || return 1
  suffix="$(unit_suffix "$project")"
  if as_root test -f "/etc/systemd/system/caidps-hostd${suffix}.service"; then echo containers; return 0; fi

  # Last resort for a missing env: find a live Compose project before treating this as a checkout.
  if command -v docker >/dev/null 2>&1 && as_root docker info >/dev/null 2>&1; then
    if as_root docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.Names}}' 2>/dev/null | grep -q .; then
      echo containers
      return 0
    fi
    if as_root docker volume ls --filter "label=com.docker.compose.project=${project}" --format '{{.Name}}' 2>/dev/null | grep -q .; then
      echo containers
      return 0
    fi
  fi
  echo systemd
}

install_project() {
  local d="$1" recorded="" project="$PROJECT_OVERRIDE"
  if [ -f "$d/deploy/.env" ]; then
    if ! as_root test -r "$d/deploy/.env"; then
      echo -e "${RED}[error] ${d}/deploy/.env is not readable even with sudo; use --project NAME.${RESET}" >&2
      return 1
    fi
    recorded="$(as_root sed -n 's/^CAIDPS_COMPOSE_PROJECT=//p' "$d/deploy/.env" | tail -n 1)"
    recorded="${recorded%\"}"; recorded="${recorded#\"}"
    recorded="${recorded%\'}"; recorded="${recorded#\'}"
  fi
  if [ -n "$recorded" ]; then
    if [ -n "$PROJECT_OVERRIDE" ] && [ "$PROJECT_OVERRIDE" != "$recorded" ]; then
      echo -e "${RED}[error] --project ${PROJECT_OVERRIDE} conflicts with ${recorded} recorded in ${d}/deploy/.env.${RESET}" >&2
      return 1
    fi
    project="$recorded"
  fi
  [ -n "$project" ] || project="caidps"
  if ! printf '%s' "$project" | grep -qE '^[a-z0-9][a-z0-9_-]*$'; then
    echo -e "${RED}[error] Invalid compose project '${project}' (lowercase letters, digits, - and _).${RESET}" >&2
    return 1
  fi
  echo "$project"
}

install_db_url() {
  local d="$1" f="$1/prototype/backend/.env" url=""
  [ -f "$f" ] || f="$1/deploy/.env"
  if [ -f "$f" ]; then
    if as_root test -r "$f"; then
      url="$(as_root sed -n 's/^CAIDPS_DATABASE_URL=//p' "$f" | tail -n 1)"
      url="${url%\"}"; url="${url#\"}"
      url="${url%\'}"; url="${url#\'}"
    else
      echo -e "${YELLOW}[reset] ${f} is not readable; the database was not inspected.${RESET}" >&2
    fi
  fi
  echo "$url"
}

install_redis_url() {
  local d="$1" f="$1/prototype/backend/.env" url=""
  [ -f "$f" ] || f="$1/deploy/.env"
  if [ -f "$f" ] && as_root test -r "$f"; then
    url="$(as_root sed -n 's/^CAIDPS_REDIS_URL=//p' "$f" | tail -n 1)"
    url="${url%\"}"; url="${url#\"}"
    url="${url%\'}"; url="${url#\'}"
  fi
  echo "$url"
}

# Never print database/Redis passwords in the reset log.
redact_url() {
  printf '%s' "$1" | sed -E 's#(://)[^/@]*@#\1***@#'
}

env_value_nonempty() {   # env_value_nonempty <file> <key>
  local value
  value="$(as_root sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1)"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  [ -n "$value" ]
}

install_tunnel_name() {
  local name="" unit="/etc/systemd/system/caidps.service"
  if as_root test -f "$unit"; then
    name="$(as_root sed -n 's/.*--tunnel-name[ =]\([^ "]*\).*/\1/p' "$unit" | head -n 1)"
  fi
  echo "$name"
}

install_tunnel_is_token() {
  local d="$1" f unit="/etc/systemd/system/caidps.service"
  for f in "$d/deploy/.env" "$d/prototype/backend/.env"; do
    if [ -f "$f" ] && env_value_nonempty "$f" CAIDPS_TUNNEL_TOKEN; then
      return 0
    fi
  done
  if as_root test -f "$unit" && as_root grep -q -- '--tunnel-token' "$unit" 2>/dev/null; then
    return 0
  fi
  return 1
}

install_tunnel_is_quick() {
  local unit="/etc/systemd/system/caidps.service"
  as_root test -f "$unit" || return 1
  as_root grep -q -- '--tunnel' "$unit" 2>/dev/null || return 1
  as_root grep -q -- '--tunnel-name' "$unit" 2>/dev/null && return 1
  as_root grep -q -- '--tunnel-token' "$unit" 2>/dev/null && return 1
  return 0
}

db_url_user() {
  local rest="${1#*://}"
  printf '%s' "${rest%%:*}" | sed 's/@.*//'
}
db_url_host() {
  local rest="${1#*://}"
  rest="${rest#*@}"
  printf '%s' "${rest%%[:/]*}"
}
db_url_port() {
  local rest="${1#*://}" hostport port
  rest="${rest#*@}"
  hostport="${rest%%/*}"
  case "$hostport" in
    *:*) port="${hostport##*:}" ;;
    *) port="5432" ;;
  esac
  [ -n "$port" ] || port="5432"
  echo "$port"
}
db_url_name() {
  local rest="${1#*://}"
  rest="${rest#*/}"
  printf '%s' "${rest%%\?*}" | sed 's/#.*//'
}
db_url_is_local() {
  case "$(db_url_host "$1")" in
    127.0.0.1|localhost|::1) return 0 ;;
    *) return 1 ;;
  esac
}
db_url_is_local_default() {
  db_url_is_local "$1" \
    && [ "$(db_url_user "$1")" = "caidps" ] \
    && [ "$(db_url_name "$1")" = "caidps" ] \
    && [ "$(db_url_port "$1")" = "5432" ]
}

unit_suffix() {
  local project="$1"
  if [ "$project" = "caidps" ]; then echo ""; else echo "-${project}"; fi
}

remove_unit() {   # remove_unit <name-without-suffix>
  local name="$1"
  if ! command -v systemctl >/dev/null 2>&1; then
    as_root rm -f "/etc/systemd/system/${name}.service" "/lib/systemd/system/${name}.service" \
      "/etc/systemd/system/${name}.timer" "/lib/systemd/system/${name}.timer" 2>/dev/null || true
    return 0
  fi
  as_root systemctl stop "${name}.service" "${name}.timer" 2>/dev/null || true
  as_root systemctl disable "${name}.service" "${name}.timer" 2>/dev/null || true
  as_root rm -f "/etc/systemd/system/${name}.service" "/lib/systemd/system/${name}.service" \
    "/etc/systemd/system/${name}.timer" "/lib/systemd/system/${name}.timer" 2>/dev/null || true
  as_root systemctl daemon-reload 2>/dev/null || true
  as_root systemctl reset-failed "${name}.service" "${name}.timer" 2>/dev/null || true
}

stop_services() {
  local d="$1" kind="$2" project="$3"
  local suffix hostd backup
  suffix="$(unit_suffix "$project")"
  hostd="caidps-hostd${suffix}"
  backup="caidps-backup${suffix}"

  if [ "$kind" = "containers" ]; then
    if [ -x "$d/scripts/hostd.sh" ]; then
      echo -e "${CYAN}[1/6] Removing the CAIDPS host updater (${hostd})...${RESET}"
      as_root "$d/scripts/hostd.sh" remove --project "$project" || true
    fi
    remove_unit "$hostd"
    if [ -x "$d/scripts/backup.sh" ]; then
      echo -e "${CYAN}[1/6] Removing the nightly backup timer (${backup}.timer)...${RESET}"
      as_root "$d/scripts/backup.sh" timer remove --containers --project "$project" || true
    fi
    remove_unit "$backup"
  else
    if [ -x "$d/scripts/service.sh" ]; then
      echo -e "${CYAN}[1/6] Removing the CAIDPS systemd service and backup timer...${RESET}"
      as_root "$d/scripts/service.sh" remove || true
    fi
    remove_unit caidps
    remove_unit "$backup"
  fi
}

compose_down() {
  local d="$1" project="$2"
  if [ ! -f "$d/deploy/compose.yml" ]; then
    echo -e "${YELLOW}[reset] ${d}/deploy/compose.yml is missing; the Compose stack was not removed.${RESET}" >&2
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${YELLOW}[reset] Docker is not installed; the Compose stack was not removed.${RESET}" >&2
    return 0
  fi
  echo -e "${CYAN}[2/6] Removing the Compose stack, networks and volumes (project ${project})...${RESET}"
  if [ -f "$d/deploy/.env" ]; then
    as_root docker compose -f "$d/deploy/compose.yml" --env-file "$d/deploy/.env" \
      -p "$project" down --volumes --remove-orphans
  else
    as_root docker compose -f "$d/deploy/compose.yml" -p "$project" down --volumes --remove-orphans
  fi
}

remove_target_containers() {
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  echo -e "${CYAN}[2/6] Removing target containers...${RESET}"
  for c in $CONTAINERS; do
    as_root docker rm -f "$c" >/dev/null 2>&1 || true
  done
}

drop_local_database() {
  local url="$1"
  [ -n "$url" ] || return 0
  if ! db_url_is_local_default "$url"; then
    if db_url_is_local "$url"; then
      echo -e "${YELLOW}[reset] $(redact_url "$url") is a local database, but not the CAIDPS-managed caidps/caidps database; not touched.${RESET}" >&2
    else
      echo -e "${YELLOW}[reset] External database $(redact_url "$url") was not touched.${RESET}" >&2
    fi
    return 0
  fi
  if ! command -v psql >/dev/null 2>&1; then
    echo -e "${YELLOW}[reset] psql is not installed; drop the caidps database and role manually.${RESET}" >&2
    return 1
  fi
  echo -e "${CYAN}[reset] Dropping the local PostgreSQL database and role 'caidps'...${RESET}"
  as_postgres_local psql -v ON_ERROR_STOP=1 -q \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'caidps' AND pid <> pg_backend_pid();" \
    >/dev/null 2>&1 || true
  as_postgres_local psql -v ON_ERROR_STOP=1 -q -c "DROP DATABASE IF EXISTS caidps;" >/dev/null 2>&1 || true
  as_postgres_local psql -v ON_ERROR_STOP=1 -q -c "DROP ROLE IF EXISTS caidps;" >/dev/null 2>&1 || true
}

remove_host_tunnel() {
  local kind="$1" name="$2" is_token="$3" is_quick="$4"
  if [ "$is_token" -eq 1 ]; then
    echo -e "${YELLOW}[reset] The Cloudflare tunnel is token-managed; delete it in Zero Trust.${RESET}" >&2
    return 0
  fi
  if [ "$kind" = "containers" ]; then
    return 0
  fi
  if [ -z "$name" ]; then
    if [ "$is_quick" -eq 1 ]; then
      echo -e "${YELLOW}[reset] This was a Quick Tunnel; there is no named tunnel to delete.${RESET}" >&2
    else
      echo -e "${YELLOW}[reset] No host-managed named Cloudflare Tunnel was detected; nothing deleted remotely.${RESET}" >&2
    fi
    return 0
  fi
  if command -v cloudflared >/dev/null 2>&1; then
    echo -e "${CYAN}[3/6] Removing the host-managed Cloudflare Tunnel '${name}' and its credentials...${RESET}"
    as_user cloudflared tunnel cleanup "$name" >/dev/null 2>&1 || true
    as_user cloudflared tunnel delete -f "$name" >/dev/null 2>&1 || true
  fi
}

# Snapshot the metadata before any checkout is deleted: the verification runs after deletion.
INSTALL_KINDS=()
INSTALL_PROJECTS=()
INSTALL_DB_URLS=()
INSTALL_REDIS_URLS=()
INSTALL_TUNNEL_NAMES=()
INSTALL_TUNNEL_TOKENS=()
INSTALL_TUNNEL_QUICKS=()
HAS_SYSTEMD=0
i=0
while [ "$i" -lt "${#INSTALL_DIRS[@]}" ]; do
  _d="${INSTALL_DIRS[$i]}"
  _kind="$(install_kind "$_d")" || exit 2
  _project="$(install_project "$_d")" || exit 2
  INSTALL_KINDS+=("$_kind")
  INSTALL_PROJECTS+=("$_project")
  INSTALL_DB_URLS+=("$(install_db_url "$_d")")
  INSTALL_REDIS_URLS+=("$(install_redis_url "$_d")")
  INSTALL_TUNNEL_NAMES+=("$(install_tunnel_name "$_d")")
  if install_tunnel_is_token "$_d"; then INSTALL_TUNNEL_TOKENS+=(1); else INSTALL_TUNNEL_TOKENS+=(0); fi
  if install_tunnel_is_quick "$_d"; then INSTALL_TUNNEL_QUICKS+=(1); else INSTALL_TUNNEL_QUICKS+=(0); fi
  [ "$_kind" = "systemd" ] && HAS_SYSTEMD=1
  i=$((i + 1))
done

echo -e "${RED}${BOLD}"
echo "================================================================="
echo "             CAIDPS System Teardown & Factory Reset              "
echo "================================================================="
echo -e "${RESET}"
echo "This will:"
echo "  1. Stop and remove CAIDPS services, host updater(s), backup timers and processes"
echo "  2. Remove target containers and, for container installs, the Compose stack, networks and data volumes"
echo "  3. Remove host-managed Cloudflare tunnel credentials (token-managed tunnels stay in Cloudflare)"
if [ "${#INSTALL_DIRS[@]}" -gt 0 ]; then
  echo "  4. Delete the CAIDPS install(s), including their settings and local database/volume data:"
  i=0
  while [ "$i" -lt "${#INSTALL_DIRS[@]}" ]; do
    d="${INSTALL_DIRS[$i]}"
    kind="${INSTALL_KINDS[$i]}"
    project="${INSTALL_PROJECTS[$i]}"
    if [ "$kind" = "containers" ]; then
      echo "       ${d}  (containers, project ${project}: stack + named volumes)"
    else
      echo "       ${d}  (systemd: local caidps database/role if used)"
    fi
    i=$((i + 1))
  done
else
  echo "  4. (no CAIDPS install found to delete)"
fi
echo "     and the 'caidps' command"
echo "     External databases, external Redis, and dashboard-managed tunnels are not touched."
if [ "$PURGE_PACKAGES" -eq 1 ]; then
  echo -e "  5. ${RED}${BOLD}Uninstall cloudflared, Node.js, Docker and whiptail — and delete ALL Docker${RESET}"
  echo -e "     ${RED}${BOLD}images, containers and volumes on this machine (/var/lib/docker)${RESET}"
else
  echo "  5. Packages (cloudflared, Node.js, Docker, whiptail) are kept; add --purge-packages to remove them"
fi
echo ""

if [ "$ASSUME_YES" -ne 1 ]; then
  if { true < /dev/tty; } 2>/dev/null; then
    read -r -p "Type 'reset' to continue: " answer < /dev/tty
    if [ "${answer:-}" != "reset" ]; then
      echo "Cancelled; nothing was changed."
      exit 1
    fi
  else
    echo -e "${RED}[error] No terminal to confirm on. Re-run with --yes (or CAIDPS_RESET_CONFIRM=yes) to reset unattended.${RESET}" >&2
    exit 1
  fi
fi

# 1. Services and processes (before the checkout is deleted, so the app's own teardown can run).
i=0
while [ "$i" -lt "${#INSTALL_DIRS[@]}" ]; do
  stop_services "${INSTALL_DIRS[$i]}" "${INSTALL_KINDS[$i]}" "${INSTALL_PROJECTS[$i]}"
  i=$((i + 1))
done
if [ "$HAS_SYSTEMD" -eq 1 ]; then
  for pattern in "${PROCESSES[@]}"; do
    stop_matching "$pattern" TERM
  done
  sleep 1
  for pattern in "${PROCESSES[@]}"; do
    stop_matching "$pattern" KILL
  done
fi

# 2. Container stacks and legacy target containers.
i=0
while [ "$i" -lt "${#INSTALL_DIRS[@]}" ]; do
  if [ "${INSTALL_KINDS[$i]}" = "containers" ]; then
    compose_down "${INSTALL_DIRS[$i]}" "${INSTALL_PROJECTS[$i]}"
  fi
  i=$((i + 1))
done
if [ "$HAS_SYSTEMD" -eq 1 ]; then
  remove_target_containers
fi

# 3. Host-managed tunnels (before credentials are removed).
i=0
while [ "$i" -lt "${#INSTALL_DIRS[@]}" ]; do
  remove_host_tunnel "${INSTALL_KINDS[$i]}" "${INSTALL_TUNNEL_NAMES[$i]}" "${INSTALL_TUNNEL_TOKENS[$i]}" "${INSTALL_TUNNEL_QUICKS[$i]}"
  i=$((i + 1))
done
for d in "${CF_DIRS[@]}"; do
  as_root rm -rf "$d" 2>/dev/null || true
done
rm -rf /tmp/cloudflared* 2>/dev/null || true

# 4. Local databases for systemd installs (external/custom databases are reported, not touched).
i=0
while [ "$i" -lt "${#INSTALL_DIRS[@]}" ]; do
  if [ "${INSTALL_KINDS[$i]}" = "systemd" ]; then
    drop_local_database "${INSTALL_DB_URLS[$i]}" || true
  fi
  i=$((i + 1))
done

remove_cli_links() {
  local link target d
  for link in /usr/local/bin/caidps "${ACTUAL_HOME}/.local/bin/caidps"; do
    [ -L "$link" ] || continue
    target="$(readlink -f "$link" 2>/dev/null || readlink "$link" 2>/dev/null || true)"
    [ -n "$target" ] || continue
    for d in "${INSTALL_DIRS[@]+"${INSTALL_DIRS[@]}"}"; do
      if [ "$target" = "$d/scripts/caidps" ]; then
        as_root rm -f "$link" 2>/dev/null || true
        break
      fi
    done
  done
}

# 5. Installs, the CLI and temporary files.
echo -e "${CYAN}[4/6] Deleting the CAIDPS install and the 'caidps' command...${RESET}"
for d in "${INSTALL_DIRS[@]+"${INSTALL_DIRS[@]}"}"; do
  as_root rm -rf "$d"
done
remove_cli_links
rm -rf /tmp/caidps* 2>/dev/null || true

# 6. Packages (opt-in)
if [ "$PURGE_PACKAGES" -eq 1 ]; then
  echo -e "${CYAN}[5/6] Uninstalling cloudflared, Node.js, Docker and whiptail...${RESET}"
  case "$(uname -s)" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        as_root apt-get purge -y cloudflared 2>/dev/null || true
        as_root rm -f /usr/local/bin/cloudflared /etc/apt/sources.list.d/cloudflared* 2>/dev/null || true
        as_root apt-get purge -y nodejs npm 2>/dev/null || true
        as_root rm -f /etc/apt/sources.list.d/nodesource* /etc/apt/keyrings/nodesource* 2>/dev/null || true
        if command -v systemctl >/dev/null 2>&1; then
          as_root systemctl stop docker docker.socket 2>/dev/null || true
          as_root systemctl disable docker 2>/dev/null || true
        fi
        as_root apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io 2>/dev/null || true
        as_root rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/containerd 2>/dev/null || true
        as_root rm -f /etc/apt/sources.list.d/docker* /etc/apt/keyrings/docker* 2>/dev/null || true
        as_root apt-get purge -y whiptail 2>/dev/null || true
        as_root apt-get autoremove -y >/dev/null 2>&1 || true
        as_root apt-get clean >/dev/null 2>&1 || true
      elif command -v dnf >/dev/null 2>&1; then
        as_root dnf remove -y cloudflared nodejs npm docker-ce docker-ce-cli containerd.io newt 2>/dev/null || true
        as_root systemctl stop docker docker.socket 2>/dev/null || true
        as_root rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/containerd 2>/dev/null || true
        as_root rm -f /etc/yum.repos.d/docker* /etc/yum.repos.d/nodesource* 2>/dev/null || true
      elif command -v yum >/dev/null 2>&1; then
        as_root yum remove -y cloudflared nodejs npm docker-ce docker-ce-cli containerd.io newt 2>/dev/null || true
        as_root systemctl stop docker docker.socket 2>/dev/null || true
        as_root rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/containerd 2>/dev/null || true
        as_root rm -f /etc/yum.repos.d/docker* /etc/yum.repos.d/nodesource* 2>/dev/null || true
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew uninstall cloudflared node newt 2>/dev/null || true
      fi
      as_root rm -f /usr/local/bin/cloudflared 2>/dev/null || true
      ;;
  esac
else
  echo -e "${CYAN}[5/6] Keeping installed packages (no --purge-packages).${RESET}"
fi

# 7. Verify: report what is actually left, not what was meant to go.
echo -e "${CYAN}[6/6] Verifying...${RESET}"
LEFT=0
check() {   # check <description> <command...>: the command succeeds while the item is still present
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo -e "  • ${what} : ${RED}still present${RESET}"
    LEFT=1
  else
    echo -e "  • ${what} : ${GREEN}removed${RESET}"
  fi
}

compose_has_containers() {
  as_root docker ps -a --filter "label=com.docker.compose.project=$1" --format '{{.Names}}' 2>/dev/null | grep -q .
}
compose_has_volumes() {
  as_root docker volume ls --filter "label=com.docker.compose.project=$1" --format '{{.Name}}' 2>/dev/null | grep -q .
}
compose_has_networks() {
  as_root docker network ls --filter "label=com.docker.compose.project=$1" --format '{{.Name}}' 2>/dev/null | grep -q .
}
local_db_exists() {
  command -v psql >/dev/null 2>&1 || return 1
  as_postgres_local psql -tAc "SELECT 1 FROM pg_database WHERE datname = 'caidps'" 2>/dev/null | grep -q 1
}
local_role_exists() {
  command -v psql >/dev/null 2>&1 || return 1
  as_postgres_local psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'caidps'" 2>/dev/null | grep -q 1
}
pg_ready() {
  command -v psql >/dev/null 2>&1 || return 1
  as_postgres_local psql -tAc "SELECT 1" >/dev/null 2>&1
}
legacy_target_exists() {
  as_root docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qxE "$(echo "$CONTAINERS" | tr ' ' '|')"
}
cli_link_leftover() {
  local link target d
  for link in /usr/local/bin/caidps "${ACTUAL_HOME}/.local/bin/caidps"; do
    [ -L "$link" ] || continue
    target="$(readlink -f "$link" 2>/dev/null || readlink "$link" 2>/dev/null || true)"
    [ -n "$target" ] || continue
    for d in "${INSTALL_DIRS[@]+"${INSTALL_DIRS[@]}"}"; do
      [ "$target" = "$d/scripts/caidps" ] && return 0
    done
  done
  return 1
}

if [ "$HAS_SYSTEMD" -eq 1 ]; then
  check "Service (caidps.service)" test -e /etc/systemd/system/caidps.service
fi

DOCKER_READY=0
if command -v docker >/dev/null 2>&1 && as_root docker info >/dev/null 2>&1; then
  DOCKER_READY=1
fi

i=0
while [ "$i" -lt "${#INSTALL_DIRS[@]}" ]; do
  d="${INSTALL_DIRS[$i]}"
  kind="${INSTALL_KINDS[$i]}"
  project="${INSTALL_PROJECTS[$i]}"
  db_url="${INSTALL_DB_URLS[$i]}"
  redis_url="${INSTALL_REDIS_URLS[$i]}"
  suffix="$(unit_suffix "$project")"

  check "Install (${d})" test -e "$d"
  if [ "$kind" = "containers" ]; then
    check "Host updater (caidps-hostd${suffix}.service)" test -e "/etc/systemd/system/caidps-hostd${suffix}.service"
  fi
  check "Backup timer (caidps-backup${suffix}.timer)" test -e "/etc/systemd/system/caidps-backup${suffix}.timer"

  if [ "$kind" = "containers" ] && [ "$DOCKER_READY" -eq 1 ]; then
    check "Compose containers (project ${project})" compose_has_containers "$project"
    check "Compose volumes (project ${project})" compose_has_volumes "$project"
    check "Compose networks (project ${project})" compose_has_networks "$project"
  fi

  if [ "$kind" = "systemd" ]; then
    if db_url_is_local_default "$db_url"; then
      if pg_ready; then
        check "Local database (caidps)" local_db_exists
        check "Local role (caidps)" local_role_exists
      else
        echo -e "  • Local database (caidps) : ${YELLOW}cannot verify (PostgreSQL not reachable)${RESET}"
        LEFT=1
      fi
    elif [ -n "$db_url" ] && ! db_url_is_local "$db_url"; then
      echo -e "${YELLOW}  • External database ($(redact_url "$db_url")) : not touched; remove it separately if required.${RESET}"
    fi
    if [ -n "$redis_url" ]; then
      case "$(db_url_host "$redis_url")" in
        127.0.0.1|localhost|::1)
          echo -e "${YELLOW}  • Local Redis ($(redact_url "$redis_url")) : not flushed; a reinstall reuses it.${RESET}" ;;
        *)
          echo -e "${YELLOW}  • External Redis ($(redact_url "$redis_url")) : not touched.${RESET}" ;;
      esac
    fi
  fi
  i=$((i + 1))
done

if [ "$DOCKER_READY" -ne 1 ] && command -v docker >/dev/null 2>&1 && [ "$PURGE_PACKAGES" -ne 1 ]; then
  echo -e "${YELLOW}  ! Docker is installed but not accessible; compose artifacts were not verified.${RESET}" >&2
  LEFT=1
fi

check "CAIDPS CLI links" cli_link_leftover
if [ "$HAS_SYSTEMD" -eq 1 ]; then
  if command -v pgrep >/dev/null 2>&1; then
    check "CAIDPS processes" still_running
  else
    echo -e "  • CAIDPS processes : ${YELLOW}cannot verify (pgrep not installed)${RESET}"
    LEFT=1
  fi
fi
for d in "${CF_DIRS[@]}"; do
  check "Cloudflare credentials (${d})" as_root test -e "$d"
done
if [ "$DOCKER_READY" -eq 1 ] && [ "$HAS_SYSTEMD" -eq 1 ]; then
  check "Target containers" legacy_target_exists
fi

echo ""
if [ "$LEFT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}CAIDPS reset complete.${RESET} Reinstall with:"
else
  echo -e "${YELLOW}${BOLD}Reset finished, but some items are still present (see above).${RESET} Reinstall with:"
fi
echo -e "  ${CYAN}curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash${RESET}"
echo ""
[ "$LEFT" -eq 0 ]
}

main "$@"
