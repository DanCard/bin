#!/bin/bash
# fan-curve.sh — Set optimized fan curves to reduce idle oscillation
set -euo pipefail

SYSFS=/sys/class/ec_su_axb35
FANS="fan1 fan2 fan3"

usage() {
    echo "Usage: $0 [--reset] [--status] [--probe]"
    echo "  (no args)  Set curve mode with optimized thresholds"
    echo "  --reset    Restore auto mode on all fans"
    echo "  --status   Show current fan state"
    echo "  --probe    Probe unknown EC codes on fan1 (requires fixed mode)"
    exit 0
}

log() {
    echo "$*"
}

do_status() {
    local temp temp_min temp_max
    temp=$(cat "$SYSFS/temp1/temp")
    temp_min=$(cat "$SYSFS/temp1/min")
    temp_max=$(cat "$SYSFS/temp1/max")
    echo "temp: ${temp}°C (min=${temp_min} max=${temp_max})  |  modes: auto=EC ctrl, fixed=static, curve=temp-based"
    echo ""
    printf "%-5s  %-6s  %5s  %5s  %5s  %-17s  %-17s\n" "FAN" "MODE" "RPM" "LEVEL" "RAW" "RAMPUP(1-5)" "RAMPDOWN(1-5)"
    printf "%-5s  %-6s  %5s  %5s  %5s  %-17s  %-17s\n" "-----" "------" "-----" "-----" "-----" "-----------------" "-----------------"
    for fan in $FANS; do
        local mode rpm level_str raw_str rampup rampdown
        mode=$(cat "$SYSFS/$fan/mode")
        rpm=$(cat "$SYSFS/$fan/rpm")
        if [ "$mode" != "auto" ]; then
            level_str=$(cat "$SYSFS/$fan/level")
            raw_str=$(cat "$SYSFS/$fan/raw_level")
            rampup=$(cat "$SYSFS/$fan/rampup_curve" 2>/dev/null || echo "-")
            rampdown=$(cat "$SYSFS/$fan/rampdown_curve" 2>/dev/null || echo "-")
        else
            level_str="-"
            raw_str="-"
            rampup="-"
            rampdown="-"
        fi
        printf "%-5s  %-6s  %5s  %5s  %5s  %-17s  %-17s\n" "$fan" "$mode" "$rpm" "$level_str" "$raw_str" "$rampup" "$rampdown"
    done
}

do_reset() {
    log "=== Resetting all fans to auto mode ==="
    for fan in $FANS; do
        local old_mode
        old_mode=$(cat "$SYSFS/$fan/mode")
        log "$fan: current mode=$old_mode, switching to auto..."
        echo auto | sudo tee "$SYSFS/$fan/mode" > /dev/null
        local new_mode
        new_mode=$(cat "$SYSFS/$fan/mode")
        log "$fan: mode is now $new_mode"
    done
    log "=== All fans restored to auto mode ==="
}

do_probe() {
    log "=== Probing all EC codes (0-15) on fan1 ==="
    log "Setting fan1 to fixed mode..."
    echo fixed | sudo tee "$SYSFS/fan1/mode" > /dev/null
    sleep 1

    local mode
    mode=$(cat "$SYSFS/fan1/mode")
    if [ "$mode" != "fixed" ]; then
        log "ERROR: fan1 mode is '$mode', expected 'fixed'. Aborting."
        return 1
    fi
    log "fan1 confirmed in fixed mode"

    log "Setting fan1 to off (raw_level=8) as baseline..."
    echo 8 | sudo tee "$SYSFS/fan1/raw_level" > /dev/null
    log "Waiting 5s for fan to stop..."
    sleep 5
    log "Baseline RPM: $(cat "$SYSFS/fan1/rpm")"

    log ""
    log "Starting probe: 16 values × 11s each ≈ 3 minutes"
    log "Each test: off(3s) → set value → wait(8s) → read RPM"
    log "----------------------------------------------"

    for val in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        # Set to off first to get a clean spin-up
        echo 8 | sudo tee "$SYSFS/fan1/raw_level" > /dev/null
        log "[$val/15] Reset to off, waiting 3s..."
        sleep 3

        # Now set the test value and wait for spin-up
        printf -v hex "0x%02X" "$val"
        log "[$val/15] Setting raw_level=$val ($hex), waiting 8s for spin-up..."
        echo "$val" | sudo tee "$SYSFS/fan1/raw_level" > /dev/null
        sleep 8

        # Verify still in fixed mode
        mode=$(cat "$SYSFS/fan1/mode")
        if [ "$mode" != "fixed" ]; then
            log "[$val/15] WARNING: mode changed to '$mode'! Re-setting fixed."
            echo fixed | sudo tee "$SYSFS/fan1/mode" > /dev/null
            sleep 1
        fi

        local rpm raw
        rpm=$(cat "$SYSFS/fan1/rpm")
        raw=$(cat "$SYSFS/fan1/raw_level")
        log "[$val/15] RESULT: raw=$val ($hex)  readback=$raw  mode=$mode  rpm=${rpm} RPM"
    done

    log "----------------------------------------------"
    log "Probe complete. Restoring fan1 to auto mode..."
    echo auto | sudo tee "$SYSFS/fan1/mode" > /dev/null
    log "fan1 mode is now $(cat "$SYSFS/fan1/mode")"
}

