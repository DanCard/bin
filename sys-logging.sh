#!/bin/bash

# To manage the associated service (if created):
#   systemctl --user status sys-logging.service
#   systemctl --user restart sys-logging.service
#   systemctl --user stop sys-logging.service
#   systemctl --user start sys-logging.service

# System Logger: top CPU, thermal summary, and fan speeds on one line.
# Abbreviation legend used in log output:
# - r8169                 = r8169_0_c100:00/temp1
# - mt7925                = mt7925_phy0/temp1
# - nvm <N>               = nvmeX/Sensor N (X = drive index)
# - composite             = nvmeX/Composite
# - F1, F2, F3            = AXB35 System Fans 1, 2, 3

LOG_DIR="$HOME/misc/logs"
INTERVAL=20
TOP_N=3
TEMP_N=5
TEMP_DECIMALS=0
TEMP_LABEL_WIDTH=6
PROC_NAME_WIDTH=15
COMM_WIDTH=15
LOG_RETENTION_DAYS=180
LOG_PREFIX="sys-logging"

mkdir -p "$LOG_DIR"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_DIR/$LOG_PREFIX-$(date +%Y-%m-%d).log"
}

trap 'log_msg "Logger stopped"; exit 0' SIGTERM SIGINT

format_temp_c() {
    local mc="$1"
    case "$TEMP_DECIMALS" in
        3) printf "%d.%03d°" "$((mc / 1000))" "$((mc % 1000))" ;;
        2) printf "%d.%02d°" "$((mc / 1000))" "$(((mc % 1000) / 10))" ;;
        1) printf "%d.%d°" "$((mc / 1000))" "$(((mc % 1000) / 100))" ;;
        *) printf "%d°" "$((mc / 1000))" ;;
    esac
}

get_fan_summary() {
    local f1 f2 f3 m1 m2 m3 l1 l2 l3 path="/sys/class/ec_su_axb35"
    local s1 s2 s3 o1 o2 o3
    if [ -d "$path" ]; then
        f1=$(cat "$path/fan1/rpm" 2>/dev/null || echo "0")
        f2=$(cat "$path/fan2/rpm" 2>/dev/null || echo "0")
        f3=$(cat "$path/fan3/rpm" 2>/dev/null || echo "0")
        m1=$(cat "$path/fan1/mode" 2>/dev/null || echo "?")
        m2=$(cat "$path/fan2/mode" 2>/dev/null || echo "?")
        m3=$(cat "$path/fan3/mode" 2>/dev/null || echo "?")
        l1=$(cat "$path/fan1/level" 2>/dev/null || echo "?")
        l2=$(cat "$path/fan2/level" 2>/dev/null || echo "?")
        l3=$(cat "$path/fan3/level" 2>/dev/null || echo "?")

        s1="${m1:0:1}${l1}"
        s2="${m2:0:1}${l2}"
        s3="${m3:0:1}${l3}"
        
        # Show suffix except for 'a0' (auto mode, level 0)
        if [[ "$s1" == "a0" ]]; then o1="$f1"; else o1="$f1:$s1"; fi
        if [[ "$s2" == "a0" ]]; then o2="$f2"; else o2="$f2:$s2"; fi
        if [[ "$s3" == "a0" ]]; then o3="$f3"; else o3="$f3:$s3"; fi

        printf "%6s %6s %6s" "$o1" "$o2" "$o3"
    else
        printf "F: n/a"
    fi
}

