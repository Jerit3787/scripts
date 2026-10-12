# danplace.tech Scripts & One-Liner Installers

A centralized collection of automated one-liner scripts, installation wizards, and utilities for [danplace.tech](https://danplace.tech) projects.

Hosted publicly at: **[https://scripts.danplace.tech](https://scripts.danplace.tech)**

---

## Available Scripts

### 1. CAIDPS (Context-Aware Intrusion Detection & Prevention System)

Automated repository downloader, dependency bootstrapper, and interactive setup wizard for CAIDPS.

#### Quickstart:
```bash
curl -fsSL https://scripts.danplace.tech/idps.sh | bash
```

**Alternative URLs:**
```bash
# Extensionless URL
curl -fsSL https://scripts.danplace.tech/idps | bash

# Project-namespaced URL
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash

# Generic setup URL
curl -fsSL https://scripts.danplace.tech/setup.sh | bash
```

#### What it does:
1. Clones `Jerit3787/IDPS-WebServer` (branch `fyp2-real-detection`) or updates your existing repository.
2. Initializes git submodules and verifies Git LFS model weights for the DistilBERT attack classifier.
3. Guides you through an interactive setup:
   - **Target application:** OWASP Juice Shop (:3000), VulnBank (:3100), MediVault (:3200), DVNA (:9090), CI/CD Goat (:3000), or custom upstream.
   - **Data ingestion mode:** Live proxy inspection, replay mode, or simulated telemetry.
   - **Network ports:** SOC Dashboard (:8000), Inline Proxy (:8081).
   - **Cloudflare Tunnel:** Ephemeral public HTTPS Quick Tunnel (`*.trycloudflare.com`) or named Zero Trust token.
   - **Prerequisites check:** Automatic installation of missing dependencies (`--install-all`).
4. Boots the CAIDPS stack with auto-restart on crash.

---

## Directory Structure

```
.
├── CNAME                    # Custom domain mapping for scripts.danplace.tech
├── .nojekyll                # Disables Jekyll processing for raw text / script serving
├── index.html               # Responsive web portal & quick copy interface
├── idps.sh                  # Root one-liner entrypoint for CAIDPS
├── idps                     # Extensionless entrypoint
├── setup.sh                 # Standard setup alias
└── IDPS-WebServer/          # Project folder for IDPS-WebServer
    ├── setup.sh             # Self-contained project installer
    └── README.md            # Project specific documentation
```

---

## Contributing

To add a new script for a project:
1. Create a subfolder named after the project: `<project-name>/`
2. Add your installer script inside: `<project-name>/setup.sh`
3. Link or document the one-liner in `index.html` and `README.md`.
