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
    echo "  --probe    Probe EC codes on all fans"
    exit 0
}

log() {
    echo "$*"
}

set_sysfs() {
    local path="$1" val="$2"
    echo "$val" | sudo tee "$SYSFS/$path" > /dev/null
}

set_all() {
    local attr="$1" val="$2"
    for fan in $FANS; do
        set_sysfs "$fan/$attr" "$val"
    done
}

get_rpms() {
    local out=""
    for fan in $FANS; do
        out+="${fan}=$(cat "$SYSFS/$fan/rpm") "
    done
    echo "$out"
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
    set_all mode auto
    log "=== All fans restored to auto mode ==="
}

do_probe() {
    log "=== Probing fans individually ==="
    log "Initial: $(get_rpms)"

    for active in $FANS; do
        log ""
        log "--- Probing $active (others untouched) ---"
        log "[$active] before: $(get_rpms)"
        sleep 1
        set_sysfs "$active/mode" fixed
        set_sysfs "$active/raw_level" 8
        sleep 1
        log "[$active] off: $(get_rpms)"

        log "[$active] Setting raw_level=2..."
        set_sysfs "$active/raw_level" 2

        local elapsed=0
        for delay in 3 1 1; do
            sleep "$delay"
            elapsed=$((elapsed + delay))
            log "[$active] +${elapsed}s: $(get_rpms)"
        done

        log "[$active] Restoring auto mode..."
        set_sysfs "$active/mode" auto
        sleep 1
        log "[$active] restored: $(get_rpms)"
    done

    log ""
    log "--- Probing all fans together ---"
    log "[all] before: $(get_rpms)"
    sleep 1
    set_all mode fixed
    set_all raw_level 8
    sleep 1
    log "[all] off: $(get_rpms)"

    log "[all] Setting raw_level=2..."
    set_all raw_level 2

    local elapsed=0
    for delay in 3 1 1; do
        sleep "$delay"
        elapsed=$((elapsed + delay))
        log "[all] +${elapsed}s: $(get_rpms)"
    done

    log "[all] Restoring auto mode..."
    set_all mode auto
    sleep 1
    log "[all] restored: $(get_rpms)"

    log ""
    log "Probe complete."
}

do_curve() {
    log "=== Setting optimized fan curves ==="
    log "Temperature: $(cat "$SYSFS/temp1/temp")°C"
    log ""

    # Config for all fans: off below 27°C, unified curve starting at 40°C
    log "Configuring unified curve for all fans..."
    set_all rampup_curve "40,60,74,86,94"
    set_all rampdown_curve "27,44,62,76,84"
    set_all mode curve

    log ""
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
