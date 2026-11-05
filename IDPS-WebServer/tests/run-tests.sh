#!/usr/bin/env bash
# Stub-driven tests for the CAIDPS installer and reset scripts.
# Run from the scripts repo root: bash IDPS-WebServer/tests/run-tests.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$ROOT/setup.sh"
RESET="$ROOT/reset.sh"
INSTALL_IMAGE="$ROOT/install-image.sh"
ORIG_PATH="$PATH"

if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ] && [ "${CAIDPS_TEST_ALLOW_HOST:-0}" != "1" ]; then
  echo "Refusing to run outside a container: these tests exercise teardown paths under /opt, /etc/systemd and /usr/local." >&2
  echo "Run them as documented, or set CAIDPS_TEST_ALLOW_HOST=1 on a disposable host." >&2
  exit 2
fi

BASE="${TMPDIR:-/tmp}/scripts-tests.$$"
PASS=0
FAIL=0
CASE_DIR=""
CASE_LOG=""

cleanup() {
  rm -rf "$BASE"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); say "ok - $1"; }
not_ok() { FAIL=$((FAIL + 1)); say "not ok - $1"; [ -n "${2:-}" ] && say "  $2"; }

new_case() {
  CASE_DIR="$BASE/$1"
  CASE_LOG="$CASE_DIR/log/cmd.log"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/home" "$CASE_DIR/log" "$CASE_DIR/tmp"
  : > "$CASE_LOG"
}

write_stub() { # write_stub <name> reads the body from stdin
  local name="$1"
  cat > "$CASE_DIR/bin/$name"
  chmod +x "$CASE_DIR/bin/$name"
}

make_stubs() {
  write_stub git <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$CAIDPS_TEST_LOG"
case "$1" in
  lfs) exit 0 ;;
  clone)
    if [ "${CAIDPS_TEST_FAIL_CLONE:-0}" = "1" ]; then exit 1; fi
    target="${!#}"
    mkdir -p "$target/scripts" "$target/prototype/backend/venv/bin" "$target/deploy"
    : > "$target/scripts/serve.sh"
    cat > "$target/scripts/caidps" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    cat > "$target/scripts/setup.sh" <<'STUB'
#!/usr/bin/env bash
printf 'WIZARD_CWD:%s\n' "$PWD" >> "$CAIDPS_TEST_LOG"
printf 'WIZARD_ARGS:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
STUB
    cat > "$target/scripts/service.sh" <<'STUB'
#!/usr/bin/env bash
printf 'SERVICE_CWD:%s\n' "$PWD" >> "$CAIDPS_TEST_LOG"
printf 'SERVICE_ARGS:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
STUB
    cat > "$target/scripts/hostd.sh" <<'STUB'
#!/usr/bin/env bash
printf 'HOSTD_ARGS:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
STUB
    cat > "$target/scripts/backup.sh" <<'STUB'
#!/usr/bin/env bash
printf 'BACKUP_ARGS:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
STUB
    cat > "$target/prototype/backend/venv/bin/python" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-c" ]; then
  printf 'VENV_ARGS:%s\n' "${2:-}" >> "$CAIDPS_TEST_LOG"
fi
exit 0
STUB
    chmod +x "$target/scripts/"*.sh "$target/scripts/caidps" "$target/prototype/backend/venv/bin/python"
    exit 0
    ;;
  config)
    case "$*" in *--get-all*) exit 1 ;; *) exit 0 ;; esac
    ;;
  *) exit 0 ;;
esac
EOF

  write_stub gh <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

  write_stub docker <<'EOF'
#!/usr/bin/env bash
printf 'DOCKER:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
if [ "${CAIDPS_TEST_LEFTOVER:-0}" = "1" ] && [ "${1:-}" = "ps" ]; then
  echo caidps-backend-1
fi
case "${1:-}" in
  compose|info|ps|volume|rm) exit 0 ;;
  *) exit 0 ;;
esac
EOF

  write_stub node <<'EOF'
#!/usr/bin/env bash
printf 'NODE:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
EOF

  write_stub npm <<'EOF'
