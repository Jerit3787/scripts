# CAIDPS Installer (`IDPS-WebServer`)

Self-contained installer and interactive setup wizard for the **Context-Aware Intrusion Detection & Prevention System (CAIDPS)**.

## Direct Execution

```bash
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash
```

## Features

- **Automated Clone / Pull:** Clones `Jerit3787/IDPS-WebServer` on branch `fyp2-real-detection` or fast-forwards your existing repository.
- **Git LFS Verification:** Automatically verifies and pulls DistilBERT machine learning weights.
- **Interactive Wizard:** Terminal GUI asking for target application, data mode, ports, and optional Cloudflare Tunnel public exposure.
- **Zero-Friction Dependencies:** Offers to install any missing tools (Docker, Node.js, Python venv, Git LFS, cloudflared) with `--install-all`.
