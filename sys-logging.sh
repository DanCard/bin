#!/bin/bash

# To manage the associated service (if created):
#   systemctl --user status sys-logging.service
#   systemctl --user restart sys-logging.service
#   systemctl --user stop sys-logging.service
#   systemctl --user start sys-logging.service
#
# Signal controls (while service is running):
#   # Trigger manual burst profile from SIGUSR1
#   # (defaults: 5s sampling for 45s, then 10s for 50s, then 15s for 60s)
#   # Use --kill-who=main so the current top sample is not interrupted.
#   systemctl --user kill -s USR1 --kill-who=main sys-logging.service
#
#   # Alternative direct signal by PID
#   kill -USR1 "$(systemctl --user show -p MainPID --value sys-logging.service)"

# System Logger: top CPU, thermal summary, and fan speeds on one line.
# Abbreviation legend used in log output:
# - r8169                 = r8169_0_c100:00/temp1
# - mt7925                = mt7925_phy0/temp1
# - nvm <N>               = nvmeX/Sensor N (X = drive index)
# - composite             = nvmeX/Composite
# - F1, F2, F3            = AXB35 System Fans 1, 2, 3

LOG_DIR="$HOME/misc/logs"
TOP_N=3
TEMP_N=4
TEMP_DECIMALS=0
TEMP_LABEL_WIDTH=6
PROC_NAME_WIDTH=15
COMM_WIDTH=15
LOG_RETENTION_DAYS=180
LOG_PREFIX="sys-logging"
EC_PATH="/sys/class/ec_su_axb35"
DEFAULT_TOP_SAMPLE_DELAY=29
LOOP_SAFETY_SLEEP=0.1
START_EVENT_CODE="▷"
RESUME_EVENT_CODE="⚡"
USER_BURST_EVENT_CODE="🏃"
BURST_EVENT_CODE="🌀"
TOP_PROCS_MIN_WIDTH=$((TOP_N * (7 + PROC_NAME_WIDTH) + ((TOP_N - 1) * 2)))
# Event markers are appended to the next telemetry line:
# - ▷   service start
# - ⚡   resume detected (after suspend/wake)
# - 🏃   SIGUSR1 burst request
# - 🏃E SIGUSR1 burst complete
# - 🌀N  level-based burst frequency set/changed (N = level 2-5)
# - 🌀E level-based burst complete
RESUME_DETECT_GRACE_MS=30000
MANUAL_BURST_LEVEL=2
BURST_PHASE1_INTERVAL=5
BURST_PHASE1_DURATION_MS=45000
BURST_PHASE2_INTERVAL=10
BURST_PHASE2_DURATION_MS=50000
BURST_PHASE3_INTERVAL=15
BURST_PHASE3_DURATION_MS=60000
EVENT_QUEUE_FILE=""
EVENT_MARKERS=""

ACTIVE_BURST_LEVEL=0
ACTIVE_BURST_UNTIL_MS=0
ACTIVE_BURST_INTERVAL_OVERRIDE=""
LAST_BURST_DELAY=""
LAST_BURST_SOURCE=""
USR1_BURST_UNTIL_MS=0
LAST_USR1_ACTIVE=0
BURST_PHASE1_UNTIL_MS=0
BURST_PHASE2_UNTIL_MS=0
BURST_PHASE3_UNTIL_MS=0
BURST_RESULT_UNTIL_MS=0
BURST_RESULT_INTERVAL=""

mkdir -p "$LOG_DIR"
# Separate past and present logs if the log file already exists.
[[ -s "$LOG_DIR/$LOG_PREFIX-$(date '+%Y-%m-%d').log" ]] && printf "\n" >> "$LOG_DIR/$LOG_PREFIX-$(date '+%Y-%m-%d').log"
EVENT_QUEUE_FILE="$LOG_DIR/.${LOG_PREFIX}.event-queue"

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

enqueue_event_marker() {
    local marker="$1"
    if [[ -n "$EVENT_MARKERS" ]]; then
        EVENT_MARKERS="${EVENT_MARKERS} ${marker}"
    else
        EVENT_MARKERS="${marker}"
    fi
    persist_event_markers
}

filter_event_markers_for_output() {
    local markers="$1"
    local has_start=0 has_stop=0 output="" marker code
    local marker_list=()

    read -r -a marker_list <<< "$markers"
    for marker in "${marker_list[@]}"; do
        [[ -z "$marker" ]] && continue
        code="$marker"
        if [[ "$code" == "$START_EVENT_CODE" ]]; then
            has_start=1
        elif [[ "$code" == "X" ]]; then
            has_stop=1
        fi
    done

    if (( has_start && has_stop )); then
        for marker in "${marker_list[@]}"; do
            [[ -z "$marker" ]] && continue
            code="$marker"
            [[ "$code" == "X" ]] && continue
            if [[ -n "$output" ]]; then
                output="${output} ${marker}"
            else
                output="$marker"
            fi
        done
        printf "%s" "$output"
    else
        printf "%s" "$markers"
    fi
}

