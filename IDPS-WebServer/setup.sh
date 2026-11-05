#!/usr/bin/env bash
# CAIDPS Installer & Interactive Setup Wizard
# Automated repository clone, environment bootstrap, and guided stack launcher.
#
# Usage:
#   curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash
#   curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash -s -- <setup.sh options>
#
# Environment:
#   GITHUB_TOKEN / GH_TOKEN   token for a private clone/update (used for this run only)
#   CAIDPS_NON_INTERACTIVE=1  take every default without prompting (containers by default)
#   CI=1                      same as CAIDPS_NON_INTERACTIVE
#   CAIDPS_INSTALL_DIR=PATH   installation directory (default /opt/caidps on Linux)
#   CAIDPS_BRANCH=NAME        branch to install (default fyp2-real-detection)
#
set -u

usage() {
  cat <<'EOF'
Usage:
  curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash
  curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash -s -- [options]

Modes:
  (interactive)                    The app's setup wizard asks every question.
  --non-interactive --profile production --run containers
                                   Current production default: Docker Compose stack.
  --non-interactive --profile production --run systemd --install-local
                                   systemd install with local PostgreSQL and Redis.

Wrapper environment:
  GITHUB_TOKEN / GH_TOKEN          Token for the private repository (this run only).
  CAIDPS_NON_INTERACTIVE=1         No wrapper prompts; defaults to the container stack.
  CI=1                             Same as CAIDPS_NON_INTERACTIVE.
  CAIDPS_INSTALL_DIR=PATH          Install path (default /opt/caidps on Linux).
  CAIDPS_BRANCH=NAME               Branch (default fyp2-real-detection).

App setup.sh options passed through:
  --run containers|systemd         Production run mode.
  --install-local                  Install PostgreSQL and Redis locally (systemd).
  --postgres-url / --redis-url     Use existing production datastores (systemd).
  --project NAME                   Compose project name (containers).
  --tls acme|files|internal|none   HTTPS in the container stack.
  --upstream URL                   Protect an existing app instead of Juice Shop.
  --restore ARCHIVE                Restore a backup into a new container stack.
  --no-link-cli                    Do not install the global caidps command.
  --dry-run                        Resolve the configuration without installing packages, changing permissions, linking the CLI, or starting services (the checkout may still be cloned/updated).

Note: --install-all belongs to scripts/serve.sh, not scripts/setup.sh.
EOF
}

# Everything runs from main(), called on the last line: if a `curl | bash` download is cut
# short, bash never reaches the call and nothing half-runs.
main() {

# ANSI color codes
if [ -t 1 ]; then
  BOLD="\033[1m"
  DIM="\033[2m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  CYAN="\033[36m"
  RED="\033[31m"
  RESET="\033[0m"
else
  BOLD=""
  DIM=""
  GREEN=""
  YELLOW=""
  CYAN=""
  RED=""
  RESET=""
fi

# Resolve effective non-root user and home directory
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  ACTUAL_USER="${SUDO_USER}"
  ACTUAL_HOME="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6)"
  [ -n "${ACTUAL_HOME}" ] || ACTUAL_HOME="$(eval echo "~${SUDO_USER}")"
else
  ACTUAL_USER="$(id -un)"
  ACTUAL_HOME="${HOME}"
fi
ACTUAL_GROUP="$(id -gn "${ACTUAL_USER}" 2>/dev/null || id -gn)"

# Recommended server/system directory:
# Linux -> /opt/caidps (Linux FHS system standard for standalone stacks)
# macOS / Darwin -> ~/caidps (or /opt/caidps if root)
if [ "$(uname -s)" = "Linux" ] || [ "$(id -u)" -eq 0 ]; then
  RECOMMENDED_DIR="/opt/caidps"
else
  RECOMMENDED_DIR="${ACTUAL_HOME}/caidps"
fi

# A terminal we can actually read from? (/dev/tty exists even without a controlling terminal,
# e.g. under cron, CI or a provisioning tool, but then it cannot be opened.)
HAS_TTY=0
if { true < /dev/tty; } 2>/dev/null; then
  HAS_TTY=1
fi

# Wrapper-level flags. Everything else is forwarded verbatim to the app's setup.sh.
NON_INTERACTIVE=0
LINK_CLI=1
SYSTEMD_MODE=0
DRY_RUN=0
NO_TUI=0
RUN_MODE=""
RUN_MODE_SET=0
SYSTEMD_HINTS=0

has_arg() {
  local needle="$1"
  shift
  local arg
  for arg in "$@"; do
    [ "$arg" = "$needle" ] && return 0
  done
  return 1
}

if has_arg --help "$@" || has_arg -h "$@"; then
  usage
  exit 0
fi

INSTALL_ALL=0
LINK_CLI=1
for arg in "$@"; do
  case "$arg" in
    --install-all|--install-all=*) INSTALL_ALL=1 ;;
    --no-link-cli) LINK_CLI=0 ;;
    --link-cli) LINK_CLI=1 ;;
  esac
done

if [ "$INSTALL_ALL" -eq 1 ]; then
  {
    echo "[error] --install-all is a scripts/serve.sh flag, not a scripts/setup.sh option." >&2
    echo "" >&2
    echo "Use one of these instead:" >&2
    echo "  Container install (default):  ... | bash -s -- --non-interactive --profile production --run containers" >&2
    echo "  systemd with local DBs:       ... | bash -s -- --non-interactive --profile production --run systemd --install-local" >&2
    echo "  After a host install:         cd <install-dir> && ./scripts/serve.sh --install-all" >&2
  }
  exit 2
