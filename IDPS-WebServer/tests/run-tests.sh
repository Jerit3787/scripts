#!/usr/bin/env bash
# Stub-driven tests for the CAIDPS installer and reset scripts.
# Run from the scripts repo root: bash IDPS-WebServer/tests/run-tests.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$ROOT/setup.sh"
RESET="$ROOT/reset.sh"
ORIG_PATH="$PATH"
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

test_help
test_install_all_rejected
test_non_interactive_defaults
test_systemd_unattended
test_unattended_requires_auth
test_reset_containers
test_reset_systemd
test_reset_external_db

say ""
say "passed: ${PASS}, failed: ${FAIL}"
[ "$FAIL" -eq 0 ]
