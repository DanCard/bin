#!/bin/bash
# Display XFCE power management settings
# If a number is provided, set power settings first

# If a parameter is given, call set-power-settings
if [ -n "$1" ]; then
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        # It's a number, call set-power-settings
        exec "$HOME/bin/set-power-settings" "$1"
    else
        echo "Error: Please provide a valid number"
        exit 1
    fi
fi

CONFIG_FILE="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml"

#echo "╔════════════════════════════════════════════════════════════╗"
#echo "║         XFCE Power Management Settings                     ║"
#echo "╚════════════════════════════════════════════════════════════╝"
echo "				  Power Management Settings"
#echo ""

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found at $CONFIG_FILE"
    exit 1
fi

# Function to get setting value from XML
get_setting() {
    local prop="$1"
    local value=$(grep "name=\"$prop\"" "$CONFIG_FILE" | sed -n 's/.*value="\([^"]*\)".*/\1/p')
    if [ -z "$value" ]; then
        echo "Not set"
    else
        echo "$value"
    fi
}

# Function to format time
format_time() {
    local val="$1"
    if [ "$val" = "Not set" ] || [ "$val" = "0" ]; then
        echo "Never"
    else
        echo "${val} minutes"
    fi
}

# Function to format sleep mode
format_sleep_mode() {
    case "$1" in
        0) echo "Nothing" ;;
        1) echo "Suspend" ;;
        2) echo "Hibernate" ;;
        *) echo "Unknown ($1)" ;;
    esac
}

# Function to format boolean
format_bool() {
    case "$1" in
        true) echo "Yes" ;;
        false) echo "No" ;;
        *) echo "$1" ;;
    esac
}

#echo "┌─ SCREEN SETTINGS ─────────────────────────────────────────┐"
blank_ac=$(get_setting "blank-on-ac")
dpms_enabled=$(get_setting "dpms-enabled")
dpms_sleep=$(get_setting "dpms-on-ac-sleep")
dpms_off=$(get_setting "dpms-on-ac-off")

echo "  Screen blank:        $(format_time "$blank_ac")"
echo "  DPMS enabled:        $(format_bool "$dpms_enabled")"
echo "  DPMS sleep:          $(format_time "$dpms_sleep")"
echo "  DPMS off:            $(format_time "$dpms_off")"
#echo ""

#echo "┌─ SYSTEM SUSPEND ──────────────────────────────────────────┐"
echo "				  SYSTEM SUSPEND"
inactivity_ac=$(get_setting "inactivity-on-ac")
sleep_mode_ac=$(get_setting "inactivity-sleep-mode-on-ac")

echo "  Inactivity timeout:  $(format_time "$inactivity_ac")"
echo "  Sleep mode:          $(format_sleep_mode "$sleep_mode_ac")"
#echo ""

#echo "┌─ OTHER SETTINGS ──────────────────────────────────────────┐"
#presentation_mode=$(get_setting "presentation-mode")
lock_screen=$(get_setting "lock-screen-suspend-hibernate")

#echo "  Presentation mode:   $(format_bool "$presentation_mode")"
echo "  Lock on suspend:     $(format_bool "$lock_screen")"
#echo ""
