#!/bin/bash
# set_gpu_performance.sh - Force AMD GPU to maximum performance states
#
# WHAT THIS DOES:
#   Sets the AMD GPU core (sclk) and memory (mclk) clocks to their highest
#   available performance levels. This is critical for stable, high-speed
#   compute workloads (ML, transcription, etc.) on Strix Halo systems.
#
# HOW IT WORKS:
#   Writes '2' (the highest state on this system) to the AMD GPU's sysfs
#   power management interfaces.
#
# SERVICE SETUP:
#   To run this automatically at boot, use the systemd service:
#     sudo cp /home/dcar/projects/video/amd-gpu-performance.service /etc/systemd/system/
#     sudo systemctl daemon-reload
#     sudo systemctl enable --now amd-gpu-performance.service
#
# REQUIRES: root privileges, AMD GPU driver (amdgpu)

# Check for root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)"
   exit 1
fi

SCLK="/sys/class/drm/card0/device/pp_dpm_sclk"
MCLK="/sys/class/drm/card0/device/pp_dpm_mclk"

# Verify hardware interfaces exist
if [[ ! -f "$SCLK" || ! -f "$MCLK" ]]; then
    echo "ERROR: AMD GPU performance interfaces not found at $SCLK"
    echo "Ensure the amdgpu driver is loaded and card0 is the correct device."
    exit 1
fi

echo "Setting AMD GPU to high performance mode (State 2)..."

# Force maximum core clock
echo "2" > "$SCLK"

# Force maximum memory clock
echo "2" > "$MCLK"

echo "------------------------------------------------"
echo "Performance mode set successfully."
echo "------------------------------------------------"

echo "Current Core Clock States (* = active):"
cat "$SCLK"
echo ""

echo "Current Memory Clock States (* = active):"
cat "$MCLK"
echo ""

if command -v rocm-smi >/dev/null; then
    echo "Current Power Consumption:"
    rocm-smi --showpower | grep -E "Power|Device"
fi
