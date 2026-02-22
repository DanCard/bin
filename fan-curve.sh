#!/bin/bash
# fan-curve.sh — Set optimized fan curves to reduce idle oscillation
set -euo pipefail

SYSFS=/sys/class/ec_su_axb35
FANS="fan1 fan2 fan3"

usage() {
    echo "Usage: $0 [--status] [--apply] [--reset] [--probe]"
    echo "  (no args)  Show current fan state"
    echo "  --apply    Set curve mode with optimized thresholds"
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

probe_target() {
    local label="$1" ; shift
    local fans=("$@")

    log "[$label] before: $(get_rpms)"
    sleep 1
    for f in "${fans[@]}"; do set_sysfs "$f/mode" fixed; set_sysfs "$f/raw_level" 8; done
    sleep 1
    log "[$label] off: $(get_rpms)"

    log "[$label] Setting raw_level=2..."
    for f in "${fans[@]}"; do set_sysfs "$f/raw_level" 2; done

    local elapsed=0
    for delay in 3 1 1; do
        sleep "$delay"
        elapsed=$((elapsed + delay))
        log "[$label] +${elapsed}s: $(get_rpms)"
    done

    log "[$label] Restoring auto mode..."
    for f in "${fans[@]}"; do set_sysfs "$f/mode" auto; done
    sleep 1
    log "[$label] restored: $(get_rpms)"
}

do_probe() {
    log "=== Probing fans individually ==="
    log "Initial: $(get_rpms)"

    for active in $FANS; do
        log ""
        log "--- Probing $active (others untouched) ---"
        probe_target "$active" "$active"
    done

    log ""
    log "--- Probing all fans together ---"
    probe_target "all" $FANS

    log ""
    log "Probe complete."
}

do_curve() {
    log "=== Setting optimized fan curves ==="
    log "Temperature: $(cat "$SYSFS/temp1/temp")°C"
    log ""

    # Config for all fans: off below 27°C, unified curve starting at 40°C
    log "Configuring unified curve for all fans..."
    set_all rampup_curve   "45,50,74,86,94"
    set_all rampdown_curve "35,44,62,76,84"
    set_all mode curve

    log ""
    do_status
}

case "${1:-}" in
    --help|-h) usage ;;
    --apply)   do_curve ;;
    --reset)   do_reset ;;
    --status)  do_status ;;
    --probe)   do_probe ;;
    "")        do_status ;;
    *)         echo "Unknown option: $1"; usage ;;
esac