#!/usr/bin/env bash
printf 'NPM:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
EOF

  write_stub ln <<'EOF'
#!/usr/bin/env bash
printf 'LN:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
EOF

  write_stub sudo <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -u|--user|-H) shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
exec "$@"
EOF

  write_stub systemctl <<'EOF'
#!/usr/bin/env bash
printf 'SYSTEMCTL:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
EOF

  write_stub pgrep <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

  write_stub kill <<'EOF'
#!/usr/bin/env bash
printf 'KILL:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
EOF

  write_stub psql <<'EOF'
#!/usr/bin/env bash
printf 'PSQL:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
case "$*" in
  *"SELECT 1 FROM pg_database"*|*"SELECT 1 FROM pg_roles"*) exit 1 ;;
  *) exit 0 ;;
esac
EOF

  write_stub dropdb <<'EOF'
#!/usr/bin/env bash
printf 'DROPDB:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
EOF

  write_stub dropuser <<'EOF'
#!/usr/bin/env bash
printf 'DROPUSER:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
EOF

  write_stub runuser <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
[ "$1" = "--" ] && shift
exec "$@"
EOF

  write_stub cloudflared <<'EOF'
#!/usr/bin/env bash
printf 'CLOUDFLARED:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
EOF

  write_stub getent <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

  write_stub groupadd <<'EOF'
#!/usr/bin/env bash
printf 'GROUPADD:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
EOF

  write_stub usermod <<'EOF'
#!/usr/bin/env bash
printf 'USERMOD:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
EOF
}

run_script() { # run_script <script> [args...]
  local script="$1"
  shift
  ( cd "$CASE_DIR" && \
    PATH="$CASE_DIR/bin:$ORIG_PATH" \
    HOME="$CASE_DIR/home" \
    TMPDIR="$CASE_DIR/tmp" \
    CAIDPS_TEST_LOG="$CASE_LOG" \
    bash "$script" "$@" ) > "$CASE_DIR/log/out" 2>&1
  rc=$?
}

assert_rc() {
  if [ "$rc" -eq "$1" ]; then ok "$2"; else not_ok "$2" "expected exit $1, got $rc: $(cat "$CASE_DIR/log/out")"; fi
}
assert_out_contains() {
  if grep -Fq -- "$1" "$CASE_DIR/log/out"; then ok "$2"; else not_ok "$2" "output did not contain '$1': $(cat "$CASE_DIR/log/out")"; fi
}
assert_log_contains() {
  if grep -Fq -- "$1" "$CASE_LOG"; then ok "$2"; else not_ok "$2" "log did not contain '$1': $(cat "$CASE_LOG")"; fi
}
assert_log_not_contains() {
  if grep -Fq -- "$1" "$CASE_LOG"; then not_ok "$2" "log unexpectedly contained '$1'"; else ok "$2"; fi
}

test_help() {
  new_case help
  make_stubs
  run_script "$SETUP" --help
  assert_rc 0 "help: exits 0"
  assert_out_contains "Usage:" "help: prints usage"
  assert_out_contains "--run containers" "help: documents the container mode"
  assert_log_not_contains "git clone" "help: does not clone"
}

test_install_all_rejected() {
  new_case install-all
  make_stubs
  run_script "$SETUP" --install-all
  assert_rc 2 "install-all: exits 2"
  assert_out_contains "serve.sh --install-all" "install-all: points at the serve.sh flag"
  assert_log_not_contains "git clone" "install-all: does not clone"
}

test_non_interactive_defaults() {
  new_case noninteractive
  make_stubs
  CAIDPS_NON_INTERACTIVE=1 CAIDPS_INSTALL_DIR="$CASE_DIR/install" CAIDPS_BRANCH="test-branch" \
    run_script "$SETUP" --no-link-cli
  assert_rc 0 "non-interactive: exits 0"
  assert_log_contains "WIZARD_ARGS:--no-link-cli --non-interactive --profile production --run containers" "non-interactive: appends current production/container flags"
  assert_log_contains "git clone --depth 1 -b test-branch" "branch: uses CAIDPS_BRANCH"
  assert_log_contains "$CASE_DIR/install" "install-dir: clones into CAIDPS_INSTALL_DIR"
  assert_log_not_contains "LN:-sf" "no-link-cli: does not link the CLI"
}

