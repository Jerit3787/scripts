#!/usr/bin/env bash
# CAIDPS image-only installer.
#
#   curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/install-image.sh | \
#     CAIDPS_GHCR_TOKEN=... CAIDPS_GHCR_USER=... bash -s -- --non-interactive --profile production --run containers
#
# It never clones the repository. It pulls the released app image, extracts /app/host-bundle, merges the
# host tooling without touching .env/cloudflared/certs/backups, and hands off to the image-only setup.
set -u

INSTALL_DIR="${CAIDPS_INSTALL_DIR:-/opt/caidps}"
VERSION="${CAIDPS_VERSION:-latest}"
APP_IMAGE_REPO="${CAIDPS_APP_IMAGE:-ghcr.io/jerit3787/caidps-app}"
IMAGE_REF="${APP_IMAGE_REPO}:${VERSION}"
TOKEN="${CAIDPS_GHCR_TOKEN:-}"
GHCR_USER="${CAIDPS_GHCR_USER:-}"
BUNDLE_CONTAINER=""
STAGING=""

usage() {
  cat <<'EOF'
Usage:
  curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/install-image.sh | \
    CAIDPS_GHCR_TOKEN=... CAIDPS_GHCR_USER=... bash -s -- [setup.sh options]

Environment:
  CAIDPS_GHCR_TOKEN   classic PAT with read:packages (private GHCR packages)
  CAIDPS_GHCR_USER    GitHub account for the token (or an authenticated gh)
  CAIDPS_VERSION      release to install (default: latest)
  CAIDPS_INSTALL_DIR  install path (default: /opt/caidps)
  CAIDPS_APP_IMAGE    image repository override (default: ghcr.io/jerit3787/caidps-app)
  CAIDPS_TUNNEL_*     passed to the host setup (token/login/none and hostnames)

Options after -- are forwarded to the extracted scripts/setup.sh. This installer always uses
--image-only --run containers; a checkout at CAIDPS_INSTALL_DIR is refused.
EOF
}

say() { printf '[image-install] %s\n' "$*"; }
die() { printf '[image-install] %s\n' "$*" >&2; exit 1; }
refuse() { printf '[image-install] %s\n' "$*" >&2; exit 2; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; elif command -v sudo >/dev/null 2>&1; then sudo "$@"; else die "root or sudo is needed for: $*"; fi
}

cleanup() {
  [ -z "$BUNDLE_CONTAINER" ] || as_root docker rm -f "$BUNDLE_CONTAINER" >/dev/null 2>&1 || true
  [ -z "$STAGING" ] || rm -rf "$STAGING"
}
trap cleanup EXIT

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || die "Docker is missing and curl isn't available to install it"
    say "Installing Docker Engine and the Compose plugin..."
    as_root sh -c 'curl -fsSL https://get.docker.com | sh' || die "Docker install failed"
  fi
  docker compose version >/dev/null 2>&1 || {
    if command -v apt-get >/dev/null 2>&1; then
      as_root apt-get update -q && as_root apt-get install -y docker-compose-plugin
    elif command -v dnf >/dev/null 2>&1; then
      as_root dnf install -y docker-compose-plugin
    fi
    docker compose version >/dev/null 2>&1 || die "Docker Compose v2 (docker compose) is missing"
  }
}

ensure_python() {
  command -v python3 >/dev/null 2>&1 && return 0
  if command -v apt-get >/dev/null 2>&1; then
    as_root apt-get update -q && as_root apt-get install -y python3 python3-venv
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y python3 python3-virtualenv
  elif command -v apk >/dev/null 2>&1; then
    as_root apk add --no-cache python3 py3-virtualenv
  fi
  command -v python3 >/dev/null 2>&1 || die "Python 3 is required for the host updater"
}