fi

if has_arg --dry-run "$@"; then
  DRY_RUN=1
  NO_TUI=1
fi
if has_arg --no-tui "$@" || has_arg --cli "$@"; then
  NO_TUI=1
fi

NONINTERACTIVE_ENV=0
case "${CAIDPS_NON_INTERACTIVE:-}" in
  ""|0|false|FALSE|no|NO) ;;
  *) NONINTERACTIVE_ENV=1 ;;
esac
case "${CI:-}" in
  ""|0|false|FALSE|no|NO) ;;
  *) NONINTERACTIVE_ENV=1 ;;
esac
if [ "$NONINTERACTIVE_ENV" -eq 1 ] || [ "$HAS_TTY" -eq 0 ] || has_arg --non-interactive "$@"; then
  NON_INTERACTIVE=1
fi

prev_arg=""
for arg in "$@"; do
  if [ "$prev_arg" = "--run" ]; then
    RUN_MODE="$arg"
  fi
  prev_arg="$arg"
done
if has_arg --run "$@"; then
  RUN_MODE_SET=1
fi
for flag in --install-local --postgres-url --redis-url; do
  if has_arg "$flag" "$@"; then
    SYSTEMD_HINTS=1
  fi
done

# Reject combinations the app's parser would silently ignore or that would overwrite a chosen datastore.
if [ "$RUN_MODE_SET" -eq 1 ] && [ "$RUN_MODE" = "containers" ] && [ "$SYSTEMD_HINTS" -eq 1 ]; then
  echo "[error] --run containers cannot be combined with --install-local, --postgres-url or --redis-url." >&2
  echo "Use --run systemd for a host/systemd install, or drop the datastore flags for the container stack." >&2
  exit 2
fi
if has_arg --install-local "$@" && { has_arg --postgres-url "$@" || has_arg --redis-url "$@"; }; then
  echo "[error] --install-local cannot be combined with --postgres-url/--redis-url; choose one." >&2
  exit 2
fi
if [ "$RUN_MODE" = "systemd" ]; then
  for flag in --project --tls --restore --upstream; do
    if has_arg "$flag" "$@"; then
      echo "[error] ${flag} is a container-install option and cannot be used with --run systemd." >&2
      exit 2
    fi
  done
fi

# Translate unattended intent into the current app's flags. Explicit user flags win.
WIZARD_ARGS=("$@")
if [ "$NON_INTERACTIVE" -eq 1 ]; then
  if ! has_arg --non-interactive "${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}"; then
    WIZARD_ARGS+=(--non-interactive)
  fi
  if ! has_arg --profile "${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}"; then
    WIZARD_ARGS+=(--profile production)
  fi
  if [ "$RUN_MODE_SET" -eq 0 ] && [ "$SYSTEMD_HINTS" -eq 0 ]; then
    WIZARD_ARGS+=(--run containers)
    RUN_MODE="containers"
  fi
  if [ "$RUN_MODE" = "systemd" ] || { [ "$RUN_MODE_SET" -eq 0 ] && [ "$SYSTEMD_HINTS" -eq 1 ]; }; then
    SYSTEMD_MODE=1
  fi
fi

# TTY-safe input reader that works even when the script is piped from curl.
read_tty() {
  local prompt_str="$1"
  local var_name="$2"
  local is_secret="${3:-0}"
  local input_val=""

  if [ "$NON_INTERACTIVE" -eq 1 ] || [ "$HAS_TTY" -ne 1 ]; then
    [ "$is_secret" -eq 1 ] && echo ""
    eval "$var_name=\"\""
    return 0
  fi

  if [ "$is_secret" -eq 1 ]; then
    # shellcheck disable=SC2034  # read through eval below
    read -r -s -p "$prompt_str" input_val < /dev/tty
    echo "" > /dev/tty 2>/dev/null || echo ""
  else
    # shellcheck disable=SC2034  # read through eval below
    read -r -p "$prompt_str" input_val < /dev/tty
  fi
  eval "$var_name=\"\$input_val\""
}

print_banner() {
  echo -e "${CYAN}${BOLD}"
  echo "  ____    _    ___ ____  ____  ____  "
  echo " / ___|  / \  |_ _|  _ \|  _ \/ ___| "
  echo "| |     / _ \  | || | | | |_) \___ \ "
  echo "| |___ / ___ \ | || |_| |  __/ ___) |"
  echo " \____/_/   \_\___|____/|_|   |____/ "
  echo -e "${RESET}"
  echo -e "${BOLD}Context-Aware Intrusion Detection & Prevention System${RESET}"
  echo -e "${DIM}Automated Server Downloader & Interactive Setup Wizard${RESET}"
  echo "─────────────────────────────────────────────────────────────────"
}

print_banner

