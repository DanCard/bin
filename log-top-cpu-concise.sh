#!/bin/bash

#===============================================================================
# CONCISE TOP CPU PROCESS LOGGER
#===============================================================================
# Logs the top 2 CPU-consuming processes on a single line every 30 seconds.
# Format: [HH:MM:SS] Process1: CPU% Process2: CPU%
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
    # Handling process names with spaces (e.g., 'Isolated Web Co')
    TOP_PROCS=$(ps -eo comm,pcpu --sort=-pcpu --no-headers | head -n 2 | awk '{
        cpu=$NF; 
        $NF=""; sub(/[ \t]+$/, ""); 
        name=$0;
        entry=sprintf("%s: %s%%", name, cpu);
        if (NR==1) printf "%-30s ", entry;
        else printf "%s", entry;
    }')
    
    # Log to daily file
    echo "[$TIMESTAMP] $TOP_PROCS" >> "$LOG_DIR/top-cpu-concise-$CURRENT_DATE.log"
    
    sleep "$INTERVAL"
done
