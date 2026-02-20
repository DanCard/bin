#!/bin/bash
# sps - Display XFCE and Strix Halo hardware power settings in a compact format

# If a parameter is given, call set-power-settings
if [ -n "$1" ]; then
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        exec "$HOME/bin/set-power-settings" "$1"
    else
        echo "Error: Please provide a valid number"
        exit 1
    fi
fi

# PERFORMANCE Data
cpu_gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "n/a")
apu_mode=$(cat /sys/class/ec_su_axb35/apu/power_mode 2>/dev/null || echo "n/a")
idle_drv=$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null || echo "n/a")

# XFCE Data - Fetch once using xfconf-query
XF_DATA=$(xfconf-query -c xfce4-power-manager -l -v 2>/dev/null)

get_xf() {
    local val=$(echo "$XF_DATA" | grep "/xfce4-power-manager/$1 " | awk '{print $2}')
    [ -z "$val" ] && echo "n/a" || echo "$val"
}

format_time() {
    local val="$1"
    if [ "$val" = "n/a" ] || [ "$val" = "0" ]; then echo "Never"; else echo "${val}m"; fi
}

format_bool() {
    case "$1" in
        true) echo "Yes" ;;
        false) echo "No" ;;
        *) echo "$1" ;;
    esac
}

format_sleep() {
    case "$1" in
        0) echo "None" ;;
        1) echo "Susp" ;;
        2) echo "Hib" ;;
        *) echo "n/a" ;;
    esac
}

# SCREEN Data
blank=$(get_xf "blank-on-ac")
dpms_s=$(get_xf "dpms-on-ac-sleep")
dpms_o=$(get_xf "dpms-on-ac-off")

# SUSPEND Data
inact=$(get_xf "inactivity-on-ac")
lock=$(get_xf "lock-screen-suspend-hibernate")

# Colors (TrueColor RGB)
CYAN='\033[38;2;0;255;255m'
YELLOW='\033[38;2;255;255;0m'
WHITE='\033[38;2;255;255;255m'
NC='\033[0m' # No Color

# COMPRESSED OUTPUT
echo -e "${CYAN}PERFORMANCE: Gov: $cpu_gov  APU: $apu_mode  Idle: $idle_drv${NC}"
echo -e "${YELLOW}SCREEN:      Blank: $(format_time "$blank")  Sleep: $(format_time "$dpms_s")  Off: $(format_time "$dpms_o")${NC}"
echo -e "${WHITE}SUSPEND:     Timeout: $(format_time "$inact")  Lock: $(format_bool "$lock")${NC}"
