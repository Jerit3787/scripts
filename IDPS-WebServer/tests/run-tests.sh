#!/usr/bin/env bash
# Stub-driven tests for the CAIDPS installer and reset scripts.
# Run from the scripts repo root: bash IDPS-WebServer/tests/run-tests.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$ROOT/setup.sh"
RESET="$ROOT/reset.sh"
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

say ""
say "passed: ${PASS}, failed: ${FAIL}"
[ "$FAIL" -eq 0 ]
