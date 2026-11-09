#!/usr/bin/env bash
# AI Discord Bot image-only installer.
#
# Pulls the released image, extracts its /app/host-bundle (Compose file and
# host tools), and runs the normal setup flow. It never clones the repository.
#
#   curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/install-image.sh | \
#     GHCR_TOKEN='<read:packages>' GHCR_USER='<your GitHub username>' bash
#
# The same flags and environment as setup.sh are accepted, for example:
#   ... | bash -s -- --non-interactive --no-start
set -eu

SETUP_URL="https://scripts.danplace.tech/AI-Discord-Bot/setup.sh"

usage() {
  cat <<'EOF'
Usage:
  curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/install-image.sh | bash
  curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/install-image.sh | bash -s -- [options]

The image-only installer pulls the private GHCR image and extracts the Compose
file and host tools from /app/host-bundle. It never clones the repository.
Existing .env and data/ are preserved on re-runs.

Environment:
  GHCR_TOKEN                 PAT with read:packages for the private image.
  GHCR_USER                  Your GitHub username (the account that owns the token).
  AI_DISCORD_BOT_INSTALL_DIR Install path (default /opt/ai-discord-bot on Linux).
  AI_DISCORD_BOT_NON_INTERACTIVE=1  No prompts; CI=1 also works.
  TOKEN_MODE, DISCORD_TOKEN, OPENAI_API_KEY, OPENAI_BASE_URL, AI_MODEL
  DASHBOARD_HOST_IP, DASHBOARD_PORT, DASHBOARD_USER, DASHBOARD_PASSWORD
  DOCKER_GID, DOCKER_CONFIG_FILE, GHCR_OWNER, CONTAINER_TAG

Options:
  --non-interactive          Take defaults; required values come from the environment.
  --dir PATH                 Install path.
  --token-mode bot|user      Discord token type (default bot).
  --dashboard-ip IP          Host interface to publish the dashboard on.
  --dashboard-port PORT      Dashboard port on the host and inside the container.
  --dashboard-password VALUE Reset the dashboard password.
  --no-watchtower            Start only the bot and dashboard.
  --no-cli                   Do not link the discord-bot command.
  --no-start                 Configure .env and data, but do not start. Image-only still pulls once to extract.
  --dry-run                  Print the plan; pull, write and start nothing.
  --help, -h                 Show this help.

The image-only flow uses Python 3 on the host only to generate the dashboard
login, exactly like the full installer; the bot itself runs from the image.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
  esac
done

command -v curl >/dev/null 2>&1 || {
  echo "[error] curl is required to download the installer." >&2
  exit 1
}
command -v bash >/dev/null 2>&1 || {
  echo "[error] bash is required." >&2
  exit 1
}

tmp="$(mktemp "${TMPDIR:-/tmp}/ai-bot-image-install.XXXXXX")" || {
  echo "[error] Could not create a temporary file." >&2
  exit 1
}
trap 'rm -f "$tmp"' EXIT

# A query string keeps a cached setup.sh from an earlier deploy out of the
# image-only path.
if ! curl -fsSL "${SETUP_URL}?v=$(date +%s)" -o "$tmp"; then
  echo "[error] Could not download $SETUP_URL." >&2
  exit 1
fi

bash "$tmp" --image-only "$@"
