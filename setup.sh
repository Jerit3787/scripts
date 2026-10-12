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
  echo -e "${DIM}Automated Downloader & Interactive Setup Wizard${RESET}"
  echo "─────────────────────────────────────────────────────────────────"
}

print_banner

# Step 0: Pre-flight checks
if ! command -v git >/dev/null 2>&1; then
  echo -e "${RED}[error] git is required but not installed.${RESET}" >&2
  echo "Please install git first:" >&2
  echo "  • macOS:        xcode-select --install  OR  brew install git" >&2
  echo "  • Ubuntu/Debian: sudo apt-get install -y git" >&2
  echo "  • Fedora/RHEL:   sudo dnf install -y git" >&2
  exit 1
fi

REPO_URL="https://github.com/Jerit3787/IDPS-WebServer.git"
REPO_BRANCH="fyp2-real-detection"
TARGET_DIR=""

# Check if we are already inside an IDPS-WebServer repository
if [ -f "./scripts/serve.sh" ] && [ -d "./prototype/backend" ]; then
  echo -e "${GREEN}[info] Detected existing CAIDPS repository in current directory: $(pwd)${RESET}"
  TARGET_DIR="$(pwd)"
else
  DEFAULT_DIR="./IDPS-WebServer"
  if [ -d "$DEFAULT_DIR" ] && [ -f "${DEFAULT_DIR}/scripts/serve.sh" ]; then
    echo ""
    echo -e "Found existing directory: ${BOLD}${DEFAULT_DIR}${RESET}"
    read_tty "Use and update this directory? [Y/n]: " use_existing
    case "${use_existing:-y}" in
      [yY]|[yY][eE][sS]|"")
        TARGET_DIR="$DEFAULT_DIR"
        ;;
      *)
        read_tty "Enter destination path for CAIDPS: " custom_dir
        TARGET_DIR="${custom_dir:-$DEFAULT_DIR}"
        ;;
    esac
  else
    echo ""
    echo -e "${BOLD}Step 0: Workspace Directory${RESET}"
    echo "------------------------------------------------"
    read_tty "Installation directory [default: ${DEFAULT_DIR}]: " input_dir
    TARGET_DIR="${input_dir:-$DEFAULT_DIR}"
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

  # Attempt 1: Standard git clone
  if git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$TARGET_DIR" 2>/dev/null; then
    CLONE_SUCCESS=1
  fi

  # Attempt 2: If standard clone failed, check if gh CLI is available
  if [ "$CLONE_SUCCESS" -eq 0 ] && command -v gh >/dev/null 2>&1; then
    echo -e "${YELLOW}[git] Public clone failed, attempting clone via GitHub CLI (gh)...${RESET}"
    if gh repo clone Jerit3787/IDPS-WebServer "$TARGET_DIR" -- --depth 1 -b "$REPO_BRANCH" 2>/dev/null; then
      CLONE_SUCCESS=1
    fi
  fi

  # Attempt 3: If still failing, prompt user for auth method (handles private repo)
  if [ "$CLONE_SUCCESS" -eq 0 ]; then
    echo -e "${YELLOW}[auth] Repository requires GitHub authentication.${RESET}"
    echo "  1) GitHub Personal Access Token (PAT)"
    echo "  2) SSH (git@github.com:Jerit3787/IDPS-WebServer.git)"
    echo "  3) GitHub CLI (gh auth login)"
    read_tty "Choose authentication method [1-3, default: 1]: " auth_choice
    case "${auth_choice:-1}" in
      2|ssh)
        git clone --depth 1 -b "$REPO_BRANCH" "git@github.com:Jerit3787/IDPS-WebServer.git" "$TARGET_DIR" && CLONE_SUCCESS=1
        ;;
      3|gh)
        if ! command -v gh >/dev/null 2>&1; then
          echo "[error] gh CLI is not installed." >&2
        else
          gh auth login
          gh repo clone Jerit3787/IDPS-WebServer "$TARGET_DIR" -- --depth 1 -b "$REPO_BRANCH" && CLONE_SUCCESS=1
        fi
        ;;
      *)
        read_tty "Enter GitHub Token: " pat_token 1
        if [ -n "$pat_token" ]; then
          git clone --depth 1 -b "$REPO_BRANCH" "https://${pat_token}@github.com/Jerit3787/IDPS-WebServer.git" "$TARGET_DIR" && CLONE_SUCCESS=1
        fi
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

# Ensure git-lfs is pulled if git-lfs is present
if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
  echo -e "${GREEN}[lfs] Checking Git LFS model weights...${RESET}"
  git lfs pull 2>/dev/null || true
fi

echo -e "${GREEN}[setup] Repository ready. Starting interactive setup wizard...${RESET}"
echo ""

# Launch the interactive wizard inside the repository
if [ -f "./scripts/setup.sh" ]; then
  chmod +x ./scripts/setup.sh ./scripts/serve.sh ./scripts/caidps ./scripts/tunnel.sh 2>/dev/null || true
  if [ -c /dev/tty ] && [ -t 1 ]; then
    exec ./scripts/setup.sh "$@" < /dev/tty
  else
    exec ./scripts/setup.sh "$@"
  fi
else
  echo -e "${RED}[error] ./scripts/setup.sh not found in $(pwd)${RESET}" >&2
  exit 1
fi
