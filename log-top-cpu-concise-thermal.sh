#!/bin/bash

# Concise top CPU logger with expanded temperature summary on one line.
# Abbreviation legend used in log output:
# - r8169                 = r8169_0_c100:00/temp1
# - mt7925                = mt7925_phy0/temp1
# - nvm <N>               = nvmeX/Sensor N (X = drive index)
# - composite             = nvmeX/Composite

LOG_DIR="$HOME/misc/logs"
INTERVAL=30
TOP_N=3
TEMP_N=5
TEMP_DECIMALS=0
TEMP_LABEL_WIDTH=6
PROC_NAME_WIDTH=21
COMM_WIDTH=14
LOG_RETENTION_DAYS=180
LOG_PREFIX="top-cpu-concise-thermal"

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

get_temp_summary() {
    local d t val name sensor_id label zone
    local collected sorted out="" dev_path dev_id

    collected=""
    for d in /sys/class/hwmon/hwmon*; do
        [ -d "$d" ] || continue
        name=$(cat "$d/name" 2>/dev/null || echo "hwmon")
        dev_path=$(readlink -f "$d/device" 2>/dev/null || true)
        dev_id=$(basename "$dev_path")
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
            collected+="${val}|${name}/${label}"$'\n'
        done
    done

    if [[ -z "$collected" ]]; then
        for zone in /sys/class/thermal/thermal_zone*; do
            [ -r "$zone/temp" ] || continue
            val=$(cat "$zone/temp" 2>/dev/null)
            [[ "$val" =~ ^[0-9]+$ ]] || continue
            label=$(cat "$zone/type" 2>/dev/null || basename "$zone")
            collected+="${val}|${label}"$'\n'
        done
    fi

    if [[ -z "$collected" ]]; then
        printf "n/a"
        return
    fi

    sorted=$(printf "%s" "$collected" | sort -t'|' -k1,1nr | head -n "$TEMP_N")
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
        # hide nvm0 2 when its one-decimal display value is 74.8C.
        if [[ "$sensor" == "nvm0 2" ]]; then
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

log_msg "Starting concise top CPU + expanded thermal logger"

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
    TOP_PROCS=$(get_top_procs)

    echo "$TIMESTAMP $TOP_PROCS  C= $TEMP_SUMMARY" >> "$LOG_DIR/$LOG_PREFIX-$CURRENT_DATE.log"
    sleep "$INTERVAL"
done
