#!/bin/bash

# To manage the associated service (if created):
#   systemctl --user status sys-logging.service
#   systemctl --user restart sys-logging.service
#   systemctl --user stop sys-logging.service
#   systemctl --user start sys-logging.service
#
# Signal controls (while service is running):
#   # Trigger manual burst profile from SIGUSR1
#   # (defaults: level 2 timing => ~15s sampling for 120s)
#   # Use --kill-who=main so the current top sample is not interrupted.
#   systemctl --user kill -s USR1 --kill-who=main sys-logging.service
#
#   # Trigger two-stage burst profile from SIGUSR2
#   # (defaults: 5s sampling for 30s, then 15s for 120s)
#   systemctl --user kill -s USR2 --kill-who=main sys-logging.service
#
#   # Alternative direct signal by PID
#   kill -USR1 "$(systemctl --user show -p MainPID --value sys-logging.service)"
#   kill -USR2 "$(systemctl --user show -p MainPID --value sys-logging.service)"

# System Logger: top CPU, thermal summary, and fan speeds on one line.
# Abbreviation legend used in log output:
# - r8169                 = r8169_0_c100:00/temp1
# - mt7925                = mt7925_phy0/temp1
# - nvm <N>               = nvmeX/Sensor N (X = drive index)
# - composite             = nvmeX/Composite
# - F1, F2, F3            = AXB35 System Fans 1, 2, 3

LOG_DIR="$HOME/misc/logs"
TOP_N=3
TEMP_N=5
TEMP_DECIMALS=0
TEMP_LABEL_WIDTH=6
PROC_NAME_WIDTH=15
COMM_WIDTH=15
LOG_RETENTION_DAYS=180
LOG_PREFIX="sys-logging"
EC_PATH="/sys/class/ec_su_axb35"
DEFAULT_TOP_SAMPLE_DELAY=29
LOOP_SAFETY_SLEEP=0.1
# Event markers are appended to the next telemetry line:
# - @R<n>   service start
# - @X<n>   service stop
# - @U1<n>  SIGUSR1 burst request
# - @U2<n>  SIGUSR2 profile request
# - @U2C<n> SIGUSR2 profile complete
# - @B<sec><n> burst frequency set/changed (for example @B5<n>, @B15<n>)
# - @BE<n>  burst frequency returned to default
MANUAL_BURST_LEVEL="${MANUAL_BURST_LEVEL:-2}"
MANUAL_BURST_DURATION_MS="${MANUAL_BURST_DURATION_MS:-120000}"
USR2_PHASE1_INTERVAL="${USR2_PHASE1_INTERVAL:-5}"
USR2_PHASE1_DURATION_MS="${USR2_PHASE1_DURATION_MS:-30000}"
USR2_PHASE2_INTERVAL="${USR2_PHASE2_INTERVAL:-15}"
USR2_PHASE2_DURATION_MS="${USR2_PHASE2_DURATION_MS:-120000}"
EVENT_QUEUE_FILE=""
EVENT_SEQ_FILE=""
EVENT_MARKERS=""

if [[ ! "$MANUAL_BURST_LEVEL" =~ ^[0-9]+$ ]] || (( MANUAL_BURST_LEVEL < 0 || MANUAL_BURST_LEVEL > 5 )); then
    MANUAL_BURST_LEVEL=2
fi

if [[ ! "$MANUAL_BURST_DURATION_MS" =~ ^[0-9]+$ ]] || (( MANUAL_BURST_DURATION_MS < 1000 )); then
    MANUAL_BURST_DURATION_MS=120000
fi

if [[ ! "$USR2_PHASE1_INTERVAL" =~ ^[0-9]+$ ]] || (( USR2_PHASE1_INTERVAL < 1 )); then
    USR2_PHASE1_INTERVAL=5
fi

if [[ ! "$USR2_PHASE1_DURATION_MS" =~ ^[0-9]+$ ]] || (( USR2_PHASE1_DURATION_MS < 1000 )); then
    USR2_PHASE1_DURATION_MS=30000