test_systemd_unattended() {
  new_case systemd
  make_stubs
  CAIDPS_NON_INTERACTIVE=1 CAIDPS_INSTALL_DIR="$CASE_DIR/install" \
    run_script "$SETUP" --no-link-cli --run systemd --install-local
  assert_rc 0 "systemd: exits 0"
  assert_log_contains "WIZARD_ARGS:--no-link-cli --run systemd --install-local --non-interactive --profile production" "systemd: keeps explicit flags and adds production/non-interactive"
  assert_log_not_contains "WIZARD_ARGS:--run containers" "systemd: does not force containers"
  assert_log_contains "DOCKER:compose version" "systemd: checks Docker"
  assert_log_contains "NODE:--version" "systemd: checks Node"
  assert_log_contains "VENV_ARGS:import sqlalchemy" "systemd: checks the backend venv"
  assert_log_contains "SERVICE_ARGS:install" "systemd: installs the service"
  assert_log_not_contains "LN:-sf" "systemd/no-link-cli: does not link the CLI"
}

make_fake_install() { # make_fake_install <dir> <containers|systemd|systemd-external>
  local dir="$1" kind="$2"
  mkdir -p "$dir/scripts" "$dir/prototype/backend" "$dir/deploy"
  : > "$dir/scripts/serve.sh"
  : > "$dir/deploy/compose.yml"
  cat > "$dir/scripts/service.sh" <<'STUB'
#!/usr/bin/env bash
printf 'SERVICE_ARGS:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
STUB
  cat > "$dir/scripts/hostd.sh" <<'STUB'
#!/usr/bin/env bash
printf 'HOSTD_ARGS:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
STUB
  cat > "$dir/scripts/backup.sh" <<'STUB'
#!/usr/bin/env bash
printf 'BACKUP_ARGS:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
exit 0
STUB
  chmod +x "$dir/scripts/"*.sh

  case "$kind" in
    containers)
      cat > "$dir/deploy/.env" <<'ENV'
CAIDPS_INSTALL=containers
CAIDPS_COMPOSE_PROJECT=caidps-test
ENV
      ;;
    systemd)
      cat > "$dir/prototype/backend/.env" <<'ENV'
CAIDPS_PROFILE=production
CAIDPS_DATABASE_URL=postgresql://caidps:pw@127.0.0.1:5432/caidps
CAIDPS_REDIS_URL=redis://:pw@127.0.0.1:6379/0
ENV
      ;;
    systemd-external)
      cat > "$dir/prototype/backend/.env" <<'ENV'
CAIDPS_PROFILE=production
CAIDPS_DATABASE_URL=postgresql://caidps:pw@db.example.com:5432/caidps
CAIDPS_REDIS_URL=redis://:pw@cache.example.com:6379/0
ENV
      ;;
  esac
}

test_reset_containers() {
  new_case reset-containers
  make_stubs
  make_fake_install "$CASE_DIR/install" containers
  run_script "$RESET" --yes --dir "$CASE_DIR/install"
  assert_rc 0 "reset containers: exits 0"
  assert_log_contains "HOSTD_ARGS:remove --project caidps-test" "reset containers: removes the host updater"
  assert_log_contains "BACKUP_ARGS:timer remove --containers --project caidps-test" "reset containers: removes the backup timer"
  assert_log_contains "DOCKER:compose" "reset containers: uses compose down"
  assert_log_contains "--volumes" "reset containers: deletes the data volumes"
  assert_log_contains "caidps-test" "reset containers: uses the project name"
  assert_log_contains "DOCKER:ps -a --filter label=com.docker.compose.project=caidps-test" "reset containers: verifies the compose project after teardown"
  if [ ! -e "$CASE_DIR/install" ]; then ok "reset containers: removes the checkout"; else not_ok "reset containers: removes the checkout"; fi
}

