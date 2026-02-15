#!/bin/bash

#===============================================================================
# CONCISE TOP CPU PROCESS LOGGER - README
#===============================================================================
#
# DESCRIPTION:
#   Logs the top N CPU-consuming processes every 30 seconds to a dated log file.
#   Automatically cleans up logs older than 30 days.
#   Format: [HH:MM:SS] CPU% Process1  CPU% Process2  CPU% Process3  CPU% Process4
#
# LOG LOCATION:
#   ~/misc/logs/top-cpu-concise-YYYY-MM-DD.log
#
# SERVICE COMMANDS:
#   systemctl --user status log-top-cpu.service   # Check status
#   systemctl --user stop log-top-cpu.service     # Stop logging
#   systemctl --user start log-top-cpu.service    # Start logging
#   systemctl --user restart log-top-cpu.service  # Restart after script changes
#   systemctl --user disable log-top-cpu.service  # Disable auto-start
#   systemctl --user enable log-top-cpu.service   # Enable auto-start
#
# VIEWING LOGS:
#   tail -f ~/misc/logs/top-cpu-concise-$(date +%Y-%m-%d).log # Live view
#
#===============================================================================

# --- Configuration ---
LOG_DIR="$HOME/misc/logs"       # Directory for log files
INTERVAL=30                     # Seconds between each snapshot
TOP_N=4                         # Number of top CPU processes to log
LOG_RETENTION_DAYS=180          # Delete log files older than this many days
SEPARATOR="\t"                  # Separator between process entries

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Graceful shutdown on SIGTERM/SIGINT
trap 'echo "[$(date "+%Y-%m-%d %H:%M:%S")] Logger stopped"; exit 0' SIGTERM SIGINT

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting concise top CPU logger"

while true; do
    # Single date call to avoid race condition at midnight
    DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
    CURRENT_DATE=${DATETIME%% *}
    TIMESTAMP=${DATETIME##* }

    # Clean up logs older than retention period
    find "$LOG_DIR" -name "top-cpu-concise-*.log" -mtime +$LOG_RETENTION_DAYS -delete 2>/dev/null

    # Fetch top N processes by %CPU, separated compactly
    TOP_PROCS=$(ps -eo pcpu,comm --sort=-pcpu --no-headers | head -n $TOP_N | awk -v top_n="$TOP_N" -v sep="$SEPARATOR" '{
        cpu=$1; name=$2;
        entry=sprintf("%5s%% %s", cpu, name);
        if (NR < top_n) printf "%s%s", entry, sep;
        else printf "%s", entry;
    }')

    # Log to daily file
    echo "[$TIMESTAMP] $TOP_PROCS" >> "$LOG_DIR/top-cpu-concise-$CURRENT_DATE.log"

    sleep "$INTERVAL"
done