fi

if [[ ! "$USR2_PHASE2_INTERVAL" =~ ^[0-9]+$ ]] || (( USR2_PHASE2_INTERVAL < 1 )); then
    USR2_PHASE2_INTERVAL=15
fi

if [[ ! "$USR2_PHASE2_DURATION_MS" =~ ^[0-9]+$ ]] || (( USR2_PHASE2_DURATION_MS < 1000 )); then
    USR2_PHASE2_DURATION_MS=120000
fi

ACTIVE_BURST_LEVEL=0
ACTIVE_BURST_UNTIL_MS=0
ACTIVE_BURST_INTERVAL_OVERRIDE=""
USR2_PHASE1_UNTIL_MS=0
USR2_PHASE2_UNTIL_MS=0
LAST_BURST_DELAY=""

mkdir -p "$LOG_DIR"
EVENT_QUEUE_FILE="$LOG_DIR/.${LOG_PREFIX}.event-queue"
EVENT_SEQ_FILE="$LOG_DIR/.${LOG_PREFIX}.event-seq"

persist_event_markers() {
    if [[ -n "$EVENT_MARKERS" ]]; then
        printf "%s\n" "$EVENT_MARKERS" > "$EVENT_QUEUE_FILE"
    else
        : > "$EVENT_QUEUE_FILE"
    fi
}

load_event_markers() {
    if [[ -r "$EVENT_QUEUE_FILE" ]]; then
        EVENT_MARKERS=$(cat "$EVENT_QUEUE_FILE" 2>/dev/null)
        EVENT_MARKERS="${EVENT_MARKERS//$'\n'/}"
    fi
}

next_event_id() {
    local seq
    seq=0
    if [[ -r "$EVENT_SEQ_FILE" ]]; then
        seq=$(cat "$EVENT_SEQ_FILE" 2>/dev/null)
        if [[ ! "$seq" =~ ^[0-9]+$ ]]; then
            seq=0
        fi
    fi
    seq=$((seq + 1))
    printf "%s\n" "$seq" > "$EVENT_SEQ_FILE"
    printf "%s" "$seq"
}

enqueue_event_marker() {
    local code="$1" event_id marker
    event_id=$(next_event_id)
    marker="@${code}${event_id}"
    if [[ -n "$EVENT_MARKERS" ]]; then
        EVENT_MARKERS="${EVENT_MARKERS},${marker}"
    else
        EVENT_MARKERS="${marker}"
    fi
    persist_event_markers
}

handle_stop() {
    enqueue_event_marker "X"
    exit 0
}

activate_manual_burst() {
    local now_ms candidate_until_ms
    ACTIVE_BURST_INTERVAL_OVERRIDE=""
    USR2_PHASE1_UNTIL_MS=0
    USR2_PHASE2_UNTIL_MS=0
    now_ms=$(date +%s%3N)
    candidate_until_ms=$((now_ms + MANUAL_BURST_DURATION_MS))

    if (( MANUAL_BURST_LEVEL > ACTIVE_BURST_LEVEL )); then
        ACTIVE_BURST_LEVEL=$MANUAL_BURST_LEVEL
        ACTIVE_BURST_UNTIL_MS=$candidate_until_ms
    elif (( MANUAL_BURST_LEVEL == ACTIVE_BURST_LEVEL && candidate_until_ms > ACTIVE_BURST_UNTIL_MS )); then
        ACTIVE_BURST_UNTIL_MS=$candidate_until_ms
    fi

    enqueue_event_marker "U1"
}

activate_profile_burst_usr2() {
    local now_ms
    now_ms=$(date +%s%3N)
    USR2_PHASE1_UNTIL_MS=$((now_ms + USR2_PHASE1_DURATION_MS))
    USR2_PHASE2_UNTIL_MS=$((USR2_PHASE1_UNTIL_MS + USR2_PHASE2_DURATION_MS))

    ACTIVE_BURST_LEVEL=2
    ACTIVE_BURST_UNTIL_MS=$USR2_PHASE2_UNTIL_MS
    ACTIVE_BURST_INTERVAL_OVERRIDE="$USR2_PHASE1_INTERVAL"

    enqueue_event_marker "U2"
}

