# danplace.tech Scripts & One-Liner Installers

A collection of one-line installers and utilities for [danplace.tech](https://danplace.tech) projects,
served at **[https://scripts.danplace.tech](https://scripts.danplace.tech)** (GitHub Pages).

The root page is a **script catalog**: each project gets a card, and project-specific detail pages live in
their own folders. Each project keeps **one copy** of its scripts in a folder named after the project.
Link to that path; there are no aliases at the root.

---

## CAIDPS (`IDPS-WebServer/`)

Context-Aware Intrusion Detection & Prevention System: installer, setup wizard and factory reset.

Project page: **[scripts.danplace.tech/IDPS-WebServer](https://scripts.danplace.tech/IDPS-WebServer/)**

```bash
# Interactive install (or update) and run the setup wizard
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | bash

# Unattended production install: Docker Compose stack (recommended)
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/setup.sh | CAIDPS_NON_INTERACTIVE=1 bash

# Remove an installation (asks you to type "reset" first; deletes local CAIDPS
# data/database/volumes, so back up with scripts/backup.sh create before resetting)
curl -fsSL https://scripts.danplace.tech/IDPS-WebServer/reset.sh | bash
```

Details, current options and environment variables: [`IDPS-WebServer/README.md`](IDPS-WebServer/README.md).

---

## Directory structure

```
.
├── CNAME                  # scripts.danplace.tech
├── .nojekyll              # serve files as-is (no Jekyll)
├── favicon.svg            # catalog/project icon
├── index.html             # script catalog with copy buttons
├── 404.html               # not-found page (absolute /assets paths)
├── assets/
│   ├── site.css           # shared Atlassian-style tokens and components (light/dark)
│   ├── site.js            # theme toggle, tabs, copy flags, script viewer
│   └── icons.svg          # SVG icon sprite
├── tools/
│   └── stamp-assets.sh    # stamps ?v=<hash> on asset URLs in every page
└── IDPS-WebServer/
    ├── setup.sh           # CAIDPS installer and setup wizard
    ├── reset.sh           # CAIDPS teardown / factory reset
    ├── README.md          # developer/operator details
    ├── index.html         # CAIDPS project page
    ├── logo.svg           # CAIDPS mark (copied from IDPS-WebServer frontend-react/public/logo.svg)
    └── tests/
        └── run-tests.sh   # stub-driven bash tests
```

## Adding a project

1. Create a folder named after the project: `<project-name>/`.
2. Put its scripts there (`<project-name>/setup.sh`, …) — one copy each, no root aliases.
3. Add an optional detail page at `<project-name>/index.html` for long setup notes, previews and options.
4. Add a card to the root `index.html` catalog: name, short description, tags, copyable install command,
   and links to the project page, source and documentation.
5. Document the one-liner in this README and `<project-name>/README.md`.
6. Link the shared files from the project page as plain `../assets/site.css`, `../assets/site.js` and
   `../assets/icons.svg#…`, then run `tools/stamp-assets.sh` to add the version stamp.
7. Before pushing: `bash -n` and `shellcheck -S warning` on every script; preview both the catalog and the
   project page in a browser.

## Changing the site styles

GitHub Pages lets browsers cache files for 10 minutes, so a page can load before its new stylesheet does.
Every page links `assets/` with a `?v=<hash>` stamp. After changing anything in `assets/`, run
`tools/stamp-assets.sh` and commit the updated pages with it.
