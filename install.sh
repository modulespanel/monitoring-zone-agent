#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# Configurable variables (placeholders replaced by the web app via sed)
# ---------------------------------------------------------------------------
INSTALL_DIR="/resource_monitor"

# Cron script (full metrics — CPU, RAM, Disk, Network)
CRON_SCRIPT_URL="https://raw.githubusercontent.com/modulespanel/monitoring-zone-agent/main/linux_monitor.sh"
CRON_SCRIPT_PATH="$INSTALL_DIR/resource_monitor.sh"
CRON_JOB="* * * * * bash $CRON_SCRIPT_PATH PLACEHOLDER_ID >> $INSTALL_DIR/cron.log 2>&1"

# Daemon script (CPU spike detection)
DAEMON_SCRIPT_URL="https://raw.githubusercontent.com/modulespanel/monitoring-zone-agent/main/linux_monitor_daemon.sh"
DAEMON_SCRIPT_PATH="$INSTALL_DIR/resource_monitor_daemon.sh"
SERVICE_NAME="resource-monitor-daemon"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo "======================================"
echo "   Resource Monitor Full Installer    "
echo "   Cron  : full metrics every 60s     "
echo "   Daemon: CPU spike detection        "
echo "======================================"

# --- 0. Root check ---
if [ "$EUID" -ne 0 ]; then
    echo "Must be run as root (sudo). Exiting..."
    exit 1
fi

# --- 1. OS check ---
if [ -f /etc/debian_version ]; then
    echo "Detected Ubuntu/Debian"
    PKG_INSTALL="apt-get install -y -qq"
elif [ -f /etc/redhat-release ]; then
    echo "CentOS/RHEL detected. Only Ubuntu/Debian is supported. Exiting..."
    exit 1
else
    echo "Unsupported OS. Exiting..."
    exit 1
fi

# --- 2. Update & install dependencies (once) ---
echo "==> Updating package lists..."
apt-get update --allow-releaseinfo-change -qq 2>/dev/null || apt-get update -qq

echo "==> Checking required packages..."
for pkg in curl ip iostat; do
    if ! command -v "$pkg" &>/dev/null; then
        echo "-> Installing $pkg..."
        case "$pkg" in
            ip)      $PKG_INSTALL iproute2 ;;
            iostat)  $PKG_INSTALL sysstat ;;
            *)       $PKG_INSTALL "$pkg" ;;
        esac
    else
        echo "-> $pkg already installed."
    fi
done

# --- 3. Stop and kill any existing daemon ---
echo "==> Stopping any existing resource monitor daemon..."
systemctl stop resource-monitor-daemon 2>/dev/null || true
pkill -f resource_monitor_daemon.sh 2>/dev/null || true

# --- 4. Create install directory ---
echo "==> Creating $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
chown -R "$SUDO_USER:$SUDO_USER" "$INSTALL_DIR"

# --- 5. Download cron script ---
echo "==> Downloading resource_monitor.sh (cron)..."
WGET_OPTS="-q"
if ! curl -6 -s --max-time 3 -o /dev/null https://ipv6.google.com 2>/dev/null; then
    WGET_OPTS="-q -4"
fi
wget $WGET_OPTS -O "$CRON_SCRIPT_PATH" "$CRON_SCRIPT_URL"
if [ ! -s "$CRON_SCRIPT_PATH" ]; then
    echo "Failed to download resource_monitor.sh. Exiting..."
    exit 1
fi
sed -i "s|__APP_URL__|PLACEHOLDER_APP_URL|g" "$CRON_SCRIPT_PATH"
sed -i "s|__AUTH_TOKEN__|PLACEHOLDER_TOKEN|g" "$CRON_SCRIPT_PATH"
chmod +x "$CRON_SCRIPT_PATH"
chown "$SUDO_USER:$SUDO_USER" "$CRON_SCRIPT_PATH"
echo "resource_monitor.sh ready."

# --- 5. Download daemon script ---
echo "==> Downloading resource_monitor_daemon.sh (daemon)..."
wget $WGET_OPTS -O "$DAEMON_SCRIPT_PATH" "$DAEMON_SCRIPT_URL"
if [ ! -s "$DAEMON_SCRIPT_PATH" ]; then
    echo "Failed to download resource_monitor_daemon.sh. Exiting..."
    exit 1
fi
sed -i "s|__APP_URL__|PLACEHOLDER_APP_URL|g" "$DAEMON_SCRIPT_PATH"
sed -i "s|__AUTH_TOKEN__|PLACEHOLDER_TOKEN|g" "$DAEMON_SCRIPT_PATH"
sed -i "s|__CPU_THRESHOLD__|PLACEHOLDER_THRESHOLD|g" "$DAEMON_SCRIPT_PATH"
chmod +x "$DAEMON_SCRIPT_PATH"
echo "resource_monitor_daemon.sh ready."

# --- 6. Clear stale snapshots ---
rm -f /tmp/.resource_monitor_snapshot_cron
rm -f /tmp/.resource_monitor_daemon_snapshot
echo "Cleared old snapshots."

# --- 7. Setup cron job ---
echo "==> Configuring cron job for user $SUDO_USER..."
(crontab -u "$SUDO_USER" -l 2>/dev/null | grep -v "$INSTALL_DIR"; echo "$CRON_JOB") | crontab -u "$SUDO_USER" -
echo "Cron job configured (every 60s)."

# --- 8. Create systemd service for daemon ---
echo "==> Creating systemd service..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Resource Monitor CPU Daemon (PLACEHOLDER_ID)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $DAEMON_SCRIPT_PATH PLACEHOLDER_ID
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# --- 9. Enable and start daemon ---
echo "==> Enabling and starting daemon service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"
echo "Daemon service started."

# --- 10. Seed initial snapshot ---
echo "==> Running initial seed..."
bash "$CRON_SCRIPT_PATH" "PLACEHOLDER_ID" || true

echo "======================================"
echo "      Resource Monitor Setup Done     "
echo ""
echo "  Cron  : full metrics every 60s      "
echo "  Logs  : $INSTALL_DIR/cron.log       "
echo ""
echo "  Daemon: CPU spike detection running "
echo "  Status: systemctl status $SERVICE_NAME"
echo "  Logs  : journalctl -t $SERVICE_NAME -f"
echo "======================================"
