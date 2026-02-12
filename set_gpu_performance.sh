#!/bin/bash
# Set AMD GPU to high performance mode for compute workloads

echo "Setting GPU to high performance mode..."

# Force maximum core clock (2900MHz)
echo "2" > /sys/class/drm/card0/device/pp_dpm_sclk

# Force maximum memory clock
echo "2" > /sys/class/drm/card0/device/pp_dpm_mclk

echo ""
echo "GPU performance mode set successfully!"
echo ""
echo "Current GPU core clock states:"
cat /sys/class/drm/card0/device/pp_dpm_sclk
echo ""
echo "Current GPU memory clock states:"
cat /sys/class/drm/card0/device/pp_dpm_mclk
echo ""
echo "Current power consumption:"
rocm-smi --showpower
exit
# below are claude instructions
# Copy the service file to systemd directory
  sudo cp /home/dcar/projects/video/amd-gpu-performance.service /etc/systemd/system/

  # Reload systemd to recognize the new service
  sudo systemctl daemon-reload

  # Enable the service to start at boot
  sudo systemctl enable amd-gpu-performance.service

  # Start the service now (without rebooting)
  sudo systemctl start amd-gpu-performance.service

  # Check the service status
  sudo systemctl status amd-gpu-performance.service