ensure_cloudflared() {
  [ "${CAIDPS_TUNNEL_MODE:-none}" = "login" ] || return 0
  command -v cloudflared >/dev/null 2>&1 && return 0
  command -v curl >/dev/null 2>&1 || die "cloudflared is needed for tunnel login and curl isn't available"
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported architecture for cloudflared: $(uname -m)" ;;
  esac
  as_root curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" \
    -o /usr/local/bin/cloudflared || die "cloudflared download failed"
  as_root chmod +x /usr/local/bin/cloudflared
}

login() {
  [ -n "$TOKEN" ] || return 0
  if [ -z "$GHCR_USER" ] && command -v gh >/dev/null 2>&1; then
    GHCR_USER="$(gh api user --jq .login 2>/dev/null || true)"
  fi
  [ -n "$GHCR_USER" ] || die "CAIDPS_GHCR_TOKEN is set but CAIDPS_GHCR_USER is empty and gh cannot resolve the account"
  printf '%s' "$TOKEN" | as_root docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null \
    || die "GHCR login failed for $GHCR_USER"
}

image_version() {
  as_root docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null || true
}
image_platform() {
  as_root docker image inspect --format '{{.Os}}/{{.Architecture}}' "$1" 2>/dev/null || true
}
version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]
}

[ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] && { usage; exit 0; }

# The image-only bootstrap must never convert or overwrite a repository checkout.
if [ -d "$INSTALL_DIR/.git" ]; then
  refuse "Refusing to install into the repository checkout at $INSTALL_DIR. Use the repo-based setup.sh, or choose another CAIDPS_INSTALL_DIR."
fi

ensure_docker
ensure_python
ensure_cloudflared
login

mkdir -p "$INSTALL_DIR"

if [ -f "$INSTALL_DIR/VERSION" ] && [ "$VERSION" != "latest" ]; then
  old="$(tr -d '[:space:]' < "$INSTALL_DIR/VERSION")"
  if version_lt "$VERSION" "$old"; then
    refuse "Refusing to install an older version of CAIDPS (downgrade) from $old to $VERSION; use the current or a newer release."
  fi
fi

say "Pulling $IMAGE_REF..."
as_root docker pull "$IMAGE_REF" >/dev/null || die "Could not pull $IMAGE_REF (is the GHCR token valid and read:packages?)"

actual="$(image_version "$IMAGE_REF")"
[ -n "$actual" ] && [ "$actual" != "<no value>" ] || die "$IMAGE_REF has no version label"
want_platform="linux/$(case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) uname -m ;; esac)"
platform="$(image_platform "$IMAGE_REF")"
[ "$platform" = "$want_platform" ] || die "$IMAGE_REF is $platform, not $want_platform"
if [ -f "$INSTALL_DIR/VERSION" ]; then
  old="$(tr -d '[:space:]' < "$INSTALL_DIR/VERSION")"
  if version_lt "$actual" "$old"; then
    refuse "Refusing to install an older version of CAIDPS (downgrade) from $old to $actual."
  fi
fi

as_root docker tag "$IMAGE_REF" caidps-app:latest || die "Could not tag caidps-app:latest"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/caidps-host-bundle.XXXXXX")" || die "Could not create a staging directory"
BUNDLE_CONTAINER="caidps-host-bundle-$$-$(date +%s)"
as_root docker create --name "$BUNDLE_CONTAINER" "$IMAGE_REF" >/dev/null || die "Could not create the bundle container"
as_root docker cp "$BUNDLE_CONTAINER:/app/host-bundle/." "$STAGING/" || die "Could not extract /app/host-bundle"
as_root docker rm -f "$BUNDLE_CONTAINER" >/dev/null 2>&1 || true
BUNDLE_CONTAINER=""
[ -s "$STAGING/VERSION" ] || die "The image's /app/host-bundle has no VERSION"
bash "$STAGING/scripts/host_bundle.sh" install "$STAGING" "$INSTALL_DIR" || die "Host bundle merge failed"

[ -x "$INSTALL_DIR/scripts/setup.sh" ] || die "The merged host bundle has no executable scripts/setup.sh"
say "Starting the image-only host setup..."
( cd "$INSTALL_DIR" && ./scripts/setup.sh --image-only --run containers "$@" )
