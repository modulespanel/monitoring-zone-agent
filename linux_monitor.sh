#!/bin/bash

################################################################################
# Server Resource Monitoring Script
################################################################################

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
RESOURCE_ID="${1:-}"

API_BASE_URL="__APP_URL__"
API_URL="${API_BASE_URL}/resource-monitor/webhook/${RESOURCE_ID}"
AUTH_TOKEN="__AUTH_TOKEN__"

# Detect default network interface (works on Ubuntu / Debian / CentOS)
NETWORK_INTERFACE=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -n1)

# Snapshot file — persists between cron runs for CPU + bandwidth diffing
SNAPSHOT="/tmp/.resource_monitor_snapshot"

# ---------------------------------------------------------------------------
# Read current raw values
# ---------------------------------------------------------------------------
# CPU: read the aggregate 'cpu ' line from /proc/stat
# Fields: user nice system idle iowait irq softirq steal guest guest_nice
CPU_RAW=$(grep '^cpu ' /proc/stat)
read -r _ CPU_USER CPU_NICE CPU_SYSTEM CPU_IDLE CPU_IOWAIT CPU_IRQ CPU_SOFTIRQ CPU_STEAL CPU_GUEST CPU_GUEST_NICE <<< "$CPU_RAW"

# ---------------------------------------------------------------------------
# 2.  Network  —  raw byte counters from sysfs
# ---------------------------------------------------------------------------
# Network: read raw byte counters from sysfs
NET_RX_BYTES=$(cat /sys/class/net/"$NETWORK_INTERFACE"/statistics/rx_bytes 2>/dev/null || echo 0)
NET_TX_BYTES=$(cat /sys/class/net/"$NETWORK_INTERFACE"/statistics/tx_bytes 2>/dev/null || echo 0)

# ---------------------------------------------------------------------------
# 3.  Epoch
# ---------------------------------------------------------------------------
NOW=$(date +%s)

# ---------------------------------------------------------------------------
# 4.  Diff against previous snapshot  →  CPU %  +  Kbps
# ---------------------------------------------------------------------------
CPU_USAGE="0.00"
IOWAIT_USAGE="0.00"
SENT_KBPS="0.00"
RECV_KBPS="0.00"

if [ -f "$SNAPSHOT" ]; then
    # Read previous snapshot
    # Format: epoch user nice system idle iowait irq softirq steal rx_bytes tx_bytes
    read -r PREV_TIME \
         PREV_USER PREV_NICE PREV_SYSTEM PREV_IDLE PREV_IOWAIT PREV_IRQ PREV_SOFTIRQ PREV_STEAL PREV_GUEST PREV_GUEST_NICE \
         PREV_RX PREV_TX < "$SNAPSHOT"

    # ----- CPU calculation -----
    # Total CPU ticks in each snapshot
    PREV_TOTAL=$((PREV_USER + PREV_NICE + PREV_SYSTEM + PREV_IDLE + PREV_IOWAIT + PREV_IRQ + PREV_SOFTIRQ + PREV_STEAL))
    NOW_TOTAL=$((CPU_USER + CPU_NICE + CPU_SYSTEM + CPU_IDLE + CPU_IOWAIT + CPU_IRQ + CPU_SOFTIRQ + CPU_STEAL))

    TOTAL_DIFF=$((NOW_TOTAL - PREV_TOTAL))
    IDLE_DIFF=$((CPU_IDLE - PREV_IDLE))

    if [ "$TOTAL_DIFF" -gt 0 ]; then
        CPU_USAGE=$(awk "BEGIN {printf \"%.2f\", 100.0 * (1.0 - ($IDLE_DIFF / $TOTAL_DIFF))}")
        IOWAIT_DIFF=$((CPU_IOWAIT - PREV_IOWAIT))
        IOWAIT_USAGE=$(awk "BEGIN {printf \"%.2f\", 100.0 * ($IOWAIT_DIFF / $TOTAL_DIFF)}")
    fi

    # ----- Bandwidth calculation -----
    TIME_DIFF=$((NOW - PREV_TIME))

    if [ "$TIME_DIFF" -gt 0 ]; then
        RX_DIFF=$((NET_RX_BYTES - PREV_RX))
        TX_DIFF=$((NET_TX_BYTES - PREV_TX))

        # Convert bytes/sec -> Kbps  (x8 bits, /1000)
        RECV_KBPS=$(awk "BEGIN {printf \"%.2f\", ($RX_DIFF / $TIME_DIFF * 8) / 1000}")
        SENT_KBPS=$(awk "BEGIN {printf \"%.2f\", ($TX_DIFF / $TIME_DIFF * 8) / 1000}")
    fi
fi

