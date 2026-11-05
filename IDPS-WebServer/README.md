# CAIDPS scripts (`IDPS-WebServer`)

Installer, setup wizard and factory reset for the **Context-Aware Intrusion Detection & Prevention System (CAIDPS)**.
These are the only copies; link to these paths. Linux server is the primary target (the reset's process cleanup uses `/proc`).

Project page: **[scripts.danplace.tech/IDPS-WebServer](https://scripts.danplace.tech/IDPS-WebServer/)**

## Install or update

```bash
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash
```

The wrapper:

- clones or fast-forwards `Jerit3787/IDPS-WebServer` (branch `fyp2-real-detection` by default) into
  `/opt/caidps` on Linux (or the path you choose);
- installs Git, Git LFS, Python 3, venv and pip;
- lets the app's setup pull the released container image for the checkout's version (or build it locally,
  fetching the DistilBERT weights, only when no image is available);
- configures ownership, permissions and the global `caidps` command;
- hands over to the app's `scripts/setup.sh`.

The app's wizard then asks the current questions: production or development, Docker Compose or systemd,
target/upstream, HTTPS, Cloudflare Tunnel, ports and prerequisites. See the
[app README](https://github.com/Jerit3787/IDPS-WebServer#-setup--installation) for the full contract.

### Unattended production install (recommended)

```bash
# Docker Compose stack: PostgreSQL, Redis, backend, proxy and Juice Shop
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh \
  | CAIDPS_NON_INTERACTIVE=1 bash
```

That is equivalent to:

```bash
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh \
  | bash -s -- --non-interactive --profile production --run containers
```

The wrapper installs Python/venv, the app installs Docker and the Compose plugin, builds and starts the
stack, installs the `caidps-hostd` updater and the nightly backup timer, and prints the one-time setup code.

### Image-only install (no repository)

For a production server that should not keep a git checkout, LFS weights, submodules or a backend venv:

```bash
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/install-image.sh | \
  CAIDPS_GHCR_TOKEN='<classic PAT with read:packages>' \
  CAIDPS_GHCR_USER=Jerit3787 \
  bash -s -- --non-interactive --profile production --run containers
```

The bootstrap pulls the released app image, extracts its host bundle (compose, tunnel/backup/CLI scripts
and the host updater), merges it without touching `.env`, tunnel credentials, certificates or backups, and
runs the image-only host setup. It never clones the repository, pulls LFS weights, checks out submodules,
installs `node_modules` or builds an image.

- `CAIDPS_GHCR_TOKEN` needs `read:packages`; it is passed to `docker login` through stdin. If `gh` is
  authenticated, `CAIDPS_GHCR_USER` can be omitted.
- `CAIDPS_VERSION` pins a fresh install (default `latest`); an existing image-only install refuses a
  downgrade.
- Tunnel settings use the same `CAIDPS_TUNNEL_MODE`/`CAIDPS_TUNNEL_TOKEN`/`CAIDPS_TUNNEL_NAME`/
  `CAIDPS_TUNNEL_DASHBOARD_HOST`/`CAIDPS_TUNNEL_APP_HOST` environment as the container wizard. Token mode
  is unattended; login mode needs a terminal and browser.
- Re-run the same command to repair or upgrade the host tooling. It refuses a directory containing `.git`;
  the repo-based installer remains the path for checkouts.
- Dashboard **Updates** then pulls new app images and host bundles; **Evaluation** pulls the released
  evaluation image. Neither builds on the host.

Unattended runs use `sudo` for package and service steps. When there is no terminal, run as root or with
passwordless sudo.

Container options passed through to the app wizard:

```bash
# Protect an app that is already running instead of Juice Shop in the stack
... | bash -s -- --non-interactive --profile production --run containers \
  --upstream http://10.0.0.5:3000

# A second install on the same machine needs its own compose project
... | bash -s -- --non-interactive --profile production --run containers --project caidps-new

# HTTPS in the stack (Let's Encrypt, your certificate files, or Caddy's internal CA)
... | bash -s -- --non-interactive --profile production --run containers \
  --tls acme --dashboard-domain soc.example.com --acme-email you@example.com

# Restore a backup (scripts/backup.sh create) into a new stack
... | bash -s -- --non-interactive --profile production --run containers \
  --restore /path/to/backups/caidps-<UTC>.tar.gz
```

A token-managed Cloudflare Tunnel is read from the environment:

```bash
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh \
  | CAIDPS_TUNNEL_TOKEN=... CAIDPS_NON_INTERACTIVE=1 bash
```

Or run the interactive container wizard and choose **Cloudflare Login** instead of a token. The app then
runs `cloudflared login`, creates/reuses a named tunnel, routes its public hostnames, and writes
`deploy/cloudflared/config.yml` plus the credentials (mounted as the `caidps_tunnel_credentials` Docker
secret). The `tunnel-login` profile is used. This login path needs the interactive wizard; unattended
installs use a token. If the name already belongs to a tunnel created in the Cloudflare dashboard, it has
no local credentials: the wizard asks for another name, and the **Tunnel Token** option is the way to
keep using that dashboard-managed tunnel.

### Unattended systemd install

```bash
# systemd + PostgreSQL and Redis installed on this server
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh \
  | CAIDPS_NON_INTERACTIVE=1 bash -s -- --run systemd --install-local

# systemd + existing PostgreSQL and Redis
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh \
  | CAIDPS_NON_INTERACTIVE=1 bash -s -- --run systemd \
      --postgres-url 'postgresql://caidps:...@db:5432/caidps' \
      --redis-url 'redis://:...@cache:6379/0'
```

For non-interactive explicit systemd installs the wrapper also installs Docker, Node/npm and the backend
Python environment (the app's non-interactive systemd path otherwise only writes the configuration), then
runs `scripts/setup.sh`, installs and starts `caidps.service`, and installs the nightly backup timer.
Interactive systemd installs let the app wizard install its own prerequisites and start the service.

The non-interactive systemd path uses the app's default target, ports and data mode. For a custom target,
ports or a Cloudflare Tunnel on systemd, use the interactive wizard (or reconfigure with
`caidps` / `scripts/service.sh install` afterwards).

### Options and environment

`--install-all` is a `scripts/serve.sh` flag, **not** a `scripts/setup.sh` option. Passing it to the
installer exits with an explanation. For a host/development install after setup, run:

```bash
cd /opt/caidps && ./scripts/serve.sh --install-all
```

`--dry-run` resolves the app's configuration and prints the commands. It may still clone or fast-forward the
checkout, but it does not install packages, change permissions, link the CLI, or start services.

Wrapper environment:

| Variable | Effect |
|---|---|
| `GITHUB_TOKEN` / `GH_TOKEN` | token for the private clone/update (this run only) |
| `CAIDPS_NON_INTERACTIVE=1` | skip wrapper prompts; defaults to the production container stack |
| `CI=1` | same as `CAIDPS_NON_INTERACTIVE` |
| `CAIDPS_INSTALL_DIR=PATH` | install path (default `/opt/caidps` on Linux) |
| `CAIDPS_BRANCH=NAME` | branch to install (default `fyp2-real-detection`) |
| `CAIDPS_NODE_CHANNEL` | NodeSource channel used by the systemd prerequisite installer (default `lts`) |
| `CAIDPS_TUNNEL_TOKEN` | Cloudflare Tunnel token passed to the container install |
| `CAIDPS_GHCR_TOKEN` | PAT with `read:packages` for the private app image (optional; a failed pull builds locally) |
| `CAIDPS_GHCR_USER` | GitHub account for `CAIDPS_GHCR_TOKEN` (default: the `gh` CLI's account) |

Container installs pull `ghcr.io/jerit3787/caidps-app:<version>` for the checkout's `APP_VERSION`, verify
its version and architecture, and use it; `--local-build` forces the build path, as does a dirty checkout,
another architecture, or a failed pull. The private GHCR packages need `CAIDPS_GHCR_TOKEN` for an
unattended pull (the installer stores the login for the checkout owner, whose account the host updater
runs as). Without it, the install still completes by building. The same applies to dashboard updates and
evaluations, which pull the released `caidps-eval` image first.

**Private access:** the application repository is private. On a fresh server, authenticate with one of:

```bash
# Token on the bash side, not on curl
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | GITHUB_TOKEN=... bash

# or export it first
export GITHUB_TOKEN=...
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash
```

An authenticated GitHub CLI (`gh auth login`) or the interactive PAT/SSH wizard is also supported. The
token is used for that run only and is not written into `.git/config`.

**Updates:** re-run the installer to fast-forward the checkout and re-run the wizard. Container installs
can also update from the dashboard through `caidps-hostd`. An interactive update warns and continues with
the existing checkout if the fast-forward fails; an unattended update exits instead of configuring stale or
wrong-branch code.

**First sign-in:** CAIDPS has no built-in accounts. The first start prints a one-time setup code; enter it
in the dashboard to create the first SOC Lead.

## Reset (uninstall)

```bash
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/reset.sh | bash
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/reset.sh | bash -s -- --yes
```

The reset targets Linux servers (systemd/Docker Compose); the process teardown uses `/proc`, so macOS
installs are not a supported reset target.

The script asks you to type `reset`, then:

- **Container installs:** removes `caidps-hostd`, the backup timer, and the Compose stack including its
  containers, networks and **named volumes** (the CAIDPS database and Redis/Caddy data); then removes the
  checkout, CLI and host-managed tunnel credentials.
- **systemd installs:** removes `caidps.service`, the backup timer and the CLI, stops leftover processes and
  legacy target containers, and drops the local `caidps` PostgreSQL database and role when the install used
  the app's local database.
- **Never touched:** external PostgreSQL/Redis, dashboard/token-managed Cloudflare tunnels, and unrelated Docker
  workloads. The script reports these as manual actions.
- **Cloudflare Login tunnels:** a named tunnel created by the container wizard is recorded as
  `CAIDPS_TUNNEL_NAME` in `deploy/.env`; the reset deletes it when the `cloudflared` CLI is available.
  Token-managed tunnels must be deleted in Cloudflare Zero Trust.
- **Scope:** the reset removes every CAIDPS install it finds (the default paths, the CLI symlink target and
  `--dir`). Do not run it on a host with another CAIDPS install you want to keep; stop that install and
  remove its unit/containers separately first.

Notes:

- **Back up first.** The checkout is deleted, including its `backups/` directory and `deploy/.env`. Use
  `scripts/backup.sh create` and copy the archive off the server before resetting.
- Unattended resets (`--yes`) use `sudo`; when there is no terminal, run as root or with passwordless sudo.
- Local Redis data/config is left in place; a reinstall with `--install-local` rewrites the local Redis
  password, while an existing local Redis URL is reused.
- Docker images and packages remain unless `--purge-packages` is used. `--purge-packages` deletes **all**
  Docker images, containers and volumes on the machine, and uninstalls cloudflared, Node.js, Docker and
  whiptail. Local PostgreSQL/Redis packages are kept.
- Host-managed Cloudflare credentials live in the installing user's `~/.cloudflared`, root's
  `~/.cloudflared`, and `/etc/cloudflared`; the reset removes those directories. They can also hold other
  cloudflared logins, so move them first on a shared server. A token-managed tunnel must be deleted in
  Cloudflare Zero Trust.

| Option | Effect |
|---|---|
| `--yes` (or `CAIDPS_RESET_CONFIRM=yes`) | no prompt — required when there is no terminal |
| `--purge-packages` | also remove cloudflared, Node.js, Docker (and **all** Docker data), whiptail |
| `--dir PATH` | also remove a CAIDPS install outside the default locations |
| `--project NAME` | compose project when `deploy/.env` is missing or unreadable; a value that conflicts with the recorded project aborts |
| `--kind containers\|systemd` | force the install kind when the metadata is missing or unreadable |

An install the `caidps` command points at is found automatically.

## Tests

Run the stub-driven tests in a disposable Linux container (they do not touch the host):

```bash
docker run --rm -v "$PWD:/repo" -w /repo python:3.12-slim bash IDPS-WebServer/tests/run-tests.sh
```

The harness refuses to run outside a container unless `CAIDPS_TEST_ALLOW_HOST=1` is set, because the reset
tests exercise paths under `/opt`, `/etc/systemd` and `/usr/local`.

Also run `bash -n` and `shellcheck -S warning` on the scripts before pushing.