test_reset_systemd() {
  new_case reset-systemd
  make_stubs
  make_fake_install "$CASE_DIR/install" systemd
  run_script "$RESET" --yes --dir "$CASE_DIR/install"
  assert_rc 0 "reset systemd: exits 0"
  assert_log_contains "SERVICE_ARGS:remove" "reset systemd: removes the service and timer"
  assert_log_contains "DROP DATABASE IF EXISTS caidps" "reset systemd: drops the local database"
  assert_log_contains "DROP ROLE IF EXISTS caidps" "reset systemd: drops the local role"
  assert_log_contains "SELECT 1 FROM pg_database WHERE datname = 'caidps'" "reset systemd: verifies the local database after teardown"
  assert_log_contains "SELECT 1 FROM pg_roles WHERE rolname = 'caidps'" "reset systemd: verifies the local role after teardown"
  assert_log_not_contains "DOCKER:compose" "reset systemd: does not tear down a compose stack"
  if [ ! -e "$CASE_DIR/install" ]; then ok "reset systemd: removes the checkout"; else not_ok "reset systemd: removes the checkout"; fi
}

test_reset_external_db() {
  new_case reset-external
  make_stubs
  make_fake_install "$CASE_DIR/install" systemd-external
  run_script "$RESET" --yes --dir "$CASE_DIR/install"
  assert_rc 0 "reset external DB: exits 0"
  assert_out_contains "not touched" "reset external DB: reports the external database as manual"
  assert_log_not_contains "DROP DATABASE IF EXISTS caidps" "reset external DB: never drops an external database"
  if [ ! -e "$CASE_DIR/install" ]; then ok "reset external DB: removes the checkout"; else not_ok "reset external DB: removes the checkout"; fi
}

test_unattended_requires_auth() {
  new_case unattended-auth
  make_stubs
  CAIDPS_NON_INTERACTIVE=1 CAIDPS_INSTALL_DIR="$CASE_DIR/install" CAIDPS_TEST_FAIL_CLONE=1 \
    run_script "$SETUP" --no-link-cli
  assert_rc 1 "unattended auth: fails without credentials"
  assert_out_contains "GITHUB_TOKEN" "unattended auth: names the token variables"
  assert_out_contains "non-interactive" "unattended auth: explains the non-interactive failure"
  assert_log_not_contains "WIZARD_ARGS:" "unattended auth: never reaches the wizard"
}

test_conflicting_flags() {
  new_case conflict-containers
  make_stubs
  run_script "$SETUP" --run containers --install-local
  assert_rc 2 "conflict containers/systemd: exits 2"
  assert_out_contains "--run containers cannot" "conflict containers/systemd: explains the conflict"
  assert_log_not_contains "git clone" "conflict containers/systemd: does not clone"

  new_case conflict-systemd
  make_stubs
  run_script "$SETUP" --run systemd --project p
  assert_rc 2 "conflict systemd/project: exits 2"
  assert_out_contains "container-install option" "conflict systemd/project: explains the conflict"

  new_case conflict-db
  make_stubs
  run_script "$SETUP" --install-local --postgres-url postgresql://x
  assert_rc 2 "conflict local/url: exits 2"
  assert_out_contains "cannot be combined" "conflict local/url: explains the conflict"
}

test_reset_5433_db() {
  new_case reset-5433
  make_stubs
  make_fake_install "$CASE_DIR/install" systemd
  sed -i 's#:5432/#:5433/#' "$CASE_DIR/install/prototype/backend/.env"
  run_script "$RESET" --yes --dir "$CASE_DIR/install"
  assert_rc 0 "reset 5433 DB: exits 0"
  assert_out_contains "not touched" "reset 5433 DB: leaves a custom local cluster alone"
  assert_log_not_contains "DROP DATABASE IF EXISTS caidps" "reset 5433 DB: never drops the default cluster"
}