# ---------------------------------------------------------------------------
# 5.  Write new snapshot  (all 10 cpu fields + 2 net counters)
# ---------------------------------------------------------------------------
echo "$NOW $CPU_USER $CPU_NICE $CPU_SYSTEM $CPU_IDLE $CPU_IOWAIT $CPU_IRQ $CPU_SOFTIRQ $CPU_STEAL $CPU_GUEST $CPU_GUEST_NICE $NET_RX_BYTES $NET_TX_BYTES" > "$SNAPSHOT"
# ---------------------------------------------------------------------------
# 6.  Memory
#     Mirrors: psutil.virtual_memory().percent  and  .total
# ---------------------------------------------------------------------------
MEMORY_PERCENT=$(free | awk 'NR==2{ printf "%.1f", $3*100/$2 }')
TOTAL_RAM_GB=$(free -b | awk 'NR==2{ printf "%.2f", $2/(1024^3) }')

# ---------------------------------------------------------------------------
# 7.  Disk  —  mirrors the Linux branch of get_disk_usage()
# ---------------------------------------------------------------------------
DISK_PERCENT=$(df / | awk 'NR==2{ gsub(/%/,"",$5); print $5 }')
DISK_TOTAL_GB=$(df -B1 / | awk 'NR==2{ printf "%.2f", $2/(1024^3) }')
DISK_USED_GB=$(df -B1 / | awk 'NR==2{ printf "%.2f", $3/(1024^3) }')
DISK_FREE_GB=$(df -B1 / | awk 'NR==2{ printf "%.2f", $4/(1024^3) }')

NUM_VOLUMES=$(df -B1 | grep -cE '^/dev/')
TOTAL_SIZE_GB=$(df -B1 | grep -E '^/dev/' | awk '{ sum+=$2 } END { printf "%.2f", sum/(1024^3) }')

# ---------------------------------------------------------------------------
# 8.  IP addresses
# ---------------------------------------------------------------------------
PUBLIC_IPV4=$(ip -4 addr show 2>/dev/null \
    | grep -oP '(?<=inet\s)\d+(\.\d+){3}' \
    | grep -v '^127\.' \
    | grep -v '^169\.254\.' \
    | head -n1)
[ -z "$PUBLIC_IPV4" ] && PUBLIC_IPV4="No IPv4 found"

PUBLIC_IPV6=$(ip -6 addr show 2>/dev/null \
    | grep -oP '(?<=inet6\s)[\da-f:]+' \
    | grep -v '^::1' \
    | grep -v '^fe80' \
    | head -n1)
[ -z "$PUBLIC_IPV6" ] && PUBLIC_IPV6="No IPv6 found"

# ---------------------------------------------------------------------------
# 9.  Other
# ---------------------------------------------------------------------------
CPU_CORES=$(nproc)
OS_NAME=$(uname -s)          # "Linux"

# ---------------------------------------------------------------------------
# 10. Sanitize string fields (whitelist characters to prevent JSON breakage)
# ---------------------------------------------------------------------------
PUBLIC_IPV4=$(printf '%s' "$PUBLIC_IPV4" | tr -dc '0-9a-fA-F.:' | cut -c1-39)
PUBLIC_IPV6=$(printf '%s' "$PUBLIC_IPV6" | tr -dc '0-9a-fA-F:' | cut -c1-39)
OS_NAME=$(printf '%s' "$OS_NAME" | tr -dc 'A-Za-z0-9 ._-' | cut -c1-64)

# ---------------------------------------------------------------------------
# 11. Build JSON
# ---------------------------------------------------------------------------
JSON=$(printf '{"cpu_usage":%s,"iowait_usage":%s,"memory_usage":%s,"network_sent_kbps":%s,"network_received_kbps":%s,"cpu_cores":%s,"total_ram_gb":%s,"public_ipv4":"%s","public_ipv6":"%s","disk_data":{"percent":%s,"total_gb":%s,"used_gb":%s,"free_gb":%s,"num_volumes":%s,"total_size_gb":%s},"os":"%s"}' \
    "$CPU_USAGE" "$IOWAIT_USAGE" "$MEMORY_PERCENT" "$SENT_KBPS" "$RECV_KBPS" \
    "$CPU_CORES" "$TOTAL_RAM_GB" \
    "$PUBLIC_IPV4" "$PUBLIC_IPV6" \
    "$DISK_PERCENT" "$DISK_TOTAL_GB" "$DISK_USED_GB" "$DISK_FREE_GB" \
    "$NUM_VOLUMES" "$TOTAL_SIZE_GB" \
    "$OS_NAME")

# ---------------------------------------------------------------------------
# 12. POST
# ---------------------------------------------------------------------------
HTTP_CODE=$(curl -s --max-time 10 -o /tmp/_monitor_resp_$$.txt -w "%{http_code}" \
    -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    --data-raw "$JSON")

RESP=$(cat /tmp/_monitor_resp_$$.txt 2>/dev/null)
rm -f /tmp/_monitor_resp_$$.txt

# ---------------------------------------------------------------------------
# 13. Log line
# ---------------------------------------------------------------------------
logger -t resource-monitor "CPU: ${CPU_USAGE}% | IOWait: ${IOWAIT_USAGE}% | RAM: ${MEMORY_PERCENT}% | Disk: ${DISK_PERCENT}% | TX: ${SENT_KBPS} Kbps | RX: ${RECV_KBPS} Kbps | HTTP: ${HTTP_CODE} | ${RESP}"

[ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ] && exit 0 || exit 1
