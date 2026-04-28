#!/bin/bash

################################################################################
# Resource Monitor — CPU Daemon
# Runs as a systemd service, samples CPU every 5s to catch short-lived spikes
# that a 1-minute cron would miss.
################################################################################

RESOURCE_ID="${1:-}"
API_BASE_URL="__APP_URL__"
AUTH_TOKEN="__AUTH_TOKEN__"
CPU_SPIKE_THRESHOLD="__CPU_THRESHOLD__"
INTERVAL=5

API_URL="${API_BASE_URL}/resource-monitor/daemon-webhook/${RESOURCE_ID}"
SNAPSHOT="/tmp/.resource_monitor_daemon_snapshot"
PROC_SNAPSHOT="/tmp/.resource_monitor_proc_snapshot"
PROC_CURR="/tmp/.resource_monitor_proc_curr"

# ---------------------------------------------------------------------------
# Clean exit on SIGTERM / SIGINT (systemd stop)
# ---------------------------------------------------------------------------
trap 'logger -t resource-monitor-daemon "Daemon stopping."; rm -f "$SNAPSHOT" "$PROC_SNAPSHOT" "$PROC_CURR"; exit 0' SIGTERM SIGINT

logger -t resource-monitor-daemon "Daemon started. Posting every ${INTERVAL}s to ${API_URL}"

TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
[ "${TOTAL_MEM_KB:-0}" -le 0 ] 2>/dev/null && TOTAL_MEM_KB=1