test_reset_project_mismatch() {
  new_case reset-project-mismatch
  make_stubs
  make_fake_install "$CASE_DIR/install" containers
  run_script "$RESET" --yes --dir "$CASE_DIR/install" --project caidps
  assert_rc 2 "reset project mismatch: exits 2"
  assert_out_contains "conflicts" "reset project mismatch: explains the conflict"
  assert_log_not_contains "DOCKER:compose" "reset project mismatch: tears nothing down"
  if [ -e "$CASE_DIR/install" ]; then ok "reset project mismatch: keeps the checkout"; else not_ok "reset project mismatch: keeps the checkout"; fi
}

test_reset_missing_env_kind() {
  new_case reset-missing-env
  make_stubs
  make_fake_install "$CASE_DIR/install" containers
  rm -f "$CASE_DIR/install/deploy/.env"
  run_script "$RESET" --yes --dir "$CASE_DIR/install" --kind containers --project caidps-test
  assert_rc 0 "reset missing env + --kind: exits 0"
  assert_log_contains "DOCKER:compose" "reset missing env + --kind: still tears down compose"
  assert_log_contains "caidps-test" "reset missing env + --kind: uses the explicit project"
}

test_reset_token_tunnel() {
  new_case reset-token
  make_stubs
  make_fake_install "$CASE_DIR/install" systemd
  printf 'CAIDPS_TUNNEL_TOKEN=secret\n' >> "$CASE_DIR/install/prototype/backend/.env"
  run_script "$RESET" --yes --dir "$CASE_DIR/install"
  assert_rc 0 "reset token tunnel: exits 0"
  assert_out_contains "token-managed" "reset token tunnel: reports the manual action"
  assert_log_not_contains "CLOUDFLARED:tunnel delete" "reset token tunnel: does not delete an unrelated tunnel"
}

test_reset_named_tunnel() {
  new_case reset-named
  make_stubs
  make_fake_install "$CASE_DIR/install" systemd
  cat > /etc/systemd/system/caidps.service <<'UNIT'
[Service]
ExecStart=/bin/bash /opt/caidps/scripts/serve.sh --tunnel-name my-caidps-tunnel
UNIT
  run_script "$RESET" --yes --dir "$CASE_DIR/install"
  rm -f /etc/systemd/system/caidps.service
  assert_rc 0 "reset named tunnel: exits 0"
  assert_log_contains "CLOUDFLARED:tunnel delete -f my-caidps-tunnel" "reset named tunnel: deletes the recorded named tunnel"
}

test_reset_leftover() {
  new_case reset-leftover
  make_stubs
  make_fake_install "$CASE_DIR/install" containers
  CAIDPS_TEST_LEFTOVER=1 run_script "$RESET" --yes --dir "$CASE_DIR/install"
  assert_rc 1 "reset leftover: exits nonzero"
  assert_out_contains "still present" "reset leftover: reports the remaining compose container"
}

test_dry_run_keeps_cli() {
  new_case dry-run
  make_stubs
  mkdir -p "$CASE_DIR/home/.local/bin"
  /bin/ln -s "$CASE_DIR/install/scripts/caidps" "$CASE_DIR/home/.local/bin/caidps"
  CAIDPS_NON_INTERACTIVE=1 CAIDPS_INSTALL_DIR="$CASE_DIR/install" run_script "$SETUP" --dry-run --no-link-cli
  assert_rc 0 "dry run: exits 0"
  if [ -L "$CASE_DIR/home/.local/bin/caidps" ]; then ok "dry run: leaves an existing CLI link alone"; else not_ok "dry run: leaves an existing CLI link alone"; fi
}

test_reset_login_tunnel() {
  new_case reset-login-tunnel
  make_stubs
  make_fake_install "$CASE_DIR/install" containers
  printf 'CAIDPS_TUNNEL_MODE=login\nCAIDPS_TUNNEL_NAME=my-login-tunnel\n' >> "$CASE_DIR/install/deploy/.env"
  mkdir -p "$CASE_DIR/install/deploy/cloudflared"
  printf 'tunnel: 11111111-1111-1111-1111-111111111111\n' > "$CASE_DIR/install/deploy/cloudflared/config.yml"
  run_script "$RESET" --yes --dir "$CASE_DIR/install"
  assert_rc 0 "reset login tunnel: exits 0"
  assert_log_contains "CLOUDFLARED:tunnel delete -f my-login-tunnel" "reset login tunnel: deletes the login-managed named tunnel"
}

