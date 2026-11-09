#!/usr/bin/env bash
# AI Discord Bot installer.
#
#   curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | bash
#   curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | bash -s -- --non-interactive
#
# By default the wrapper clones or fast-forwards Jerit3787/ai-discord-bot.
# With --image-only it pulls the published image and extracts /app/host-bundle
# instead. Either way it writes the container settings into .env without
# discarding existing values, logs in to GHCR, and starts the bot, dashboard
# and Watchtower with Docker Compose.
#
# Environment (all optional except on a fresh unattended install):
#   GITHUB_TOKEN / GH_TOKEN       private repository token, this run only
#   GHCR_TOKEN                   PAT with read:packages for the private image
#   GHCR_USER                    your GitHub username (owner of GHCR_TOKEN)
#   AI_DISCORD_BOT_INSTALL_DIR   install path (default /opt/ai-discord-bot)
#   AI_DISCORD_BOT_BRANCH        branch (default main)
#   AI_DISCORD_BOT_NON_INTERACTIVE=1   no prompts; CI=1 does the same
#   AI_DISCORD_BOT_IMAGE_ONLY=1      pull the image; never clone the repository
#   TOKEN_MODE=bot|user          Discord token type (default bot)
#   DISCORD_TOKEN                bot token, or user token in user mode
#   OPENAI_API_KEY               OpenAI-compatible API key
#   OPENAI_BASE_URL              endpoint (default https://api.openai.com/v1)
#   AI_MODEL                     model name (default gpt-4o-mini)
#   OWNER_ID                     optional numeric Discord user id
#   GIPHY_API_KEY                optional GIF search key
#   DASHBOARD_HOST_IP            host interface to publish on (default: Tailscale or 127.0.0.1)
#   DASHBOARD_PORT               host port (default 8787)
#   DASHBOARD_USER               dashboard login user (default admin)
#   DASHBOARD_PASSWORD           reset the dashboard password to this value
#   DOCKER_GID                   socket group id (detected)
#   DOCKER_CONFIG_FILE           host Docker config (default ~/.docker/config.json)
#   GHCR_OWNER                   image owner (default jerit3787)
#   CONTAINER_TAG                bot, user, latest or a pinned <mode>-<sha>
#   TZ                           container timezone (default Asia/Kuala_Lumpur)
#
# The script never writes a token into .git/config and never stores the
# dashboard password in plaintext. Existing .env and data/ survive updates.
set -u

usage() {
  cat <<'EOF'
Usage:
  curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | bash
  curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | bash -s -- [options]

Options:
  --non-interactive          Take defaults; required values come from the environment.
  --dir PATH                 Install path (default /opt/ai-discord-bot on Linux).
  --branch NAME              Git branch (default main).
  --token-mode bot|user      Discord token type (default bot).
  --dashboard-ip IP          Host interface to publish the dashboard on.
  --dashboard-port PORT      Host port (default 8787).
  --dashboard-password VALUE Reset the dashboard password.
  --no-watchtower            Start only the bot and dashboard.
  --no-cli                   Do not link the discord-bot command.
  --no-start                 Configure .env and data, but do not start. Image-only still pulls once to extract.
  --no-git-update            Use an existing checkout without git fetch/pull.
  --image-only               Pull the image and extract its host bundle; never clone the repo.
  --dry-run                  Resolve and print the plan; write and start nothing.
  --help, -h                 Show this help.

Environment:
  GITHUB_TOKEN / GH_TOKEN    Token for the private clone/update (this run only).
  GHCR_TOKEN                 PAT with read:packages for the private image.
  GHCR_USER                  Your GitHub username (the account that owns GHCR_TOKEN).
  AI_DISCORD_BOT_INSTALL_DIR Install path.
  AI_DISCORD_BOT_BRANCH      Branch.
  AI_DISCORD_BOT_NON_INTERACTIVE=1  Same as --non-interactive.
  AI_DISCORD_BOT_NO_GIT_UPDATE=1    Same as --no-git-update.
  AI_DISCORD_BOT_IMAGE_ONLY=1       Same as --image-only.
  CI=1                       Same as --non-interactive.
  TOKEN_MODE, DISCORD_TOKEN, OPENAI_API_KEY, OPENAI_BASE_URL, AI_MODEL
  OWNER_ID, GIPHY_API_KEY, TZ
  DASHBOARD_HOST_IP, DASHBOARD_PORT, DASHBOARD_USER, DASHBOARD_PASSWORD
  DOCKER_GID, DOCKER_CONFIG_FILE, GHCR_OWNER, CONTAINER_TAG

A fresh unattended install needs DISCORD_TOKEN, OPENAI_API_KEY and a GitHub
token (or an authenticated gh CLI) for the full checkout. The image-only path
needs only Docker and a PAT with read:packages; it never clones the repository.
GITHUB_TOKEN is reused when GHCR_TOKEN is unset. Put tokens on the bash side of
the pipe, never on the curl side.
EOF
}

