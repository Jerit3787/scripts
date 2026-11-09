# AI Discord Bot scripts (`AI-Discord-Bot`)

Installer for the private **AI Discord Bot**: a two-mode Discord bot and a password-protected
monitoring dashboard, both run from private GHCR images with Docker Compose.

Project page: **[scripts.danplace.tech/AI-Discord-Bot](https://scripts.danplace.tech/AI-Discord-Bot/)**

## Install or update

```bash
curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | bash
```

The wrapper:

- clones or fast-forwards `Jerit3787/ai-discord-bot` (branch `main` by default) into
  `/opt/ai-discord-bot` on Linux (or the path you choose);
- installs Docker Engine with the Compose plugin when it is missing;
- reads an existing `.env` and preserves every value that is already there; only missing keys are added;
- generates a dashboard username/password login (scrypt hash), a signed-cookie secret and a Watchtower
  token when they are not already configured;
- detects `DOCKER_GID` from `/var/run/docker.sock` and uses the installing user's
  `~/.docker/config.json` for Watchtower;
- logs in to GHCR, pulls the private `:bot` or `:user` image, and starts the bot, dashboard and
  Watchtower with Docker Compose;
- links the `discord-bot` host command when it can.

Existing `data/` and `.env` files are never deleted. Re-run the same command to update.

The installer finds an existing checkout from the running `ai-discord-bot` container's Compose
working directory, the current directory, or the common paths (`/opt/ai-discord-bot`,
`~/ai-discord-bot`, `~/Desktop/ai-discord-bot`). Image-only installs are found by their
`.image-install` marker. It refuses to install a second copy at a different path because the Compose
project and container names are fixed; stop and remove the old stack first if you are migrating.

### Image-only install (no repository)

If the server should not keep a git checkout, use the image-only bootstrap:

```bash
curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/install-image.sh | \
  GHCR_TOKEN='<PAT with read:packages>' \
  GHCR_USER='<your GitHub username>' \
  bash
```

It pulls the released image, extracts the Compose file and host tools from `/app/host-bundle`, and
runs the same setup flow. It never clones the repository. Re-run the same command to pull a new image
and refresh the host bundle; `.env` and `data/` are preserved. The install directory is marked with
`.image-install` so later runs find it.

The image-only flow still uses Python 3 on the host only to generate the dashboard login; the bot and
dashboard run from the image. The installer installs Python 3 if it is missing. All options
(`--dir`, `--dashboard-port`, `--no-start`, `--dry-run`, …) work the same way.

```bash
# Configure the image-only install but do not start it
curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/install-image.sh | \
  GHCR_TOKEN='<PAT with read:packages>' GHCR_USER='<your GitHub username>' \
  bash -s -- --no-start
```

The bot repository and its container package are private. A fresh full install needs a GitHub token
(or `gh auth login`) for the checkout and a PAT with `read:packages` for the image. An image-only
install needs only the GHCR token. Put tokens on the bash side of the pipe, not on the curl side.

### Interactive install

```bash
curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | bash
```

The wizard asks for the install path, token mode, the dashboard bind address and port, the
OpenAI-compatible endpoint and key, the Discord token, optional owner/GIPHY details, and the
dashboard password. Press Enter on the password prompt to generate a strong one.

A token for the private repository and the private image can be supplied up front:

```bash
curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | \
  GITHUB_TOKEN='<PAT with repo and read:packages>' \
  GHCR_USER='<your GitHub username>' \
  bash
```

`GITHUB_TOKEN` is reused for the GHCR login when `GHCR_TOKEN` is unset.

### Unattended install

```bash
curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | \
  GITHUB_TOKEN='<PAT with repo and read:packages>' \
  GHCR_TOKEN='<PAT with read:packages>' \
  GHCR_USER='<your GitHub username>' \
  DISCORD_TOKEN='<bot or user token>' \
  OPENAI_API_KEY='<OpenAI-compatible key>' \
  TOKEN_MODE=bot \
  DASHBOARD_HOST_IP=100.64.0.10 \
  AI_DISCORD_BOT_NON_INTERACTIVE=1 \
  bash
```

`AI_DISCORD_BOT_NON_INTERACTIVE=1` and `CI=1` both skip prompts. A fresh unattended install requires
`DISCORD_TOKEN` and `OPENAI_API_KEY`; everything with a safe default is filled in. The generated
dashboard password is printed once at the end.

If `DASHBOARD_HOST_IP` is omitted, an unattended install binds the dashboard to `127.0.0.1`, or to the
Tailscale IPv4 address when Tailscale is available. Set it to a private LAN or Tailscale address to
reach the dashboard remotely. Avoid `0.0.0.0` unless the port is firewalled.

### Update an existing install

```bash
curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | \
  GITHUB_TOKEN='<PAT with repo access>' bash
```

The installer fast-forwards the checkout, keeps the existing `.env` and `data/`, pulls the current
image and recreates the containers. It saves the previous environment as `.env.bak` before writing.
If the checkout is managed outside the installer, add `--no-git-update`:

```bash
curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | \
  GHCR_TOKEN='<PAT with read:packages>' GHCR_USER='<your GitHub username>' \
  bash -s -- --no-git-update
```

For updates without re-running the installer:

```bash
discord-bot update
```

On an image-only install, `discord-bot update` pulls the image, refreshes the Compose file and host
tools from `/app/host-bundle`, and recreates the containers. Re-run `install-image.sh` if the CLI is
missing or you want to repair the host bundle.

On a full checkout, `discord-bot update` updates the image only; refresh the checkout with git or the
installer.

## Dashboard login

The dashboard uses a username and password, not a shared bearer token. The installer generates
`DASHBOARD_USER`, `DASHBOARD_PASSWORD_HASH`, `DASHBOARD_SESSION_SECRET` and `WATCHTOWER_TOKEN` when
they are missing, and prints the generated password once. It is not stored in plaintext.

- Username: `DASHBOARD_USER` (default `admin`).
- Reset the password by re-running with `DASHBOARD_PASSWORD`:

```bash
curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | \
  DASHBOARD_PASSWORD='new strong password' bash
```

Resetting the password also rotates the session secret, so existing dashboard sessions are signed
out.

- The **Settings** tab writes through the mounted host `.env`, so changes survive dashboard restarts.
- The legacy `DASHBOARD_TOKEN` is left untouched if it is already in `.env`; password login takes
  precedence. Remove it with `sed -i '/^DASHBOARD_TOKEN=/d' .env` after confirming the login works.

## Token modes

| `TOKEN_MODE` | Token | Library | Risk |
|---|---|---|---|
| `bot` (default) | bot account token | official `discord.py` | supported by Discord |
| `user` | personal account token | `discord.py-self` | **violates Discord ToS; the account can be banned** |

`CONTAINER_TAG` must match the mode: `bot`, `latest`, or `bot-<sha>` for bot mode; `user` or
`user-<sha>` for user mode. The installer keeps the two in sync and refuses a mismatched pair.

Switching modes requires a different Discord token. The installer does not carry the old mode's token
across a switch.

## Watchtower and updates

The Compose stack includes a `watchtower` sidecar with a filtered update API:

- only the labeled `ai-discord-bot` container is recreated;
- `WATCHTOWER_CLEANUP=true` removes superseded images;
- the dashboard's **Update bot** button calls it with `WATCHTOWER_TOKEN`.

Use `--no-watchtower` to start only the bot and dashboard. The installer clears
`WATCHTOWER_TOKEN`, so the dashboard's update action is disabled; update with `discord-bot update`
instead.

To pin a build, set `CONTAINER_TAG` to a published commit tag (for example `user-1a2b3c4d5e6f`) and
re-run. Watchtower and `discord-bot update` will stay on the pinned tag.

## Data, backups and secrets

Runtime state lives in the checkout's `data/` directory and is mounted at `/data` in both containers:

```text
data/
├── bot.db, bot.db-wal, bot.db-shm
├── gifs/
├── backups/
├── gif_cache/
└── image_cache/
```

The directory is kept across container recreation and installer updates. Back it up before major
updates. The container runs as UID/GID `1000:1000`; the installer fixes ownership on Linux.

`.env` holds the Discord token, API key, dashboard hash and other secrets. It is written with mode
`600` and is never committed. The previous version is saved as `.env.bak` before an update. GHCR and
GitHub tokens are used for the run only and are not written to `.git/config` or `.env`; `docker login`
stores the registry credential in the installing user's `~/.docker/config.json` (mode `600`).

## Requirements

- Linux server with `sudo` or root (macOS is supported for Docker Desktop installs).
- Docker Engine with Compose v2; the installer installs it when missing.
- The published images are `linux/amd64`. ARM hosts can use Docker's amd64 emulation with
  `DOCKER_DEFAULT_PLATFORM=linux/amd64`, or build the image locally.
- Git for the full checkout (the image-only installer does not need it).
- Python 3 on the host **only** to generate the dashboard login; the bot itself runs in the container.
- A GitHub token or `gh auth login` for the full private checkout.
- A classic PAT with `repo` + `read:packages`, or a fine-grained token with Contents read and Packages
  read, for the private GHCR image. The image-only installer needs only `read:packages`.
- A Tailscale or private LAN address if the dashboard should be reachable from another machine.

## Options

| Option | Effect |
|---|---|
| `--non-interactive` | Skip prompts. Required values come from the environment. |
| `--dir PATH` | Install path. Default `/opt/ai-discord-bot` on Linux. |
| `--branch NAME` | Git branch. Default `main`. |
| `--token-mode bot\|user` | Discord token type. Default `bot`. |
| `--dashboard-ip IP` | Host interface to publish the dashboard on. |
| `--dashboard-port PORT` | Dashboard port on the host and inside the container. Default `8787`. |
| `--dashboard-password VALUE` | Reset the dashboard password. |
| `--no-watchtower` | Start only the bot and dashboard. |
| `--no-cli` | Do not link the `discord-bot` command. |
| `--no-start` | Configure `.env` and `data/`, but do not pull or start. |
| `--no-git-update` | Use an existing checkout without `git fetch`/fast-forward. |
| `--image-only` | Pull the image and extract its host bundle; never clone the repository. |
| `--dry-run` | Print the resolved plan; write, pull and start nothing. |
| `--help`, `-h` | Show usage. |

Pass flags after `bash -s --`:

```bash
curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | \
  GITHUB_TOKEN=... bash -s -- --token-mode user --dashboard-ip 100.64.0.10
```

## Environment

| Variable | Effect |
|---|---|
| `GITHUB_TOKEN` / `GH_TOKEN` | Private repository token for this run. Also reused for GHCR when `GHCR_TOKEN` is unset. |
| `GHCR_TOKEN` | PAT with `read:packages` for the private image. |
| `GHCR_USER` | Your GitHub username, for the account that owns `GHCR_TOKEN`. Default: the authenticated `gh` account, otherwise prompted. |
| `AI_DISCORD_BOT_INSTALL_DIR` | Install path. |
| `AI_DISCORD_BOT_BRANCH` | Branch. Default `main`. |
| `AI_DISCORD_BOT_NON_INTERACTIVE=1` | Same as `--non-interactive`. `CI=1` also works. |
| `AI_DISCORD_BOT_NO_GIT_UPDATE=1` | Same as `--no-git-update`. |
| `AI_DISCORD_BOT_IMAGE_ONLY=1` | Same as `--image-only`. |
| `TOKEN_MODE` | `bot` or `user`. Default `bot`. |
| `DISCORD_TOKEN` | Bot token, or user token in user mode. Required on a fresh install. |
| `OPENAI_API_KEY` | OpenAI-compatible API key. Required on a fresh install. |
| `OPENAI_BASE_URL` | Endpoint. Default `https://api.openai.com/v1`. |
| `AI_MODEL` | Model name. Default `gpt-4o-mini`. |
| `OWNER_ID` | Optional numeric Discord user ID. |
| `GIPHY_API_KEY` | Optional GIF search key. |
| `DASHBOARD_HOST_IP` | Host interface to publish on. |
| `DASHBOARD_PORT` | Dashboard port on the host and inside the container. Default `8787`. |
| `DASHBOARD_USER` | Dashboard login user. Default `admin`. |
| `DASHBOARD_PASSWORD` | Reset the dashboard password to this value. |
| `DOCKER_GID` | Socket group ID. Detected from `/var/run/docker.sock`. |
| `DOCKER_CONFIG_FILE` | Host Docker config mounted into Watchtower. Default `~/.docker/config.json`. |
| `GHCR_OWNER` | Image owner. Default `jerit3787`. |
| `CONTAINER_TAG` | `bot`, `user`, `latest`, `bot-<sha>` or `user-<sha>`. |
| `TZ` | Container timezone. Default `Asia/Kuala_Lumpur`. |

## Private access details

The application repository is private. On a fresh server, use one of:

```bash
# Token on the bash side, not curl
curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | GITHUB_TOKEN=... bash

# Or authenticate the GitHub CLI first
gh auth login
curl -fsSL https://scripts.danplace.tech/AI-Discord-Bot/setup.sh | bash
```

The interactive wizard also prompts for a PAT or falls back to an SSH key. The clone token is passed
to git through an `Authorization` header in the environment, never written to `.git/config`.

For GHCR, the package is private. Create a classic PAT with `read:packages` (and `repo` if the same
token is used for the clone), or a fine-grained token with Packages read access. `GHCR_USER` must be
your GitHub username: the account that owns the token. A token from a different account that only has package access also
works when that account is named.

## Troubleshooting

| Symptom | Check |
|---|---|
| `Could not clone the private repository` | Set `GITHUB_TOKEN`, run `gh auth login`, or add an SSH key. |
| `GHCR login failed` / `pull access denied` | Token has `read:packages`; `GHCR_USER` is the token owner; the package is private. |
| `The private image ... is not available` | Run with `GHCR_TOKEN` and `GHCR_USER`, or log in with `docker login ghcr.io` first. |
| `The image host bundle has no docker-compose.yml` | The image predates the host bundle; use a current `:bot`/`:user` build or re-run the full installer. |
| `no matching manifest for linux/arm64` | The published image is amd64. Set `DOCKER_DEFAULT_PLATFORM=linux/amd64` or build locally. |
| Dashboard not reachable | `DASHBOARD_HOST_IP` must be an address on the host; open `http://IP:PORT`; check firewall/Tailscale. |
| `permission denied` on `/var/run/docker.sock` | Re-run so `DOCKER_GID` is detected, or add the user to the `docker` group and log back in. |
| Settings save fails | The dashboard mounts the host `.env`; check that `./.env` exists and the install user can write it. |
| Update button does nothing | Watchtower is enabled and the bot image tag is not pinned; check `discord-bot logs watchtower`. |
| Dashboard login lost | Re-run with `DASHBOARD_PASSWORD='...'`; the hash is replaced and the session secret is kept. |

## Verify before pushing

```bash
bash -n AI-Discord-Bot/setup.sh
shellcheck -S warning AI-Discord-Bot/setup.sh
AI_DISCORD_BOT_INSTALL_DIR=/path/to/checkout bash AI-Discord-Bot/setup.sh --dry-run
```

The dry run does not write, pull or start anything. For a full test, use a disposable server or a
checkout copy and run with `--no-start --no-cli` first, inspect `.env`, then run again without
`--no-start`.