make_image_stubs() {
  write_stub docker <<'DOCKER_STUB'
#!/usr/bin/env bash
printf 'DOCKER:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
case "${1:-}" in
  login|pull|tag|create|rm) exit 0 ;;
  image)
    if [ "${2:-}" = "inspect" ]; then
      case "$*" in
        *org.opencontainers.image.version*) printf '%s\n' "${CAIDPS_TEST_IMAGE_VERSION:-2.3.0}" ;;
        *Os*Architecture*) arch="$(uname -m)"; case "$arch" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac; printf 'linux/%s\n' "$arch" ;;
        *org.opencontainers.image.revision*) printf 'abc1234\n' ;;
        *) printf 'unknown\n' ;;
      esac
    fi
    exit 0
    ;;
  cp)
    dest="${!#}"
    mkdir -p "$dest/scripts"
    printf '%s\n' "${CAIDPS_TEST_IMAGE_VERSION:-2.3.0}" > "$dest/VERSION"
    cat > "$dest/scripts/host_bundle.sh" <<'HOST'
#!/usr/bin/env bash
printf 'HOST_BUNDLE:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
mkdir -p "$3/scripts"
cp "$2/VERSION" "$3/VERSION"
cp "$2/scripts/setup.sh" "$3/scripts/setup.sh"
chmod +x "$3/scripts/setup.sh"
HOST
    cat > "$dest/scripts/setup.sh" <<'SETUP'
#!/usr/bin/env bash
printf 'SETUP_ARGS:%s\n' "$*" >> "$CAIDPS_TEST_LOG"
printf 'SETUP_TUNNEL:%s\n' "${CAIDPS_TUNNEL_MODE:-}" >> "$CAIDPS_TEST_LOG"
[ "${CAIDPS_TEST_SETUP_FAIL:-0}" = "1" ] && exit 1
exit 0
SETUP
    chmod +x "$dest/scripts/"*.sh
    exit 0
    ;;
  *) exit 0 ;;
esac
DOCKER_STUB
}

test_install_image_fresh() {
  new_case install-image-fresh
  make_stubs
  make_image_stubs
  CAIDPS_GHCR_TOKEN='ghp_secret' CAIDPS_GHCR_USER='Jerit3787' CAIDPS_VERSION='2.3.0' \
    CAIDPS_INSTALL_DIR="$CASE_DIR/install" \
    run_script "$INSTALL_IMAGE" --non-interactive --profile production --run containers
  assert_rc 0 "image install: exits 0"
  assert_log_contains "DOCKER:login ghcr.io -u Jerit3787 --password-stdin" "image install: logs in through stdin"
  assert_log_contains "DOCKER:pull ghcr.io/jerit3787/caidps-app:2.3.0" "image install: pulls the requested version"
  assert_log_contains "DOCKER:tag ghcr.io/jerit3787/caidps-app:2.3.0 caidps-app:latest" "image install: tags the local name"
  assert_log_contains "HOST_BUNDLE:install" "image install: runs the extracted merge script"
  assert_log_contains "SETUP_ARGS:--image-only --run containers" "image install: hands off in image-only mode"
  assert_log_not_contains "git " "image install: never invokes git"
  assert_log_not_contains "ghp_secret" "image install: never logs the token"
  if [ "$(cat "$CASE_DIR/install/VERSION")" = "2.3.0" ]; then
    ok "image install: writes the bundle version"
  else
    not_ok "image install: writes the bundle version"
  fi
}

