# Monitoring Zone Agent

Shell scripts for the [Monitoring Zone](https://monitoring.zone) resource monitoring addon. These scripts are installed on your Linux servers to collect and report CPU, RAM, disk, and network metrics.

> **Note:** These scripts are served and configured automatically through the Monitoring Zone dashboard. Do not run them directly from GitHub — use the install command generated in your dashboard.

---

## Scripts

### `install.sh`
The main installer. Sets up both the cron job (full metrics) and the CPU spike daemon on your server.

It is served by the Monitoring Zone app with the following placeholders replaced before delivery:

| Placeholder | Replaced with |
|---|---|
| `PLACEHOLDER_ID` | Your monitor's unique UUID |
| `PLACEHOLDER_APP_URL` | Your Monitoring Zone app URL |
| `PLACEHOLDER_TOKEN` | Your monitor's webhook token |
| `PLACEHOLDER_THRESHOLD` | CPU spike threshold percentage (default: 80) |

**What it does:**
- Detects OS (Ubuntu/Debian only)
- Installs required packages: `curl`, `iproute2`, `sysstat`
- Downloads `linux_monitor.sh` and `linux_monitor_daemon.sh` from this repo
- Replaces `__APP_URL__`, `__AUTH_TOKEN__`, `__CPU_THRESHOLD__` in the downloaded scripts
- Sets up a cron job to run `linux_monitor.sh` every minute
- Creates and starts a systemd service for `linux_monitor_daemon.sh`
- Runs an initial seed so the first cron tick has real data

---

### `linux_monitor.sh`
The cron script. Runs every minute and POSTs full server metrics to the Monitoring Zone API.

**Collects:**
- CPU usage % and I/O wait %
- RAM usage % and total RAM (GB)
- Disk usage %, total, used, and free (GB)
- Network bandwidth in/out (Kbps)
- Public IPv4 and IPv6 addresses
- CPU core count and OS name

**How it works:**
- Reads `/proc/stat` for CPU ticks and diffs against a snapshot from the previous run
- Reads `/sys/class/net/` for raw network byte counters and diffs for Kbps calculation
- Snapshot is stored in `/tmp/.resource_monitor_snapshot` between runs
- POSTs a JSON payload to `APP_URL/resource-monitor/webhook/MONITOR_ID`
- Logs each run via `logger` (visible with `journalctl -t resource-monitor`)

**Placeholders (replaced by `install.sh`):**

| Placeholder | Description |
|---|---|
| `__APP_URL__` | Monitoring Zone app URL |
| `__AUTH_TOKEN__` | Monitor webhook token (Bearer auth) |

---

### `linux_monitor_daemon.sh`
Runs as a systemd service, sampling CPU every 5 seconds to catch short-lived spikes that a 1-minute cron would miss.

**Collects:**
- CPU usage % and I/O wait %
- Disk I/O read/write (kB/s), await (ms), utilization % via `iostat`
- Top 3 processes by CPU usage during a spike (name, CPU %, RAM %)

**How it works:**
- Loops every 5 seconds reading `/proc/stat`
- When CPU exceeds the configured threshold, captures top processes from `/proc/[pid]/stat`
- POSTs to `APP_URL/resource-monitor/daemon-webhook/MONITOR_ID`
- Handles `SIGTERM`/`SIGINT` cleanly for systemd stop
- Logs via `logger` (visible with `journalctl -t resource-monitor-daemon`)

**Placeholders (replaced by `install.sh`):**

| Placeholder | Description |
|---|---|
| `__APP_URL__` | Monitoring Zone app URL |
| `__AUTH_TOKEN__` | Monitor webhook token (Bearer auth) |
| `__CPU_THRESHOLD__` | CPU % threshold to trigger spike capture |

---

## Requirements

- Ubuntu / Debian (20.04+)
- Must be run as root (`sudo`)
- Packages: `curl`, `iproute2`, `sysstat` (installed automatically by `install.sh`)

---

## Installed File Locations

| File | Path |
|---|---|
| Cron script | `/resource_monitor/resource_monitor.sh` |
| Daemon script | `/resource_monitor/resource_monitor_daemon.sh` |
| Cron logs | `/resource_monitor/cron.log` |
| Daemon logs | `journalctl -t resource-monitor-daemon` |
| Systemd service | `/etc/systemd/system/resource-monitor-daemon.service` |

---

## Useful Commands

```bash
# Check daemon status
systemctl status resource-monitor-daemon

# Follow daemon logs
journalctl -t resource-monitor-daemon -f

# Follow cron logs
tail -f /resource_monitor/cron.log

# Stop the daemon
systemctl stop resource-monitor-daemon

# Uninstall
systemctl stop resource-monitor-daemon
systemctl disable resource-monitor-daemon
rm -rf /resource_monitor
rm /etc/systemd/system/resource-monitor-daemon.service
crontab -l | grep -v resource_monitor | crontab -
```