get_temp_summary() {
    local d t val name sensor_id label zone
    local collected sorted out="" dev_path dev_id

    collected=""
    for d in /sys/class/hwmon/hwmon*; do
        [ -d "$d" ] || continue
        name=$(cat "$d/name" 2>/dev/null || echo "hwmon")
        dev_path=$(readlink -f "$d/device" 2>/dev/null || true)
        dev_id=$(basename "$dev_path")
        
        # Skip the virtual su_axb35 hwmon to avoid duplicate temp entries 
        # (we handle the EC driver directly or through other hwmon devices)
        if [[ "$name" == "su_axb35" ]]; then
            continue
        fi

        if [[ "$name" == "nvme" && "$dev_id" =~ ^nvme[0-9]+$ ]]; then
            name="$dev_id"
        fi
        for t in "$d"/temp*_input; do
            [ -r "$t" ] || continue
            val=$(cat "$t" 2>/dev/null)
            [[ "$val" =~ ^[0-9]+$ ]] || continue
            sensor_id=$(basename "$t")
            sensor_id="${sensor_id%_input}"
            label=$(cat "$d/${sensor_id}_label" 2>/dev/null || echo "$sensor_id")
            collected+="${val}|${name}/${label}"$'
'
        done
    done

    if [[ -z "$collected" ]]; then
        for zone in /sys/class/thermal/thermal_zone*; do
            [ -r "$zone/temp" ] || continue
            val=$(cat "$zone/temp" 2>/dev/null)
            [[ "$val" =~ ^[0-9]+$ ]] || continue
            label=$(cat "$zone/type" 2>/dev/null || basename "$zone")
            collected+="${val}|${label}"$'
'
        done
    fi

    if [[ -z "$collected" ]]; then
        printf "n/a"
        return
    fi

    # Always place acpitz first (if available), then fill remaining slots
    # with hottest non-acpitz sensors.
    local acpi_first non_acpi_sorted remain
    acpi_first=$(printf "%s\n" "$collected" \
        | awk -F'|' '$2 ~ /^acpitz(\/|$)/' \
        | sort -t'|' -k1,1nr \
        | head -n 1)

    if [[ -n "$acpi_first" ]]; then
        remain=$((TEMP_N - 1))
        non_acpi_sorted=$(printf "%s\n" "$collected" \
            | awk -F'|' '$2 !~ /^acpitz(\/|$)/' \
            | sort -t'|' -k1,1nr \
            | head -n "$remain")
        sorted=$(
            {
                printf "%s\n" "$acpi_first"
                printf "%s\n" "$non_acpi_sorted"
            } | sed '/^$/d'
        )
    else
        sorted=$(printf "%s" "$collected" | sort -t'|' -k1,1nr | head -n "$TEMP_N")
    fi

    while IFS='|' read -r mc sensor; do
        [[ -z "$mc" ]] && continue
        local t_fmt
        local base lbl
        if [[ "$sensor" == */* ]]; then
            base="${sensor%%/*}"
            lbl="${sensor#*/}"
        else
            base=""
            lbl="$sensor"
        fi

        if [[ "$base" == r8169_* ]]; then
            base="r8169"
        elif [[ "$base" == mt7925_phy* ]]; then
            base="mt7925"
        elif [[ "$base" =~ ^nvme([0-9]+)$ ]]; then
            local idx="${BASH_REMATCH[1]}"
            base="nvm$idx"
        fi

        lbl="${lbl//Sensor /S}"
        lbl="${lbl//Sensor/S}"
        if [[ "$lbl" =~ ^[Tt]emp([0-9]+)$ ]]; then
            lbl="${BASH_REMATCH[1]}"
        elif [[ "$lbl" =~ ^S([0-9]+)$ ]]; then
            lbl="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$base" ]]; then
            if [[ "$base" == "r8169" && "$lbl" == "1" ]]; then
                sensor="r8169"
            elif [[ "$base" == "mt7925" && "$lbl" == "1" ]]; then
                sensor="mt7925"
            elif [[ "$base" == nvm* && "$lbl" == "Composite" ]]; then
                sensor="compo${base#nvm}"
            elif [[ "$base" == nvm* && "$lbl" =~ ^[0-9]+$ ]]; then
                sensor="$base $lbl"
            else
                sensor="$base/$lbl"
            fi
        else
            sensor="$lbl"
        fi

        # Suspected stuck sensor filter:
        if [[ "$sensor" == "nvm0 2" || "$sensor" == "nvm1 2" ]]; then
            if (( mc / 100 == 748 )); then
                continue
            fi
        fi

        t_fmt=$(printf "%4s %-*.*s" "$(format_temp_c "$mc")" "$TEMP_LABEL_WIDTH" "$TEMP_LABEL_WIDTH" "$sensor")
        if [[ -z "$out" ]]; then
            out="$t_fmt"
        else
            out="$out  $t_fmt"
        fi
    done <<< "$sorted"

    printf "%s" "$out"
}

get_top_procs() {
    ps -eo pcpu,comm:${COMM_WIDTH},args --sort=-pcpu --no-headers \
        | head -n "$TOP_N" \
        | awk -v top_n="$TOP_N" -v name_w="$PROC_NAME_WIDTH" -v comm_w="$COMM_WIDTH" '
            {
                cpu = $1;
                line = $0; match(line, /[0-9.]+/);
                rest = substr(line, RSTART + RLENGTH); sub(/^ +/, "", rest);
                comm = substr(rest, 1, comm_w); sub(/ +$/, "", comm);
                args_str = substr(rest, comm_w + 2); sub(/^ +/, "", args_str);

                sub(/^\/[^ ]*\//, "", args_str);
                gsub(/\/home\/[^/ ]+\//, "", args_str);
                gsub(/\/usr(\/local)?\/(s?bin|libexec)\//, "", args_str);

                if (args_str != "" && index(args_str, comm) == 1) {
                    extra = substr(args_str, length(comm) + 1); sub(/^ +/, "", extra);
                } else {
                    extra = "";
                }

                name = comm;
                if (extra != "") {
                    name = comm " " extra;
                }
                if (length(name) > name_w) {
                    name = substr(name, 1, name_w);
                }

                if (NR < top_n) {
                    printf "%5s%% %-*s  ", cpu, name_w, name;
                } else {
                    printf "%5s%% %-*s", cpu, name_w, name;
                }
            }'
}

log_msg "Starting system logging (CPU + Thermal + Fans)"

LAST_CLEANUP_DATE=""
while true; do
    DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
    CURRENT_DATE=${DATETIME%% *}
    TIMESTAMP=${DATETIME##* }

    if [ "$CURRENT_DATE" != "$LAST_CLEANUP_DATE" ]; then
        find "$LOG_DIR" -name "$LOG_PREFIX-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
        LAST_CLEANUP_DATE="$CURRENT_DATE"
    fi

    TEMP_SUMMARY=$(get_temp_summary)
    FAN_SUMMARY=$(get_fan_summary)
    TOP_PROCS=$(get_top_procs)

    echo "$TIMESTAMP $TOP_PROCS  F= $FAN_SUMMARY  C= $TEMP_SUMMARY" >> "$LOG_DIR/$LOG_PREFIX-$CURRENT_DATE.log"
    sleep "$INTERVAL"
done