test_install_image_refuses_checkout() {
  new_case install-image-checkout
  make_stubs
  make_image_stubs
  mkdir -p "$CASE_DIR/install/.git"
  CAIDPS_GHCR_TOKEN='ghp_secret' CAIDPS_GHCR_USER='Jerit3787' CAIDPS_INSTALL_DIR="$CASE_DIR/install" \
    run_script "$INSTALL_IMAGE" --non-interactive --profile production --run containers
  assert_rc 2 "image install checkout: exits 2"
  assert_out_contains "repository checkout" "image install checkout: refuses a git checkout"
  assert_log_not_contains "DOCKER:pull" "image install checkout: pulls nothing"
}

test_install_image_preserves_state() {
  new_case install-image-preserve
  make_stubs
  make_image_stubs
  mkdir -p "$CASE_DIR/install/deploy/cloudflared"
  printf 'KEEP=1\n' > "$CASE_DIR/install/.env"
  printf 'secret\n' > "$CASE_DIR/install/deploy/cloudflared/credentials.json"
  printf '2.2.0\n' > "$CASE_DIR/install/VERSION"
  CAIDPS_GHCR_TOKEN='ghp_secret' CAIDPS_GHCR_USER='Jerit3787' CAIDPS_VERSION='2.3.0' \
    CAIDPS_INSTALL_DIR="$CASE_DIR/install" \
    run_script "$INSTALL_IMAGE" --non-interactive --profile production --run containers
  assert_rc 0 "image install preserve: exits 0"
  if [ "$(cat "$CASE_DIR/install/.env")" = "KEEP=1" ] && \
      [ "$(cat "$CASE_DIR/install/deploy/cloudflared/credentials.json")" = "secret" ] && \
      [ "$(cat "$CASE_DIR/install/VERSION")" = "2.3.0" ]; then
    ok "image install preserve: keeps state and updates VERSION"
  else
    not_ok "image install preserve: keeps state and updates VERSION"
  fi
  assert_log_contains "HOST_BUNDLE:install" "image install preserve: merges the bundle"
}

test_install_image_refuses_downgrade() {
  new_case install-image-downgrade
  make_stubs
  make_image_stubs
  mkdir -p "$CASE_DIR/install"
  printf '2.4.0\n' > "$CASE_DIR/install/VERSION"
  CAIDPS_GHCR_TOKEN='ghp_secret' CAIDPS_GHCR_USER='Jerit3787' CAIDPS_VERSION='2.3.0' \
    CAIDPS_INSTALL_DIR="$CASE_DIR/install" \
    run_script "$INSTALL_IMAGE" --non-interactive --profile production --run containers
  assert_rc 2 "image install downgrade: exits 2"
  assert_out_contains "older" "image install downgrade: refuses an older version"
  assert_log_not_contains "HOST_BUNDLE:install" "image install downgrade: does not merge"
}

test_install_image_persists_a_ghcr_mirror() {
  new_case install-image-mirror
  make_stubs
  make_image_stubs
  CAIDPS_GHCR_TOKEN='ghp_secret' CAIDPS_GHCR_USER='Jerit3787' CAIDPS_APP_IMAGE='ghcr.io/example/caidps-app' \
    CAIDPS_INSTALL_DIR="$CASE_DIR/install" \
    run_script "$INSTALL_IMAGE" --non-interactive --profile production --run containers
  assert_rc 0 "image install mirror: exits 0"
  assert_log_contains "DOCKER:pull ghcr.io/example/caidps-app:latest" "image install mirror: pulls the mirror"
  assert_log_contains "SETUP_ARGS:--image-only --run containers" "image install mirror: hands off"
  if grep -q '^CAIDPS_APP_IMAGE=ghcr.io/example/caidps-app$' "$CASE_DIR/install/deploy/.env" 2>/dev/null && \
      grep -q '^CAIDPS_EVAL_IMAGE=ghcr.io/example/caidps-eval$' "$CASE_DIR/install/deploy/.env" 2>/dev/null; then
    ok "image install mirror: persists the image repositories"
  else
    not_ok "image install mirror: persists the image repositories"
  fi
}