ensure_whiptail() {
  if command -v whiptail >/dev/null 2>&1; then
    return 0
  fi
  local os_type
  os_type="$(uname -s)"
  local SUDO=""
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi
  case "$os_type" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        echo -e "${YELLOW}[setup] Installing whiptail for interactive wizard...${RESET}"
        $SUDO apt-get update -y >/dev/null 2>&1 && $SUDO apt-get install -y whiptail >/dev/null 2>&1 || true
      elif command -v dnf >/dev/null 2>&1; then
        echo -e "${YELLOW}[setup] Installing newt (whiptail) for interactive wizard...${RESET}"
        $SUDO dnf install -y newt >/dev/null 2>&1 || true
      elif command -v yum >/dev/null 2>&1; then
        echo -e "${YELLOW}[setup] Installing newt (whiptail) for interactive wizard...${RESET}"
        $SUDO yum install -y newt >/dev/null 2>&1 || true
      elif command -v pacman >/dev/null 2>&1; then
        $SUDO pacman -Sy --noconfirm libnewt >/dev/null 2>&1 || true
      elif command -v apk >/dev/null 2>&1; then
        $SUDO apk add --no-cache newt >/dev/null 2>&1 || true
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        echo -e "${YELLOW}[setup] Installing newt (whiptail) via Homebrew...${RESET}"
        brew install newt >/dev/null 2>&1 || true
      fi
      ;;
  esac
  command -v whiptail >/dev/null 2>&1
}

USE_TUI=0
if [ "$NON_INTERACTIVE" -eq 0 ] && [ "$NO_TUI" -eq 0 ] && [ "$HAS_TTY" -eq 1 ] && [ -t 1 ]; then
  if ensure_whiptail; then
    USE_TUI=1
  fi
fi

ensure_git() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${RED}[error] git is required even for --dry-run; install it first.${RESET}" >&2
    return 1
  fi
  echo -e "${YELLOW}[setup] git is not installed. Installing git automatically...${RESET}"
  local os_type
  os_type="$(uname -s)"
  local SUDO=""
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi

  case "$os_type" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -y && $SUDO apt-get install -y git git-lfs curl
      elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y git git-lfs curl
      elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y git git-lfs curl
      elif command -v pacman >/dev/null 2>&1; then
        $SUDO pacman -Sy --noconfirm git git-lfs curl
      elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache git git-lfs curl bash
      else
        echo -e "${RED}[error] Unsupported Linux package manager. Please install git manually.${RESET}" >&2
        return 1
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install git git-lfs
      elif ! xcode-select -p >/dev/null 2>&1; then
        echo -e "${YELLOW}[setup] Prompting Apple Developer Command Line Tools install...${RESET}"
        xcode-select --install
        echo "Please complete the installation dialog and re-run this command."
        return 1
      fi
      ;;
    *)
      echo -e "${RED}[error] Unsupported operating system: $os_type${RESET}" >&2
      return 1
      ;;
  esac

  if ! command -v git >/dev/null 2>&1; then
    echo -e "${RED}[error] git installation could not be completed automatically.${RESET}" >&2
    return 1
  fi
  echo -e "${GREEN}[setup] git installed successfully!${RESET}"
}

ensure_lfs() {
  if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}[setup] git-lfs is not installed; --dry-run will not install it.${RESET}" >&2
    return 0
  fi
  echo -e "${YELLOW}[setup] git-lfs is not installed. Installing git-lfs automatically...${RESET}"
  local os_type
  os_type="$(uname -s)"
  local SUDO=""
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi

  case "$os_type" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -y && $SUDO apt-get install -y git-lfs
      elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y git-lfs
      elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y git-lfs
      elif command -v pacman >/dev/null 2>&1; then
        $SUDO pacman -Sy --noconfirm git-lfs
      elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache git-lfs
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install git-lfs
      fi
      ;;
  esac

  if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
    git lfs install 2>/dev/null || true
    echo -e "${GREEN}[setup] git-lfs installed successfully!${RESET}"
  fi
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

run_as_user() {
  if [ "$(id -u)" -eq 0 ] && [ "$ACTUAL_USER" != "root" ]; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$ACTUAL_USER" -- "$@"
    elif command -v sudo >/dev/null 2>&1; then
      sudo -u "$ACTUAL_USER" -H "$@"
    else
      "$@"
    fi
  else
    "$@"
  fi
}

ensure_curl() {
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}[setup] curl is missing; --dry-run will not install it.${RESET}" >&2
    return 0
  fi
  echo -e "${YELLOW}[setup] Installing curl (needed by the app's dependency installers)...${RESET}"
  case "$(uname -s)" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        as_root apt-get update -y && as_root apt-get install -y curl
      elif command -v dnf >/dev/null 2>&1; then
        as_root dnf install -y curl
      elif command -v yum >/dev/null 2>&1; then
        as_root yum install -y curl
      elif command -v pacman >/dev/null 2>&1; then
        as_root pacman -Sy --noconfirm curl
      elif command -v apk >/dev/null 2>&1; then
        as_root apk add --no-cache curl
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install curl || true
      fi
      ;;
  esac
  command -v curl >/dev/null 2>&1
}

