#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# Configurable variables (placeholders replaced by the web app via sed)
# ---------------------------------------------------------------------------
INSTALL_DIR="/resource_monitor"
SCRIPT_URL="https://raw.githubusercontent.com/modulespanel/monitoring-zone-agent/main/linux_monitor_daemon.sh"
# Daemon samples CPU every 5s to catch short-lived spikes a 1-minute cron would miss
SCRIPT_PATH="$INSTALL_DIR/resource_monitor_daemon.sh"
SERVICE_NAME="resource-monitor-daemon"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo "======================================"
echo "   Resource Monitor Daemon Installer  "
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
else
    echo "Only Ubuntu/Debian supported. Exiting..."
    exit 1
fi

# --- 2. Dependencies ---
echo "==> Checking required packages..."
apt-get update --allow-releaseinfo-change -qq 2>/dev/null || apt-get update -qq

for pkg in curl; do
    if ! command -v "$pkg" &>/dev/null; then
        echo "-> Installing $pkg..."
        $PKG_INSTALL "$pkg"
    else
        echo "-> $pkg already installed."
    fi
done

# --- 3. Install directory ---
echo "==> Creating $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# --- 4. Download daemon script ---
echo "==> Downloading daemon script..."
wget -q -O "$SCRIPT_PATH" "$SCRIPT_URL"

if [ ! -s "$SCRIPT_PATH" ]; then
    echo "Failed to download daemon script. Exiting..."
    exit 1
fi

sed -i "s|__APP_URL__|PLACEHOLDER_APP_URL|g" "$SCRIPT_PATH"
sed -i "s|__AUTH_TOKEN__|PLACEHOLDER_TOKEN|g" "$SCRIPT_PATH"
sed -i "s|__CPU_THRESHOLD__|PLACEHOLDER_THRESHOLD|g" "$SCRIPT_PATH"

chmod +x "$SCRIPT_PATH"
echo "Daemon script ready at $SCRIPT_PATH"

# --- 5. Create systemd service ---
echo "==> Creating systemd service..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Resource Monitor CPU Daemon (PLACEHOLDER_ID)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $SCRIPT_PATH PLACEHOLDER_ID
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# --- 6. Enable and start ---
echo "==> Enabling and starting service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

echo "======================================"
echo "   Resource Monitor Daemon Running    "
echo "   Service : $SERVICE_NAME                          "
echo "   Logs    : journalctl -t resource-monitor-daemon  "
echo "   Follow  : journalctl -t resource-monitor-daemon -f"
echo "   Status  : systemctl status $SERVICE_NAME         "
echo "======================================"