handle_stop() {
    exit 0
}

start_burst_profile() {
    local current_time_ms="$1"
    BURST_PHASE1_UNTIL_MS=$((current_time_ms + BURST_PHASE1_DURATION_MS))
    BURST_PHASE2_UNTIL_MS=$((BURST_PHASE1_UNTIL_MS + BURST_PHASE2_DURATION_MS))
    BURST_PHASE3_UNTIL_MS=$((BURST_PHASE2_UNTIL_MS + BURST_PHASE3_DURATION_MS))
    BURST_RESULT_UNTIL_MS=$BURST_PHASE3_UNTIL_MS
}

get_burst_profile_interval() {
    local current_time_ms="$1"
    BURST_RESULT_INTERVAL=""
    if (( BURST_PHASE3_UNTIL_MS == 0 )); then
        return
    fi
    if (( current_time_ms < BURST_PHASE1_UNTIL_MS )); then
        BURST_RESULT_INTERVAL="$BURST_PHASE1_INTERVAL"
    elif (( current_time_ms < BURST_PHASE2_UNTIL_MS )); then
        BURST_RESULT_INTERVAL="$BURST_PHASE2_INTERVAL"
    elif (( current_time_ms < BURST_PHASE3_UNTIL_MS )); then
        BURST_RESULT_INTERVAL="$BURST_PHASE3_INTERVAL"
    else
        BURST_PHASE1_UNTIL_MS=0
        BURST_PHASE2_UNTIL_MS=0
        BURST_PHASE3_UNTIL_MS=0
    fi
}

activate_manual_burst() {
    local current_time_ms
    ACTIVE_BURST_INTERVAL_OVERRIDE=""
    current_time_ms=$(date +%s%3N)
    start_burst_profile "$current_time_ms"
    USR1_BURST_UNTIL_MS=$BURST_RESULT_UNTIL_MS

    if (( MANUAL_BURST_LEVEL > ACTIVE_BURST_LEVEL )); then
        ACTIVE_BURST_LEVEL=$MANUAL_BURST_LEVEL
        ACTIVE_BURST_UNTIL_MS=$BURST_RESULT_UNTIL_MS
    elif (( MANUAL_BURST_LEVEL == ACTIVE_BURST_LEVEL && BURST_RESULT_UNTIL_MS > ACTIVE_BURST_UNTIL_MS )); then
        ACTIVE_BURST_UNTIL_MS=$BURST_RESULT_UNTIL_MS
    fi

    enqueue_event_marker "${USER_BURST_EVENT_CODE}"
}

trap 'handle_stop' SIGTERM SIGINT
trap 'activate_manual_burst' SIGUSR1

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
    local millidegrees="$1"
    case "$TEMP_DECIMALS" in
        3) printf "%d.%03d°" "$((millidegrees / 1000))" "$((millidegrees % 1000))" ;;
        2) printf "%d.%02d°" "$((millidegrees / 1000))" "$(((millidegrees % 1000) / 10))" ;;
        1) printf "%d.%d°" "$((millidegrees / 1000))" "$(((millidegrees % 1000) / 100))" ;;
        *) printf "%d°" "$((millidegrees / 1000))" ;;
    esac
}

format_temp_cf() {
    local millidegrees="$1"
    local celsius fahrenheit
    celsius=$(format_temp_c "$millidegrees")
    fahrenheit=$(( (millidegrees * 9 / 5 + 32000) / 1000 ))
    printf "%s %3d°F" "$celsius" "$fahrenheit"
}

c_to_f() {
    local millidegrees="$1"
    printf "%3d°F   " "$(( (millidegrees * 9 / 5 + 32000) / 1000 ))"
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
    local mode1 level1 status1
    if [ -d "$EC_PATH" ]; then
        mode1=$(read_fan_field 1 mode "?")
        level1=$(read_fan_field 1 level "?")
        status1="${mode1:0:1}${level1}"
        printf "%s" "$status1"
    fi
}

sanitize_rpm() {
    local fan_rpm="$1"
    if [[ "$fan_rpm" =~ ^[0-9]+$ ]]; then
        printf "%s" "$fan_rpm"
    else
        printf "0"
    fi
}

