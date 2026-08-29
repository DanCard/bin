#!/bin/bash
# check_fans.sh - Monitor CPU and system fan speeds
#
# WHAT THIS DOES:
#   Checks fan RPMs using three different methods to ensure broad compatibility
#   on systems like the Alienware R12 or Strix Halo.
#
# METHODS:
#   1. lm-sensors: Standard Linux hardware monitoring
#   2. i8kutils: Dell-specific SMM BIOS interface (for older Dell/Alienware)
#   3. sysfs (hwmon): Direct kernel interface for all detected fans
#
# USAGE:
#   check_fans.sh

echo "=== Method 1: lm-sensors ==="
if command -v sensors >/dev/null; then
    sensors
else
    echo "lm-sensors not installed (sudo apt install lm-sensors)"
fi

echo -e "\n=== Method 2: i8kutils (Dell/Alienware) ==="
if command -v i8kctl >/dev/null; then
    i8kctl fan
else
    echo "i8kutils not installed or not a Dell system."
fi

echo -e "\n=== Method 3: Direct sysfs (hwmon) ==="
for d in /sys/class/hwmon/hwmon*; do
    [ -d "$d" ] || continue
    NAME=$(cat "$d/name" 2>/dev/null || echo "unknown")
    
    # Check for any fan inputs in this device
    for f in "$d"/fan*_input; do
        if [ -r "$f" ]; then
            VAL=$(cat "$f")
            FAN_NUM=$(basename "$f" | sed 's/fan\([0-9]*\)_input/\1/')
            LABEL=$(cat "$d/fan${FAN_NUM}_label" 2>/dev/null || echo "Fan $FAN_NUM")
            echo "[$NAME] $LABEL: $VAL RPM"
        fi
    done
done
