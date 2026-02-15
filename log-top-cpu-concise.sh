#!/bin/bash

#===============================================================================
# CONCISE TOP CPU PROCESS LOGGER - README
#===============================================================================
#
# DESCRIPTION:
#   Logs the top 2 CPU-consuming processes every 30 seconds to a dated log file.
#   Format: [HH:MM:SS] Process1: CPU% Process2: CPU%
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

LOG_DIR="$HOME/misc/logs"
INTERVAL=30

# Ensure log directory exists
mkdir -p "$LOG_DIR"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting concise top CPU logger"

while true; do
    CURRENT_DATE=$(date +%Y-%m-%d)
    TIMESTAMP=$(date '+%H:%M:%S')
    
    # Fetch top 2 processes by %CPU
    # comm: process name
    # pcpu: cpu percentage
    # Vertically align both the process name and the CPU usage percentage
    TOP_PROCS=$(ps -eo comm,pcpu --sort=-pcpu --no-headers | head -n 2 | awk '{
        cpu=$NF; 
        $NF=""; sub(/[ \t]+$/, ""); 
        name=$0;
        # Entry format: Name (20 chars) + CPU (5 chars) + %
        entry=sprintf("%-20s %5s%%", name ":", cpu);
        if (NR==1) printf "%-30s ", entry;
        else printf "%s", entry;
    }')
    
    # Log to daily file
    echo "[$TIMESTAMP] $TOP_PROCS" >> "$LOG_DIR/top-cpu-concise-$CURRENT_DATE.log"
    
    sleep "$INTERVAL"
done