test_install_image_restores_latest_after_setup_failure() {
  new_case install-image-rollback
  make_stubs
  make_image_stubs
  CAIDPS_GHCR_TOKEN='ghp_secret' CAIDPS_GHCR_USER='Jerit3787' CAIDPS_TEST_SETUP_FAIL=1 \
    CAIDPS_INSTALL_DIR="$CASE_DIR/install" \
    run_script "$INSTALL_IMAGE" --non-interactive --profile production --run containers
  assert_rc 1 "image install rollback: exits 1"
  assert_out_contains "restored caidps-app:latest" "image install rollback: says it restored latest"
  assert_log_contains "DOCKER:tag unknown caidps-app:latest" "image install rollback: retags the previous image"
}

test_install_image_refuses_a_concurrent_update() {
  new_case install-image-lock
  make_stubs
  make_image_stubs
  mkdir -p "$CASE_DIR/install"
  if ! command -v flock >/dev/null 2>&1; then
    ok "image install lock: skipped (flock isn't installed)"
    return
  fi
  ( exec 9>"$CASE_DIR/install/.update.lock"; flock -n 9; sleep 3 ) &
  lock_pid=$!
  sleep 0.2
  CAIDPS_GHCR_TOKEN='ghp_secret' CAIDPS_GHCR_USER='Jerit3787' CAIDPS_INSTALL_DIR="$CASE_DIR/install" \
    run_script "$INSTALL_IMAGE" --non-interactive --profile production --run containers
  wait "$lock_pid" 2>/dev/null || true
  assert_rc 1 "image install lock: exits 1"
  assert_out_contains "Another CAIDPS update" "image install lock: refuses while a bootstrap holds it"
  assert_log_not_contains "DOCKER:pull" "image install lock: pulls nothing"
}

test_install_image_refuses_a_non_ghcr_mirror() {
  new_case install-image-bad-mirror
  make_stubs
  make_image_stubs
  CAIDPS_GHCR_TOKEN='ghp_secret' CAIDPS_GHCR_USER='Jerit3787' CAIDPS_APP_IMAGE='example.com/caidps-app' \
    CAIDPS_INSTALL_DIR="$CASE_DIR/install" \
    run_script "$INSTALL_IMAGE" --non-interactive --profile production --run containers
  assert_rc 1 "image install bad mirror: exits 1"
  assert_out_contains "GHCR" "image install bad mirror: says GHCR is required"
  assert_log_not_contains "DOCKER:pull" "image install bad mirror: pulls nothing"
}

test_install_image_forwards_tunnel_env() {
  new_case install-image-tunnel
  make_stubs
  make_image_stubs
  CAIDPS_GHCR_TOKEN='ghp_secret' CAIDPS_GHCR_USER='Jerit3787' CAIDPS_VERSION='2.3.0' \
    CAIDPS_INSTALL_DIR="$CASE_DIR/install" CAIDPS_TUNNEL_MODE='login' \
    run_script "$INSTALL_IMAGE" --non-interactive --profile production --run containers
  assert_rc 0 "image install tunnel: exits 0"
  assert_log_contains "SETUP_TUNNEL:login" "image install tunnel: forwards the tunnel environment"
}

test_help
test_install_all_rejected
test_non_interactive_defaults
test_systemd_unattended
test_unattended_requires_auth
test_conflicting_flags
test_reset_containers
test_reset_systemd
test_reset_external_db
test_reset_5433_db
test_reset_project_mismatch
test_reset_missing_env_kind
test_reset_token_tunnel
test_reset_named_tunnel
test_reset_login_tunnel
test_reset_leftover
test_dry_run_keeps_cli
test_install_image_fresh
test_install_image_refuses_checkout
test_install_image_preserves_state
test_install_image_refuses_downgrade
test_install_image_persists_a_ghcr_mirror
test_install_image_restores_latest_after_setup_failure
test_install_image_refuses_a_concurrent_update
test_install_image_refuses_a_non_ghcr_mirror
test_install_image_forwards_tunnel_env

say ""
say "passed: ${PASS}, failed: ${FAIL}"
[ "$FAIL" -eq 0 ]
