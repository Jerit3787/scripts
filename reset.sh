#!/usr/bin/env bash
# CAIDPS Teardown & Factory Reset Script
# Completely reverses the CAIDPS installation, removes background services,
# deletes local & remote Cloudflare configurations, and purges auto-installed packages
# so the server is restored to its fresh, uninstalled state for end-to-end testing.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Jerit3787/scripts/main/reset.sh | bash
#   curl -fsSL https://scripts.danplace.tech/reset.sh | bash
#
set -u

# ANSI colors
if [ -t 1 ]; then
  BOLD="\033[1m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  RED="\033[31m"
  CYAN="\033[36m"
  RESET="\033[0m"
else
  BOLD=""
  GREEN=""
  YELLOW=""
  RED=""
  CYAN=""
  RESET=""
fi

echo -e "${RED}${BOLD}"
echo "================================================================="
echo "             CAIDPS System Teardown & Factory Reset              "
echo "================================================================="
echo -e "${RESET}"
echo "This will revert all changes made by CAIDPS, including:"
echo "  1. Stopping and deleting the 'caidps' systemd service"
echo "  2. Stopping and removing Docker containers (juice-shop, etc.)"
echo "  3. Deleting Cloudflare Tunnel registrations and local credentials"
echo "  4. Removing /opt/caidps and global CLI commands"
echo "  5. Purging auto-installed packages (cloudflared, nodejs, docker, whiptail)"
echo ""

# Ensure sudo / elevated permissions if needed
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo -e "${RED}[error] Elevated root privileges are required to uninstall system services and packages.${RESET}" >&2
    exit 1
  fi
fi

# 1. Stop and remove systemd service
echo -e "${CYAN}[1/6] Stopping and removing CAIDPS systemd background service...${RESET}"
if command -v systemctl >/dev/null 2>&1; then
  $SUDO systemctl stop caidps 2>/dev/null || true
  $SUDO systemctl disable caidps 2>/dev/null || true
  $SUDO rm -f /etc/systemd/system/caidps.service /lib/systemd/system/caidps.service
  $SUDO systemctl daemon-reload 2>/dev/null || true
  $SUDO systemctl reset-failed caidps 2>/dev/null || true
fi

# Kill any lingering CAIDPS processes
pkill -9 -f "uvicorn app:app" 2>/dev/null || true
pkill -9 -f "proxy.server" 2>/dev/null || true
pkill -9 -f "scripts/serve.sh" 2>/dev/null || true
pkill -9 -f "cloudflared tunnel" 2>/dev/null || true

# 2. Stop and remove Docker containers
echo -e "${CYAN}[2/6] Cleaning up Docker containers and ranges...${RESET}"
if command -v docker >/dev/null 2>&1; then
  $SUDO docker stop juice-shop vulnbank medivault dvna cicd-goat 2>/dev/null || true
  $SUDO docker rm -f juice-shop vulnbank medivault dvna cicd-goat 2>/dev/null || true
fi

# 3. Cloudflare Tunnel cleanup
echo -e "${CYAN}[3/6] Cleaning up Cloudflare Tunnel and certificates...${RESET}"
if command -v cloudflared >/dev/null 2>&1; then
  # Delete remote tunnel registration if logged in
  cloudflared tunnel delete -f caidps 2>/dev/null || true
  cloudflared tunnel cleanup caidps 2>/dev/null || true
fi
# Remove local credentials, tokens, and certs across all users
$SUDO rm -rf /root/.cloudflared /etc/cloudflared
rm -rf ~/.cloudflared /home/*/.cloudflared /tmp/cloudflared* 2>/dev/null || true
$SUDO rm -rf /home/*/.cloudflared 2>/dev/null || true

# 4. Remove /opt/caidps and CLI links
echo -e "${CYAN}[4/6] Deleting repository and global CLI symlinks...${RESET}"
$SUDO rm -rf /opt/caidps "${HOME}/caidps" /home/*/caidps /tmp/caidps* 2>/dev/null || true
$SUDO rm -f /usr/local/bin/caidps "${HOME}/.local/bin/caidps" /home/*/.local/bin/caidps 2>/dev/null || true

# 5. Purge auto-installed system packages
echo -e "${CYAN}[5/6] Purging auto-installed software packages (cloudflared, Node.js, Docker, whiptail)...${RESET}"
os_type="$(uname -s)"
case "$os_type" in
  Linux)
    if command -v apt-get >/dev/null 2>&1; then
      # Purge cloudflared
      $SUDO apt-get purge -y cloudflared 2>/dev/null || true
      $SUDO rm -f /usr/local/bin/cloudflared /usr/bin/cloudflared /etc/apt/sources.list.d/cloudflared* 2>/dev/null || true

      # Purge nodejs & npm
      $SUDO apt-get purge -y nodejs npm 2>/dev/null || true
      $SUDO rm -f /etc/apt/sources.list.d/nodesource* /etc/apt/keyrings/nodesource* 2>/dev/null || true

      # Purge Docker packages and storage
      if command -v systemctl >/dev/null 2>&1; then
        $SUDO systemctl stop docker 2>/dev/null || true
        $SUDO systemctl disable docker 2>/dev/null || true
      fi
      $SUDO apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io 2>/dev/null || true
      $SUDO rm -rf /var/lib/docker /var/lib/containerd /etc/docker 2>/dev/null || true
      $SUDO rm -f /etc/apt/sources.list.d/docker* /etc/apt/keyrings/docker* 2>/dev/null || true

      # Purge whiptail
      $SUDO apt-get purge -y whiptail 2>/dev/null || true

      # Autoremove dangling libraries and clean cache
      $SUDO apt-get autoremove -y >/dev/null 2>&1 || true
      $SUDO apt-get clean >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
      $SUDO dnf remove -y cloudflared nodejs npm docker-ce docker-ce-cli containerd.io newt 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
      $SUDO yum remove -y cloudflared nodejs npm docker-ce docker-ce-cli containerd.io newt 2>/dev/null || true
    fi
    ;;
  Darwin)
    if command -v brew >/dev/null 2>&1; then
      brew uninstall cloudflared node newt 2>/dev/null || true
    fi
    $SUDO rm -f /usr/local/bin/cloudflared 2>/dev/null || true
    ;;
esac

# 6. Verify clean state
echo -e "${CYAN}[6/6] Verifying server state...${RESET}"
echo ""
echo "================================================================="
echo -e "${GREEN}${BOLD}         CAIDPS Reset Complete — Fresh State Restored!           ${RESET}"
echo "================================================================="
echo -e "  • Service (/etc/systemd/system/caidps.service) : ${GREEN}Removed${RESET}"
echo -e "  • Repository (/opt/caidps)                     : ${GREEN}Removed${RESET}"
echo -e "  • Global CLI (/usr/local/bin/caidps)           : ${GREEN}Removed${RESET}"
echo -e "  • Cloudflare Certs (~/.cloudflared)            : ${GREEN}Removed${RESET}"
echo -e "  • Auto-installed packages                      : ${GREEN}Purged${RESET}"
echo "================================================================="
echo ""
echo -e "${BOLD}You can now perform a clean end-to-end install test:${RESET}"
echo -e "  ${CYAN}curl -fsSL https://raw.githubusercontent.com/Jerit3787/scripts/main/idps.sh | bash${RESET}"
echo ""