ensure_python() {
  if command -v python3 >/dev/null 2>&1 \
      && python3 -c 'import venv' >/dev/null 2>&1 \
      && python3 -m pip --version >/dev/null 2>&1; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}[setup] Python 3/venv/pip are missing; --dry-run will not install them.${RESET}" >&2
    return 0
  fi
  echo -e "${YELLOW}[setup] Installing Python 3, venv and pip (needed by the setup wizard and host updater)...${RESET}"
  case "$(uname -s)" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        as_root apt-get update -y && as_root apt-get install -y python3 python3-venv python3-pip
      elif command -v dnf >/dev/null 2>&1; then
        as_root dnf install -y python3 python3-pip
      elif command -v yum >/dev/null 2>&1; then
        as_root yum install -y python3 python3-pip
      elif command -v pacman >/dev/null 2>&1; then
        as_root pacman -Sy --noconfirm python python-pip
      elif command -v apk >/dev/null 2>&1; then
        as_root apk add --no-cache python3 py3-pip
      else
        echo -e "${RED}[error] Unsupported Linux package manager. Install python3, python3-venv and pip manually.${RESET}" >&2
        return 1
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install python || true
      fi
      ;;
    *)
      echo -e "${RED}[error] Unsupported operating system: $(uname -s)${RESET}" >&2
      return 1
      ;;
  esac
  if command -v python3 >/dev/null 2>&1 \
      && python3 -c 'import venv' >/dev/null 2>&1 \
      && python3 -m pip --version >/dev/null 2>&1; then
    echo -e "${GREEN}[setup] Python 3, venv and pip are ready.${RESET}"
    return 0
  fi
  echo -e "${RED}[error] Python 3 with venv and pip could not be installed automatically.${RESET}" >&2
  return 1
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if ! docker info >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
      as_root systemctl enable --now docker >/dev/null 2>&1 || true
    fi
    return 0
  fi
  echo -e "${YELLOW}[setup] Installing Docker Engine and the Compose plugin...${RESET}"
  case "$(uname -s)" in
    Linux)
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com | { if [ "$(id -u)" -eq 0 ]; then sh; else as_root sh; fi; } || return 1
      else
        echo -e "${RED}[error] curl is required to install Docker.${RESET}" >&2
        return 1
      fi
      if command -v systemctl >/dev/null 2>&1; then
        as_root systemctl enable --now docker 2>/dev/null || true
      fi
      if [ -n "${ACTUAL_USER}" ] && [ "$ACTUAL_USER" != "root" ]; then
        as_root usermod -aG docker "$ACTUAL_USER" 2>/dev/null || true
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install --cask docker || true
      fi
      ;;
    *)
      echo -e "${RED}[error] Unsupported operating system: $(uname -s)${RESET}" >&2
      return 1
      ;;
  esac
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo -e "${GREEN}[setup] Docker and Compose are ready.${RESET}"
    return 0
  fi
  echo -e "${RED}[error] Docker with the Compose plugin could not be installed automatically.${RESET}" >&2
  return 1
}

ensure_node() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    node --version >/dev/null 2>&1 || true
    npm --version >/dev/null 2>&1 || true
    return 0
  fi
  echo -e "${YELLOW}[setup] Installing Node.js and npm for the dashboard build...${RESET}"
  local node_channel="${CAIDPS_NODE_CHANNEL:-lts}"
  case "$(uname -s)" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        curl -fsSL "https://deb.nodesource.com/setup_${node_channel}.x" | { if [ "$(id -u)" -eq 0 ]; then bash -; else as_root bash -; fi; } || true
        as_root apt-get install -y nodejs
      elif command -v dnf >/dev/null 2>&1; then
        curl -fsSL "https://rpm.nodesource.com/setup_${node_channel}.x" | { if [ "$(id -u)" -eq 0 ]; then bash -; else as_root bash -; fi; } || true
        as_root dnf install -y nodejs
      elif command -v yum >/dev/null 2>&1; then
        curl -fsSL "https://rpm.nodesource.com/setup_${node_channel}.x" | { if [ "$(id -u)" -eq 0 ]; then bash -; else as_root bash -; fi; } || true
        as_root yum install -y nodejs
      elif command -v pacman >/dev/null 2>&1; then
        as_root pacman -Sy --noconfirm nodejs npm
      elif command -v apk >/dev/null 2>&1; then
        as_root apk add --no-cache nodejs npm
      else
        echo -e "${RED}[error] Unsupported Linux package manager. Install Node.js and npm manually.${RESET}" >&2
        return 1
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install node || true
      fi
      ;;
    *)
      echo -e "${RED}[error] Unsupported operating system: $(uname -s)${RESET}" >&2
      return 1
      ;;
  esac
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    echo -e "${GREEN}[setup] Node.js and npm are ready.${RESET}"
    return 0
  fi
  echo -e "${RED}[error] Node.js and npm could not be installed automatically.${RESET}" >&2
  return 1
}

ensure_backend_venv() {
  local dir="$1"
  local venv="$dir/prototype/backend/venv"
  local py="$venv/bin/python"

  if [ -x "$py" ] && "$py" -c 'import sqlalchemy, psycopg2, alembic, fastapi, pydantic' >/dev/null 2>&1; then
    # The checkout may have new pinned dependencies after an update; sync the core set.
    run_as_user "$py" -m pip install -r "$dir/prototype/backend/requirements.txt" || return 1
    return 0
  fi
  echo -e "${YELLOW}[setup] Preparing the backend Python environment...${RESET}"
  if [ ! -x "$py" ]; then
    run_as_user python3 -m venv "$venv" || return 1
  fi
  run_as_user "$py" -m pip install --upgrade pip >/dev/null 2>&1 || true
  run_as_user "$py" -m pip install -r "$dir/prototype/backend/requirements.txt" || return 1
  if [ -f "$dir/prototype/backend/requirements-ml.txt" ]; then
    if ! run_as_user "$py" -m pip install -r "$dir/prototype/backend/requirements-ml.txt"; then
      echo -e "${YELLOW}[setup] ML requirements could not be installed yet; the service will retry them on first start.${RESET}" >&2
    fi
  fi
}

