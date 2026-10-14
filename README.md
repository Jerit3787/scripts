# danplace.tech Scripts & One-Liner Installers

A collection of one-line installers and utilities for [danplace.tech](https://danplace.tech) projects,
served at **[https://scripts.danplace.tech](https://scripts.danplace.tech)** (GitHub Pages).

Each project keeps **one copy** of its scripts in a folder named after the project. Link to that path;
there are no aliases at the root.

---

## CAIDPS (`IDPS-WebServer/`)

Context-Aware Intrusion Detection & Prevention System: installer, setup wizard and reset.

```bash
# Install (or update) and run the setup wizard
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash

# Remove an installation (asks you to type "reset" first)
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/reset.sh | bash
```

Details, options and environment variables: [`IDPS-WebServer/README.md`](IDPS-WebServer/README.md).

---

## Directory structure

```
.
├── CNAME                  # scripts.danplace.tech
├── .nojekyll              # serve files as-is (no Jekyll)
├── index.html             # landing page with copy buttons
└── IDPS-WebServer/
    ├── setup.sh           # CAIDPS installer and setup wizard
    ├── reset.sh           # CAIDPS teardown / factory reset
    └── README.md
```

## Adding a project

1. Create a folder named after the project: `<project-name>/`.
2. Put its scripts there (`<project-name>/setup.sh`, …) — one copy each, no root aliases.
3. Document the one-liner in `index.html`, this README and `<project-name>/README.md`.
4. Before pushing: `bash -n` and `shellcheck -S warning` on every script.
