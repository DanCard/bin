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
EC_PATH="/sys/class/ec_su_axb35"

mkdir -p "$LOG_DIR"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_DIR/$LOG_PREFIX-$(date +%Y-%m-%d).log"
}

trap 'log_msg "Logger stopped"; exit 0' SIGTERM SIGINT

SHOW_ACPI_EC=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--show-acpi-ec)
            SHOW_ACPI_EC=1
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

format_temp_c() {
    local mc="$1"
    case "$TEMP_DECIMALS" in
        3) printf "%d.%03d°" "$((mc / 1000))" "$((mc % 1000))" ;;
        2) printf "%d.%02d°" "$((mc / 1000))" "$(((mc % 1000) / 10))" ;;
        1) printf "%d.%d°" "$((mc / 1000))" "$(((mc % 1000) / 100))" ;;
        *) printf "%d°" "$((mc / 1000))" ;;
    esac
}

c_to_f() {
    local mc="$1"
    printf "%3d°F   " "$(( (mc * 9 / 5 + 32000) / 1000 ))"
}

read_file_or() {
    local path="$1" fallback="$2"
    cat "$path" 2>/dev/null || printf "%s" "$fallback"
}

read_fan_field() {
    local fan="$1" field="$2" fallback="$3"
    read_file_or "$EC_PATH/fan${fan}/${field}" "$fallback"
}

get_fan_mode() {
    local m1 l1 s1
    if [ -d "$EC_PATH" ]; then
        m1=$(read_fan_field 1 mode "?")
        l1=$(read_fan_field 1 level "?")
        s1="${m1:0:1}${l1}"
        printf "%s" "$s1"
    fi
}

get_fan_summary() {
    local f1 f2 f3
    if [ -d "$EC_PATH" ]; then
        f1=$(read_fan_field 1 rpm "0")
        f2=$(read_fan_field 2 rpm "0")
        f3=$(read_fan_field 3 rpm "0")
        printf "%5d%5d%5d" "$f1" "$f2" "$f3"
    else
        printf "n/a"
    fi
}

get_acpi_temp_c() {
    local d t val name best_mc=""

    for d in /sys/class/hwmon/hwmon*; do
        [ -d "$d" ] || continue
        name=$(cat "$d/name" 2>/dev/null || echo "hwmon")
        [[ "$name" == acpitz* ]] || continue
        for t in "$d"/temp*_input; do
            [ -r "$t" ] || continue
            val=$(cat "$t" 2>/dev/null)
            [[ "$val" =~ ^[0-9]+$ ]] || continue
            if [[ -z "$best_mc" || "$val" -gt "$best_mc" ]]; then
                best_mc="$val"
            fi
        done
    done

    if [[ -z "$best_mc" ]]; then
        for d in /sys/class/thermal/thermal_zone*; do
            [ -d "$d" ] || continue
            name=$(cat "$d/type" 2>/dev/null || echo "")
            [[ "$name" == "acpitz" ]] || continue
            val=$(cat "$d/temp" 2>/dev/null)
            [[ "$val" =~ ^[0-9]+$ ]] || continue
            if [[ -z "$best_mc" || "$val" -gt "$best_mc" ]]; then
                best_mc="$val"
            fi
        done
    fi

    if [[ -z "$best_mc" ]]; then
        printf "n/a"
    else
        printf "%d" "$((best_mc / 1000))"
    fi
}

get_ec_temp_c() {
    local ec
    ec=$(read_file_or "$EC_PATH/temp1/temp" "n/a")
    if [[ "$ec" =~ ^[0-9]+$ ]]; then
        printf "%s" "$ec"
    else
        printf "n/a"
    fi
}

append_temp_entry() {
    local value="$1" label="$2"
    collected+="${value}|${label}"$'\n'
}

normalize_sensor_name() {
    local sensor="$1"
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

    printf "%s" "$sensor"
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
            append_temp_entry "$val" "${name}/${label}"
        done
    done

    if [[ -z "$collected" ]]; then
        for zone in /sys/class/thermal/thermal_zone*; do
            [ -r "$zone/temp" ] || continue
            val=$(cat "$zone/temp" 2>/dev/null)
            [[ "$val" =~ ^[0-9]+$ ]] || continue
            label=$(cat "$zone/type" 2>/dev/null || basename "$zone")
            append_temp_entry "$val" "$label"
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
        sensor="$(normalize_sensor_name "$sensor")"

        # Suspected stuck sensor filter:
        if [[ "$sensor" == "nvm0 2" || "$sensor" == "nvm1 2" ]]; then
            if (( mc / 100 == 748 )); then
                continue
            fi
        fi

        local label

        if [[ "$sensor" == acpitz* ]]; then
            label=$(c_to_f "$mc")
        else
            label="$sensor"
        fi
        t_fmt=$(printf "%4s %-*.*s" "$(format_temp_c "$mc")" "$TEMP_LABEL_WIDTH" "$TEMP_LABEL_WIDTH" "$label")
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
    
    if [ "$SHOW_ACPI_EC" -eq 1 ]; then
        ACPI_TEMP=$(get_acpi_temp_c)
        EC_TEMP=$(get_ec_temp_c)
        if [[ "$ACPI_TEMP" =~ ^[0-9]+$ && "$EC_TEMP" =~ ^[0-9]+$ ]]; then
            TEMP_DELTA=$((ACPI_TEMP - EC_TEMP))
            TEMP_BLOCK=$(printf "T=acpi:%sC ec:%sC Δ:%+dC" "$ACPI_TEMP" "$EC_TEMP" "$TEMP_DELTA")
        else
            TEMP_BLOCK=$(printf "T=acpi:%s ec:%s Δ:n/a" "$ACPI_TEMP" "$EC_TEMP")
        fi
        TEMP_BLOCK="  $TEMP_BLOCK"
    else
        TEMP_BLOCK=""
    fi
    
    FAN_MODE=$(get_fan_mode)
    FAN_SUMMARY=$(get_fan_summary)
    TOP_PROCS=$(get_top_procs)

    echo "$TIMESTAMP $TOP_PROCS  $FAN_MODE$FAN_SUMMARY$TEMP_BLOCK  C= $TEMP_SUMMARY" >> "$LOG_DIR/$LOG_PREFIX-$CURRENT_DATE.log"
    sleep "$INTERVAL"
done