ensure_gh() {
  if command -v gh >/dev/null 2>&1; then
    return 0
  fi
  echo -e "${YELLOW}[setup] GitHub CLI (gh) is not installed. Installing gh automatically...${RESET}"
  local os_type
  os_type="$(uname -s)"
  local SUDO=""
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi

  case "$os_type" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        if $SUDO apt-get update -y && $SUDO apt-get install -y gh 2>/dev/null; then
          true
        fi
        if ! command -v gh >/dev/null 2>&1; then
          $SUDO mkdir -p -m 755 /etc/apt/keyrings 2>/dev/null || true
          curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null 2>&1 || true
          $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
          echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | $SUDO tee /etc/apt/sources.list.d/github-cli.list > /dev/null 2>&1 || true
          $SUDO apt-get update -y && $SUDO apt-get install -y gh 2>/dev/null || true
        fi
      elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y gh 2>/dev/null || true
      elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y gh 2>/dev/null || true
      elif command -v pacman >/dev/null 2>&1; then
        $SUDO pacman -Sy --noconfirm github-cli 2>/dev/null || true
      elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache github-cli 2>/dev/null || $SUDO apk add --no-cache github-cli 2>/dev/null || true
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install gh 2>/dev/null || true
      fi
      ;;
  esac

  if command -v gh >/dev/null 2>&1; then
    echo -e "${GREEN}[setup] GitHub CLI (gh) installed successfully!${RESET}"
    return 0
  else
    echo -e "${YELLOW}[setup] Could not automatically install gh CLI. Continuing with alternate auth methods...${RESET}"
    return 1
  fi
}

configure_permissions() {
  local dir="$1"
  echo -e "${GREEN}[setup] Configuring directory permissions and execution bits...${RESET}"
  chmod -R u+rwX "$dir" 2>/dev/null || true
  chmod +x "${dir}/scripts/"*.sh "${dir}/scripts/caidps" 2>/dev/null || true

  # Security hardening: restrict directory to owner and group, block other local users
  chmod 750 "$dir" 2>/dev/null || true
  find "$dir" -maxdepth 4 -name ".env*" -not -name "*.example" -exec chmod 600 {} + 2>/dev/null || true

  # Ensure target non-root user owns the repository if run with sudo
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    chown -R "${ACTUAL_USER}:${ACTUAL_GROUP}" "$dir" 2>/dev/null || true
  fi

  # Git safe directory (prevents CVE-2022-24765 dubious ownership warnings across users)
  if command -v git >/dev/null 2>&1; then
    # Added once: --add appends a duplicate on every run otherwise.
    if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$dir"; then
      git config --global --add safe.directory "$dir" 2>/dev/null || true
    fi
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
      su - "${ACTUAL_USER}" -c "git config --global --get-all safe.directory 2>/dev/null | grep -qxF '${dir}' || git config --global --add safe.directory '${dir}'" 2>/dev/null || true
    fi
  fi

  # Docker permissions: add user to docker group if on Linux so docker commands never need sudo
  if [ "$(uname -s)" = "Linux" ] && command -v docker >/dev/null 2>&1; then
    if ! getent group docker >/dev/null 2>&1; then
      if [ "$(id -u)" -eq 0 ]; then
        groupadd docker 2>/dev/null || true
      elif command -v sudo >/dev/null 2>&1; then
        sudo groupadd docker 2>/dev/null || true
      fi
    fi
    if getent group docker >/dev/null 2>&1; then
      if ! id -nG "$ACTUAL_USER" 2>/dev/null | grep -qw "docker"; then
        echo -e "${YELLOW}[setup] Adding ${ACTUAL_USER} to the docker group for passwordless access...${RESET}"
        if [ "$(id -u)" -eq 0 ]; then
          usermod -aG docker "$ACTUAL_USER" 2>/dev/null || true
        elif command -v sudo >/dev/null 2>&1; then
          sudo usermod -aG docker "$ACTUAL_USER" 2>/dev/null || true
        fi
      fi
    fi
  fi

  # Link caidps CLI globally to PATH (unless the caller passed --no-link-cli)
  if [ "$LINK_CLI" -eq 1 ] && [ -f "${dir}/scripts/caidps" ]; then
    if [ -w "/usr/local/bin" ]; then
      ln -sf "${dir}/scripts/caidps" /usr/local/bin/caidps 2>/dev/null || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo ln -sf "${dir}/scripts/caidps" /usr/local/bin/caidps 2>/dev/null || true
    else
      mkdir -p "${ACTUAL_HOME}/.local/bin" 2>/dev/null || true
      ln -sf "${dir}/scripts/caidps" "${ACTUAL_HOME}/.local/bin/caidps" 2>/dev/null || true
    fi
  fi
}

# Authenticate git to GitHub for this run only: an Authorization header passed through git's
# environment (GIT_CONFIG_*), so the token is never written to .git/config and never appears in
# a process listing. git-lfs reads the same configuration.
use_token() {
  local basic
  basic="$(printf 'x-access-token:%s' "$1" | base64 | tr -d '\n')"
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
  export GIT_CONFIG_VALUE_0="Authorization: Basic ${basic}"
}

forget_token() {
  unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
}

# Step 0: Ensure git, git-lfs and Python are installed
ensure_git || exit 1
ensure_lfs || true
ensure_curl || true
ensure_python || exit 1

REPO_URL="https://github.com/Jerit3787/IDPS-WebServer.git"
REPO_BRANCH="${CAIDPS_BRANCH:-fyp2-real-detection}"
TARGET_DIR="${CAIDPS_INSTALL_DIR:-}"

# Check if we are already inside an IDPS-WebServer repository
if [ -n "$TARGET_DIR" ]; then
  echo -e "${GREEN}[info] Using installation directory from CAIDPS_INSTALL_DIR: ${TARGET_DIR}${RESET}"