trap 'handle_stop' SIGTERM SIGINT
trap 'activate_manual_burst' SIGUSR1
trap 'activate_profile_burst_usr2' SIGUSR2

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

format_temp_cf() {
    local mc="$1"
    local c f
    c=$(format_temp_c "$mc")
    f=$(( (mc * 9 / 5 + 32000) / 1000 ))
    printf "%s %3d°F" "$c" "$f"
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

sanitize_rpm() {
    local rpm="$1"
    if [[ "$rpm" =~ ^[0-9]+$ ]]; then
        printf "%s" "$rpm"
    else
        printf "0"
    fi
}

rpm_to_level() {
    local rpm
    rpm=$(sanitize_rpm "$1")
    # User-provided RPM thresholds:
    # L1: 1500, L2: 2400, L3: 3300, L4: 4100, L5: 4800+.
    if (( rpm >= 4800 )); then printf "5"
    elif (( rpm >= 4000 )); then printf "4"
    elif (( rpm >= 3200 )); then printf "3"
    elif (( rpm >= 2300 )); then printf "2"
    elif (( rpm >= 1500 )); then printf "1"
    else printf "0"
    fi
}

get_effective_level_from_rpms() {
    local fan1_rpm="$1" fan2_rpm="$2" fan3_rpm="$3"
    local l1 l2 l3 max_level
    l1=$(rpm_to_level "$fan1_rpm")
    l2=$(rpm_to_level "$fan2_rpm")
    l3=$(rpm_to_level "$fan3_rpm")
    max_level="$l1"
    if (( l2 > max_level )); then max_level="$l2"; fi
    if (( l3 > max_level )); then max_level="$l3"; fi
    printf "%s" "$max_level"
}

get_burst_interval_for_level() {
    local level="$1"
    # Burst logging schedule:
    # L2: 15s for 60s, L3: 8s for 60s, L4: 4s for 30s, L5: 2s for 16s.
    case "$level" in
        2) printf "15" ;;
        3) printf "8" ;;
        4) printf "4" ;;
        5) printf "2" ;;
        *) printf "%s" "$DEFAULT_TOP_SAMPLE_DELAY" ;;
    esac
}

get_burst_duration_ms_for_level() {
    local level="$1"
    case "$level" in
        2|3) printf "60000" ;;
        4) printf "30000" ;;
        5) printf "16000" ;;
        *) printf "0" ;;
    esac
}

get_fan_rpms() {
    local f1 f2 f3
    if [ -d "$EC_PATH" ]; then
        f1=$(read_fan_field 1 rpm "0")
        f2=$(read_fan_field 2 rpm "0")
        f3=$(read_fan_field 3 rpm "0")
        printf "%s %s %s" "$(sanitize_rpm "$f1")" "$(sanitize_rpm "$f2")" "$(sanitize_rpm "$f3")"
    else
        printf "0 0 0"
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
    local first_non_acpi=1

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

        if [[ "$sensor" != acpitz* ]] && (( first_non_acpi )); then
            t_fmt=$(printf "%s %3d°F %-*.*s" "$(format_temp_c "$mc")" "$(( (mc * 9 / 5 + 32000) / 1000 ))" "$TEMP_LABEL_WIDTH" "$TEMP_LABEL_WIDTH" "$label")
            first_non_acpi=0
        else
            t_fmt=$(printf "%4s %-*.*s" "$(format_temp_c "$mc")" "$TEMP_LABEL_WIDTH" "$TEMP_LABEL_WIDTH" "$label")
        fi
        if [[ -z "$out" ]]; then
            out="$t_fmt"
        else
            out="$out  $t_fmt"
        fi
    done <<< "$sorted"

    printf "%s" "$out"
}

