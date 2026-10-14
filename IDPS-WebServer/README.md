# CAIDPS scripts (`IDPS-WebServer`)

Installer, setup wizard and reset for the **Context-Aware Intrusion Detection & Prevention System (CAIDPS)**.
These are the only copies; link to these paths.

## Install or update

```bash
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash
# pass options through to the repository's setup wizard:
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash -s -- --install-all
```

- **Clone or update:** clones `Jerit3787/IDPS-WebServer` (branch `fyp2-real-detection`) into `/opt/caidps` on
  Linux (`~/caidps` on macOS) or a path you choose. Run again and it fast-forwards the existing install;
  if that fails (offline, no access, local changes) it says so and continues with the code already there.
- **Private access:** `GITHUB_TOKEN` / `GH_TOKEN` from the environment, an authenticated GitHub CLI, a
  token you paste, or SSH. A token is used for that run only — passed to git through its environment,
  never written into `.git/config` and never visible in the process list.
- **Model weights:** pulls the DistilBERT weights with Git LFS and warns if it could not
  (the DistilBERT tier stays off until `git lfs pull` succeeds).
- **Then** hands over to the repository's interactive wizard (`scripts/setup.sh`): target application,
  data mode, ports, Cloudflare Tunnel, missing dependencies.
- **First sign-in:** CAIDPS has no built-in accounts. The first start prints a one-time setup code;
  enter it in the dashboard to create the first SOC Lead.

| Environment | Effect |
|---|---|
| `GITHUB_TOKEN` / `GH_TOKEN` | token for a private clone or update (this run only) |
| `CAIDPS_NON_INTERACTIVE=1` | take every default without prompting (also when `CI` is set or there is no terminal) |

## Reset (uninstall)

```bash
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/reset.sh | bash
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/reset.sh | bash -s -- --yes --purge-packages
```

Lists what it will do and asks you to type `reset`. Then it stops and removes the `caidps` service and
processes, the target containers (Juice Shop, VulnBank, …), the `caidps` Cloudflare Tunnel and its
credentials, the install (with its database and settings) and the `caidps` command — and checks that
each is gone.

| Option | Effect |
|---|---|
| `--yes` (or `CAIDPS_RESET_CONFIRM=yes`) | no prompt — required when there is no terminal |
| `--purge-packages` | also uninstall cloudflared, Node.js, Docker and whiptail. **Deletes every Docker image, container and volume on the machine.** Off by default: they may have been there before CAIDPS |
| `--dir PATH` | also remove an install outside the default locations (must be a CAIDPS checkout) |

An install the `caidps` command points at is found automatically.
