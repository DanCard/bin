#!/bin/bash

#===============================================================================
# TOP CPU PROCESS LOGGER - README
#===============================================================================
#
# DESCRIPTION:
#   Logs the top CPU-consuming process every 30 seconds to a dated log file.
#   Useful for tracking down intermittent high CPU usage or identifying
#   runaway processes over time.
#
# LOG LOCATION:
#   ~/misc/logs/top-cpu-YYYY-MM-DD.log
#
# CONFIGURATION:
#   INTERVAL      - Seconds between logs (default: 30)
#   THREAD_MODE   - 0=process mode (default), 1=thread mode
#
# THREAD vs PROCESS MONITORING:
#   PROCESS mode (default, THREAD_MODE=0):
#   - Shows one entry per process, regardless of thread count
#   - Good for: general monitoring, seeing which applications use CPU
#   - Shows thread count (NLWP) so you know if an app is heavily threaded
#   - Clean, readable logs
#
#   THREAD mode (THREAD_MODE=1):
#   - Shows individual threads
#   - Good for: debugging thread-specific issues, identifying runaway threads
#   - Can be very verbose (browsers often have 100+ threads)
#   - Use only when investigating specific thread-related problems
#
# LOG FORMAT:
#   [2026-02-12 13:08:51] PID: 1234 | User: dcar | CPU: 45.2% | MEM: 12.3% |
#   Threads: 8 | Process: firefox | Cmd: /usr/lib/firefox/firefox -contentproc ...
#
# SERVICE COMMANDS:
#   systemctl --user status log-top-cpu.service   # Check status
#   systemctl --user stop log-top-cpu.service     # Stop logging
#   systemctl --user start log-top-cpu.service    # Start logging
#   systemctl --user restart log-top-cpu.service  # Restart after config changes
#   systemctl --user disable log-top-cpu.service  # Disable auto-start
#
# VIEWING LOGS:
#   cat ~/misc/logs/top-cpu-$(date +%Y-%m-%d).log     # Today's log
#   ls -la ~/misc/logs/                                # List all logs
#   tail -f ~/misc/logs/top-cpu-$(date +%Y-%m-%d).log # Live view
#
# AUTO-START:
#   Enabled via systemd user service at:
#   ~/.config/systemd/user/log-top-cpu.service
#   Starts automatically on desktop login.
#
#  To disable autostart, run this command:
#  systemctl --user disable log-top-cpu.service
#  This removes the service from starting automatically on login,
#  but the currently running instance keeps running until you stop it (or reboot).
#  To stop it immediately too:
#  systemctl --user disable --now log-top-cpu.service
#  To re-enable autostart later:
#  systemctl --user enable log-top-cpu.service
#  The --now flag works for both - enable --now starts it immediately, disable --now stops it immediately.
#
#===============================================================================

LOG_DIR="$HOME/misc/logs"
INTERVAL=30
THREAD_MODE=0  # Set to 1 to monitor individual threads instead of processes

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Get current date for log filename
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/top-cpu-$DATE.log"

# Function to get current timestamp
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Function to log top CPU process/thread
log_top_cpu() {
    local pid user cpu_usage mem_usage nlwp process_name full_cmd
    
    if [[ "$THREAD_MODE" == "1" ]]; then
        # Thread mode: Show individual threads
        # Using ps -eLf to get thread info: PID, LWP (thread ID), NLWP, etc.
        local top_line
        top_line=$(ps -eLf --sort=-%cpu | head -n 2 | tail -n 1)
        
        pid=$(echo "$top_line" | awk '{print $2}')
        local lwp=$(echo "$top_line" | awk '{print $4}')
        user=$(echo "$top_line" | awk '{print $1}')
        cpu_usage=$(echo "$top_line" | awk '{print $5}')
        mem_usage=$(echo "$top_line" | awk '{print $6}')
        nlwp=$(echo "$top_line" | awk '{print $14}')
        
        # Full command line starts at field 15
        full_cmd=$(echo "$top_line" | awk '{for(i=15;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')
        process_name=$(echo "$full_cmd" | awk '{print $1}' | sed 's|.*/||')
        
        # Truncate very long command lines
        if [[ ${#full_cmd} -gt 200 ]]; then
            full_cmd="${full_cmd:0:200}..."
        fi
        
        if [[ "$pid" == "$lwp" ]]; then
            echo "[$(timestamp)] PID: $pid | User: $user | CPU: ${cpu_usage}% | MEM: ${mem_usage}% | Threads: $nlwp | Process: $process_name | Cmd: $full_cmd" >> "$LOG_FILE"
        else
            echo "[$(timestamp)] PID: $pid (TID: $lwp) | User: $user | CPU: ${cpu_usage}% | MEM: ${mem_usage}% | Threads: $nlwp | Process: $process_name | Cmd: $full_cmd" >> "$LOG_FILE"
        fi
    else
        # Process mode (default): Show processes only
        # Using custom ps format to get all needed fields
        local top_line
        top_line=$(ps -eo pid,user,pcpu,pmem,nlwp,comm,args --sort=-%cpu | head -n 2 | tail -n 1)
        
        pid=$(echo "$top_line" | awk '{print $1}')
        user=$(echo "$top_line" | awk '{print $2}')
        cpu_usage=$(echo "$top_line" | awk '{print $3}')
        mem_usage=$(echo "$top_line" | awk '{print $4}')
        nlwp=$(echo "$top_line" | awk '{print $5}')
        process_name=$(echo "$top_line" | awk '{print $6}')
        
        # Full command line starts at field 7
        full_cmd=$(echo "$top_line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')
        
        # Truncate very long command lines (keep first 200 chars)
        if [[ ${#full_cmd} -gt 200 ]]; then
            full_cmd="${full_cmd:0:200}..."
        fi
        
        echo "[$(timestamp)] PID: $pid | User: $user | CPU: ${cpu_usage}% | MEM: ${mem_usage}% | Threads: $nlwp | Process: $process_name | Cmd: $full_cmd" >> "$LOG_FILE"
    fi
}

# Log startup info
echo "[$(timestamp)] Starting top CPU process logger (THREAD_MODE=$THREAD_MODE)" >> "$LOG_FILE"
if [[ "$THREAD_MODE" == "0" ]]; then
    echo "[$(timestamp)] Mode: Process-level monitoring (set THREAD_MODE=1 for thread-level)" >> "$LOG_FILE"
fi

# Main loop
while true; do
    # Check if date has changed (new day = new log file)
    CURRENT_DATE=$(date +%Y-%m-%d)
    if [[ "$CURRENT_DATE" != "$DATE" ]]; then
        DATE="$CURRENT_DATE"
        LOG_FILE="$LOG_DIR/top-cpu-$DATE.log"
        echo "[$(timestamp)] Starting top CPU process logger (new day, THREAD_MODE=$THREAD_MODE)" >> "$LOG_FILE"
    fi

    log_top_cpu
    sleep "$INTERVAL"
done
