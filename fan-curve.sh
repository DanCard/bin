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
    for fan in $FANS; do
        log "$fan: mode $(cat "$SYSFS/$fan/mode") -> auto"
        set_sysfs "$fan/mode" auto
    done
}

do_probe() {
    local target="$1" val=2

    log "=== Probing $target (reporting all fans) ==="
    set_sysfs "$target/mode" fixed
    sleep 1

    [[ $(cat "$SYSFS/$target/mode") == "fixed" ]] || { log "ERROR: $target not in fixed mode"; return 1; }

    log "Baseline (off, waiting 5s): $(set_sysfs "$target/raw_level" 8; sleep 5; get_rpms)"

    log ""
    log "Starting sequence: off(3s) → set value → report at +5s, +7s, +9s"
    log "----------------------------------------------"
    set_sysfs "$target/raw_level" 8; sleep 3
    
    log "[$val] Setting raw_level=$val (0x02)..."
    set_sysfs "$target/raw_level" "$val"

    local elapsed=0
    for delay in 5 2 2; do
        sleep "$delay"
        elapsed=$((elapsed + delay))
        
        # Verify fixed mode at each step
        [[ $(cat "$SYSFS/$target/mode") == "fixed" ]] || set_sysfs "$target/mode" fixed
        
        log "[$val] RESULT (+${elapsed}s): $(get_rpms) RPM"
    done

    log "----------------------------------------------"
    log "Restoring $target to auto mode..."
    set_sysfs "$target/mode" auto
}

do_curve() {
    log "=== Setting optimized fan curves ==="
    log "Temperature: $(cat "$SYSFS/temp1/temp")°C"
    log ""

    # Config for all fans: off below 27°C, unified curve starting at 40°C
    for fan in $FANS; do
        log "$fan: configuring curve..."
        set_sysfs "$fan/rampup_curve" "40,60,74,86,94"
        set_sysfs "$fan/rampdown_curve" "27,44,62,76,84"
        set_sysfs "$fan/mode" curve
    done
    log ""
    do_status
}

case "${1:-}" in
    --help|-h) usage ;;
    --reset)   do_reset ;;
    --status)  do_status ;;
    --probe)
        for fan in $FANS; do
            do_probe "$fan"
        done
        ;;
    "")        do_curve ;;
    *)         echo "Unknown option: $1"; usage ;;
esac