elif [ -f "./scripts/serve.sh" ] && [ -d "./prototype/backend" ]; then
  echo -e "${GREEN}[info] Detected existing CAIDPS repository in current directory: $(pwd)${RESET}"
  TARGET_DIR="$(pwd)"
else
  if [ -d "$RECOMMENDED_DIR" ] && [ -f "${RECOMMENDED_DIR}/scripts/serve.sh" ]; then
    if [ "$USE_TUI" -eq 1 ]; then
      if whiptail --title "CAIDPS Installation" --backtitle "CAIDPS Installer" \
        --yesno "Found existing CAIDPS installation at:\n${RECOMMENDED_DIR}\n\nUpdate and use this existing installation?" 12 70 \
        3>&1 1>&2 2>&3 < /dev/tty; then
        TARGET_DIR="$RECOMMENDED_DIR"
      else
        TARGET_DIR=$(whiptail --title "CAIDPS Installation" --backtitle "CAIDPS Installer" \
          --inputbox "Enter destination path for CAIDPS:" 10 70 "$RECOMMENDED_DIR" \
          3>&1 1>&2 2>&3 < /dev/tty) || { echo "Cancelled."; exit 1; }
      fi
    else
      echo ""
      echo -e "Found existing installation at: ${BOLD}${RECOMMENDED_DIR}${RESET}"
      read_tty "Update and use this installation? [Y/n]: " use_existing
      case "${use_existing:-y}" in
        [yY]|[yY][eE][sS]|"")
          TARGET_DIR="$RECOMMENDED_DIR"
          ;;
        *)
          read_tty "Enter destination path for CAIDPS: " custom_dir
          TARGET_DIR="${custom_dir:-$RECOMMENDED_DIR}"
          ;;
      esac
    fi
  else
    if [ "$USE_TUI" -eq 1 ]; then
      TARGET_DIR=$(whiptail --title "CAIDPS Installation" --backtitle "CAIDPS Installer" \
        --inputbox "Choose installation location for CAIDPS:\n(Linux system standard: /opt/caidps)" 12 70 "$RECOMMENDED_DIR" \
        3>&1 1>&2 2>&3 < /dev/tty) || { echo "Cancelled."; exit 1; }
    else
      echo ""
      echo -e "${BOLD}Step 0: Installation Location${RESET}"
      echo "------------------------------------------------"
      echo -e "Recommended location : ${BOLD}${CYAN}${RECOMMENDED_DIR}${RESET}"
      read_tty "Installation path [default: ${RECOMMENDED_DIR}]: " input_dir
      TARGET_DIR="${input_dir:-$RECOMMENDED_DIR}"
    fi
  fi
fi

# Refuse to clone into an existing non-empty directory that is not a CAIDPS checkout.
if [ -d "$TARGET_DIR" ] && [ ! -f "$TARGET_DIR/scripts/serve.sh" ] && [ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]; then
  echo -e "${RED}[error] ${TARGET_DIR} exists and is not an empty directory or a CAIDPS checkout.${RESET}" >&2
  echo "Choose another path, empty it, or remove it before re-running." >&2
  exit 1
fi

