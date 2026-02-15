#!/bin/bash

#===============================================================================
# CONCISE TOP CPU PROCESS LOGGER - README
#===============================================================================
#
# DESCRIPTION:
#   Logs the top N CPU-consuming processes every 30 seconds to a dated log file.
#   Automatically cleans up logs older than 180 days.
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

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Graceful shutdown on SIGTERM/SIGINT
LOG_FILE_MSG() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_DIR/top-cpu-concise-$(date +%Y-%m-%d).log"; }
trap 'LOG_FILE_MSG "Logger stopped"; exit 0' SIGTERM SIGINT

LOG_FILE_MSG "Starting concise top CPU logger"

while true; do
    # Single date call to avoid race condition at midnight
    DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
    CURRENT_DATE=${DATETIME%% *}
    TIMESTAMP=${DATETIME##* }

    # Clean up logs older than retention period (once per day)
    if [ "$CURRENT_DATE" != "$LAST_CLEANUP_DATE" ]; then
        find "$LOG_DIR" -name "top-cpu-concise-*.log" -mtime +$LOG_RETENTION_DAYS -delete 2>/dev/null
        LAST_CLEANUP_DATE="$CURRENT_DATE"
    fi

    # Fetch top N processes by %CPU, separated compactly
    # Uses comm (process name, matches top) + args (command line) for extra context
    TOP_PROCS=$(ps -eo pcpu,comm:15,args --sort=-pcpu --no-headers | head -n $TOP_N | awk -v top_n="$TOP_N" '{
        cpu = $1;
        line = $0; match(line, /[0-9.]+/);
        rest = substr(line, RSTART + RLENGTH); sub(/^ +/, "", rest);
        comm = substr(rest, 1, 15); sub(/ +$/, "", comm);
        args_str = substr(rest, 17); sub(/^ +/, "", args_str);
        sub(/^\/[^ ]*\//, "", args_str);
        if (index(args_str, comm) == 1) {
            extra = substr(args_str, length(comm) + 1); sub(/^ +/, "", extra);
        } else {
            extra = "(" args_str ")";
        }
        if (extra != "" && extra != ")" && length(comm) < 35)
            name = comm " " extra;
        else
            name = comm;
        if (length(name) > 35) name = substr(name, 1, 35);
        if (NR < top_n) {
            printf "%5s%% %-35s  ", cpu, name;
        } else {
            printf "%5s%% %s", cpu, name;
        }
    }')

    # Log to daily file
    echo "[$TIMESTAMP] $TOP_PROCS" >> "$LOG_DIR/top-cpu-concise-$CURRENT_DATE.log"

    sleep "$INTERVAL"
done
