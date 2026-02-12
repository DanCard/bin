#!/bin/bash
# Check CPU fan speed on Dell Alienware R12 (Debian)

echo "=== Checking with lm-sensors ==="
if command -v sensors >/dev/null; then
    sensors
else
    echo "lm-sensors not installed. Install with: sudo apt install lm-sensors"
fi

echo ""
echo "=== Checking with i8kutils (Dell-specific) ==="
if command -v i8kctl >/dev/null; then
    i8kctl fan
else
    echo "i8kutils not installed. Install with: sudo apt install i8kutils"
fi

echo ""
echo "=== Checking /sys/class/hwmon ==="
for f in /sys/class/hwmon/hwmon*/fan*_input; do
    [ -r "$f" ] || continue
    echo "$f: $(cat $f) RPM"
done
