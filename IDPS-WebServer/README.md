# CAIDPS scripts (`IDPS-WebServer`)

Installer, setup wizard and factory reset for the **Context-Aware Intrusion Detection & Prevention System (CAIDPS)**.
These are the only copies; link to these paths. Linux server is the primary target (the reset's process cleanup uses `/proc`).

## Install or update

```bash
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash
```

The wrapper:

- clones or fast-forwards `Jerit3787/IDPS-WebServer` (branch `fyp2-real-detection` by default) into
  `/opt/caidps` on Linux (or the path you choose);
- installs Git, Git LFS, Python 3, venv and pip;
- pulls the DistilBERT weights with Git LFS and warns if it could not;
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

For explicit systemd installs the wrapper also installs Docker, Node/npm and the backend Python
environment (the app's non-interactive systemd path otherwise only writes the configuration), then runs
`scripts/setup.sh`, installs and starts `caidps.service`, and installs the nightly backup timer.

The non-interactive systemd path uses the app's default target, ports and data mode. For a custom target,
ports or a Cloudflare Tunnel on systemd, use the interactive wizard (or reconfigure with
`caidps` / `scripts/service.sh install` afterwards).

### Options and environment

`--install-all` is a `scripts/serve.sh` flag, **not** a `scripts/setup.sh` option. Passing it to the
installer exits with an explanation. For a host/development install after setup, run:

```bash
cd /opt/caidps && ./scripts/serve.sh --install-all
```

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
can also update from the dashboard through `caidps-hostd`.

**First sign-in:** CAIDPS has no built-in accounts. The first start prints a one-time setup code; enter it
in the dashboard to create the first SOC Lead.

## Reset (uninstall)

```bash
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/reset.sh | bash
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/reset.sh | bash -s -- --yes
```

The script asks you to type `reset`, then:

- **Container installs:** removes `caidps-hostd`, the backup timer, and the Compose stack including its
  containers, networks and **named volumes** (the CAIDPS database and Redis/Caddy data); then removes the
  checkout, CLI and host-managed tunnel credentials.
- **systemd installs:** removes `caidps.service`, the backup timer and the CLI, stops leftover processes and
  legacy target containers, and drops the local `caidps` PostgreSQL database and role when the install used
  the app's local database.
- **Never touched:** external PostgreSQL/Redis, dashboard-managed Cloudflare tunnels, and unrelated Docker
  workloads. The script reports these as manual actions.

Notes:

- **Back up first.** The checkout is deleted, including its `backups/` directory and `deploy/.env`. Use
  `scripts/backup.sh create` and copy the archive off the server before resetting.
- Unattended resets (`--yes`) use `sudo`; when there is no terminal, run as root or with passwordless sudo.
- Local Redis data/config is left in place; a reinstall with `--install-local` rewrites the local Redis
  password, while an existing local Redis URL is reused.
- Docker images and packages remain unless `--purge-packages` is used. `--purge-packages` deletes **all**
  Docker images, containers and volumes on the machine, and uninstalls cloudflared, Node.js, Docker and
  whiptail. Local PostgreSQL/Redis packages are kept.
- Host-managed Cloudflare credentials live in the installing user's `~/.cloudflared` (and root's, if used);
  the reset removes those directories. That directory can also hold other cloudflared logins, so move them
  first on a shared server. A token-managed tunnel must be deleted in Cloudflare Zero Trust.

| Option | Effect |
|---|---|
| `--yes` (or `CAIDPS_RESET_CONFIRM=yes`) | no prompt — required when there is no terminal |
| `--purge-packages` | also remove cloudflared, Node.js, Docker (and **all** Docker data), whiptail |
| `--dir PATH` | also remove a CAIDPS install outside the default locations |
| `--project NAME` | compose project to use when `deploy/.env` is missing |

An install the `caidps` command points at is found automatically.
