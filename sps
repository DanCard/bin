#!/bin/bash
# sps - Display XFCE and Strix Halo hardware power settings in a compact format
# Note: Governor/EPP details are documented in ~/notes/cpu-governor-epp.md , 260302-apu-power-modes.md

# If a parameter is given, call set power settings
if [ -n "$1" ]; then
    exec "$HOME/bin/power" "$1"
fi

# PERFORMANCE Data
cpu_gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "n/a")
cpu_epp=$(cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference 2>/dev/null || echo "n/a")
apu_mode=$(cat /sys/class/ec_su_axb35/apu/power_mode 2>/dev/null || echo "n/a")
gpu_perf=$(cat /sys/class/drm/card0/device/power_dpm_force_performance_level 2>/dev/null || echo "n/a")
gpu_sclk=$(awk '/\*/ {print $2; exit}' /sys/class/drm/card0/device/pp_dpm_sclk 2>/dev/null)
gpu_mclk=$(awk '/\*/ {print $2; exit}' /sys/class/drm/card0/device/pp_dpm_mclk 2>/dev/null)
gpu_sclk_levels=$(awk '{print $2}' /sys/class/drm/card0/device/pp_dpm_sclk 2>/dev/null | paste -sd/ -)
gpu_mclk_levels=$(awk '{print $2}' /sys/class/drm/card0/device/pp_dpm_mclk 2>/dev/null | paste -sd/ -)
[ -z "$gpu_sclk" ] && gpu_sclk="${gpu_sclk_levels:-n/a}"
[ -z "$gpu_mclk" ] && gpu_mclk="${gpu_mclk_levels:-n/a}"

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
dpms_s=$(get_xf "dpms-on-ac-sleep")
dpms_o=$(get_xf "dpms-on-ac-off")
dpms_enabled=$(xset q 2>/dev/null | grep -c "DPMS is Enabled")

# SUSPEND Data
inact=$(get_xf "inactivity-on-ac")
lock=$(get_xf "lock-screen-suspend-hibernate")

# Colors (TrueColor RGB)
CYAN='\033[38;2;225;255;255m'
YELLOW='\033[38;2;255;255;225m'
WHITE='\033[38;2;255;225;255m'
NC='\033[0m' # No Color

# COMPRESSED OUTPUT
echo -e "${CYAN}PERFORMANCE: Gov: $cpu_gov  EPP: $cpu_epp  GPU: $gpu_perf  SCLK: $gpu_sclk  MCLK: $gpu_mclk"
#  EC (embedded controller) APU power policy: $apu_mode${NC}"
echo -e "${YELLOW}SCREEN:      Sleep: $(format_time "$dpms_s")  Off: $(format_time "$dpms_o")  DPMS: $([ "$dpms_enabled" = "1" ] && echo "On" || echo "OFF")${NC}"
echo -e "${WHITE}SUSPEND:     Timeout: $(format_time "$inact")  Lock: $(format_bool "$lock")${NC}"