rpm_to_level() {
    local fan_rpm
    fan_rpm=$(sanitize_rpm "$1")
    # User-provided RPM thresholds:
    # L1: 1500, L2: 2400, L3: 3300, L4: 4100, L5: 4800+.
    if (( fan_rpm >= 4800 )); then printf "5"
    elif (( fan_rpm >= 4000 )); then printf "4"
    elif (( fan_rpm >= 3200 )); then printf "3"
    elif (( fan_rpm >= 2300 )); then printf "2"
    elif (( fan_rpm >= 1500 )); then printf "1"
    else printf "0"
    fi
}

get_effective_level_from_rpms() {
    local fan1_rpm="$1" fan2_rpm="$2" fan3_rpm="$3"
    local level1 level2 level3 max_fan_level
    level1=$(rpm_to_level "$fan1_rpm")
    level2=$(rpm_to_level "$fan2_rpm")
    level3=$(rpm_to_level "$fan3_rpm")
    max_fan_level="$level1"
    if (( level2 > max_fan_level )); then max_fan_level="$level2"; fi
    if (( level3 > max_fan_level )); then max_fan_level="$level3"; fi
    printf "%s" "$max_fan_level"
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
    local fan1_rpm fan2_rpm fan3_rpm
    if [ -d "$EC_PATH" ]; then
        fan1_rpm=$(read_fan_field 1 rpm "0")
        fan2_rpm=$(read_fan_field 2 rpm "0")
        fan3_rpm=$(read_fan_field 3 rpm "0")
        printf "%s %s %s" "$(sanitize_rpm "$fan1_rpm")" "$(sanitize_rpm "$fan2_rpm")" "$(sanitize_rpm "$fan3_rpm")"
    else
        printf "0 0 0"
    fi
}

get_acpi_temp_c() {
    local hwmon_dir temp_file temp_value sensor_name best_millidegrees=""

    for hwmon_dir in /sys/class/hwmon/hwmon*; do
        [ -d "$hwmon_dir" ] || continue
        sensor_name=$(cat "$hwmon_dir/name" 2>/dev/null || echo "hwmon")
        [[ "$sensor_name" == acpitz* ]] || continue
        for temp_file in "$hwmon_dir"/temp*_input; do
            [ -r "$temp_file" ] || continue
            temp_value=$(cat "$temp_file" 2>/dev/null)
            [[ "$temp_value" =~ ^[0-9]+$ ]] || continue
            if [[ -z "$best_millidegrees" || "$temp_value" -gt "$best_millidegrees" ]]; then
                best_millidegrees="$temp_value"
            fi
        done
    done

    if [[ -z "$best_millidegrees" ]]; then
        for hwmon_dir in /sys/class/thermal/thermal_zone*; do
            [ -d "$hwmon_dir" ] || continue
            sensor_name=$(cat "$hwmon_dir/type" 2>/dev/null || echo "")
            [[ "$sensor_name" == "acpitz" ]] || continue
            temp_value=$(cat "$hwmon_dir/temp" 2>/dev/null)
            [[ "$temp_value" =~ ^[0-9]+$ ]] || continue
            if [[ -z "$best_millidegrees" || "$temp_value" -gt "$best_millidegrees" ]]; then
                best_millidegrees="$temp_value"
            fi
        done
    fi

    if [[ -z "$best_millidegrees" ]]; then
        printf "n/a"
    else
        printf "%d" "$((best_millidegrees / 1000))"
    fi
}

get_ec_temp_c() {
    local ec_temp_value
    ec_temp_value=$(read_file_or "$EC_PATH/temp1/temp" "n/a")
    if [[ "$ec_temp_value" =~ ^[0-9]+$ ]]; then
        printf "%s" "$ec_temp_value"
    else
        printf "n/a"
    fi
}

append_temp_entry() {
    local millidegrees="$1" sensor_name="$2"
    collected+="${millidegrees}|${sensor_name}"$'\n'
}

normalize_sensor_name() {
    local sensor="$1"
    local base_name label

    if [[ "$sensor" == */* ]]; then
        base_name="${sensor%%/*}"
        label="${sensor#*/}"
    else
        base_name=""
        label="$sensor"
    fi

    if [[ "$base_name" == r8169_* ]]; then
        base_name="r8169"
    elif [[ "$base_name" == mt7925_phy* ]]; then
        base_name="mt7925"
    elif [[ "$base_name" =~ ^nvme([0-9]+)$ ]]; then
        local idx="${BASH_REMATCH[1]}"
        base_name="nvm$idx"
    fi

    label="${label//Sensor /S}"
    label="${label//Sensor/S}"
    if [[ "$label" =~ ^[Tt]emp([0-9]+)$ ]]; then
        label="${BASH_REMATCH[1]}"
    elif [[ "$label" =~ ^S([0-9]+)$ ]]; then
        label="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$base_name" ]]; then
        if [[ "$base_name" == "r8169" && "$label" == "1" ]]; then
            sensor="r8169"
        elif [[ "$base_name" == "mt7925" && "$label" == "1" ]]; then
            sensor="mt7925"
        elif [[ "$base_name" == nvm* && "$label" == "Composite" ]]; then
            sensor="compo${base_name#nvm}"
        elif [[ "$base_name" == nvm* && "$label" =~ ^[0-9]+$ ]]; then
            sensor="$base_name $label"
        else
            sensor="$base_name/$label"
        fi
    else
        sensor="$label"
    fi

    printf "%s" "$sensor"
}