# ---------------------------------------------------------------------------
# Snapshot per-process CPU ticks + RSS into PROC_CURR
# Read at the same moment as /proc/stat so both cover the same interval
# Output: "pid ticks rss name" per line
# ---------------------------------------------------------------------------
snapshot_procs() {
    for f in /proc/[0-9]*/stat; do
        [ -r "$f" ] || continue
        IFS= read -r line < "$f" 2>/dev/null || continue
        pid="${line%% *}"
        tmp="${line#*(}"; name="${tmp%%)*}"
        name="${name//[^A-Za-z0-9._-]/}"
        [ -z "$name" ] && name="unknown"
        [ "${#name}" -gt 30 ] && name="${name:0:30}"
        rest="${line##*) }"
        read -ra fields <<< "$rest"
        ticks=$(( ${fields[11]:-0} + ${fields[12]:-0} ))
        # RSS from statm field 2 (pages)
        rss=0
        statm="${f%stat}statm"
        if [ -r "$statm" ]; then
            read -ra sm < "$statm" 2>/dev/null
            rss=${sm[1]:-0}
        fi
        echo "$pid $ticks $rss $name"
    done
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
while true; do

    # --- Read /proc/stat and per-process stats at the same moment ---
    CPU_RAW=$(grep '^cpu ' /proc/stat)
    snapshot_procs > "$PROC_CURR"

    read -r _ CPU_USER CPU_NICE CPU_SYSTEM CPU_IDLE CPU_IOWAIT CPU_IRQ CPU_SOFTIRQ CPU_STEAL _ _ <<< "$CPU_RAW"

    CPU_USAGE="0.00"
    IOWAIT_USAGE="0.00"
    TOTAL_DIFF=0

    if [ -f "$SNAPSHOT" ]; then
        read -r PREV_USER PREV_NICE PREV_SYSTEM PREV_IDLE PREV_IOWAIT PREV_IRQ PREV_SOFTIRQ PREV_STEAL < "$SNAPSHOT"

        PREV_TOTAL=$((PREV_USER + PREV_NICE + PREV_SYSTEM + PREV_IDLE + PREV_IOWAIT + PREV_IRQ + PREV_SOFTIRQ + PREV_STEAL))
        NOW_TOTAL=$((CPU_USER + CPU_NICE + CPU_SYSTEM + CPU_IDLE + CPU_IOWAIT + CPU_IRQ + CPU_SOFTIRQ + CPU_STEAL))

        TOTAL_DIFF=$((NOW_TOTAL - PREV_TOTAL))
        IDLE_DIFF=$((CPU_IDLE - PREV_IDLE))
        IOWAIT_DIFF=$((CPU_IOWAIT - PREV_IOWAIT))

        if [ "$TOTAL_DIFF" -gt 0 ]; then
            CPU_USAGE=$(awk "BEGIN {printf \"%.2f\", 100.0 * (1.0 - ($IDLE_DIFF / $TOTAL_DIFF))}")
            IOWAIT_USAGE=$(awk "BEGIN {printf \"%.2f\", 100.0 * ($IOWAIT_DIFF / $TOTAL_DIFF)}")
        fi
    fi

    # --- Save CPU snapshot for next iteration ---
    echo "$CPU_USER $CPU_NICE $CPU_SYSTEM $CPU_IDLE $CPU_IOWAIT $CPU_IRQ $CPU_SOFTIRQ $CPU_STEAL" > "$SNAPSHOT"

    # --- Disk I/O via iostat (requires sysstat) ---
    DISK_READ_KBPS="0.00"
    DISK_WRITE_KBPS="0.00"
    DISK_AWAIT_MS="0.00"
    DISK_UTIL_PERCENT="0.00"

    if command -v iostat &>/dev/null; then
        # iostat -dx 1 2: disk extended stats, 1s interval, 2 samples (discard first)
        IOSTAT_LINE=$(iostat -dx 1 2 2>/dev/null | awk '
            /^Device/ { header=1; next }
            header && /^[a-z]/ && !/^loop/ { print; exit }
        ')
        if [ -n "$IOSTAT_LINE" ]; then
            # Columns: Device tps kB_read/s kB_wrtn/s kB_dscd/s kB_read kB_wrtn kB_dscd rrqm/s wrqm/s %rrqm %wrqm r/s w/s d/s f/s rareq-sz wareq-sz dareq-sz fareq-sz aqu-sz await r_await w_await d_await f_await svctm %util
            DISK_READ_KBPS=$(echo "$IOSTAT_LINE" | awk '{printf "%.2f", $3}')
            DISK_WRITE_KBPS=$(echo "$IOSTAT_LINE" | awk '{printf "%.2f", $4}')
            DISK_AWAIT_MS=$(echo "$IOSTAT_LINE" | awk '{printf "%.2f", $22}')
            DISK_UTIL_PERCENT=$(echo "$IOSTAT_LINE" | awk '{printf "%.2f", $NF}')
        fi
    fi

    # --- Collect top processes on CPU spike ---
    # Uses the same TOTAL_DIFF denominator as the overall CPU% — no timing mismatch.
    # Both /proc/stat and /proc/[pid]/stat were read at the top of this iteration.
    TOP_PROCESSES_JSON="[]"
    if awk "BEGIN {exit !($CPU_USAGE >= $CPU_SPIKE_THRESHOLD)}"; then
        if [ -f "$PROC_SNAPSHOT" ] && [ "$TOTAL_DIFF" -gt 0 ]; then
            TOP_PROCESSES_JSON=$(awk -v total="$TOTAL_DIFF" -v total_mem_kb="$TOTAL_MEM_KB" '
                NR==FNR { prev_ticks[$1]=$2; next }
                {
                    pid=$1; ticks=$2; rss=$3; name=$4
                    if (pid in prev_ticks && ticks > prev_ticks[pid]) {
                        delta = ticks - prev_ticks[pid]
                        cpu_pct = 100.0 * delta / total
                        mem_pct = (total_mem_kb > 0) ? (rss * 4.0 / total_mem_kb * 100.0) : 0
                        printf "%.2f %.1f %s\n", cpu_pct, mem_pct, name
                    }
                }
            ' "$PROC_SNAPSHOT" "$PROC_CURR" | \
            sort -k1 -rn | head -3 | \
            awk '
                BEGIN { first=1; printf "[" }
                {
                    if (!first) printf ","
                    printf "{\"name\":\"%s\",\"cpu\":%s,\"mem\":%s}", $3, $1, $2
                    first = 0
                }
                END { printf "]" }
            ')
        fi
        logger -t resource-monitor-daemon "CPU spike: ${CPU_USAGE}% >= ${CPU_SPIKE_THRESHOLD}% — capturing top processes"
    fi

    # --- Rotate process snapshot ---
    mv "$PROC_CURR" "$PROC_SNAPSHOT"

    # --- POST ---
    JSON="{\"cpu_usage\":${CPU_USAGE},\"iowait_usage\":${IOWAIT_USAGE},\"disk_read_kbps\":${DISK_READ_KBPS},\"disk_write_kbps\":${DISK_WRITE_KBPS},\"disk_await_ms\":${DISK_AWAIT_MS},\"disk_util_percent\":${DISK_UTIL_PERCENT},\"top_processes\":${TOP_PROCESSES_JSON}}"

    HTTP_CODE=$(curl -s --max-time 10 -o /tmp/_daemon_resp_$$.txt -w "%{http_code}" \
        -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        --data-raw "$JSON")

    RESP=$(cat /tmp/_daemon_resp_$$.txt 2>/dev/null)
    rm -f /tmp/_daemon_resp_$$.txt

    logger -t resource-monitor-daemon "CPU: ${CPU_USAGE}% | IOWait: ${IOWAIT_USAGE}% | DiskR: ${DISK_READ_KBPS} kB/s | DiskW: ${DISK_WRITE_KBPS} kB/s | Await: ${DISK_AWAIT_MS}ms | DiskUtil: ${DISK_UTIL_PERCENT}% | HTTP: ${HTTP_CODE} | ${RESP}"

    sleep "$INTERVAL"
done