get_top_procs() {
    local sample_delay="$1"
    # Use top in batch mode for an N-second average.
    # We use -n 2 because the first iteration is the lifetime average.
    # The second iteration reflects activity over the sample delay (-d N).
    top -b -n 2 -d "$sample_delay" -w 512 -c \
        | awk -v top_n="$TOP_N" -v name_w="$PROC_NAME_WIDTH" '
            # Skip to the second iteration of top
            /^top - / { iter++; next }
            iter < 2 { next }
            
            # Find the process list header
            /PID USER/ { found=1; next }
            
            # Process the top N entries
            found && proc_count < top_n {
                # Column 9 is %CPU, column 12+ is COMMAND
                cpu_val = $9 + 0;
                if (cpu_val <= 0) next; # Filter out idle processes

                if (cpu_val >= 1000) {
                    cpu = sprintf("%.0f", cpu_val);
                } else {
                    cpu = sprintf("%.1f", cpu_val);
                }
                
                # Reconstruct command line from all fields starting at 12
                cmd = "";
                for (i=12; i<=NF; i++) {
                    cmd = (cmd == "" ? $i : cmd " " $i);
                }
                
                # Split binary name and arguments
                split(cmd, parts, " ");
                binary = parts[1];
                args = "";
                for (i=2; i<=length(parts); i++) {
                    args = (args == "" ? parts[i] : args " " parts[i]);
                }
                
                # Clean up binary (basename)
                if (binary ~ /^\[/) {
                    # Kernel thread: strip brackets
                    gsub(/[\[\]]/, "", binary);
                } else {
                    sub(/.*\/+/, "", binary);
                }
                
                # Clean up args (home, usr, and leading paths from the first arg)
                gsub(/\/home\/[^/ ]+\//, "", args);
                gsub(/\/usr(\/local)?\/(s?bin|libexec)\//, "", args);
                sub(/^\/[^ ]*\//, "", args); 
                
                # Combine binary and args
                display_name = binary;
                if (args != "") {
                    display_name = binary " " args;
                }
                
                # Truncate to match name_w
                if (length(display_name) > name_w) {
                    display_name = substr(display_name, 1, name_w);
                }
                
                proc_count++;
                if (proc_count < top_n) {
                    printf "%5s%% %-*s  ", cpu, name_w, display_name;
                } else {
                    printf "%5s%% %-*s", cpu, name_w, display_name;
                }
            }
            
            END {
                # Fill remaining slots with spaces to maintain column alignment
                while (proc_count < top_n) {
                    proc_count++;
                    if (proc_count < top_n) {
                        printf "%*s  ", 7 + name_w, "";
                    } else {
                        printf "%*s", 7 + name_w, "";
                    }
                }
            }'
}

load_event_markers
enqueue_event_marker "R"

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
    read -r FAN1_RPM FAN2_RPM FAN3_RPM <<< "$(get_fan_rpms)"
    FAN_SUMMARY=$(printf "%5d%5d%5d" "$FAN1_RPM" "$FAN2_RPM" "$FAN3_RPM")
    EFFECTIVE_LEVEL=$(get_effective_level_from_rpms "$FAN1_RPM" "$FAN2_RPM" "$FAN3_RPM")
    NOW_MS=$(date +%s%3N)

    if (( USR2_PHASE2_UNTIL_MS > 0 )); then
        if (( NOW_MS < USR2_PHASE1_UNTIL_MS )); then
            ACTIVE_BURST_INTERVAL_OVERRIDE="$USR2_PHASE1_INTERVAL"
        elif (( NOW_MS < USR2_PHASE2_UNTIL_MS )); then
            ACTIVE_BURST_INTERVAL_OVERRIDE="$USR2_PHASE2_INTERVAL"
        else
            ACTIVE_BURST_INTERVAL_OVERRIDE=""
            USR2_PHASE1_UNTIL_MS=0
            USR2_PHASE2_UNTIL_MS=0
            enqueue_event_marker "U2C"
        fi
    fi

    if (( NOW_MS >= ACTIVE_BURST_UNTIL_MS )); then
        ACTIVE_BURST_LEVEL=0
        ACTIVE_BURST_UNTIL_MS=0
        ACTIVE_BURST_INTERVAL_OVERRIDE=""
    fi

    if (( EFFECTIVE_LEVEL >= 2 && EFFECTIVE_LEVEL <= 5 )); then
        BURST_DURATION_MS=$(get_burst_duration_ms_for_level "$EFFECTIVE_LEVEL")
        CANDIDATE_UNTIL_MS=$((NOW_MS + BURST_DURATION_MS))
        if (( EFFECTIVE_LEVEL > ACTIVE_BURST_LEVEL )); then
            ACTIVE_BURST_LEVEL=$EFFECTIVE_LEVEL
            ACTIVE_BURST_UNTIL_MS=$CANDIDATE_UNTIL_MS
        elif (( EFFECTIVE_LEVEL == ACTIVE_BURST_LEVEL && CANDIDATE_UNTIL_MS > ACTIVE_BURST_UNTIL_MS )); then
            ACTIVE_BURST_UNTIL_MS=$CANDIDATE_UNTIL_MS
        fi
    fi

    TOP_SAMPLE_DELAY="$DEFAULT_TOP_SAMPLE_DELAY"
    if [[ -n "$ACTIVE_BURST_INTERVAL_OVERRIDE" ]]; then
        TOP_SAMPLE_DELAY="$ACTIVE_BURST_INTERVAL_OVERRIDE"
    elif (( ACTIVE_BURST_LEVEL >= 2 && ACTIVE_BURST_LEVEL <= 5 )); then
        TOP_SAMPLE_DELAY=$(get_burst_interval_for_level "$ACTIVE_BURST_LEVEL")
    fi

    if (( TOP_SAMPLE_DELAY != DEFAULT_TOP_SAMPLE_DELAY )); then
        if [[ "$TOP_SAMPLE_DELAY" != "$LAST_BURST_DELAY" ]]; then
            enqueue_event_marker "B${TOP_SAMPLE_DELAY}"
            LAST_BURST_DELAY="$TOP_SAMPLE_DELAY"
        fi
    elif [[ -n "$LAST_BURST_DELAY" ]]; then
        enqueue_event_marker "BE"
        LAST_BURST_DELAY=""
    fi

    SAMPLE_START_MS=$(date +%s%3N)
    TOP_PROCS=$(get_top_procs "$TOP_SAMPLE_DELAY")
    SAMPLE_END_MS=$(date +%s%3N)
    SAMPLE_ELAPSED_MS=$((SAMPLE_END_MS - SAMPLE_START_MS))
    MIN_SAMPLE_ELAPSED_MS=$((TOP_SAMPLE_DELAY * 1000 - 1000))
    if (( MIN_SAMPLE_ELAPSED_MS < 0 )); then
        MIN_SAMPLE_ELAPSED_MS=0
    fi

    # If sampling was interrupted (for example by an external signal sent to
    # the whole unit), skip this write and keep queued event markers for the
    # next complete sample line.
    if (( SAMPLE_ELAPSED_MS < MIN_SAMPLE_ELAPSED_MS )); then
        sleep "$LOOP_SAFETY_SLEEP"
        continue
    fi

    EVENT_SUFFIX=""
    if [[ -n "$EVENT_MARKERS" ]]; then
        EVENT_SUFFIX="  E=$EVENT_MARKERS"
        EVENT_MARKERS=""
        persist_event_markers
    fi
    echo "$TIMESTAMP $TOP_PROCS  $FAN_MODE$FAN_SUMMARY$TEMP_BLOCK  C= $TEMP_SUMMARY$EVENT_SUFFIX" >> "$LOG_DIR/$LOG_PREFIX-$CURRENT_DATE.log"
    # Safety delay prevents busy-looping if top fails or is interrupted.
    sleep "$LOOP_SAFETY_SLEEP"
done