get_temp_summary() {
    local hwmon_dir temp_file temp_value sensor_name sensor_identifier label thermal_zone
    local collected sorted temp_accum_output="" dev_path dev_id
    local first_non_acpi=1

    collected=""
    for hwmon_dir in /sys/class/hwmon/hwmon*; do
        [ -d "$hwmon_dir" ] || continue
        sensor_name=$(cat "$hwmon_dir/name" 2>/dev/null || echo "hwmon")
        dev_path=$(readlink -f "$hwmon_dir/device" 2>/dev/null || true)
        dev_id=$(basename "$dev_path")
        
        # Skip the virtual su_axb35 hwmon to avoid duplicate temp entries 
        # (we handle the EC driver directly or through other hwmon devices)
        if [[ "$sensor_name" == "su_axb35" ]]; then
            continue
        fi

        if [[ "$sensor_name" == "nvme" && "$dev_id" =~ ^nvme[0-9]+$ ]]; then
            sensor_name="$dev_id"
        fi
        for temp_file in "$hwmon_dir"/temp*_input; do
            [ -r "$temp_file" ] || continue
            temp_value=$(cat "$temp_file" 2>/dev/null)
            [[ "$temp_value" =~ ^[0-9]+$ ]] || continue
            sensor_identifier=$(basename "$temp_file")
            sensor_identifier="${sensor_identifier%_input}"
            label=$(cat "$hwmon_dir/${sensor_identifier}_label" 2>/dev/null || echo "$sensor_identifier")
            append_temp_entry "$temp_value" "${sensor_name}/${label}"
        done
    done

    if [[ -z "$collected" ]]; then
        for thermal_zone in /sys/class/thermal/thermal_zone*; do
            [ -r "$thermal_zone/temp" ] || continue
            temp_value=$(cat "$thermal_zone/temp" 2>/dev/null)
            [[ "$temp_value" =~ ^[0-9]+$ ]] || continue
            label=$(cat "$thermal_zone/type" 2>/dev/null || basename "$thermal_zone")
            append_temp_entry "$temp_value" "$label"
        done
    fi

    if [[ -z "$collected" ]]; then
        printf "n/a"
        return
    fi

    # Always place acpitz first (if available), then fill remaining slots
    # with hottest non-acpitz sensors.
    local acpi_first non_acpi_sorted
    acpi_first=$(printf "%s\n" "$collected" \
        | awk -F'|' '$2 ~ /^acpitz(\/|$)/' \
        | sort -t'|' -k1,1nr \
        | head -n 1)

    if [[ -n "$acpi_first" ]]; then
        non_acpi_sorted=$(printf "%s\n" "$collected" \
            | awk -F'|' '$2 !~ /^acpitz(\/|$)/' \
            | sort -t'|' -k1,1nr)
        sorted=$(
            {
                printf "%s\n" "$acpi_first"
                printf "%s\n" "$non_acpi_sorted"
            } | sed '/^$/d'
        )
    else
        sorted=$(printf "%s" "$collected" | sort -t'|' -k1,1nr)
    fi

    local count=0
    while IFS='|' read -r millidegrees sensor; do
        [[ -z "$millidegrees" ]] && continue
        local temp_formatted
        sensor="$(normalize_sensor_name "$sensor")"

        # Suspected stuck sensor filter:
        if [[ "$sensor" == "nvm0 2" || "$sensor" == "nvm1 2" ]]; then
            if (( millidegrees / 100 == 748 )); then
                continue
            fi
        fi

        # nvm0 1 / nvm1 1 filter: show only if less than 100°F (~37778 mC)
        if [[ "$sensor" == "nvm0 1" || "$sensor" == "nvm1 1" ]]; then
            if (( millidegrees >= 37778 )); then
                continue
            fi
        fi

        # Already have enough items? Stop now.
        (( count >= TEMP_N )) && break

        local label

        if [[ "$sensor" == acpitz* ]]; then
            label=$(c_to_f "$millidegrees")
        else
            label="$sensor"
        fi

        if [[ "$sensor" != acpitz* ]] && (( first_non_acpi )); then
            # Format temperature string for non-ACPI sensors with both Celsius and Fahrenheit values
            # Printf format specifiers breakdown:
            #   %5s      - First argument: Celsius temperature string (e.g., "45.5°C"), right-aligned in 5-character field
            #   %3d°F    - Second argument: Fahrenheit temperature integer (e.g., "114"), right-aligned in 3-char field, followed by °F
            #   %*.*s    - Third argument: Sensor label string, using dynamic width and precision
            #       - *   - Field width taken from argument (fourth argument: $TEMP_LABEL_WIDTH)
            #       - .*  - Precision taken from argument (fifth argument: $TEMP_LABEL_WIDTH)
            #       - s   - String type, right-aligned (no leading minus sign)
            # Why dynamic width and precision (* vs hardcoded number)?
            #   1. Configurable column width - TEMP_LABEL_WIDTH can be adjusted in one place to change all label column spacing
            #   2. Consistent alignment - All sensor labels use the same width value, ensuring uniform formatting
            #   3. Flexible formatting - Same printf format works regardless of actual width setting (e.g., change from 15 to 20 without editing format string)
            #   4. Maintainability - Single source of truth vs hardcoding numbers like %15.15s scattered throughout
            # Arguments breakdown:
            #   $(format_temp_c "$millidegrees") - Converts millidegrees to formatted Celsius string (e.g., 45000 → "45.0°C")
            #   $(( (millidegrees * 9 / 5 + 32000) / 1000 )) - Fahrenheit conversion formula:
            #       - millidegrees * 9 / 5      - Convert millidegrees Celsius to millidegrees Fahrenheit
            #       - + 32000                    - Add 32 degrees in millidegree units (32 * 1000)
            #       - / 1000                     - Convert millidegrees to whole degrees (integer division truncates)
            #       Example: 45000 millidegrees → (45000 * 9 / 5 + 32000) / 1000 = 113000 / 1000 = 113°F
            #   $TEMP_LABEL_WIDTH              - Variable controlling label column width for alignment
            #   $label                         - Sensor identifier string to display in the label column
            temp_formatted=$(printf "%5s%3d°%*.*s" "$(format_temp_c "$millidegrees")" "$(( (millidegrees * 9 / 5 + 32000) / 1000 ))" "$TEMP_LABEL_WIDTH" "$TEMP_LABEL_WIDTH" "$label")
            first_non_acpi=0
        else
            # Format temperature string for ACPI sensors (or subsequent sensors) with only Celsius value
            # Printf format specifiers breakdown:
            #   %5s      - First argument: Celsius temperature string (e.g., "45.5°C"), right-aligned in 5-character field
            #   %*.*s    - Second argument: Sensor label string, using dynamic width and precision
            #       - *   - Field width taken from argument (third argument: $TEMP_LABEL_WIDTH)
            #       - .*  - Precision taken from argument (fourth argument: $TEMP_LABEL_WIDTH)
            #       - s   - String type, right-aligned (no leading minus sign)
            # Why dynamic width and precision (* vs hardcoded number)?
            #   1. Configurable column width - TEMP_LABEL_WIDTH can be adjusted in one place to change all label column spacing
            #   2. Consistent alignment - All sensor labels use the same width value, ensuring uniform formatting
            #   3. Flexible formatting - Same printf format works regardless of actual width setting (e.g., change from 15 to 20 without editing format string)
            #   4. Maintainability - Single source of truth vs hardcoding numbers like %15.15s scattered throughout
            # Arguments breakdown:
            #   $(format_temp_c "$millidegrees") - Converts millidegrees to formatted Celsius string (e.g., 45000 → "45.0°C")
            #   $TEMP_LABEL_WIDTH              - Variable controlling label column width for alignment
            #   $label                         - Sensor identifier string to display in the label column
            # Note: This format is used for ACPI sensors because Fahrenheit is redundant (displayed separately)
            temp_formatted=$(printf "%5s%*.*s" "$(format_temp_c "$millidegrees")" "$TEMP_LABEL_WIDTH" "$TEMP_LABEL_WIDTH" "$label")
        fi

        if [[ -z "$temp_accum_output" ]]; then
            temp_accum_output="$temp_formatted"
        else
            temp_accum_output="$temp_accum_output  $temp_formatted"
        fi
        (( count++ ))
    done <<< "$sorted"

    printf "%s" "$temp_accum_output"
}

