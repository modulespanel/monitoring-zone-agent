#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# Configurable variables
# ---------------------------------------------------------------------------
INSTALL_DIR="/resource_monitor"
SCRIPT_URL="https://raw.githubusercontent.com/modulespanel/monitoring-zone-agent/main/linux_monitor.sh"
SCRIPT_PATH="$INSTALL_DIR/resource_monitor.sh"
CRON_JOB="*/5 * * * * bash $SCRIPT_PATH PLACEHOLDER_ID >> $INSTALL_DIR/cron.log 2>&1"

echo "======================================"
echo "       Resource Monitor Installer      "
echo "======================================"

# --- 0. Root / sudo check ---
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root (sudo user). Exiting..."
  exit 1
fi

# --- 1. Detect OS and package manager ---
if [ -f /etc/debian_version ]; then
    echo "Detected Ubuntu/Debian"
    PKG_INSTALL="apt-get install -y -qq"
elif [ -f /etc/redhat-release ]; then
    echo "CentOS/RHEL detected. Only Ubuntu machines are supported for now. Exiting..."
    exit 1
else
    echo "Unsupported OS. Exiting..."
    exit 1
fi

# --- 2. Update repositories ---
echo "==> Updating package lists..."
apt-get update --allow-releaseinfo-change -qq 2>/dev/null || apt-get update --allow-releaseinfo-change -qq

# --- 3. Ensure required packages ---
#   curl     -> POSTs the data to the API
#   iproute2 -> provides the `ip` command (interface / IPv4 / IPv6 detection)
echo "==> Checking and installing required packages..."

if ! command -v curl &>/dev/null; then
    echo "-> curl not found. Installing..."
    $PKG_INSTALL curl
else
    echo "-> curl is already installed."
fi

if ! command -v ip &>/dev/null; then
    echo "-> iproute2 not found. Installing..."
    $PKG_INSTALL iproute2
else
    echo "-> iproute2 is already installed."
fi

# --- 4. Create install directory ---
echo "==> Creating installation directory at $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
chown -R "$SUDO_USER:$SUDO_USER" "$INSTALL_DIR"

# --- 5. Download monitoring script ---
echo "==> Downloading resource_monitor.sh..."
wget -q -O "$SCRIPT_PATH" "$SCRIPT_URL"

if [ ! -s "$SCRIPT_PATH" ]; then
  echo "Failed to download resource_monitor.sh or file is empty. Exiting..."
  exit 1
fi

sed -i "s|__APP_URL__|PLACEHOLDER_APP_URL|g" "$SCRIPT_PATH"
sed -i "s|__AUTH_TOKEN__|PLACEHOLDER_TOKEN|g" "$SCRIPT_PATH"

chmod +x "$SCRIPT_PATH"
chown "$SUDO_USER:$SUDO_USER" "$SCRIPT_PATH"
echo "Monitoring script is ready!"

# --- 6. Clear any stale snapshot from a previous install ---
rm -f /tmp/.resource_monitor_snapshot
echo "Cleared old snapshot."

# --- 7. Setup cron job ---
echo "==> Configuring cron job for user $SUDO_USER..."
(crontab -u "$SUDO_USER" -l 2>/dev/null | grep -v "$INSTALL_DIR"; echo "$CRON_JOB") | crontab -u "$SUDO_USER" -
echo "Cron job configured successfully!"

# --- 8. Seed the snapshot (run once so next cron tick has real CPU / bandwidth) ---
echo "==> Running initial seed..."
RESOURCE_ID=$(echo "$CRON_JOB" | awk '{print $8}')
bash "$SCRIPT_PATH" "$RESOURCE_ID" || true

echo "======================================"
echo "      Resource Monitor Setup Done      "
echo "  resource_monitor.sh runs every   "
echo "  5 minutes via cron.                  "
echo "  Logs: $INSTALL_DIR/cron.log          "
echo "======================================"