main() {
  if [ -t 1 ]; then
    BOLD="$(printf '\033[1m')"
    DIM="$(printf '\033[2m')"
    GREEN="$(printf '\033[32m')"
    YELLOW="$(printf '\033[33m')"
    RED="$(printf '\033[31m')"
    RESET="$(printf '\033[0m')"
  else
    BOLD="" DIM="" GREEN="" YELLOW="" RED="" RESET=""
  fi

  info() { printf '%s[setup]%s %s\n' "$GREEN" "$RESET" "$*"; }
  warn() { printf '%s[warn]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
  die() { printf '%s[error]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

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

  NON_INTERACTIVE=0
  DRY_RUN=0
  NO_WATCHTOWER=0
  NO_CLI=0
  NO_START=0
  NO_GIT_UPDATE=0
  IMAGE_ONLY=0
  IMAGE_PREPARED=0
  DOCKER_READY=0
  TAG_SUPPLIED=0
  [ -n "${CONTAINER_TAG:-}" ] && TAG_SUPPLIED=1
  INSTALL_DIR_ARG=""
  BRANCH_ARG=""
  TOKEN_MODE_ARG=""
  DASHBOARD_IP_ARG=""
  DASHBOARD_PORT_ARG=""
  DASHBOARD_PASSWORD_ARG=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --non-interactive) NON_INTERACTIVE=1 ;;
      --dir) [ "$#" -ge 2 ] || die "--dir needs a path"; INSTALL_DIR_ARG="$2"; shift ;;
      --dir=*) INSTALL_DIR_ARG="${1#*=}" ;;
      --branch) [ "$#" -ge 2 ] || die "--branch needs a name"; BRANCH_ARG="$2"; shift ;;
      --branch=*) BRANCH_ARG="${1#*=}" ;;
      --token-mode) [ "$#" -ge 2 ] || die "--token-mode needs bot or user"; TOKEN_MODE_ARG="$2"; shift ;;
      --token-mode=*) TOKEN_MODE_ARG="${1#*=}" ;;
      --dashboard-ip) [ "$#" -ge 2 ] || die "--dashboard-ip needs an address"; DASHBOARD_IP_ARG="$2"; shift ;;
      --dashboard-ip=*) DASHBOARD_IP_ARG="${1#*=}" ;;
      --dashboard-port) [ "$#" -ge 2 ] || die "--dashboard-port needs a number"; DASHBOARD_PORT_ARG="$2"; shift ;;
      --dashboard-port=*) DASHBOARD_PORT_ARG="${1#*=}" ;;
      --dashboard-password) [ "$#" -ge 2 ] || die "--dashboard-password needs a value"; DASHBOARD_PASSWORD_ARG="$2"; shift ;;
      --dashboard-password=*) DASHBOARD_PASSWORD_ARG="${1#*=}" ;;
      --no-watchtower) NO_WATCHTOWER=1 ;;
      --no-cli) NO_CLI=1 ;;
      --no-start) NO_START=1 ;;
      --no-git-update) NO_GIT_UPDATE=1 ;;
      --image-only) IMAGE_ONLY=1 ;;
      --dry-run) DRY_RUN=1; NON_INTERACTIVE=1 ;;
      *) die "Unknown option: $1 (use --help)" ;;
    esac
    shift
  done

  case "${AI_DISCORD_BOT_NON_INTERACTIVE:-}" in
    ""|0|false|FALSE|no|NO) ;;
    *) NON_INTERACTIVE=1 ;;
  esac
  case "${CI:-}" in
    ""|0|false|FALSE|no|NO) ;;
    *) NON_INTERACTIVE=1 ;;
  esac
  case "${AI_DISCORD_BOT_NO_GIT_UPDATE:-}" in
    ""|0|false|FALSE|no|NO) ;;
    *) NO_GIT_UPDATE=1 ;;
  esac
  case "${AI_DISCORD_BOT_IMAGE_ONLY:-}" in
    ""|0|false|FALSE|no|NO) ;;
    *) IMAGE_ONLY=1 ;;
  esac
  [ "$DRY_RUN" -eq 1 ] && NON_INTERACTIVE=1

  HAS_TTY=0
  if { true < /dev/tty; } 2>/dev/null; then
    HAS_TTY=1
  fi
  if [ "$HAS_TTY" -eq 0 ]; then
    NON_INTERACTIVE=1
  fi

  # Resolve the real owner even when the one-liner is piped through sudo.
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    ACTUAL_USER="${SUDO_USER}"
    ACTUAL_HOME="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6)"
    [ -n "$ACTUAL_HOME" ] || ACTUAL_HOME="$(eval echo "~${SUDO_USER}")"
  else
    ACTUAL_USER="$(id -un)"
    ACTUAL_HOME="${HOME}"
  fi
  ACTUAL_GROUP="$(id -gn "$ACTUAL_USER" 2>/dev/null || id -gn)"

  if [ "$(uname -s)" = "Linux" ] || [ "$(id -u)" -eq 0 ]; then
    RECOMMENDED_DIR="/opt/ai-discord-bot"
  else
    RECOMMENDED_DIR="${ACTUAL_HOME}/ai-discord-bot"
  fi

  read_tty() { # prompt, variable, secret(0/1)
    local prompt="$1" var="$2" secret="${3:-0}" value=""
    if [ "$NON_INTERACTIVE" -eq 1 ] || [ "$HAS_TTY" -ne 1 ]; then
      printf -v "$var" '%s' ""
      return 0
    fi
    if [ "$secret" -eq 1 ]; then
      printf '%s' "$prompt" > /dev/tty
      IFS= read -r -s value < /dev/tty || value=""
      printf '\n' > /dev/tty
    else
      printf '%s' "$prompt" > /dev/tty
      IFS= read -r value < /dev/tty || value=""
    fi
    printf -v "$var" '%s' "$value"
  }

  normalize_mode() {
    case "$(printf '%s' "${1:-bot}" | tr '[:upper:]' '[:lower:]')" in
      self|selfbot|user) printf 'user' ;;
      bot|'') printf 'bot' ;;
      *) printf 'invalid' ;;
    esac
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

  pkg_install() {
    if command -v apt-get >/dev/null 2>&1; then
      as_root apt-get update -y >/dev/null 2>&1 && as_root apt-get install -y "$@"
    elif command -v dnf >/dev/null 2>&1; then
      as_root dnf install -y "$@"
    elif command -v yum >/dev/null 2>&1; then
      as_root yum install -y "$@"
    elif command -v pacman >/dev/null 2>&1; then
      as_root pacman -Sy --noconfirm "$@"
    elif command -v apk >/dev/null 2>&1; then
      as_root apk add --no-cache "$@"
    else
      return 1
    fi
  }

  ensure_git() {
    if command -v git >/dev/null 2>&1; then
      return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "git is not installed; --dry-run will not install it."
      return 0
    fi
    info "Installing git..."
    if [ "$(uname -s)" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
      brew install git || true
    else
      pkg_install git curl || true
    fi
    command -v git >/dev/null 2>&1 || die "git is required; install it and re-run."
  }

  ensure_python() {
    if command -v python3 >/dev/null 2>&1; then
      return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "python3 is not installed; --dry-run will not install it."
      return 0
    fi
    info "Installing Python 3 (used only to generate the dashboard login)..."
    if [ "$(uname -s)" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
      brew install python || true
    else
      pkg_install python3 || true
    fi
    command -v python3 >/dev/null 2>&1 || die "Python 3 is required to generate the dashboard login."
  }

  ensure_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      if ! docker info >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
        as_root systemctl enable --now docker >/dev/null 2>&1 || true
      fi
      return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "Docker with the Compose plugin is missing; --dry-run will not install it."
      return 0
    fi
    info "Installing Docker Engine and the Compose plugin..."
    case "$(uname -s)" in
      Linux)
        command -v curl >/dev/null 2>&1 || pkg_install curl || die "curl is required to install Docker."
        if [ "$(id -u)" -eq 0 ]; then
          curl -fsSL https://get.docker.com | sh || die "Docker installation failed."
        else
          curl -fsSL https://get.docker.com | as_root sh || die "Docker installation failed."
        fi
        if command -v systemctl >/dev/null 2>&1; then
          as_root systemctl enable --now docker >/dev/null 2>&1 || true
        fi
        if [ "$ACTUAL_USER" != "root" ]; then
          as_root usermod -aG docker "$ACTUAL_USER" >/dev/null 2>&1 || true
          warn "Added ${ACTUAL_USER} to the docker group; log out and back in for passwordless docker. This run uses sudo."
        fi
        ;;
      Darwin)
        if command -v brew >/dev/null 2>&1; then
          brew install --cask docker >/dev/null 2>&1 || true
          open -a Docker >/dev/null 2>&1 || true
          local i=0
          while [ "$i" -lt 30 ] && ! docker info >/dev/null 2>&1; do
            sleep 2
            i=$((i + 1))
          done
        fi
        ;;
      *)
        die "Unsupported operating system: $(uname -s). Install Docker Compose v2 and re-run."
        ;;
    esac
    command -v docker >/dev/null 2>&1 || die "Docker could not be installed automatically."
    docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
  }

  USE_SUDO_DOCKER=0
  detect_docker() {
    if docker info >/dev/null 2>&1; then
      USE_SUDO_DOCKER=0
      return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
      if [ "$NON_INTERACTIVE" -eq 1 ]; then
        if sudo -n docker info >/dev/null 2>&1; then
          USE_SUDO_DOCKER=1
          return 0
        fi
      elif sudo docker info >/dev/null 2>&1; then
        USE_SUDO_DOCKER=1
        return 0
      fi
    fi
    return 1
  }

  DOCKER_CONFIG_DIR="${ACTUAL_HOME}/.docker"
  DOCKER_BIN="$(command -v docker 2>/dev/null || true)"
  docker_run() {
    if [ "$USE_SUDO_DOCKER" -eq 1 ]; then
      sudo env DOCKER_CONFIG="$DOCKER_CONFIG_DIR" docker "$@"
    else
      DOCKER_CONFIG="$DOCKER_CONFIG_DIR" docker "$@"
    fi
  }

  # Compose reads .env from the project directory, including interpolation.
  compose() {
    ( cd "$TARGET_DIR" && docker_run compose "$@" )
  }

  image_exists() {
    docker_run image inspect "${IMAGE_REF:-ghcr.io/${GHCR_OWNER}/ai-discord-bot:${CONTAINER_TAG}}" >/dev/null 2>&1
  }

  detect_tailscale_ip() {
    local ip=""
    if command -v tailscale >/dev/null 2>&1; then
      ip="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    fi
    printf '%s' "$ip"
  }

  detect_dashboard_ip() {
    local ip
    ip="$(detect_tailscale_ip)"
    if [ -z "$ip" ] && command -v ip >/dev/null 2>&1; then
      ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
    fi
    if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
      ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    if ! is_ipv4 "$ip"; then
      ip="127.0.0.1"
    fi
    # Only suggest an address that is private by construction. A public
    # primary address is not a safe default for an interactive prompt.
    case "$ip" in
      10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|127.0.0.1) ;;
      100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) ;;
      *) ip="127.0.0.1" ;;
    esac
    printf '%s' "$ip"
  }

  # Unattended installs stay local unless the operator names an address; a
  # detected public/LAN address is only offered as an interactive default.
  default_dashboard_ip() {
    local ip
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
      ip="$(detect_tailscale_ip)"
      printf '%s' "${ip:-127.0.0.1}"
    else
      detect_dashboard_ip
    fi
  }

  detect_docker_gid() {
    local gid=""
    if [ -S /var/run/docker.sock ]; then
      if stat -c '%g' /var/run/docker.sock >/dev/null 2>&1; then
        gid="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)"
      else
        gid="$(stat -f '%g' /var/run/docker.sock 2>/dev/null || true)"
      fi
    fi
    if [ -z "$gid" ] && command -v getent >/dev/null 2>&1; then
      gid="$(getent group docker 2>/dev/null | cut -d: -f3 || true)"
    fi
    printf '%s' "$gid"
  }

  validate_port() {
    case "$1" in
      ""|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
  }

  is_ipv4() {
    local ip="$1" a b c d extra octet
    local IFS=.
    read -r a b c d extra <<< "$ip"
    [ -z "$extra" ] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
      case "$octet" in
        ""|*[!0-9]*) return 1 ;;
      esac
      [ "$((10#$octet))" -ge 0 ] && [ "$((10#$octet))" -le 255 ] || return 1
    done
    return 0
  }

  validate_value() {
    case "$1" in
      *$'\n'*|*$'\r'*) return 1 ;;
    esac
    return 0
  }

  env_get() { # key, default
    local key="$1" default="${2:-}" line value
    if [ ! -f "$ENV_FILE" ]; then
      printf '%s' "$default"
      return 0
    fi
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE" 2>/dev/null | tail -n 1 || true)"
    if [ -z "$line" ]; then
      printf '%s' "$default"
      return 0
    fi
    value="${line#*=}"
    value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$value" in
      \'*\')
        value="${value#\'}"
        value="${value%\'}"
        ;;
      \"*\")
        value="${value#\"}"
        value="${value%\"}"
        ;;
      *)
        value="$(printf '%s' "$value" | sed 's/[[:space:]]#.*$//')"
        ;;
    esac
    printf '%s' "${value:-$default}"
  }

  env_line() { # key, value
    local key="$1" value="$2"
    case "$value" in
      *$'\n'*|*$'\r'*) die "The value for ${key} contains a newline." ;;
      *\'*) die "The value for ${key} contains a single quote; set it in .env manually." ;;
    esac
    case "$value" in
      *[\$\#[:space:]]*) printf "%s='%s'\n" "$key" "$value" ;;
      *) printf '%s=%s\n' "$key" "$value" ;;
    esac
  }

  MANAGED_KEYS="OPENAI_API_KEY OPENAI_BASE_URL AI_MODEL TOKEN_MODE DISCORD_TOKEN OWNER_ID GIPHY_API_KEY GHCR_OWNER CONTAINER_TAG DASHBOARD_HOST_IP DASHBOARD_PORT DASHBOARD_USER DASHBOARD_PASSWORD_HASH DASHBOARD_SESSION_SECRET WATCHTOWER_TOKEN DOCKER_GID DOCKER_CONFIG_FILE TZ"

  ENV_TMP=""
  cleanup() {
    if [ -n "${ENV_TMP:-}" ]; then
      rm -f "$ENV_TMP" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT INT TERM

  write_env() {
    local tmp
    if [ -f "$ENV_FILE" ]; then
      cp -p "$ENV_FILE" "$ENV_FILE.bak" 2>/dev/null || true
      chmod 600 "$ENV_FILE.bak" 2>/dev/null || true
    fi
    tmp="$(mktemp "${TARGET_DIR}/.env.tmp.XXXXXX")" || die "Could not create a temporary .env."
    ENV_TMP="$tmp"
    if [ -f "$ENV_FILE" ]; then
      tr -d '\r' < "$ENV_FILE" | awk -v keys="$MANAGED_KEYS" '
        BEGIN { n=split(keys, a, " "); for (i=1; i<=n; i++) drop[a[i]]=1 }
        {
          key=$0
          sub(/^[[:space:]]*(export[[:space:]]+)?/, "", key)
          sub(/=.*/, "", key)
          if (key in drop) next
          print
        }
      ' > "$tmp" || die "Could not read the existing .env."
    fi
    {
      env_line OPENAI_API_KEY "$OPENAI_API_KEY"
      env_line OPENAI_BASE_URL "$OPENAI_BASE_URL"
      env_line AI_MODEL "$AI_MODEL"
      env_line TOKEN_MODE "$MODE"
      env_line DISCORD_TOKEN "$DISCORD_TOKEN"
      [ -n "$OWNER_ID_VALUE" ] && env_line OWNER_ID "$OWNER_ID_VALUE"
      [ -n "$GIPHY_API_KEY_VALUE" ] && env_line GIPHY_API_KEY "$GIPHY_API_KEY_VALUE"
      env_line GHCR_OWNER "$GHCR_OWNER"
      env_line CONTAINER_TAG "$CONTAINER_TAG"
      env_line DASHBOARD_HOST_IP "$DASHBOARD_HOST_IP"
      env_line DASHBOARD_PORT "$DASHBOARD_PORT"
      env_line DASHBOARD_USER "$DASHBOARD_USER"
      env_line DASHBOARD_PASSWORD_HASH "$DASHBOARD_PASSWORD_HASH"
      env_line DASHBOARD_SESSION_SECRET "$DASHBOARD_SESSION_SECRET"
      env_line WATCHTOWER_TOKEN "$WATCHTOWER_TOKEN"
      env_line DOCKER_GID "$DOCKER_GID"
      env_line DOCKER_CONFIG_FILE "$DOCKER_CONFIG_FILE"
      env_line TZ "$TZ_VALUE"
    } >> "$tmp" || die "Could not write the new .env."
    chmod 600 "$tmp"
    if [ "$(id -u)" -eq 0 ] && [ "$ACTUAL_USER" != "root" ]; then
      chown "$ACTUAL_USER:$ACTUAL_GROUP" "$tmp" 2>/dev/null || true
    fi
    mv "$tmp" "$ENV_FILE" || die "Could not replace .env."
    ENV_TMP=""
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    if [ "$(id -u)" -eq 0 ] && [ "$ACTUAL_USER" != "root" ]; then
      chown "$ACTUAL_USER:$ACTUAL_GROUP" "$ENV_FILE" 2>/dev/null || true
    fi
  }

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

  git_run() {
    git -C "$TARGET_DIR" -c safe.directory="$TARGET_DIR" "$@"
  }

  clone_target() {
    if [ -d "$TARGET_DIR" ]; then
      find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    fi
  }

  clone_repo() {
    local token="${GIT_TOKEN:-}" pat=""
    if [ -n "$token" ]; then
      use_token "$token"
      if GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$TARGET_DIR"; then
        forget_token
        return 0
      fi
      forget_token
      warn "The token clone failed; trying the next method."
      clone_target
    fi
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      if gh repo clone Jerit3787/ai-discord-bot "$TARGET_DIR" -- --depth 1 -b "$REPO_BRANCH"; then
        return 0
      fi
      clone_target
    fi
    if GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$TARGET_DIR" 2>/dev/null; then
      return 0
    fi
    clone_target
    if [ "$NON_INTERACTIVE" -eq 0 ] && [ "$HAS_TTY" -eq 1 ]; then
      read_tty "GitHub token with repo access for the private app repository (hidden): " pat 1
      if [ -n "$pat" ]; then
        use_token "$pat"
        if GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$TARGET_DIR"; then
          GIT_TOKEN="$pat"
          forget_token
          return 0
        fi
        forget_token
        clone_target
      fi
    fi
    if GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$REPO_BRANCH" "git@github.com:Jerit3787/ai-discord-bot.git" "$TARGET_DIR" 2>/dev/null; then
      return 0
    fi
    clone_target
    return 1
  }

  update_repo() {
    local token="${GIT_TOKEN:-}" pat=""
    if [ -n "$token" ]; then
      use_token "$token"
    fi
    if GIT_TERMINAL_PROMPT=0 git_run fetch --depth=1 origin "$REPO_BRANCH" \
      && { git_run checkout "$REPO_BRANCH" 2>/dev/null || git_run checkout -b "$REPO_BRANCH" "origin/$REPO_BRANCH"; } \
      && git_run merge --ff-only "origin/$REPO_BRANCH"; then
      forget_token
      return 0
    fi
    forget_token
    if [ "$NON_INTERACTIVE" -eq 0 ] && [ "$HAS_TTY" -eq 1 ]; then
      read_tty "GitHub token to update the checkout (hidden, Enter to skip): " pat 1
      if [ -n "$pat" ]; then
        use_token "$pat"
        if GIT_TERMINAL_PROMPT=0 git_run fetch --depth=1 origin "$REPO_BRANCH" \
          && { git_run checkout "$REPO_BRANCH" 2>/dev/null || git_run checkout -b "$REPO_BRANCH" "origin/$REPO_BRANCH"; } \
          && git_run merge --ff-only "origin/$REPO_BRANCH"; then
          GIT_TOKEN="$pat"
          forget_token
          return 0
        fi
        forget_token
      fi
    fi
    return 1
  }

  docker_login() { # token, user
    local token="$1" user="$2"
    [ -n "$token" ] || return 1
    [ -n "$user" ] || return 1
    mkdir -p "$DOCKER_CONFIG_DIR" 2>/dev/null || true
    chmod 700 "$DOCKER_CONFIG_DIR" 2>/dev/null || true
    [ -n "$DOCKER_BIN" ] || DOCKER_BIN="$(command -v docker 2>/dev/null || echo docker)"
    if [ "$(id -u)" -eq 0 ] && [ "$ACTUAL_USER" != "root" ]; then
      run_as_user env DOCKER_CONFIG="$DOCKER_CONFIG_DIR" "$DOCKER_BIN" login ghcr.io -u "$user" --password-stdin <<< "$token" >/dev/null 2>&1
    else
      DOCKER_CONFIG="$DOCKER_CONFIG_DIR" "$DOCKER_BIN" login ghcr.io -u "$user" --password-stdin <<< "$token" >/dev/null 2>&1
    fi
    local rc=$?
    if [ "$rc" -eq 0 ]; then
      if [ "$(id -u)" -eq 0 ] && [ "$ACTUAL_USER" != "root" ]; then
        chown -R "$ACTUAL_USER:$ACTUAL_GROUP" "$DOCKER_CONFIG_DIR" 2>/dev/null || true
      fi
      chmod 600 "$DOCKER_CONFIG_FILE" 2>/dev/null || true
      return 0
    fi
    return 1
  }

  ghcr_user_from_gh() {
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh api user --jq .login 2>/dev/null || true
    fi
  }

  prompt_ghcr_user() {
    local default_user answer
    if [ "$NON_INTERACTIVE" -eq 1 ] || [ "$HAS_TTY" -ne 1 ]; then
      return 1
    fi
    default_user="$(ghcr_user_from_gh)"
    while [ -z "${GHCR_USER:-}" ]; do
      if [ -n "$default_user" ]; then
        read_tty "GitHub username for GHCR [${default_user}]: " answer
        GHCR_USER="${answer:-$default_user}"
      else
        read_tty "GitHub username for GHCR (the account that owns the token): " answer
        GHCR_USER="$answer"
      fi
      if [ -z "$GHCR_USER" ]; then
        printf 'Enter the GitHub account that owns the token.\n' > /dev/tty
      fi
    done
  }

  ensure_config_file() {
    local dir
    dir="$(dirname "$DOCKER_CONFIG_FILE")"
    mkdir -p "$dir" 2>/dev/null || as_root mkdir -p "$dir" || die "Could not create ${dir}."
    if [ -d "$DOCKER_CONFIG_FILE" ]; then
      die "${DOCKER_CONFIG_FILE} is a directory; remove it and re-run."
    fi
    if [ ! -f "$DOCKER_CONFIG_FILE" ]; then
      if ! printf '{}\n' > "$DOCKER_CONFIG_FILE" 2>/dev/null; then
        printf '{}\n' | as_root tee "$DOCKER_CONFIG_FILE" >/dev/null
      fi
    fi
    [ -f "$DOCKER_CONFIG_FILE" ] || die "Could not create ${DOCKER_CONFIG_FILE}."
    chmod 600 "$DOCKER_CONFIG_FILE" 2>/dev/null || true
    if [ "$(id -u)" -eq 0 ] && [ "$ACTUAL_USER" != "root" ]; then
      chown "$ACTUAL_USER:$ACTUAL_GROUP" "$DOCKER_CONFIG_FILE" 2>/dev/null || true
      chown "$ACTUAL_USER:$ACTUAL_GROUP" "$dir" 2>/dev/null || true
    fi
  }

  pull_images() {
    local services=(bot dashboard)
    [ "$NO_WATCHTOWER" -eq 0 ] && services+=(watchtower)
    compose pull "${services[@]}"
  }

  generate_secret() {
    python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
  }

  hash_password_value() {
    local password="$1"
    printf '%s' "$password" | python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from dashboard_app.auth import hash_password
print(hash_password(sys.stdin.read().rstrip("\n")))
' "$TARGET_DIR"
  }

  generate_login() {
    local output
    output="$(cd "$TARGET_DIR" && python3 tools/dashboard_password.py --generate)" || return 1
    DASHBOARD_PASSWORD_HASH="$(printf '%s\n' "$output" | sed -n "s/^DASHBOARD_PASSWORD_HASH='\(.*\)'$/\1/p" | head -n 1)"
    DASHBOARD_SESSION_SECRET="$(printf '%s\n' "$output" | sed -n "s/^DASHBOARD_SESSION_SECRET='\(.*\)'$/\1/p" | head -n 1)"
    WATCHTOWER_TOKEN="$(printf '%s\n' "$output" | sed -n "s/^WATCHTOWER_TOKEN='\(.*\)'$/\1/p" | head -n 1)"
    DASHBOARD_PASSWORD_PLAIN="$(printf '%s\n' "$output" | sed -n 's/^Dashboard password: //p' | head -n 1)"
    [ -n "$DASHBOARD_PASSWORD_HASH" ] && [ -n "$DASHBOARD_SESSION_SECRET" ] && [ -n "$WATCHTOWER_TOKEN" ]
  }

  pre_resolve_image_tag() {
    local raw_stored stored mode tag
    raw_stored="$(env_get TOKEN_MODE "")"
    stored="$(normalize_mode "$raw_stored")"
    [ -n "$raw_stored" ] || stored=""
    mode="$(normalize_mode "${TOKEN_MODE_ARG:-${TOKEN_MODE:-${stored:-}}}")"
    [ "$mode" != "invalid" ] || die "TOKEN_MODE must be bot or user."
    if [ -z "${TOKEN_MODE_ARG:-}${TOKEN_MODE:-}${stored:-}" ]; then
      if [ "$NON_INTERACTIVE" -eq 0 ]; then
        printf '\nToken mode:\n  bot  = dedicated bot account (recommended, ToS-safe)\n  user = your own account as a self-bot (violates Discord ToS, ban risk)\n' > /dev/tty
        while :; do
          read_tty "Token mode (bot or user) [bot]: " mode_answer
          mode="$(normalize_mode "${mode_answer:-bot}")"
          [ "$mode" != "invalid" ] && break
          printf 'Please type bot or user.\n' > /dev/tty
        done
      else
        mode="bot"
      fi
    fi
    tag="${CONTAINER_TAG:-$(env_get CONTAINER_TAG "$mode")}"
    if [ "$TAG_SUPPLIED" -eq 0 ] && [ -n "$stored" ] && [ "$stored" != "$mode" ]; then
      case "$(env_get CONTAINER_TAG "")" in
        ""|bot|user|latest) tag="$mode" ;;
      esac
    fi
    validate_value "$tag" || die "CONTAINER_TAG contains a newline."
    case "$tag" in
      latest) [ "$mode" = "bot" ] || die "CONTAINER_TAG=latest is a bot-mode image; set CONTAINER_TAG=user or a user-<sha> tag." ;;
      bot|bot-*) [ "$mode" = "bot" ] || die "TOKEN_MODE=user needs CONTAINER_TAG=user (or user-<sha>), not ${tag}." ;;
      user|user-*) [ "$mode" = "user" ] || die "TOKEN_MODE=bot needs CONTAINER_TAG=bot (or bot-<sha>), not ${tag}." ;;
      *) die "CONTAINER_TAG must be bot, user, latest, bot-<sha> or user-<sha>." ;;
    esac
    GHCR_OWNER="${GHCR_OWNER:-$(env_get GHCR_OWNER jerit3787)}"
    GHCR_OWNER="$(printf '%s' "$GHCR_OWNER" | tr '[:upper:]' '[:lower:]')"
    validate_value "$GHCR_OWNER" || die "GHCR_OWNER contains a newline."
    [ -n "$GHCR_OWNER" ] || die "GHCR_OWNER must not be empty."
    TOKEN_MODE="$mode"
    CONTAINER_TAG="$tag"
    IMAGE_REF="ghcr.io/${GHCR_OWNER}/ai-discord-bot:${CONTAINER_TAG}"
  }

  extract_host_bundle() {
    local archive
    info "Extracting the host bundle from ${IMAGE_REF}..."
    archive="$(mktemp "${TMPDIR:-/tmp}/ai-bot-bundle.XXXXXX")" || die "Could not create a temporary archive."
    if ! docker_run run --rm --entrypoint tar "$IMAGE_REF" -C /app/host-bundle -cf - . > "$archive"; then
      rm -f "$archive"
      die "${IMAGE_REF} does not contain /app/host-bundle (or tar is missing). Rebuild or update the image."
    fi
    if ! tar -C "$TARGET_DIR" -xf "$archive"; then
      rm -f "$archive"
      die "Could not extract the host bundle into ${TARGET_DIR}."
    fi
    rm -f "$archive"
    [ -f "$TARGET_DIR/docker-compose.yml" ] || die "The image host bundle has no docker-compose.yml."
    [ -f "$TARGET_DIR/tools/dashboard_password.py" ] || die "The image host bundle has no credential generator."
    [ -f "$TARGET_DIR/dashboard_app/auth.py" ] || die "The image host bundle has no dashboard auth module."
    printf '%s\n' "$IMAGE_REF" > "$TARGET_DIR/.image-install"
    chmod +x "$TARGET_DIR/tools/discord-bot" "$TARGET_DIR/tools/install-cli.sh" 2>/dev/null || true
    if [ "$(id -u)" -eq 0 ] && [ "$ACTUAL_USER" != "root" ]; then
      chown -R "$ACTUAL_USER:$ACTUAL_GROUP" "$TARGET_DIR" 2>/dev/null || true
    fi
  }

  resolve_docker_config_file() {
    DOCKER_CONFIG_FILE="${DOCKER_CONFIG_FILE:-$(env_get DOCKER_CONFIG_FILE "")}"
    if [ -z "$DOCKER_CONFIG_FILE" ]; then
      DOCKER_CONFIG_FILE="${ACTUAL_HOME}/.docker/config.json"
    fi
    case "$DOCKER_CONFIG_FILE" in
      /*) ;;
      *) DOCKER_CONFIG_FILE="${TARGET_DIR}/${DOCKER_CONFIG_FILE}" ;;
    esac
    if [ "$DOCKER_CONFIG_FILE" = "/home/ubuntu/.docker/config.json" ] \
       && [ "$ACTUAL_HOME" != "/home/ubuntu" ] \
       && [ ! -f "$DOCKER_CONFIG_FILE" ]; then
      DOCKER_CONFIG_FILE="${ACTUAL_HOME}/.docker/config.json"
    fi
    case "$DOCKER_CONFIG_FILE" in
      */config.json) ;;
      *)
        warn "Docker stores registry credentials in config.json; using $(dirname "$DOCKER_CONFIG_FILE")/config.json."
        DOCKER_CONFIG_FILE="$(dirname "$DOCKER_CONFIG_FILE")/config.json"
        ;;
    esac
    DOCKER_CONFIG_DIR="$(dirname "$DOCKER_CONFIG_FILE")"
  }

  ensure_compose_plugin() {
    local plugin
    # Docker Desktop installs the Compose plugin under ~/.docker. Pointing
    # DOCKER_CONFIG at a custom directory would otherwise hide it.
    [ "$DOCKER_CONFIG_DIR" = "${ACTUAL_HOME}/.docker" ] && return 0
    [ -x "${DOCKER_CONFIG_DIR}/cli-plugins/docker-compose" ] && return 0
    for plugin in \
      "${ACTUAL_HOME}/.docker/cli-plugins/docker-compose" \
      /usr/local/lib/docker/cli-plugins/docker-compose \
      /usr/lib/docker/cli-plugins/docker-compose \
      /usr/libexec/docker/cli-plugins/docker-compose; do
      [ -x "$plugin" ] || continue
      mkdir -p "${DOCKER_CONFIG_DIR}/cli-plugins" 2>/dev/null || true
      ln -sfn "$plugin" "${DOCKER_CONFIG_DIR}/cli-plugins/docker-compose" 2>/dev/null || true
      return 0
    done
    plugin="$(command -v docker-compose 2>/dev/null || true)"
    if [ -n "$plugin" ]; then
      mkdir -p "${DOCKER_CONFIG_DIR}/cli-plugins" 2>/dev/null || true
      ln -sfn "$plugin" "${DOCKER_CONFIG_DIR}/cli-plugins/docker-compose" 2>/dev/null || true
    fi
    return 0
  }

  prepare_image_only() {
    local pulled=0
    ensure_docker
    if ! detect_docker; then
      die "Docker is installed but not reachable. Start Docker and make sure ${ACTUAL_USER} can use it."
    fi
    DOCKER_READY=1
    resolve_docker_config_file
    ensure_compose_plugin
    pre_resolve_image_tag

    GHCR_TOKEN="${GHCR_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
    GHCR_USER="${GHCR_USER:-${GITHUB_USER:-}}"
    if [ -z "$GHCR_USER" ] && [ -n "$GHCR_TOKEN" ]; then
      GHCR_USER="$(ghcr_user_from_gh)"
    fi
    if [ -n "$GHCR_TOKEN" ]; then
      if [ -z "$GHCR_USER" ]; then
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
          die "Set GHCR_USER to the GitHub account that owns GHCR_TOKEN (or authenticate gh)."
        fi
        prompt_ghcr_user
      fi
      if docker_login "$GHCR_TOKEN" "$GHCR_USER"; then
        info "Logged in to GHCR as ${GHCR_USER}."
      else
        warn "GHCR login failed for ${GHCR_USER}; trying the existing Docker login."
      fi
    fi

    if docker_run pull "$IMAGE_REF"; then
      pulled=1
    fi
    if [ "$pulled" -eq 0 ] && [ "$NON_INTERACTIVE" -eq 0 ] && [ "$HAS_TTY" -eq 1 ]; then
      printf '\nThe private image could not be pulled. A classic PAT with read:packages is needed.\n' > /dev/tty
      read_tty "GHCR token with read:packages (hidden, Enter to skip): " pull_token 1
      if [ -n "$pull_token" ]; then
        if [ -z "$GHCR_USER" ]; then
          prompt_ghcr_user || true
        fi
        if [ -n "$GHCR_USER" ] && docker_login "$pull_token" "$GHCR_USER"; then
          info "Logged in to GHCR as ${GHCR_USER}."
          if docker_run pull "$IMAGE_REF"; then
            pulled=1
          fi
        else
          warn "GHCR login failed with the supplied token."
        fi
      fi
    fi
    if ! image_exists; then
      die "The private image ${IMAGE_REF} is not available. Set GHCR_TOKEN (read:packages) and GHCR_USER, then re-run."
    fi
    if [ "$pulled" -eq 0 ]; then
      warn "Could not pull ${IMAGE_REF}; using the local copy."
    fi
    if [ "$NO_START" -eq 0 ] && [ "$NO_WATCHTOWER" -eq 0 ]; then
      docker_run pull nickfedor/watchtower:latest >/dev/null 2>&1 \
        || warn "Could not pull the Watchtower image; Compose will retry."
    fi
    extract_host_bundle
    IMAGE_PREPARED=1
  }

  # -----------------------------------------------------------------------
  # Target directory
  # -----------------------------------------------------------------------
  is_install_dir() {
    [ -f "$1/docker-compose.yml" ] || return 1
    [ -f "$1/bot.py" ] || [ -f "$1/.image-install" ]
  }

  detect_existing_checkout() {
    local dir candidate
    # A running stack records the checkout it was started from. Prefer that
    # over a default path so an update never creates a second Compose project.
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      dir="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' ai-discord-bot 2>/dev/null || true)"
    fi
    if [ -z "$dir" ] && command -v sudo >/dev/null 2>&1; then
      dir="$(sudo -n docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' ai-discord-bot 2>/dev/null || true)"
    fi
    if [ -n "$dir" ] && is_install_dir "$dir"; then
      printf '%s' "$dir"
      return 0
    fi
    for candidate in "$PWD" "$RECOMMENDED_DIR" "$ACTUAL_HOME/ai-discord-bot" \
      "$ACTUAL_HOME/Desktop/ai-discord-bot" "$ACTUAL_HOME/Projects/ai-discord-bot" \
      "/opt/ai-discord-bot" "/srv/ai-discord-bot"; do
      if is_install_dir "$candidate"; then
        printf '%s' "$candidate"
        return 0
      fi
    done
    return 1
  }

  EXISTING_INSTALL_DIR="$(detect_existing_checkout || true)"
  TARGET_DIR="${INSTALL_DIR_ARG:-${AI_DISCORD_BOT_INSTALL_DIR:-}}"
  if [ -z "$TARGET_DIR" ] && [ -n "$EXISTING_INSTALL_DIR" ]; then
    TARGET_DIR="$EXISTING_INSTALL_DIR"
    info "Using the existing installation at ${TARGET_DIR}."
  fi
  if [ -z "$TARGET_DIR" ]; then
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
      TARGET_DIR="$RECOMMENDED_DIR"
    else
      printf '%s' "Installation path [${RECOMMENDED_DIR}]: " > /dev/tty
      IFS= read -r input_dir < /dev/tty || input_dir=""
      TARGET_DIR="${input_dir:-$RECOMMENDED_DIR}"
    fi
  fi
  TARGET_DIR="${TARGET_DIR%/}"
  [ -n "$TARGET_DIR" ] || die "No installation path given."

  if [ -n "$EXISTING_INSTALL_DIR" ] && [ "$EXISTING_INSTALL_DIR" != "$TARGET_DIR" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "An existing AI Discord Bot checkout is at ${EXISTING_INSTALL_DIR}; a real run would refuse to create a second copy at ${TARGET_DIR}."
    else
      die "An existing AI Discord Bot checkout is at ${EXISTING_INSTALL_DIR}. Re-run without --dir to update it, or stop and remove that stack before installing at ${TARGET_DIR}. The Compose project uses fixed container names, so only one copy can run per host."
    fi
  fi

  if [ -d "$TARGET_DIR" ] && is_install_dir "$TARGET_DIR"; then
    EXISTING_CHECKOUT=1
  else
    EXISTING_CHECKOUT=0
  fi
  if [ -d "$TARGET_DIR" ] && [ "$EXISTING_CHECKOUT" -eq 0 ] && [ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]; then
    die "${TARGET_DIR} exists and is not an AI Discord Bot checkout."
  fi

  ENV_FILE="$TARGET_DIR/.env"
  REPO_URL="https://github.com/Jerit3787/ai-discord-bot.git"
  REPO_BRANCH="${BRANCH_ARG:-${AI_DISCORD_BOT_BRANCH:-main}}"
  GIT_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -z "$GIT_TOKEN" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    GIT_TOKEN="$(gh auth token 2>/dev/null || true)"
  fi

  # -----------------------------------------------------------------------
  # Dry run: resolve what is possible and print the plan without side effects.
  # -----------------------------------------------------------------------
  if [ "$DRY_RUN" -eq 1 ]; then
    RAW_STORED_MODE="$(env_get TOKEN_MODE "")"
    STORED_MODE="$(normalize_mode "$RAW_STORED_MODE")"
    [ -n "$RAW_STORED_MODE" ] || STORED_MODE=""
    MODE="$(normalize_mode "${TOKEN_MODE_ARG:-${TOKEN_MODE:-${STORED_MODE:-bot}}}")"
    [ "$MODE" != "invalid" ] || die "TOKEN_MODE must be bot or user."
    CONTAINER_TAG="${CONTAINER_TAG:-$(env_get CONTAINER_TAG "$MODE")}"
    GHCR_OWNER="${GHCR_OWNER:-$(env_get GHCR_OWNER jerit3787)}"
    GHCR_OWNER="$(printf '%s' "$GHCR_OWNER" | tr '[:upper:]' '[:lower:]')"
    IMAGE_REF="ghcr.io/${GHCR_OWNER}/ai-discord-bot:${CONTAINER_TAG}"
    DASHBOARD_HOST_IP="${DASHBOARD_IP_ARG:-${DASHBOARD_HOST_IP:-$(env_get DASHBOARD_HOST_IP "")}}"
    [ -n "$DASHBOARD_HOST_IP" ] || DASHBOARD_HOST_IP="$(default_dashboard_ip)"
    DASHBOARD_PORT="${DASHBOARD_PORT_ARG:-${DASHBOARD_PORT:-$(env_get DASHBOARD_PORT 8787)}}"
    is_ipv4 "$DASHBOARD_HOST_IP" || die "DASHBOARD_HOST_IP must be an IPv4 address such as 100.64.0.10 or 127.0.0.1."
    validate_port "$DASHBOARD_PORT" || die "DASHBOARD_PORT must be a whole number from 1 to 65535."
    dry_gid="$(detect_docker_gid)"
    DOCKER_GID="${DOCKER_GID:-${dry_gid:-$(env_get DOCKER_GID 999)}}"
    DOCKER_CONFIG_FILE="${DOCKER_CONFIG_FILE:-$(env_get DOCKER_CONFIG_FILE "${ACTUAL_HOME}/.docker/config.json")}"
    printf '\n%sAI Discord Bot — dry run%s\n' "$BOLD" "$RESET"
    printf '  install dir:      %s\n' "$TARGET_DIR"
    if [ "$IMAGE_ONLY" -eq 1 ]; then
      printf '  source:          image only (no git checkout)\n'
      printf '  checkout:        host bundle from the image\n'
      printf '  checkout update: n/a\n'
    else
      printf '  checkout:        %s\n' "$([ "$EXISTING_CHECKOUT" -eq 1 ] && echo existing || echo 'will clone')"
      printf '  checkout update: %s\n' "$([ "$NO_GIT_UPDATE" -eq 1 ] && echo skipped || echo yes)"
      printf '  branch:          %s\n' "$REPO_BRANCH"
    fi
    printf '  token mode:      %s\n' "$MODE"
    printf '  image:           %s\n' "$IMAGE_REF"
    printf '  dashboard:       http://%s:%s\n' "$DASHBOARD_HOST_IP" "$DASHBOARD_PORT"
    printf '  .env:            %s\n' "$([ -f "$ENV_FILE" ] && echo present || echo 'will create')"
    printf '  docker gid:      %s\n' "$DOCKER_GID"
    printf '  docker config:   %s\n' "$DOCKER_CONFIG_FILE"
    printf '  watchtower:      %s\n' "$([ "$NO_WATCHTOWER" -eq 1 ] && echo disabled || echo enabled)"
    printf '  start stack:     %s\n' "$([ "$NO_START" -eq 1 ] && echo no || echo yes)"
    printf '  cli link:        %s\n' "$([ "$NO_CLI" -eq 1 ] && echo no || echo yes)"
    if [ ! -f "$ENV_FILE" ]; then
      printf '\n  Fresh install values still needed: DISCORD_TOKEN and OPENAI_API_KEY.\n'
      printf '  The dashboard password is generated during the real run.\n'
    fi
    printf '\n%sDry run complete; nothing was cloned, written, pulled or started.%s\n' "$DIM" "$RESET"
    exit 0
  fi

  # -----------------------------------------------------------------------
  # Clone/update the private checkout, or extract the host bundle from the image
  # -----------------------------------------------------------------------
  if [ ! -d "$TARGET_DIR" ]; then
    parent_dir="$(dirname "$TARGET_DIR")"
    if [ ! -d "$parent_dir" ]; then
      if [ "$(id -u)" -eq 0 ]; then
        mkdir -p "$parent_dir"
      elif command -v sudo >/dev/null 2>&1; then
        as_root mkdir -p "$parent_dir"
      else
        mkdir -p "$parent_dir" 2>/dev/null || die "Could not create ${parent_dir}."
      fi
    fi
    if [ ! -w "$parent_dir" ]; then
      as_root mkdir -p "$TARGET_DIR"
      if [ "$(id -u)" -eq 0 ] && [ "$ACTUAL_USER" != "root" ]; then
        chown -R "$ACTUAL_USER:$ACTUAL_GROUP" "$TARGET_DIR" 2>/dev/null || true
      fi
    else
      mkdir -p "$TARGET_DIR"
    fi
  fi
  if [ ! -w "$TARGET_DIR" ]; then
    if command -v sudo >/dev/null 2>&1; then
      as_root chown -R "$ACTUAL_USER:$ACTUAL_GROUP" "$TARGET_DIR" 2>/dev/null || true
    fi
  fi
  [ -w "$TARGET_DIR" ] || die "${TARGET_DIR} is not writable by ${ACTUAL_USER}."

  if [ "$IMAGE_ONLY" -eq 1 ]; then
    prepare_image_only
  else
    ensure_git
    if [ "$NO_GIT_UPDATE" -eq 1 ]; then
      [ "$EXISTING_CHECKOUT" -eq 1 ] || die "--no-git-update needs an existing checkout at ${TARGET_DIR}."
      info "Skipping the checkout update (--no-git-update)."
    elif [ "$EXISTING_CHECKOUT" -eq 1 ] && [ -d "$TARGET_DIR/.git" ]; then
      info "Updating ${TARGET_DIR} (${REPO_BRANCH})..."
      if ! update_repo; then
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
          die "Could not fast-forward ${TARGET_DIR}. Resolve local changes or credentials first."
        fi
        warn "Could not update the checkout; continuing with the code already there."
      fi
      git_run config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" >/dev/null 2>&1 || true
    elif [ "$EXISTING_CHECKOUT" -eq 1 ]; then
      warn "${TARGET_DIR} is not a git checkout; using the files already there."
    else
      info "Cloning Jerit3787/ai-discord-bot (${REPO_BRANCH}) into ${TARGET_DIR}..."
      if ! clone_repo; then
        die "Could not clone the private repository. Set GITHUB_TOKEN/GH_TOKEN, authenticate gh, or use an SSH key."
      fi
    fi
  fi
  [ -f "$TARGET_DIR/docker-compose.yml" ] || die "docker-compose.yml not found in ${TARGET_DIR}."
  [ -f "$TARGET_DIR/tools/dashboard_password.py" ] || die "The dashboard credential generator is missing."

  if [ "$(id -u)" -eq 0 ] && [ "$ACTUAL_USER" != "root" ]; then
    chown -R "$ACTUAL_USER:$ACTUAL_GROUP" "$TARGET_DIR" 2>/dev/null || true
  fi

  ensure_python

  # -----------------------------------------------------------------------
  # Read existing values, then fill only what is missing or explicitly changed.
  # -----------------------------------------------------------------------
  EXISTING_ENV=0
  [ -f "$ENV_FILE" ] && EXISTING_ENV=1

  RAW_STORED_MODE="$(env_get TOKEN_MODE "")"
  STORED_MODE="$(normalize_mode "$RAW_STORED_MODE")"
  [ -n "$RAW_STORED_MODE" ] || STORED_MODE=""
  MODE_SUPPLIED=0
  [ -n "${TOKEN_MODE_ARG:-}${TOKEN_MODE:-}" ] && MODE_SUPPLIED=1
  MODE="$(normalize_mode "${TOKEN_MODE_ARG:-${TOKEN_MODE:-${STORED_MODE:-}}}")"
  if [ "$MODE" = "invalid" ]; then
    die "TOKEN_MODE must be bot or user."
  fi
  if [ "$MODE_SUPPLIED" -eq 0 ] && [ -z "$STORED_MODE" ]; then
    if [ "$NON_INTERACTIVE" -eq 0 ]; then
      printf '\nToken mode:\n  bot  = dedicated bot account (recommended, ToS-safe)\n  user = your own account as a self-bot (violates Discord ToS, ban risk)\n' > /dev/tty
      while :; do
        read_tty "Token mode (bot or user) [bot]: " mode_answer
        MODE="$(normalize_mode "${mode_answer:-bot}")"
        [ "$MODE" != "invalid" ] && break
        printf 'Please type bot or user.\n' > /dev/tty
      done
    else
      MODE="bot"
    fi
  fi
  MODE_CHANGED=0
  if [ -n "$STORED_MODE" ] && [ "$STORED_MODE" != "$MODE" ]; then
    MODE_CHANGED=1
  fi

  STORED_TAG="$(env_get CONTAINER_TAG "")"
  CONTAINER_TAG="${CONTAINER_TAG:-${STORED_TAG:-$MODE}}"
  if [ "$TAG_SUPPLIED" -eq 0 ] && [ "$MODE_CHANGED" -eq 1 ]; then
    case "$STORED_TAG" in
      ""|bot|user|latest) CONTAINER_TAG="$MODE" ;;
    esac
  fi
  validate_value "$CONTAINER_TAG" || die "CONTAINER_TAG contains a newline."
  case "$CONTAINER_TAG" in
    latest) [ "$MODE" = "bot" ] || die "CONTAINER_TAG=latest is a bot-mode image; set CONTAINER_TAG=user or a user-<sha> tag." ;;
    bot|bot-*) [ "$MODE" = "bot" ] || die "TOKEN_MODE=user needs CONTAINER_TAG=user (or user-<sha>), not ${CONTAINER_TAG}." ;;
    user|user-*) [ "$MODE" = "user" ] || die "TOKEN_MODE=bot needs CONTAINER_TAG=bot (or bot-<sha>), not ${CONTAINER_TAG}." ;;
    *) die "CONTAINER_TAG must be bot, user, latest, bot-<sha> or user-<sha>." ;;
  esac

  GHCR_OWNER="${GHCR_OWNER:-$(env_get GHCR_OWNER jerit3787)}"
  GHCR_OWNER="$(printf '%s' "$GHCR_OWNER" | tr '[:upper:]' '[:lower:]')"
  validate_value "$GHCR_OWNER" || die "GHCR_OWNER contains a newline."
  [ -n "$GHCR_OWNER" ] || die "GHCR_OWNER must not be empty."
  IMAGE_REF="ghcr.io/${GHCR_OWNER}/ai-discord-bot:${CONTAINER_TAG}"

  DASHBOARD_IP_SUPPLIED=0
  [ -n "${DASHBOARD_IP_ARG:-}${DASHBOARD_HOST_IP:-}" ] && DASHBOARD_IP_SUPPLIED=1
  STORED_DASHBOARD_IP="$(env_get DASHBOARD_HOST_IP "")"
  DASHBOARD_HOST_IP="${DASHBOARD_IP_ARG:-${DASHBOARD_HOST_IP:-$STORED_DASHBOARD_IP}}"
  if [ -z "$DASHBOARD_HOST_IP" ]; then
    DASHBOARD_HOST_IP="$(default_dashboard_ip)"
  fi
  if [ "$DASHBOARD_IP_SUPPLIED" -eq 0 ] && [ -z "$STORED_DASHBOARD_IP" ] && [ "$NON_INTERACTIVE" -eq 0 ]; then
    printf '\nThe dashboard publishes on one host interface. Use a Tailscale\nor private LAN address, or 127.0.0.1 for local-only access.\n' > /dev/tty
    read_tty "Dashboard bind address [${DASHBOARD_HOST_IP}]: " ip_answer
    DASHBOARD_HOST_IP="${ip_answer:-$DASHBOARD_HOST_IP}"
  fi
  validate_value "$DASHBOARD_HOST_IP" || die "DASHBOARD_HOST_IP contains a newline."
  [ -n "$DASHBOARD_HOST_IP" ] || die "DASHBOARD_HOST_IP must not be empty."
  case "$DASHBOARD_HOST_IP" in
    *[[:space:]]*) die "DASHBOARD_HOST_IP must not contain spaces." ;;
    *:*) die "DASHBOARD_HOST_IP must be an IPv4 address; IPv6 publishing is not supported here." ;;
  esac
  is_ipv4 "$DASHBOARD_HOST_IP" || die "DASHBOARD_HOST_IP must be an IPv4 address such as 100.64.0.10 or 127.0.0.1."

  DASHBOARD_PORT_SUPPLIED=0
  [ -n "${DASHBOARD_PORT_ARG:-}${DASHBOARD_PORT:-}" ] && DASHBOARD_PORT_SUPPLIED=1
  STORED_DASHBOARD_PORT="$(env_get DASHBOARD_PORT "")"
  DASHBOARD_PORT="${DASHBOARD_PORT_ARG:-${DASHBOARD_PORT:-${STORED_DASHBOARD_PORT:-8787}}}"
  if [ "$DASHBOARD_PORT_SUPPLIED" -eq 0 ] && [ -z "$STORED_DASHBOARD_PORT" ] && [ "$NON_INTERACTIVE" -eq 0 ]; then
    read_tty "Dashboard port [${DASHBOARD_PORT}]: " port_answer
    DASHBOARD_PORT="${port_answer:-$DASHBOARD_PORT}"
  fi
  if ! validate_port "$DASHBOARD_PORT"; then
    if [ "$NON_INTERACTIVE" -eq 0 ]; then
      read_tty "Dashboard port [8787]: " port_answer
      DASHBOARD_PORT="${port_answer:-8787}"
    fi
  fi
  validate_port "$DASHBOARD_PORT" || die "DASHBOARD_PORT must be a whole number from 1 to 65535."

  DASHBOARD_USER="${DASHBOARD_USER:-$(env_get DASHBOARD_USER admin)}"
  [ -n "$DASHBOARD_USER" ] || DASHBOARD_USER="admin"
  validate_value "$DASHBOARD_USER" || die "DASHBOARD_USER contains a newline."

  TZ_VALUE="${TZ:-$(env_get TZ Asia/Kuala_Lumpur)}"
  [ -n "$TZ_VALUE" ] || TZ_VALUE="Asia/Kuala_Lumpur"

  OPENAI_API_KEY="${OPENAI_API_KEY:-$(env_get OPENAI_API_KEY "")}"
  OPENAI_BASE_URL_SUPPLIED=0
  [ -n "${OPENAI_BASE_URL:-}" ] && OPENAI_BASE_URL_SUPPLIED=1
  STORED_OPENAI_BASE_URL="$(env_get OPENAI_BASE_URL "")"
  OPENAI_BASE_URL="${OPENAI_BASE_URL:-${STORED_OPENAI_BASE_URL:-https://api.openai.com/v1}}"
  OPENAI_BASE_URL="${OPENAI_BASE_URL%/}"
  [ -n "$OPENAI_BASE_URL" ] || OPENAI_BASE_URL="https://api.openai.com/v1"

  AI_MODEL_SUPPLIED=0
  [ -n "${AI_MODEL:-}" ] && AI_MODEL_SUPPLIED=1
  STORED_AI_MODEL="$(env_get AI_MODEL "")"
  AI_MODEL="${AI_MODEL:-${STORED_AI_MODEL:-gpt-4o-mini}}"
  [ -n "$AI_MODEL" ] || AI_MODEL="gpt-4o-mini"

  STORED_DISCORD_TOKEN="$(env_get DISCORD_TOKEN "")"
  if [ "$MODE_CHANGED" -eq 1 ]; then
    # A bot token and a user token are different credentials; never carry the
    # old mode's token across a mode switch unless it was supplied explicitly.
    DISCORD_TOKEN="${DISCORD_TOKEN:-}"
  else
    DISCORD_TOKEN="${DISCORD_TOKEN:-$STORED_DISCORD_TOKEN}"
  fi

  OWNER_ID_VALUE="${OWNER_ID:-$(env_get OWNER_ID "")}"
  GIPHY_API_KEY_VALUE="${GIPHY_API_KEY:-$(env_get GIPHY_API_KEY "")}"

  if [ "$NON_INTERACTIVE" -eq 0 ]; then
    if [ -z "$OPENAI_API_KEY" ]; then
      read_tty "OpenAI-compatible API key (hidden): " OPENAI_API_KEY 1
    fi
    if [ "$OPENAI_BASE_URL_SUPPLIED" -eq 0 ] && [ -z "$STORED_OPENAI_BASE_URL" ]; then
      read_tty "Endpoint base URL [${OPENAI_BASE_URL}]: " base_answer
      OPENAI_BASE_URL="${base_answer:-$OPENAI_BASE_URL}"
      OPENAI_BASE_URL="${OPENAI_BASE_URL%/}"
      [ -n "$OPENAI_BASE_URL" ] || OPENAI_BASE_URL="https://api.openai.com/v1"
    fi
    if [ "$AI_MODEL_SUPPLIED" -eq 0 ] && [ -z "$STORED_AI_MODEL" ]; then
      read_tty "Model name [${AI_MODEL}]: " model_answer
      AI_MODEL="${model_answer:-$AI_MODEL}"
      [ -n "$AI_MODEL" ] || AI_MODEL="gpt-4o-mini"
    fi
    if [ -z "$DISCORD_TOKEN" ]; then
      if [ "$MODE" = "bot" ]; then
        printf '\nBot token: Discord Developer Portal -> your app -> Bot -> Reset Token.\nEnable "Message Content Intent" on the same Bot tab.\n' > /dev/tty
        read_tty "Discord bot token (hidden): " token_answer 1
      else
        printf '\nUser token: browser DevTools -> Application -> Local Storage -> token.\nSelf-bots violate Discord ToS; the account can be banned.\n' > /dev/tty
        read_tty "Discord user token (hidden): " token_answer 1
      fi
      [ -n "$token_answer" ] && DISCORD_TOKEN="$token_answer"
    fi
    if [ "$EXISTING_ENV" -eq 0 ]; then
      read_tty "Your numeric Discord user ID (optional, Enter to skip): " owner_answer
      [ -n "$owner_answer" ] && OWNER_ID_VALUE="${owner_answer//[!0-9]/}"
      read_tty "GIPHY API key (optional, hidden, Enter to skip): " giphy_answer 1
      [ -n "$giphy_answer" ] && GIPHY_API_KEY_VALUE="$giphy_answer"
    fi
  fi

  [ -n "$OPENAI_API_KEY" ] || die "OPENAI_API_KEY is required. Set it in the environment or in ${ENV_FILE}."
  [ -n "$DISCORD_TOKEN" ] || die "DISCORD_TOKEN is required for token mode ${MODE}. Switching modes does not reuse the other mode's token; set it in the environment."
  validate_value "$OPENAI_API_KEY" || die "OPENAI_API_KEY contains a newline."
  validate_value "$DISCORD_TOKEN" || die "DISCORD_TOKEN contains a newline."
  validate_value "$OPENAI_BASE_URL" || die "OPENAI_BASE_URL contains a newline."
  validate_value "$AI_MODEL" || die "AI_MODEL contains a newline."

  # -----------------------------------------------------------------------
  # Docker / socket details
  # -----------------------------------------------------------------------
  if [ "$NO_START" -eq 0 ] && [ "$DOCKER_READY" -eq 0 ]; then
    ensure_docker
    if ! detect_docker; then
      die "Docker is installed but not reachable. Start Docker and make sure ${ACTUAL_USER} can use it."
    fi
    DOCKER_READY=1
  fi
  DOCKER_BIN="$(command -v docker 2>/dev/null || true)"

  detected_gid="$(detect_docker_gid)"
  DOCKER_GID="${DOCKER_GID:-${detected_gid:-$(env_get DOCKER_GID 999)}}"
  case "$DOCKER_GID" in
    ""|*[!0-9]*) DOCKER_GID=999 ;;
  esac

  resolve_docker_config_file
  ensure_compose_plugin

  # -----------------------------------------------------------------------
  # Dashboard login and Watchtower token
  # -----------------------------------------------------------------------
  DASHBOARD_PASSWORD_GENERATED=0
  DASHBOARD_PASSWORD_SET=0
  DASHBOARD_PASSWORD_PLAIN=""
  DASHBOARD_PASSWORD_HASH="$(env_get DASHBOARD_PASSWORD_HASH "")"
  DASHBOARD_SESSION_SECRET="$(env_get DASHBOARD_SESSION_SECRET "")"
  WATCHTOWER_TOKEN="$(env_get WATCHTOWER_TOKEN "")"

  case "$DASHBOARD_PASSWORD_HASH" in
    scrypt\$*) ;;
    "") ;;
    *)
      warn "The existing dashboard hash is not a scrypt hash; it will be replaced."
      DASHBOARD_PASSWORD_HASH=""
      ;;
  esac

  password_override="${DASHBOARD_PASSWORD_ARG:-${DASHBOARD_PASSWORD:-}}"
  if [ -n "$password_override" ]; then
    validate_value "$password_override" || die "DASHBOARD_PASSWORD contains a newline."
    DASHBOARD_PASSWORD_HASH="$(hash_password_value "$password_override")" || die "Could not hash the dashboard password."
    [ -n "$DASHBOARD_PASSWORD_HASH" ] || die "Could not hash the dashboard password."
    DASHBOARD_PASSWORD_SET=1
    DASHBOARD_PASSWORD_PLAIN=""
    # A password reset also invalidates existing login cookies.
    DASHBOARD_SESSION_SECRET=""
  fi

  if [ -z "$DASHBOARD_PASSWORD_HASH" ]; then
    if [ "$NON_INTERACTIVE" -eq 0 ] && [ -z "$password_override" ]; then
      printf '\nSet the dashboard admin password. Press Enter to generate a strong random one.\n' > /dev/tty
      while :; do
        pass_one=""
        pass_two=""
        read_tty "Dashboard password (hidden, Enter = generate): " pass_one 1
        [ -z "$pass_one" ] && break
        read_tty "Repeat dashboard password (hidden): " pass_two 1
        if [ "$pass_one" != "$pass_two" ]; then
          printf 'Passwords do not match. Try again.\n' > /dev/tty
          continue
        fi
        DASHBOARD_PASSWORD_HASH="$(hash_password_value "$pass_one")" || die "Could not hash the dashboard password."
        DASHBOARD_PASSWORD_SET=1
        DASHBOARD_SESSION_SECRET=""
        break
      done
    fi
  fi

  if [ -z "$DASHBOARD_PASSWORD_HASH" ]; then
    generate_login || die "Could not generate the dashboard login."
    DASHBOARD_PASSWORD_GENERATED=1
  fi
  [ -n "$DASHBOARD_SESSION_SECRET" ] || DASHBOARD_SESSION_SECRET="$(generate_secret)" || die "Could not generate a session secret."
  [ -n "$DASHBOARD_SESSION_SECRET" ] || die "Could not generate a session secret."
  [ -n "$WATCHTOWER_TOKEN" ] || WATCHTOWER_TOKEN="$(generate_secret)" || die "Could not generate a Watchtower token."
  [ -n "$WATCHTOWER_TOKEN" ] || die "Could not generate a Watchtower token."
  if [ "$NO_WATCHTOWER" -eq 1 ]; then
    WATCHTOWER_TOKEN=""
  fi

  # -----------------------------------------------------------------------
  # Write .env and prepare host state
  # -----------------------------------------------------------------------
  write_env
  info "Wrote ${ENV_FILE} (mode: ${MODE}, image: ${CONTAINER_TAG})."

  mkdir -p "$TARGET_DIR/data" || die "Could not create ${TARGET_DIR}/data."
  if [ "$(uname -s)" = "Linux" ]; then
    if [ "$(id -u)" -eq 0 ]; then
      chown -R 1000:1000 "$TARGET_DIR/data" 2>/dev/null || true
    elif command -v sudo >/dev/null 2>&1; then
      as_root chown -R 1000:1000 "$TARGET_DIR/data" 2>/dev/null || true
    fi
  fi
  if [ "$(id -u)" -eq 0 ] && [ "$ACTUAL_USER" != "root" ]; then
    chown -R "$ACTUAL_USER:$ACTUAL_GROUP" "$TARGET_DIR" 2>/dev/null || true
    if [ "$(uname -s)" = "Linux" ]; then
      chown -R 1000:1000 "$TARGET_DIR/data" 2>/dev/null || true
    fi
  fi

  ensure_config_file

  # -----------------------------------------------------------------------
  # GHCR login, image pull and start
  # -----------------------------------------------------------------------
  GHCR_TOKEN="${GHCR_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
  GHCR_USER="${GHCR_USER:-${GITHUB_USER:-}}"
  if [ -z "$GHCR_USER" ] && [ -n "$GHCR_TOKEN" ]; then
    GHCR_USER="$(ghcr_user_from_gh)"
  fi

  if [ "$NO_START" -eq 0 ]; then
    if [ "$IMAGE_PREPARED" -eq 0 ]; then
      if [ -n "$GHCR_TOKEN" ]; then
        if [ -z "$GHCR_USER" ]; then
          if [ "$NON_INTERACTIVE" -eq 1 ]; then
            die "Set GHCR_USER to the GitHub account that owns GHCR_TOKEN (or authenticate gh)."
          fi
          prompt_ghcr_user
        fi
        if docker_login "$GHCR_TOKEN" "$GHCR_USER"; then
          info "Logged in to GHCR as ${GHCR_USER}."
        else
          warn "GHCR login failed for ${GHCR_USER}; trying the existing Docker login."
        fi
      fi

      PULL_OK=0
      if pull_images; then
        PULL_OK=1
      else
        if [ "$NON_INTERACTIVE" -eq 0 ] && [ "$HAS_TTY" -eq 1 ]; then
          printf '\nThe private image could not be pulled. A classic PAT with read:packages is needed.\n' > /dev/tty
          read_tty "GHCR token with read:packages (hidden, Enter to skip): " pull_token 1
          if [ -n "$pull_token" ]; then
            if [ -z "$GHCR_USER" ]; then
              prompt_ghcr_user || true
            fi
            if [ -z "$GHCR_USER" ]; then
              warn "No GitHub username supplied; cannot log in to GHCR."
            elif docker_login "$pull_token" "$GHCR_USER"; then
              info "Logged in to GHCR as ${GHCR_USER}."
              if pull_images; then
                PULL_OK=1
              fi
            else
              warn "GHCR login failed with the supplied token."
            fi
          fi
        fi
      fi
      if ! image_exists; then
        die "The private image ${IMAGE_REF} is not available. Set GHCR_TOKEN (read:packages) and GHCR_USER, then re-run."
      fi
      if [ "$PULL_OK" -eq 0 ]; then
        warn "Could not pull the current image; starting the local copy. Set GHCR_TOKEN (read:packages) to update it."
      fi
    fi

    info "Starting the Compose stack..."
    if [ "$NO_WATCHTOWER" -eq 1 ]; then
      compose stop watchtower >/dev/null 2>&1 || true
      compose up -d --remove-orphans bot dashboard || die "docker compose up failed."
    else
      compose up -d --remove-orphans || die "docker compose up failed."
    fi
    compose ps || true

    local i=0
    while [ "$i" -lt 30 ]; do
      if docker_run inspect -f '{{.State.Running}}' ai-discord-bot-dashboard 2>/dev/null | grep -q true; then
        break
      fi
      i=$((i + 1))
      sleep 2
    done
    if ! docker_run inspect -f '{{.State.Running}}' ai-discord-bot-dashboard 2>/dev/null | grep -q true; then
      warn "The dashboard did not report running within 60 seconds."
      compose logs --tail=40 dashboard 2>/dev/null || true
    fi
  fi

  # -----------------------------------------------------------------------
  # CLI link
  # -----------------------------------------------------------------------
  CLI_PATH=""
  if [ "$NO_CLI" -eq 0 ]; then
    chmod +x "$TARGET_DIR/tools/discord-bot" 2>/dev/null || true
    if [ ! -e /usr/local/bin/discord-bot ] || [ -L /usr/local/bin/discord-bot ]; then
      if as_root ln -sfn "$TARGET_DIR/tools/discord-bot" /usr/local/bin/discord-bot 2>/dev/null; then
        CLI_PATH="/usr/local/bin/discord-bot"
      fi
    fi
    if [ -z "$CLI_PATH" ]; then
      mkdir -p "${ACTUAL_HOME}/.local/bin" 2>/dev/null || true
      if ln -sfn "$TARGET_DIR/tools/discord-bot" "${ACTUAL_HOME}/.local/bin/discord-bot" 2>/dev/null; then
        CLI_PATH="${ACTUAL_HOME}/.local/bin/discord-bot"
      fi
    fi
    if [ "$(id -u)" -eq 0 ] && [ "$ACTUAL_USER" != "root" ] && [ -n "$CLI_PATH" ]; then
      chown -h "$ACTUAL_USER:$ACTUAL_GROUP" "$CLI_PATH" 2>/dev/null || true
    fi
  fi

  # -----------------------------------------------------------------------
  # Summary
  # -----------------------------------------------------------------------
  if [ "$DASHBOARD_HOST_IP" = "0.0.0.0" ]; then
    DASHBOARD_URL="http://127.0.0.1:${DASHBOARD_PORT}"
  else
    DASHBOARD_URL="http://${DASHBOARD_HOST_IP}:${DASHBOARD_PORT}"
  fi

  if [ "$NO_START" -eq 1 ]; then
    printf '\n%sAI Discord Bot is configured%s\n' "$BOLD" "$RESET"
  else
    printf '\n%sAI Discord Bot is ready%s\n' "$BOLD" "$RESET"
  fi
  printf '  install:    %s\n' "$TARGET_DIR"
  if [ "$IMAGE_ONLY" -eq 1 ]; then
    printf '  source:     image only (%s)\n' "$IMAGE_REF"
  fi
  printf '  mode:       %s (%s)\n' "$MODE" "$CONTAINER_TAG"
  printf '  dashboard:  %s\n' "$DASHBOARD_URL"
  printf '  login:      %s\n' "$DASHBOARD_USER"
  if [ "$DASHBOARD_PASSWORD_GENERATED" -eq 1 ]; then
    printf '  password:   %s\n' "$DASHBOARD_PASSWORD_PLAIN"
    printf '  %sSave the password now; it is not stored in plaintext.%s\n' "$DIM" "$RESET"
  elif [ "$DASHBOARD_PASSWORD_SET" -eq 1 ]; then
    printf '  password:   set to the value you supplied\n'
  else
    printf '  password:   unchanged (set DASHBOARD_PASSWORD=... and re-run to reset)\n'
  fi
  printf '  data:       %s/data (kept across updates)\n' "$TARGET_DIR"
  if [ "$NO_WATCHTOWER" -eq 1 ]; then
    printf '  watchtower: not started; the dashboard update action is disabled\n'
  else
    printf '  watchtower: enabled for the labeled bot container\n'
  fi
  if [ -n "$CLI_PATH" ]; then
    printf '  cli:        %s\n' "$CLI_PATH"
  fi
  if [ "$DASHBOARD_HOST_IP" = "127.0.0.1" ]; then
    printf '\n%sThe dashboard is local-only. Set DASHBOARD_HOST_IP to a Tailscale or private LAN address to reach it remotely.%s\n' "$DIM" "$RESET"
  elif [ "$DASHBOARD_HOST_IP" = "0.0.0.0" ]; then
    printf '\n%sThe dashboard is published on every interface. Keep the login strong and firewall the port.%s\n' "$YELLOW" "$RESET"
  fi
  if [ "$MODE" = "user" ]; then
    printf '\n%sSelf-bot mode violates Discord ToS and can get the account banned.%s\n' "$YELLOW" "$RESET"
  fi

  if [ "$NO_START" -eq 1 ]; then
    printf '\n%sNot started (%s). Start it with:%s\n' "$DIM" "--no-start" "$RESET"
    printf '  cd %s && docker compose up -d\n' "$TARGET_DIR"
  else
    printf '\n%sNext:%s\n' "$BOLD" "$RESET"
    if [ -n "$CLI_PATH" ]; then
      printf '  discord-bot status\n  discord-bot logs bot -f\n  discord-bot update\n'
    else
      printf '  cd %s\n  docker compose ps\n  docker compose logs -f bot\n' "$TARGET_DIR"
    fi
    if [ "$IMAGE_ONLY" -eq 1 ]; then
      printf '\nRe-run this installer to pull a new image; .env and data/ are preserved.\n'
    else
      printf '\nRe-run this installer to update the checkout and images; .env and data/ are preserved.\n'
    fi
  fi
}

main "$@"