do_curve() {
    log "=== Setting optimized fan curves ==="
    local temp
    temp=$(cat "$SYSFS/temp1/temp")
    log "Current temperature: ${temp}°C"
    log ""

    # Show before state
    log "--- Before ---"
    for fan in $FANS; do
        local mode level rpm
        mode=$(cat "$SYSFS/$fan/mode")
        level=$(cat "$SYSFS/$fan/level")
        rpm=$(cat "$SYSFS/$fan/rpm")
        log "$fan: mode=$mode  level=$level  rpm=${rpm} RPM"
        log "  rampup:   $(cat "$SYSFS/$fan/rampup_curve")"
        log "  rampdown: $(cat "$SYSFS/$fan/rampdown_curve")"
    done
    log ""

    # Fan 1 & 2 (CPU): level 1 (~1482 RPM) at 45°C, off below 38°C
    log "--- Configuring fan1 & fan2 (CPU fans) ---"
    log "  Curve: off → 1482RPM@45°C → 2557RPM@65°C → 3374RPM@78°C → 4030RPM@88°C → 4647RPM@95°C"
    log "  Hysteresis: rampdown 7°C below rampup for level 1, 6°C-10°C for higher levels"
    for fan in fan1 fan2; do
        log "$fan: writing rampup_curve=45,65,78,88,95"
        echo "45,65,78,88,95" | sudo tee "$SYSFS/$fan/rampup_curve" > /dev/null
        log "$fan: writing rampdown_curve=38,55,72,84,92"
        echo "38,55,72,84,92" | sudo tee "$SYSFS/$fan/rampdown_curve" > /dev/null
        log "$fan: setting mode to curve"
        echo curve | sudo tee "$SYSFS/$fan/mode" > /dev/null
        log "$fan: mode is now $(cat "$SYSFS/$fan/mode"), level=$(cat "$SYSFS/$fan/level"), rpm=$(cat "$SYSFS/$fan/rpm") RPM"
    done
    log ""

    # Fan 3 (system): level 1 at 40°C, off below 33°C
    log "--- Configuring fan3 (system fan) ---"
    log "  Curve: off → on@40°C → 60°C → 74°C → 86°C → 94°C"
    log "$fan: writing rampup_curve=40,60,74,86,94"
    echo "40,60,74,86,94" | sudo tee "$SYSFS/fan3/rampup_curve" > /dev/null
    log "fan3: writing rampdown_curve=33,50,68,82,90"
    echo "33,50,68,82,90" | sudo tee "$SYSFS/fan3/rampdown_curve" > /dev/null
    log "fan3: setting mode to curve"
    echo curve | sudo tee "$SYSFS/fan3/mode" > /dev/null
    log "fan3: mode is now $(cat "$SYSFS/fan3/mode"), level=$(cat "$SYSFS/fan3/level"), rpm=$(cat "$SYSFS/fan3/rpm") RPM"
    log ""

    # Show after state
    log "--- After ---"
    do_status
}

case "${1:-}" in
    --help|-h) usage ;;
    --reset)   do_reset ;;
    --status)  do_status ;;
    --probe)   do_probe ;;
    "")        do_curve ;;
    *)         echo "Unknown option: $1"; usage ;;
esac