get_top_procs() {
    local top_sample_delay="$1"
    # Use top in batch mode for an N-second average.
    # We use -n 2 because the first iteration is the lifetime average.
    # The second iteration reflects activity over the sample delay (-d N).
    top -b -n 2 -d "$top_sample_delay" -w 512 -c \
        | awk -v top_n="$TOP_N" -v name_width="$PROC_NAME_WIDTH" '
            # Skip to the second iteration of top
            /^top - / { iteration++; next }
            iteration < 2 { next }
            
            # Find the process list header
            /PID USER/ { header_found=1; next }
            
            # Process the top N entries
            header_found && process_count < top_n {
                # Column 9 is %CPU, column 12+ is COMMAND
                cpu_value = $9 + 0;
                if (cpu_value <= 0) next; # Filter out idle processes

                if (cpu_value >= 1000) {
                    cpu = sprintf("%.0f", cpu_value);
                } else {
                    cpu = sprintf("%.1f", cpu_value);
                }
                
                # Reconstruct command line from all fields starting at 12
                command_line = "";
                for (i=12; i<=NF; i++) {
                    command_line = (command_line == "" ? $i : command_line " " $i);
                }
                
                # Split binary name and arguments
                split(command_line, command_parts, " ");
                binary_name = command_parts[1];
                command_args = "";
                for (i=2; i<=length(command_parts); i++) {
                    command_args = (command_args == "" ? command_parts[i] : command_args " " command_parts[i]);
                }
                
                # Clean up binary (basename)
                if (binary_name ~ /^\[/) {
                    # Kernel thread: strip brackets
                    gsub(/[\[\]]/, "", binary_name);
                } else {
                    sub(/.*\/+/, "", binary_name);
                }
                
                # Clean up args (home, usr, and leading paths from the first arg)
                gsub(/\/home\/[^/ ]+\//, "", command_args);
                gsub(/\/usr(\/local)?\/(s?bin|libexec)\//, "", command_args);
                sub(/^\/[^ ]*\//, "", command_args); 
                
                # Combine binary and args
                process_display_name = binary_name;
                if (command_args != "") {
                    process_display_name = binary_name " " command_args;
                }
                
                # Truncate to match name_width
                if (length(process_display_name) > name_width) {
                    process_display_name = substr(process_display_name, 1, name_width);
                }
                
                process_count++;
                if (process_count < top_n) {
                    printf "%5s%% %-*s  ", cpu, name_width, process_display_name;
                } else {
                    printf "%5s%% %-*s", cpu, name_width, process_display_name;
                }
            }
            
            END {
                # Fill remaining slots with spaces to maintain column alignment
                while (process_count < top_n) {
                    process_count++;
                    if (process_count < top_n) {
                        printf "%*s  ", 7 + name_width, "";
                    } else {
                        printf "%*s", 7 + name_width, "";
                    }
                }
            }'
}

load_event_markers
enqueue_event_marker "$START_EVENT_CODE"
STARTUP_CURRENT_TIME_MS=$(date +%s%3N)
start_burst_profile "$STARTUP_CURRENT_TIME_MS"
ACTIVE_BURST_UNTIL_MS=$BURST_RESULT_UNTIL_MS
ACTIVE_BURST_INTERVAL_OVERRIDE="$BURST_PHASE1_INTERVAL"

# Bootstrap fan snapshot so first-loop burst logic has a valid input.
FAN_STATUS=$(get_fan_mode)
read -r FAN1_RPM_VALUE FAN2_RPM_VALUE FAN3_RPM_VALUE <<< "$(get_fan_rpms)"
FAN_RPM_SUMMARY=$(printf "%5d%5d%5d" "$FAN1_RPM_VALUE" "$FAN2_RPM_VALUE" "$FAN3_RPM_VALUE")
EFFECTIVE_FAN_LEVEL=$(get_effective_level_from_rpms "$FAN1_RPM_VALUE" "$FAN2_RPM_VALUE" "$FAN3_RPM_VALUE")

LAST_CLEANUP_DATE=""
while true; do
    CURRENT_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
    LOG_DATE=${CURRENT_DATETIME%% *}
    LOG_TIMESTAMP=${CURRENT_DATETIME##* }

    if [ "$LOG_DATE" != "$LAST_CLEANUP_DATE" ]; then
        find "$LOG_DIR" -name "$LOG_PREFIX-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
        LAST_CLEANUP_DATE="$LOG_DATE"
    fi

    TEMPERATURE_SUMMARY=$(get_temp_summary)
    
    if [ "$SHOW_ACPI_EC" -eq 1 ]; then
        ACPI_TEMPERATURE=$(get_acpi_temp_c)
        EC_TEMPERATURE=$(get_ec_temp_c)
        if [[ "$ACPI_TEMPERATURE" =~ ^[0-9]+$ && "$EC_TEMPERATURE" =~ ^[0-9]+$ ]]; then
            TEMPERATURE_DELTA=$((ACPI_TEMPERATURE - EC_TEMPERATURE))
            TEMPERATURE_BLOCK=$(printf "T=acpi:%sC ec:%sC Δ:%+dC" "$ACPI_TEMPERATURE" "$EC_TEMPERATURE" "$TEMPERATURE_DELTA")
        else
            TEMPERATURE_BLOCK=$(printf "T=acpi:%s ec:%s Δ:n/a" "$ACPI_TEMPERATURE" "$EC_TEMPERATURE")
        fi
        TEMPERATURE_BLOCK="  $TEMPERATURE_BLOCK"
    else
        TEMPERATURE_BLOCK=""
    fi
    
    CURRENT_TIME_MS=$(date +%s%3N)
    USR1_BURST_ACTIVE=0

    get_burst_profile_interval "$CURRENT_TIME_MS"
    ACTIVE_BURST_INTERVAL_OVERRIDE="$BURST_RESULT_INTERVAL"

    if (( USR1_BURST_UNTIL_MS > CURRENT_TIME_MS )); then
        USR1_BURST_ACTIVE=1
    fi
    if (( LAST_USR1_ACTIVE == 1 && USR1_BURST_ACTIVE == 0 )); then
        enqueue_event_marker "${USER_BURST_EVENT_CODE}E"
    fi
    LAST_USR1_ACTIVE=$USR1_BURST_ACTIVE
    if (( USR1_BURST_UNTIL_MS > 0 && CURRENT_TIME_MS >= USR1_BURST_UNTIL_MS )); then
        USR1_BURST_UNTIL_MS=0
    fi

    if (( CURRENT_TIME_MS >= ACTIVE_BURST_UNTIL_MS )); then
        ACTIVE_BURST_LEVEL=0
        ACTIVE_BURST_UNTIL_MS=0
        ACTIVE_BURST_INTERVAL_OVERRIDE=""
    fi

    if (( EFFECTIVE_FAN_LEVEL >= 2 && EFFECTIVE_FAN_LEVEL <= 5 )); then
        BURST_DURATION_MILLISECONDS=$(get_burst_duration_ms_for_level "$EFFECTIVE_FAN_LEVEL")
        CANDIDATE_BURST_UNTIL_MS=$((CURRENT_TIME_MS + BURST_DURATION_MILLISECONDS))
        if (( EFFECTIVE_FAN_LEVEL > ACTIVE_BURST_LEVEL )); then
            ACTIVE_BURST_LEVEL=$EFFECTIVE_FAN_LEVEL
            ACTIVE_BURST_UNTIL_MS=$CANDIDATE_BURST_UNTIL_MS
        elif (( EFFECTIVE_FAN_LEVEL == ACTIVE_BURST_LEVEL && CANDIDATE_BURST_UNTIL_MS > ACTIVE_BURST_UNTIL_MS )); then
            ACTIVE_BURST_UNTIL_MS=$CANDIDATE_BURST_UNTIL_MS
        fi
    fi

    TOP_SAMPLE_DELAY="$DEFAULT_TOP_SAMPLE_DELAY"
    if [[ -n "$ACTIVE_BURST_INTERVAL_OVERRIDE" ]]; then
        TOP_SAMPLE_DELAY="$ACTIVE_BURST_INTERVAL_OVERRIDE"
    elif (( ACTIVE_BURST_LEVEL >= 2 && ACTIVE_BURST_LEVEL <= 5 )); then
        TOP_SAMPLE_DELAY=$(get_burst_interval_for_level "$ACTIVE_BURST_LEVEL")
    fi

    CURRENT_BURST_SOURCE=""
    if (( TOP_SAMPLE_DELAY != DEFAULT_TOP_SAMPLE_DELAY )); then
        if [[ -n "$ACTIVE_BURST_INTERVAL_OVERRIDE" ]]; then
            CURRENT_BURST_SOURCE="override"
        elif (( USR1_BURST_ACTIVE == 1 )); then
            CURRENT_BURST_SOURCE="usr1"
        elif (( ACTIVE_BURST_LEVEL >= 2 && ACTIVE_BURST_LEVEL <= 5 )); then
            CURRENT_BURST_SOURCE="level"
        fi
    fi

    if [[ "$CURRENT_BURST_SOURCE" == "level" ]]; then
        if [[ "$LAST_BURST_SOURCE" != "level" || "$TOP_SAMPLE_DELAY" != "$LAST_BURST_DELAY" ]]; then
            enqueue_event_marker "${BURST_EVENT_CODE}${ACTIVE_BURST_LEVEL}"
        fi
        LAST_BURST_DELAY="$TOP_SAMPLE_DELAY"
    elif [[ "$LAST_BURST_SOURCE" == "level" ]]; then
        enqueue_event_marker "${BURST_EVENT_CODE}E"
        LAST_BURST_DELAY=""
    fi
    LAST_BURST_SOURCE="$CURRENT_BURST_SOURCE"

    SAMPLE_START_MILLISECONDS=$(date +%s%3N)
    TOP_PROCESSES=$(get_top_procs "$TOP_SAMPLE_DELAY")
    SAMPLE_END_MILLISECONDS=$(date +%s%3N)
    SAMPLE_ELAPSED_MILLISECONDS=$((SAMPLE_END_MILLISECONDS - SAMPLE_START_MILLISECONDS))
    RESUME_DETECT_THRESHOLD_MS=$((TOP_SAMPLE_DELAY * 1000 + RESUME_DETECT_GRACE_MS))
    if (( SAMPLE_ELAPSED_MILLISECONDS > RESUME_DETECT_THRESHOLD_MS )); then
        # Visually separate telemetry around suspend/resume boundaries.
        printf "\n" >> "$LOG_DIR/$LOG_PREFIX-$LOG_DATE.log"
        enqueue_event_marker "$RESUME_EVENT_CODE"
        RESUME_TIME_MS=$(date +%s%3N)
        start_burst_profile "$RESUME_TIME_MS"
        
        if (( BURST_RESULT_UNTIL_MS > ACTIVE_BURST_UNTIL_MS )); then
            ACTIVE_BURST_UNTIL_MS=$BURST_RESULT_UNTIL_MS
        fi
        ACTIVE_BURST_INTERVAL_OVERRIDE="$BURST_PHASE1_INTERVAL"
    fi
    MINIMUM_SAMPLE_ELAPSED_MS=$((TOP_SAMPLE_DELAY * 1000 - 1000))
    if (( MINIMUM_SAMPLE_ELAPSED_MS < 0 )); then
        MINIMUM_SAMPLE_ELAPSED_MS=0
    fi

    # If sampling was interrupted (for example by an external signal sent to
    # the whole unit), skip this write and keep queued event markers for the
    # next complete sample line.
    if (( SAMPLE_ELAPSED_MILLISECONDS < MINIMUM_SAMPLE_ELAPSED_MS )); then
        sleep "$LOOP_SAFETY_SLEEP"
        continue
    fi

    # `top` can occasionally return partial/empty process text when a signal
    # lands while sampling. Treat this as an interrupted sample and wait for
    # the next scheduled line so column alignment remains stable.
    if (( ${#TOP_PROCESSES} < TOP_PROCS_MIN_WIDTH )); then
        sleep "$LOOP_SAFETY_SLEEP"
        continue
    fi

    # Read fan state after top so logged fan values align with sampled procs.
    FAN_STATUS=$(get_fan_mode)
    read -r FAN1_RPM_VALUE FAN2_RPM_VALUE FAN3_RPM_VALUE <<< "$(get_fan_rpms)"
    FAN_RPM_SUMMARY=$(printf "%5d%5d%5d" "$FAN1_RPM_VALUE" "$FAN2_RPM_VALUE" "$FAN3_RPM_VALUE")
    NEXT_FAN_LEVEL=$(get_effective_level_from_rpms "$FAN1_RPM_VALUE" "$FAN2_RPM_VALUE" "$FAN3_RPM_VALUE")

    EVENT_MARKER_SUFFIX=""
    if [[ -n "$EVENT_MARKERS" ]]; then
        FILTERED_EVENT_MARKERS=$(filter_event_markers_for_output "$EVENT_MARKERS")
        if [[ -n "$FILTERED_EVENT_MARKERS" ]]; then
            EVENT_MARKER_SUFFIX="  $FILTERED_EVENT_MARKERS"
        fi
        EVENT_MARKERS=""
        persist_event_markers
    fi
    echo "$LOG_TIMESTAMP $TOP_PROCESSES  $FAN_STATUS$FAN_RPM_SUMMARY$TEMPERATURE_BLOCK   $TEMPERATURE_SUMMARY$EVENT_MARKER_SUFFIX" >> "$LOG_DIR/$LOG_PREFIX-$LOG_DATE.log"
    EFFECTIVE_FAN_LEVEL="$NEXT_FAN_LEVEL"
    # Safety delay prevents busy-looping if top fails or is interrupted.
    sleep "$LOOP_SAFETY_SLEEP"
done