# Ensure target installation directory exists and is writable by ACTUAL_USER
parent_dir="$(dirname "$TARGET_DIR")"
if [ ! -d "$parent_dir" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    mkdir -p "$parent_dir"
  elif command -v sudo >/dev/null 2>&1; then
    sudo mkdir -p "$parent_dir"
  else
    mkdir -p "$parent_dir" 2>/dev/null || true
  fi
fi

if [ ! -d "$TARGET_DIR" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    mkdir -p "$TARGET_DIR"
  elif [ ! -w "$parent_dir" ]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo mkdir -p "$TARGET_DIR"
      sudo chown -R "${ACTUAL_USER}:${ACTUAL_GROUP}" "$TARGET_DIR" 2>/dev/null || true
    fi
  else
    mkdir -p "$TARGET_DIR" 2>/dev/null || true
  fi
fi

if [ -d "$TARGET_DIR" ] && [ ! -w "$TARGET_DIR" ]; then
  if command -v sudo >/dev/null 2>&1; then
    sudo chown -R "${ACTUAL_USER}:${ACTUAL_GROUP}" "$TARGET_DIR" 2>/dev/null || true
  fi
fi

# Clone or pull repository
if [ -z "$TARGET_DIR" ]; then
  echo -e "${RED}[error] No installation path given.${RESET}" >&2
  exit 1
fi

if [ -d "$TARGET_DIR" ] && [ -f "${TARGET_DIR}/scripts/serve.sh" ]; then
  echo -e "${GREEN}[git] Updating existing repository in ${TARGET_DIR}...${RESET}"
  cd "$TARGET_DIR" || exit 1
  if [ -d ".git" ]; then
    if [ -n "${GITHUB_TOKEN:-}" ] || [ -n "${GH_TOKEN:-}" ]; then
      use_token "${GITHUB_TOKEN:-${GH_TOKEN}}"
    fi
    git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" 2>/dev/null || true
    if GIT_TERMINAL_PROMPT=0 git fetch origin "$REPO_BRANCH" \
        && git checkout "$REPO_BRANCH" \
        && git merge --ff-only "origin/${REPO_BRANCH}"; then
      echo -e "${GREEN}[git] Up to date with origin/${REPO_BRANCH}.${RESET}"
    else
      echo -e "${YELLOW}[git] Could not update ${TARGET_DIR} automatically (offline, no access, or local changes)." \
              "Continuing with the code already there; update it later with: caidps update${RESET}" >&2
      if [ "$NON_INTERACTIVE" -eq 1 ]; then
        echo -e "${RED}[error] Unattended update failed; refusing to configure stale or wrong-branch code.${RESET}" >&2
        exit 1
      fi
    fi
    # Submodules are initialized on-demand by scripts/serve.sh
  fi
else
  echo ""
  echo -e "${GREEN}[git] Cloning IDPS-WebServer (${REPO_BRANCH}) into ${TARGET_DIR}...${RESET}"
  
  CLONE_SUCCESS=0

  # Check 1: GITHUB_TOKEN or GH_TOKEN from environment
  if [ -n "${GITHUB_TOKEN:-}" ] || [ -n "${GH_TOKEN:-}" ]; then
    echo -e "${GREEN}[auth] Detected GITHUB_TOKEN in environment, cloning...${RESET}"
    use_token "${GITHUB_TOKEN:-${GH_TOKEN}}"
    if GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$TARGET_DIR" 2>/dev/null; then
      CLONE_SUCCESS=1
    else
      forget_token
    fi
  fi

  # Check 2: Existing gh CLI authentication
  if [ "$CLONE_SUCCESS" -eq 0 ] && command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      echo -e "${GREEN}[auth] Authenticated GitHub CLI detected. Cloning Jerit3787/IDPS-WebServer...${RESET}"
      if [ "$HAS_TTY" -eq 1 ]; then
        if gh repo clone Jerit3787/IDPS-WebServer "$TARGET_DIR" -- --depth 1 -b "$REPO_BRANCH" < /dev/tty; then
          CLONE_SUCCESS=1
        fi
      else
        if gh repo clone Jerit3787/IDPS-WebServer "$TARGET_DIR" -- --depth 1 -b "$REPO_BRANCH"; then
          CLONE_SUCCESS=1
        fi
      fi
    fi
  fi

  # Check 3: Public non-interactive clone (GIT_TERMINAL_PROMPT=0 prevents any blocking username prompt)
  if [ "$CLONE_SUCCESS" -eq 0 ]; then
    if GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$TARGET_DIR" 2>/dev/null; then
      CLONE_SUCCESS=1
    fi
  fi

  # Check 4: Private repository authentication wizard
  if [ "$CLONE_SUCCESS" -eq 0 ]; then
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
      echo -e "${RED}[error] The repository is private and no non-interactive GitHub credentials worked.${RESET}" >&2
      echo "Set GITHUB_TOKEN or GH_TOKEN (on the bash side of the pipe), or authenticate gh first." >&2
      exit 1
    fi
    auth_choice=""
    if [ "$USE_TUI" -eq 1 ]; then
      auth_choice=$(whiptail --title "GitHub Authentication" --backtitle "CAIDPS Installer" \
        --menu "Repository Jerit3787/IDPS-WebServer requires GitHub authentication.\nChoose authentication method:" 16 78 3 \
        "1" "GitHub CLI (Recommended — browser login code or token)" \
        "2" "Personal Access Token (PAT) — paste token directly" \
        "3" "SSH Key — git@github.com:Jerit3787/IDPS-WebServer.git" \
        3>&1 1>&2 2>&3 < /dev/tty || echo "1")
    else
      echo ""
      echo -e "${YELLOW}[auth] Repository Jerit3787/IDPS-WebServer requires GitHub authentication.${RESET}"
      echo "How would you like to authenticate?"
      echo -e "  ${BOLD}1)${RESET} GitHub CLI (${BOLD}gh auth login${RESET}) ${GREEN}(Recommended)${RESET} — Web browser code or token"
      echo -e "  ${BOLD}2)${RESET} Personal Access Token (PAT) — Paste token directly"
      echo -e "  ${BOLD}3)${RESET} SSH Key — git@github.com:Jerit3787/IDPS-WebServer.git"
      echo ""
      read_tty "Choose authentication method [1-3, default: 1]: " auth_choice
    fi
    case "${auth_choice:-1}" in
      1|gh)
        ensure_gh || true
        if command -v gh >/dev/null 2>&1; then
          if ! gh auth status >/dev/null 2>&1; then
            if [ "$USE_TUI" -eq 1 ]; then
              whiptail --title "GitHub Login" --backtitle "CAIDPS Installer" \
                --msgbox "GitHub CLI will now open in the terminal.\n\nFollow the instructions to authorize your GitHub account in your browser.\nPress OK to begin." 12 70 < /dev/tty
              clear
            fi
            echo ""
            echo -e "${CYAN}[auth] Launching GitHub CLI login wizard...${RESET}"
            if [ "$HAS_TTY" -eq 1 ]; then
              gh auth login < /dev/tty > /dev/tty 2>&1 || true
            else
              gh auth login || true
            fi
          fi
          gh auth setup-git 2>/dev/null || true
          echo -e "${GREEN}[git] Cloning repository with GitHub CLI...${RESET}"
          if [ "$HAS_TTY" -eq 1 ]; then
            if gh repo clone Jerit3787/IDPS-WebServer "$TARGET_DIR" -- --depth 1 -b "$REPO_BRANCH" < /dev/tty; then
              CLONE_SUCCESS=1
            fi
          else
            if gh repo clone Jerit3787/IDPS-WebServer "$TARGET_DIR" -- --depth 1 -b "$REPO_BRANCH"; then
              CLONE_SUCCESS=1
            fi
          fi
        else
          echo -e "${RED}[error] gh CLI could not be installed. Please choose Option 2 (PAT) or Option 3 (SSH).${RESET}" >&2
        fi
        ;;
      2|token|pat)
        echo ""
        if [ "$USE_TUI" -eq 1 ]; then
          pat_token=$(whiptail --title "GitHub Personal Access Token" --backtitle "CAIDPS Installer" \
            --passwordbox "Enter your GitHub Personal Access Token (PAT):" 10 70 \
            3>&1 1>&2 2>&3 < /dev/tty || echo "")
        else
          read_tty "Enter your GitHub Personal Access Token (PAT): " pat_token 1
        fi
        if [ -n "$pat_token" ]; then
          echo -e "${GREEN}[git] Cloning repository using token...${RESET}"
          use_token "$pat_token"
          if GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$TARGET_DIR"; then
            CLONE_SUCCESS=1
          else
            forget_token
          fi
        fi
        ;;
      3|ssh)
        echo -e "${GREEN}[git] Cloning repository using SSH...${RESET}"
        if git clone --depth 1 -b "$REPO_BRANCH" "git@github.com:Jerit3787/IDPS-WebServer.git" "$TARGET_DIR"; then
          CLONE_SUCCESS=1
        fi
        ;;
      *)
        echo -e "${RED}[error] Invalid choice.${RESET}" >&2
        ;;
    esac
  fi

  if [ "$CLONE_SUCCESS" -ne 1 ]; then
    echo -e "${RED}[error] Failed to clone Jerit3787/IDPS-WebServer.${RESET}" >&2
    echo "Please ensure you have access to the repository or clone manually." >&2
    exit 1
  fi

  cd "$TARGET_DIR" || exit 1
