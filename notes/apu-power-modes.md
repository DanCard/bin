# APU Power Modes (Sixunited AXB35-02 / Strix Halo)

This information describes the power and performance characteristics of the Embedded Controller (EC) power policies for the Strix Halo APU.

## Power Mode Characteristics

| Power Mode | Target TDP (Watt Limit) | Impact Description |
| :--- | :--- | :--- |
| **Performance** | **120W - 140W** | **Maximum Power.** Best for 3D rendering and high-end gaming. Loudest fan noise. |
| **Balanced** | **~85W** | **Efficiency Sweet Spot.** Retains ~90% performance with significantly less heat and noise. |
| **Quiet (Silent)** | **~54W** | **Minimum Noise.** Used for light tasks where noise must be minimized. |

## Key Insights

* **Performance Gains:** The jump from 85W (Balanced) to 120W (Performance) is a ~40% increase in power draw, but only translates to an 8-15% gain in actual performance due to diminishing returns.
* **Fan Noise:** Balanced mode is significantly quieter than Performance mode, as the fans do not need to dissipate the extra 35W+ of heat.

## Commands

### Check Current Mode
```bash
# Using custom sps script
sps

# Or via direct sysfs interface
cat /sys/class/ec_su_axb35/apu/power_mode
```

### Set to Balanced
```bash
echo "balanced" | sudo tee /sys/class/ec_su_axb35/apu/power_mode
```

### Set to Performance
```bash
echo "performance" | sudo tee /sys/class/ec_su_axb35/apu/power_mode
```
