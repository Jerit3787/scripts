#!/usr/bin/env bash
# CAIDPS Installer & Interactive Setup Wizard
# Automated repository clone, environment bootstrap, and guided stack launcher.
#
# Usage:
#   curl -fsSL https://scripts.danplace.tech/idps.sh | bash
#   curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash
#   /bin/bash -c "$(curl -fsSL https://scripts.danplace.tech/idps.sh)"
#
set -u

# ANSI color codes
if [ -t 1 ]; then
  BOLD="\033[1m"
  DIM="\033[2m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  BLUE="\033[34m"
  MAGENTA="\033[35m"
  CYAN="\033[36m"
  RED="\033[31m"
  RESET="\033[0m"
else
  BOLD=""
  DIM=""
  GREEN=""
  YELLOW=""
  BLUE=""
  MAGENTA=""
  CYAN=""
  RED=""
  RESET=""
fi

# Resolve effective non-root user and home directory
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  ACTUAL_USER="${SUDO_USER}"
  ACTUAL_HOME="$(eval echo ~${SUDO_USER})"
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

# TTY-safe input reader that works even when the script is piped from curl
read_tty() {
  local prompt_str="$1"
  local var_name="$2"
  local is_secret="${3:-0}"
  local input_val=""

  if [ -c /dev/tty ] && [ -z "${CAIDPS_NON_INTERACTIVE:-}" ] && [ -z "${CI:-}" ]; then
    if [ "$is_secret" -eq 1 ]; then
      read -r -s -p "$prompt_str" input_val < /dev/tty
      echo "" > /dev/tty 2>/dev/null || echo ""
    else
      read -r -p "$prompt_str" input_val < /dev/tty
    fi
  else
    if [ "$is_secret" -eq 1 ]; then
      read -r -s -p "$prompt_str" input_val 2>/dev/null || true
      echo ""
    else
      read -r -p "$prompt_str" input_val 2>/dev/null || true
    fi
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

ensure_git() {
  if command -v git >/dev/null 2>&1; then
    return 0
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

  # Ensure target non-root user owns the repository if run with sudo
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    chown -R "${ACTUAL_USER}:${ACTUAL_GROUP}" "$dir" 2>/dev/null || true
  fi

  # Git safe directory (prevents CVE-2022-24765 dubious ownership warnings across users)
  if command -v git >/dev/null 2>&1; then
    git config --global --add safe.directory "$dir" 2>/dev/null || true
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
      su - "${ACTUAL_USER}" -c "git config --global --add safe.directory '${dir}'" 2>/dev/null || true
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

  # Link caidps CLI globally to PATH
  if [ -f "${dir}/scripts/caidps" ]; then
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

# Step 0: Ensure git and git-lfs are installed
ensure_git || exit 1
ensure_lfs || true

REPO_URL="https://github.com/Jerit3787/IDPS-WebServer.git"
REPO_BRANCH="fyp2-real-detection"
TARGET_DIR=""

# Check if we are already inside an IDPS-WebServer repository
if [ -f "./scripts/serve.sh" ] && [ -d "./prototype/backend" ]; then
  echo -e "${GREEN}[info] Detected existing CAIDPS repository in current directory: $(pwd)${RESET}"
  TARGET_DIR="$(pwd)"
else
  if [ -d "$RECOMMENDED_DIR" ] && [ -f "${RECOMMENDED_DIR}/scripts/serve.sh" ]; then
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
  else
    echo ""
    echo -e "${BOLD}Step 0: Installation Location${RESET}"
    echo "------------------------------------------------"
    echo -e "Recommended location : ${BOLD}${CYAN}${RECOMMENDED_DIR}${RESET}"
    read_tty "Installation path [default: ${RECOMMENDED_DIR}]: " input_dir
    TARGET_DIR="${input_dir:-$RECOMMENDED_DIR}"
  fi
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
if [ -d "$TARGET_DIR" ] && [ -f "${TARGET_DIR}/scripts/serve.sh" ]; then
  echo -e "${GREEN}[git] Updating existing repository in ${TARGET_DIR}...${RESET}"
  cd "$TARGET_DIR" || exit 1
  if [ -d ".git" ]; then
    git fetch origin "$REPO_BRANCH" 2>/dev/null || true
    git checkout "$REPO_BRANCH" 2>/dev/null || true
    git pull origin "$REPO_BRANCH" 2>/dev/null || true
    git submodule update --init --recursive 2>/dev/null || true
  fi
else
  echo ""
  echo -e "${GREEN}[git] Cloning IDPS-WebServer (${REPO_BRANCH}) into ${TARGET_DIR}...${RESET}"
  
  CLONE_SUCCESS=0

  # Check 1: GITHUB_TOKEN or GH_TOKEN from environment
  if [ -n "${GITHUB_TOKEN:-}" ] || [ -n "${GH_TOKEN:-}" ]; then
    auth_env_token="${GITHUB_TOKEN:-${GH_TOKEN}}"
    echo -e "${GREEN}[auth] Detected GITHUB_TOKEN in environment, cloning...${RESET}"
    if git clone --depth 1 -b "$REPO_BRANCH" "https://${auth_env_token}@github.com/Jerit3787/IDPS-WebServer.git" "$TARGET_DIR" 2>/dev/null; then
      CLONE_SUCCESS=1
    fi
  fi

  # Check 2: Existing gh CLI authentication
  if [ "$CLONE_SUCCESS" -eq 0 ] && command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      echo -e "${GREEN}[auth] Authenticated GitHub CLI detected. Cloning Jerit3787/IDPS-WebServer...${RESET}"
      if [ -c /dev/tty ]; then
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
    echo ""
    echo -e "${YELLOW}[auth] Repository Jerit3787/IDPS-WebServer requires GitHub authentication.${RESET}"
    echo "How would you like to authenticate?"
    echo -e "  ${BOLD}1)${RESET} GitHub CLI (${BOLD}gh auth login${RESET}) ${GREEN}(Recommended)${RESET} — Web browser code or token"
    echo -e "  ${BOLD}2)${RESET} Personal Access Token (PAT) — Paste token directly"
    echo -e "  ${BOLD}3)${RESET} SSH Key — git@github.com:Jerit3787/IDPS-WebServer.git"
    echo ""
    read_tty "Choose authentication method [1-3, default: 1]: " auth_choice
    case "${auth_choice:-1}" in
      1|gh)
        ensure_gh || true
        if command -v gh >/dev/null 2>&1; then
          if ! gh auth status >/dev/null 2>&1; then
            echo ""
            echo -e "${CYAN}[auth] Launching GitHub CLI login wizard...${RESET}"
            if [ -c /dev/tty ]; then
              gh auth login < /dev/tty > /dev/tty 2>&1 || true
            else
              gh auth login || true
            fi
          fi
          echo -e "${GREEN}[git] Cloning repository with GitHub CLI...${RESET}"
          if [ -c /dev/tty ]; then
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
        read_tty "Enter your GitHub Personal Access Token (PAT): " pat_token 1
        if [ -n "$pat_token" ]; then
          echo -e "${GREEN}[git] Cloning repository using token...${RESET}"
          if git clone --depth 1 -b "$REPO_BRANCH" "https://${pat_token}@github.com/Jerit3787/IDPS-WebServer.git" "$TARGET_DIR"; then
            CLONE_SUCCESS=1
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
  git submodule update --init --recursive 2>/dev/null || true
fi

# Ensure git-lfs model weights are pulled
if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
  echo -e "${GREEN}[lfs] Checking Git LFS model weights...${RESET}"
  git lfs pull 2>/dev/null || true
fi

# Configure all permissions across the repository and docker group
configure_permissions "$TARGET_DIR"

echo -e "${GREEN}[setup] Repository ready at ${TARGET_DIR}.${RESET}"
echo -e "${GREEN}[setup] Starting interactive setup wizard...${RESET}"
echo ""

# Launch the interactive wizard inside the repository
if [ -f "./scripts/setup.sh" ]; then
  if [ -c /dev/tty ] && [ -t 1 ]; then
    exec ./scripts/setup.sh "$@" < /dev/tty
  else
    exec ./scripts/setup.sh "$@"
  fi
else
  echo -e "${RED}[error] ./scripts/setup.sh not found in $(pwd)${RESET}" >&2
  exit 1
fi
