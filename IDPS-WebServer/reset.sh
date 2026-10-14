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
#
set -u

# Everything runs from main(), called on the last line: a `curl | bash` download cut short
# never runs half a teardown.
main() {

if [ -t 1 ]; then
  BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; RESET=""
fi

ASSUME_YES=0
PURGE_PACKAGES=0
EXTRA_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --purge-packages) PURGE_PACKAGES=1 ;;
    --dir) EXTRA_DIR="${2:-}"; shift ;;
    -h|--help)
      echo "Usage: reset.sh [--yes] [--purge-packages] [--dir PATH]"
      echo "  --yes             no confirmation prompt (scripted runs)"
      echo "  --purge-packages  also uninstall cloudflared, Node.js, Docker (and ALL Docker data), whiptail"
      echo "  --dir PATH        also remove a CAIDPS install at PATH"
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

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo -e "${RED}[error] Root privileges (or sudo) are required to remove the service and system files.${RESET}" >&2
    exit 1
  fi
fi

# Run a command as the installing user (their Cloudflare login, not root's).
as_user() {
  if [ "$(id -u)" -eq 0 ] && [ "$ACTUAL_USER" != "root" ]; then
    sudo -u "$ACTUAL_USER" -H "$@"
  else
    "$@"
  fi
}

# CAIDPS processes, matched on their command line.
PROCESSES=("uvicorn app:app" "proxy.server" "scripts/serve.sh" "cloudflared tunnel")

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
    $SUDO kill "-$2" "$p" 2>/dev/null || true
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
    target="$(readlink -f "$link" 2>/dev/null || true)"
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

echo -e "${RED}${BOLD}"
echo "================================================================="
echo "             CAIDPS System Teardown & Factory Reset              "
echo "================================================================="
echo -e "${RESET}"
echo "This will:"
echo "  1. Stop and delete the 'caidps' systemd service and running CAIDPS processes"
echo "  2. Stop and remove the target containers: ${CONTAINERS}"
echo "  3. Delete the 'caidps' Cloudflare Tunnel and the credentials in: ${CF_DIRS[*]}"
if [ "${#INSTALL_DIRS[@]}" -gt 0 ]; then
  echo "  4. Delete the CAIDPS install(s), including its database and settings:"
  for d in "${INSTALL_DIRS[@]}"; do echo "       ${d}"; done
else
  echo "  4. (no CAIDPS install found to delete)"
fi
echo "     and the 'caidps' command"
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

# 1. Service and processes
echo -e "${CYAN}[1/6] Stopping and removing the CAIDPS systemd service...${RESET}"
if command -v systemctl >/dev/null 2>&1; then
  $SUDO systemctl stop caidps 2>/dev/null || true
  $SUDO systemctl disable caidps 2>/dev/null || true
  $SUDO rm -f /etc/systemd/system/caidps.service /lib/systemd/system/caidps.service
  $SUDO systemctl daemon-reload 2>/dev/null || true
  $SUDO systemctl reset-failed caidps 2>/dev/null || true
fi
for pattern in "${PROCESSES[@]}"; do
  stop_matching "$pattern" TERM
done
sleep 1
for pattern in "${PROCESSES[@]}"; do
  stop_matching "$pattern" KILL
done

# 2. Containers
echo -e "${CYAN}[2/6] Removing target containers...${RESET}"
if command -v docker >/dev/null 2>&1; then
  for c in $CONTAINERS; do
    $SUDO docker rm -f "$c" >/dev/null 2>&1 || true
  done
fi

# 3. Cloudflare Tunnel
echo -e "${CYAN}[3/6] Removing the Cloudflare Tunnel and its credentials...${RESET}"
if command -v cloudflared >/dev/null 2>&1; then
  as_user cloudflared tunnel cleanup caidps >/dev/null 2>&1 || true
  as_user cloudflared tunnel delete -f caidps >/dev/null 2>&1 || true
fi
for d in "${CF_DIRS[@]}"; do
  $SUDO rm -rf "$d" 2>/dev/null || true
done
rm -rf /tmp/cloudflared* 2>/dev/null || true

# 4. Installs and the CLI
echo -e "${CYAN}[4/6] Deleting the CAIDPS install and the 'caidps' command...${RESET}"
for d in "${INSTALL_DIRS[@]+"${INSTALL_DIRS[@]}"}"; do
  $SUDO rm -rf "$d"
done
$SUDO rm -f /usr/local/bin/caidps "${ACTUAL_HOME}/.local/bin/caidps" 2>/dev/null || true
rm -rf /tmp/caidps* 2>/dev/null || true

# 5. Packages (opt-in)
if [ "$PURGE_PACKAGES" -eq 1 ]; then
  echo -e "${CYAN}[5/6] Uninstalling cloudflared, Node.js, Docker and whiptail...${RESET}"
  case "$(uname -s)" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get purge -y cloudflared 2>/dev/null || true
        $SUDO rm -f /usr/local/bin/cloudflared /etc/apt/sources.list.d/cloudflared* 2>/dev/null || true
        $SUDO apt-get purge -y nodejs npm 2>/dev/null || true
        $SUDO rm -f /etc/apt/sources.list.d/nodesource* /etc/apt/keyrings/nodesource* 2>/dev/null || true
        if command -v systemctl >/dev/null 2>&1; then
          $SUDO systemctl stop docker docker.socket 2>/dev/null || true
          $SUDO systemctl disable docker 2>/dev/null || true
        fi
        $SUDO apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io 2>/dev/null || true
        $SUDO rm -rf /var/lib/docker /var/lib/containerd /etc/docker 2>/dev/null || true
        $SUDO rm -f /etc/apt/sources.list.d/docker* /etc/apt/keyrings/docker* 2>/dev/null || true
        $SUDO apt-get purge -y whiptail 2>/dev/null || true
        $SUDO apt-get autoremove -y >/dev/null 2>&1 || true
        $SUDO apt-get clean >/dev/null 2>&1 || true
      elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf remove -y cloudflared nodejs npm docker-ce docker-ce-cli containerd.io newt 2>/dev/null || true
      elif command -v yum >/dev/null 2>&1; then
        $SUDO yum remove -y cloudflared nodejs npm docker-ce docker-ce-cli containerd.io newt 2>/dev/null || true
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew uninstall cloudflared node newt 2>/dev/null || true
      fi
      $SUDO rm -f /usr/local/bin/cloudflared 2>/dev/null || true
      ;;
  esac
else
  echo -e "${CYAN}[5/6] Keeping installed packages (no --purge-packages).${RESET}"
fi

# 6. Verify: report what is actually left, not what was meant to go
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
check "Service (caidps.service)" test -e /etc/systemd/system/caidps.service
for d in "${INSTALL_DIRS[@]+"${INSTALL_DIRS[@]}"}"; do
  check "Install (${d})" test -e "$d"
done
check "Global CLI (/usr/local/bin/caidps)" test -e /usr/local/bin/caidps
check "CAIDPS processes" still_running
check "Cloudflare credentials (${ACTUAL_HOME}/.cloudflared)" test -e "${ACTUAL_HOME}/.cloudflared"
if command -v docker >/dev/null 2>&1; then
  check "Target containers" sh -c "docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qxE '$(echo "$CONTAINERS" | tr ' ' '|')'"
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