fi

# Ensure shallow clones can discover and switch between all remote branches on origin
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" 2>/dev/null || true

# Ensure git credentials are configured for LFS and submodules if gh is authenticated
if [ "$DRY_RUN" -eq 0 ] && command -v gh >/dev/null 2>&1; then
  gh auth setup-git 2>/dev/null || true
fi

# Ensure git-lfs model weights are pulled
if [ "$DRY_RUN" -eq 1 ]; then
  echo -e "${YELLOW}[lfs] --dry-run: skipping the model-weight download.${RESET}"
elif command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
  echo -e "${GREEN}[lfs] Checking Git LFS model weights...${RESET}"
  git lfs install --local 2>/dev/null || true
  if ! GIT_TERMINAL_PROMPT=0 git lfs pull; then
    echo -e "${YELLOW}[lfs] Could not download the model weights (Git LFS). The DistilBERT tier stays off" \
            "until you run: cd ${TARGET_DIR} && git lfs pull${RESET}" >&2
  fi
else
  echo -e "${YELLOW}[lfs] git-lfs is not installed: the DistilBERT model weights were not downloaded.${RESET}" >&2
fi
forget_token

# Configure all permissions across the repository and docker group
if [ "$DRY_RUN" -eq 0 ]; then
  configure_permissions "$TARGET_DIR"
fi

# Explicit non-interactive systemd needs the host prerequisites the app's non-interactive
# setup path skips: Docker for the target, Node/npm for the dashboard, and the backend venv.
if [ "$NON_INTERACTIVE" -eq 1 ] && [ "$SYSTEMD_MODE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  ensure_docker || exit 1
  ensure_node || exit 1
  ensure_backend_venv "$TARGET_DIR" || exit 1
  configure_permissions "$TARGET_DIR"
fi

echo -e "${GREEN}[setup] Repository ready at ${TARGET_DIR}.${RESET}"
if [ "$NON_INTERACTIVE" -eq 1 ]; then
  echo -e "${GREEN}[setup] Starting unattended setup...${RESET}"
else
  echo -e "${GREEN}[setup] Starting interactive setup wizard...${RESET}"
fi
echo ""

# Launch the app wizard inside the repository.
if [ ! -f "./scripts/setup.sh" ]; then
  echo -e "${RED}[error] ./scripts/setup.sh not found in $(pwd)${RESET}" >&2
  exit 1
fi

if [ "$HAS_TTY" -eq 1 ] && [ -t 1 ] && [ "$NON_INTERACTIVE" -eq 0 ]; then
  ./scripts/setup.sh "${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}" < /dev/tty
else
  ./scripts/setup.sh "${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}"
fi
rc=$?
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

# The app's non-interactive systemd path only configures the server; install and start it.
if [ "$NON_INTERACTIVE" -eq 1 ] && [ "$SYSTEMD_MODE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  echo -e "${GREEN}[setup] Installing and starting the CAIDPS systemd service...${RESET}"
  ./scripts/service.sh install
  rc=$?
  if [ "$rc" -ne 0 ]; then
    exit "$rc"
  fi
fi

# service.sh install links the CLI unconditionally; honor --no-link-cli after it runs.
remove_target_cli_links() {
  local link target
  for link in /usr/local/bin/caidps "${ACTUAL_HOME}/.local/bin/caidps"; do
    [ -L "$link" ] || continue
    target="$(readlink -f "$link" 2>/dev/null || readlink "$link" 2>/dev/null || true)"
    [ "$target" = "$TARGET_DIR/scripts/caidps" ] || continue
    if [ -w "$(dirname "$link")" ]; then
      rm -f "$link" 2>/dev/null || true
    else
      as_root rm -f "$link" 2>/dev/null || true
    fi
  done
}

if [ "$LINK_CLI" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  remove_target_cli_links
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo -e "${GREEN}[setup] Dry run complete; nothing was started.${RESET}"
else
  echo -e "${GREEN}[setup] CAIDPS installation complete.${RESET}"
fi
exit 0
}

main "$@"
