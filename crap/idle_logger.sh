#!/bin/bash

LOGFILE="$HOME/idle_activity.log"

echo "Logging started at $(date)" >> "$LOGFILE"

while true; do
    {
        echo "================================================================"
        date
        
        # Lock status
        SESSION_ID=$(loginctl | grep "$USER" | awk '{print $1}' | head -n 1)
        if [ -n "$SESSION_ID" ]; then
            LOCK_STATUS=$(loginctl show-session "$SESSION_ID" | grep LockedHint)
            echo "Status: $LOCK_STATUS"
        else
            echo "Status: Session not found"
        fi
        
        # Load Average
        echo "Load Average: $(uptime | awk -F'load average:' '{ print $2 }')"
        
        # Power Profile
        echo "Power Profile: $(powerprofilesctl get 2>/dev/null || echo 'N/A')"
        
        # Temperatures
        echo "Temperatures:"
        sensors 2>/dev/null | grep -E 'Tctl|edge|Composite'
        
        # GPU Usage
        # Check if rocm-smi gives JSON or text
        GPU_JSON=$(rocm-smi -u --json 2>/dev/null)
        if [ -n "$GPU_JSON" ]; then
             echo "$GPU_JSON" | jq -r '.["GPU[0]"] | "GPU Usage: \(.["GPU use (%)"])%"' 2>/dev/null
        else
             rocm-smi -u 2>/dev/null | grep "GPU use" || echo "GPU Usage: N/A"
        fi
        
        # Top 10 CPU Processes (More verbose to be sure)
        echo "Top 10 Processes (CPU%):"
        ps axo pcpu,comm,pid --sort=-pcpu | head -n 11
        
        echo ""
    } >> "$LOGFILE" 2>&1
    
    # Flush to disk
    sync "$LOGFILE" 2>/dev/null || sync
    
    sleep 20
done
