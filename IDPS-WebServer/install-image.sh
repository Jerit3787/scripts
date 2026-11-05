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
# The checkout owner: the host updater's unit runs as this user, so its Docker credentials and files must
# belong to it. Plain `bash` uses the invoking user; `sudo bash` uses SUDO_USER (never root).
OWNER="${SUDO_USER:-$(id -un)}"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
OWNER_GROUP="$(id -gn "$OWNER" 2>/dev/null || echo "$OWNER")"

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
  [ -z "$STAGING" ] || as_root rm -rf "$STAGING" 2>/dev/null || true
}
trap cleanup EXIT

# A fresh cloud image's first boot runs cloud-init/unattended-upgrades, holding the apt lock for minutes.
wait_apt() {
  command -v pgrep >/dev/null 2>&1 || return 0
  local i
  for i in $(seq 1 150); do
    if ! pgrep -x apt-get >/dev/null 2>&1 && ! pgrep -x apt >/dev/null 2>&1 \
       && ! pgrep -x dpkg >/dev/null 2>&1 && ! pgrep -x unattended-upgr >/dev/null 2>&1; then
      return 0
    fi
    [ "$i" -eq 1 ] && say "Waiting for the package manager to finish..."
    sleep 2
  done
  say "The package manager is still busy; continuing."
}

ensure_owner_docker_group() {
  if ! id -nG "$OWNER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    as_root usermod -aG docker "$OWNER" >/dev/null 2>&1 || true
  fi
}

ensure_docker() {
  # The bootstrap runs Docker as root; checking compose as the invoking user would fail on a fresh install
  # before the new docker group reaches this shell.
  if command -v docker >/dev/null 2>&1 && as_root docker compose version >/dev/null 2>&1; then
    ensure_owner_docker_group
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || die "Docker is missing and curl isn't available to install it"
    say "Installing Docker Engine and the Compose plugin..."
    wait_apt
    as_root sh -c 'curl -fsSL https://get.docker.com | sh' || die "Docker install failed"
  fi
  as_root docker compose version >/dev/null 2>&1 || {
    wait_apt
    if command -v apt-get >/dev/null 2>&1; then
      as_root apt-get update -q && as_root apt-get install -y docker-compose-plugin
    elif command -v dnf >/dev/null 2>&1; then
      as_root dnf install -y docker-compose-plugin
    fi
    as_root docker compose version >/dev/null 2>&1 || die "Docker Compose v2 (docker compose) is missing"
  }
  ensure_owner_docker_group
}

ensure_python() {
  command -v python3 >/dev/null 2>&1 && return 0
  wait_apt
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
  # The bootstrap's docker commands run as root, but hostd runs as OWNER. Persist the same login in the
  # owner's Docker config too; otherwise Updates/Evaluation see "no Docker token for ghcr.io".
  if [ "$OWNER" != "root" ]; then
    [ -n "$OWNER_HOME" ] || die "Could not find the home directory of $OWNER"
    as_root mkdir -p "$OWNER_HOME/.docker"
    printf '%s' "$TOKEN" | as_root docker --config "$OWNER_HOME/.docker" login ghcr.io -u "$GHCR_USER" \
      --password-stdin >/dev/null || die "GHCR login failed for $OWNER"
    as_root chown -R "$OWNER:$OWNER_GROUP" "$OWNER_HOME/.docker"
  fi
}

run_setup() {
  local -a cmd=(./scripts/setup.sh --image-only --run containers "$@")
  local quoted
  quoted="$(printf '%q ' "${cmd[@]}")"
  # A fresh docker group doesn't reach this shell. `sg` runs setup as the owner with that group, so the
  # compose calls and the hostd venv work without asking for a new login.
  if [ "$OWNER" = "$(id -un)" ] && ! id -nG | tr ' ' '\n' | grep -qx docker \
     && command -v sg >/dev/null 2>&1 && sg docker -c true >/dev/null 2>&1; then
    ( cd "$INSTALL_DIR" && sg docker -c "$quoted" )
  else
    ( cd "$INSTALL_DIR" && "${cmd[@]}" )
  fi
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

as_root mkdir -p "$INSTALL_DIR"
as_root chown "$OWNER:$OWNER_GROUP" "$INSTALL_DIR"

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
# The staged files are root-owned (docker cp); merge as root, then hand the tree to the owner so hostd's
# user can replace managed files during an update.
as_root bash "$STAGING/scripts/host_bundle.sh" install "$STAGING" "$INSTALL_DIR" || die "Host bundle merge failed"
as_root chown -R "$OWNER:$OWNER_GROUP" "$INSTALL_DIR"

[ -x "$INSTALL_DIR/scripts/setup.sh" ] || die "The merged host bundle has no executable scripts/setup.sh"
say "Starting the image-only host setup..."
run_setup "$@"
setup_rc=$?
# setup.sh runs hostd as the checkout owner; if this bootstrap ran as root (sudo), the files it wrote are
# root-owned. Hand them over and restart hostd so it can read deploy/.env and write managed files.
as_root chown -R "$OWNER:$OWNER_GROUP" "$INSTALL_DIR" 2>/dev/null || true
project="$(awk -F= '$1 == "CAIDPS_COMPOSE_PROJECT" { print substr($0, index($0, "=") + 1); exit }' \
  "$INSTALL_DIR/deploy/.env" 2>/dev/null || true)"
unit="caidps-hostd"
[ -z "$project" ] || [ "$project" = "caidps" ] || unit="caidps-hostd-$project"
as_root systemctl restart "$unit" >/dev/null 2>&1 || true
exit "$setup_rc"
