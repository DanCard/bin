#!/bin/bash

# signal-record.sh - Record Signal calls with app-level audio isolation
#
# WHAT THIS DOES:
#   Records a Signal call by capturing ONLY Signal's audio (not YouTube, games,
#   etc.) plus your microphone. Other apps' audio is unaffected.
#
# HOW IT WORKS:
#   1. Creates a virtual PipeWire sink (like a fake speaker)
#   2. Finds Signal's active sink-input in PulseAudio/PipeWire
#   3. Moves just that sink-input into the virtual sink
#   4. Loops the virtual sink back to your speakers (so you still hear the call)
#   5. Records from the virtual sink's monitor (Signal only) + your mic
#   6. On exit, restores Signal to its original sink and removes temporary modules
#
# USAGE:
#   signal-record.sh [name]    # Start a Signal call first, then run this
#   signal-record.sh anti-drone-weekly
#   signal-record.sh --mic-mode off
#   signal-record.sh --self-test [name]
#   Press 'q' or Ctrl+C to stop recording
#
# REQUIRES: PipeWire, PulseAudio compatibility layer, ffmpeg
#   Signal must be in an active call (a Signal sink-input must exist)

# --- Hardware-specific device names (from `pactl list short sinks/sources`) ---
SPEAKER="alsa_output.pci-0000_c6_00.6.analog-stereo"          # Built-in speakers
ORIGINAL_MIC="alsa_input.usb-EMEET_HD_Webcam_eMeet_C950_A230803002402311-02.analog-stereo"  # USB webcam mic
SIGNAL_NODE="ringrtc"       # Signal's WebRTC node name, used for mic auto-detection only
VIRTUAL_SINK="signal_sink"  # Name for the virtual sink we create

# Tunable gain for diagnostics and optional mic trim:
SIGNAL_REMOTE_GAIN_DB="${SIGNAL_REMOTE_GAIN_DB:-0}"
SIGNAL_MIC_GAIN_DB="${SIGNAL_MIC_GAIN_DB:-0}"
# Self-test recording length in seconds (override per run if needed):
SIGNAL_SELF_TEST_SECONDS="${SIGNAL_SELF_TEST_SECONDS:-25}"
SIGNAL_MIC_MODE="${SIGNAL_MIC_MODE:-auto}"

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [name]
  $(basename "$0") --self-test [name]
  $(basename "$0") --self-test --self-test-seconds N [name]

Options:
  --mic-mode auto|on|off             Set microphone capture mode (default: ${SIGNAL_MIC_MODE})
  --mute-system-mic-during-recording Mute hardware mic during the call
  --self-test                        Run deterministic test without a live Signal call
  --self-test-seconds N              Self-test duration in seconds (default: ${SIGNAL_SELF_TEST_SECONDS})
  -h, --help                         Show this help

Environment:
  SIGNAL_REMOTE_GAIN_DB    Diagnostic self-test gain in dB (default: ${SIGNAL_REMOTE_GAIN_DB})
  SIGNAL_MIC_GAIN_DB       Mic gain trim in dB (default: ${SIGNAL_MIC_GAIN_DB})
EOF
}

SELF_TEST=0
SELF_TEST_SECONDS="$SIGNAL_SELF_TEST_SECONDS"
MIC_MODE="$SIGNAL_MIC_MODE"
MUTE_MIC=0
NAME=""

while [ $# -gt 0 ]; do
    case "$1" in
        --mic-mode)
            if [[ "$2" != "auto" && "$2" != "on" && "$2" != "off" ]]; then
                echo "ERROR: --mic-mode must be auto, on, or off."
                exit 1
            fi
            MIC_MODE="$2"
            shift 2
            ;;
        --mute-system-mic-during-recording)
            MUTE_MIC=1
            shift
            ;;
        --self-test)
            SELF_TEST=1
            shift
            ;;
        --self-test-seconds)
            if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "ERROR: --self-test-seconds requires an integer value."
                exit 1
            fi
            SELF_TEST_SECONDS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "ERROR: Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [ -n "$NAME" ]; then
                echo "ERROR: Only one optional recording name is supported."
                usage
                exit 1
            fi
            NAME="$1"
            shift
            ;;
    esac
done

if [ -z "$NAME" ]; then
    if [ "$SELF_TEST" -eq 1 ]; then
        NAME="signal-selftest"
    else
        NAME="signal-call"
    fi
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTFILE="${NAME}-${TIMESTAMP}.m4a"

# Track what we set up so cleanup only undoes what we did
ECHO_MODULE_ID=""
SINK_MODULE_ID=""
LOOPBACK_MODULE_ID=""
SIGNAL_SINK_INPUT_ID=""
SIGNAL_ORIGINAL_SINK=""
SIGNAL_SINK_INPUT_VOLUME=""
SIGNAL_MATCH_DESC=""

ORIGINAL_MUTE_STATE=$(pactl get-source-mute "$ORIGINAL_MIC" 2>/dev/null | grep -i 'yes')
if [ "$MUTE_MIC" -eq 1 ]; then
    pactl set-source-mute "$ORIGINAL_MIC" 1 2>/dev/null
    echo "Hardware mic muted via --mute-system-mic-during-recording."
fi

find_signal_sink_input() {
    local -a matches
    local count

    mapfile -t matches < <(
        pactl list sink-inputs 2>/dev/null | awk '
            BEGIN { RS=""; FS="\n" }
            /^Sink Input #[0-9]+/ {
                id=""; sink=""; volume=""; process=""; app=""; media=""; node=""
                for (i = 1; i <= NF; i++) {
                    line = $i
                    lower = tolower(line)
                    if (line ~ /^Sink Input #[0-9]+/) {
                        sub(/^Sink Input #/, "", line)
                        id = line
                    } else if (line ~ /^[[:space:]]*Sink: /) {
                        sub(/^[[:space:]]*Sink: /, "", line)
                        sink = line
                    } else if (line ~ /^[[:space:]]*Volume: / && volume == "") {
                        sub(/^[[:space:]]*Volume: /, "", line)
                        volume = line
                    } else if (lower ~ /application\.process\.binary = /) {
                        sub(/.*= "/, "", line)
                        sub(/"$/, "", line)
                        process = line
                    } else if (lower ~ /application\.name = /) {
                        sub(/.*= "/, "", line)
                        sub(/"$/, "", line)
                        app = line
                    } else if (lower ~ /media\.name = /) {
                        sub(/.*= "/, "", line)
                        sub(/"$/, "", line)
                        media = line
                    } else if (lower ~ /node\.name = /) {
                        sub(/.*= "/, "", line)
                        sub(/"$/, "", line)
                        node = line
                    }
                }

                haystack = tolower(process " " app " " media " " node)
                if (haystack ~ /(signal|ringrtc)/) {
                    print id "|" sink "|" volume "|" process "|" app "|" media "|" node
                }
            }
        '
    )

    count=${#matches[@]}
    if [ "$count" -eq 0 ]; then
        echo "ERROR: No active Signal sink-input found."
        echo "Start a Signal call first, make sure audio is playing, then run this script."
        return 1
    fi

    if [ "$count" -gt 1 ]; then
        echo "ERROR: Multiple Signal-like sink-inputs found; refusing to guess."
        printf '  %s\n' "${matches[@]}"
        return 1
    fi

    IFS='|' read -r SIGNAL_SINK_INPUT_ID SIGNAL_ORIGINAL_SINK SIGNAL_SINK_INPUT_VOLUME _process _app _media _node <<< "${matches[0]}"
    SIGNAL_MATCH_DESC="process=${_process:-?}, app=${_app:-?}, media=${_media:-?}, node=${_node:-?}"
}

find_existing_module_id() {
    local module_name="$1"
    local match_text="$2"

    pactl list short modules 2>/dev/null | awk -v module_name="$module_name" -v match_text="$match_text" '
        $2 == module_name && index($0, match_text) { print $1; exit }
    '
}

build_live_mix_filter() {
    if [ "$FINAL_MIC_ON" -ne 1 ]; then
        return
    fi

    if [ "${SIGNAL_MIC_GAIN_DB}" = "0" ]; then
        MIX_FILTER="[0:a][1:a]amix=inputs=2:duration=longest:normalize=0"
    else
        MIX_FILTER="[1:a]volume=${SIGNAL_MIC_GAIN_DB}dB[mic];[0:a][mic]amix=inputs=2:duration=longest:normalize=0"
    fi
}

build_self_test_filter() {
    local remote_branch="[0:a]"
    local mic_branch="[1:a]"
    local remote_branch_output="[0:a]"
    local mic_branch_output="[1:a]"

    if [ "${SIGNAL_REMOTE_GAIN_DB}" != "0" ]; then
        remote_branch="[0:a]volume=${SIGNAL_REMOTE_GAIN_DB}dB[remote]"
        remote_branch_output="[remote]"
    fi

    if [ "$FINAL_MIC_ON" -eq 1 ]; then
        if [ "${SIGNAL_MIC_GAIN_DB}" != "0" ]; then
            mic_branch="[1:a]volume=${SIGNAL_MIC_GAIN_DB}dB[mic]"
            mic_branch_output="[mic]"
        fi
        SELF_TEST_FILTER="${remote_branch};${mic_branch};${remote_branch_output}${mic_branch_output}amix=inputs=2:duration=longest:normalize=0"
    else
        if [ "${SIGNAL_REMOTE_GAIN_DB}" != "0" ]; then
            SELF_TEST_FILTER="${remote_branch#\[0:a\]}"
        else
            SELF_TEST_FILTER=""
        fi
    fi
}

# Undo all audio routing changes on exit (Ctrl+C, quit, or error)
cleanup() {
    echo -e "\n------------------------------------------------"
    echo "Cleaning up..."

    # Restore Signal stream to original sink via pw-metadata, then let
    # module unload handle any remaining rerouting automatically
    if [ -n "$SIGNAL_SINK_INPUT_ID" ]; then
        ringrtc_node_id=$(pw-dump 2>/dev/null | python3 -c "
import sys, json
target_serial = '${SIGNAL_SINK_INPUT_ID}'
for o in json.load(sys.stdin):
    props = o.get('info', {}).get('props', {})
    if str(props.get('object.serial', '')) == target_serial and props.get('node.name') == 'ringrtc':
        print(o['id']); break
" 2>/dev/null)
        if [ -n "$ringrtc_node_id" ]; then
            pw-metadata "$ringrtc_node_id" target.node -1 2>/dev/null && \
                echo "  Signal stream released to default routing"
        fi
    fi

    if [ -n "$LOOPBACK_MODULE_ID" ]; then
        pactl unload-module "$LOOPBACK_MODULE_ID" 2>/dev/null || true
        echo "  Monitor loopback removed"
    fi

    if [ -n "$SINK_MODULE_ID" ]; then
        pactl unload-module "$SINK_MODULE_ID" 2>/dev/null || true
        echo "  Virtual sink removed"
    fi

    if [ -n "$ECHO_MODULE_ID" ]; then
        pactl unload-module "$ECHO_MODULE_ID" 2>/dev/null || true
        echo "  Echo cancel module unloaded"
    fi

    if [ "$MUTE_MIC" -eq 1 ]; then
        if [ -z "$ORIGINAL_MUTE_STATE" ]; then
            pactl set-source-mute "$ORIGINAL_MIC" 0 2>/dev/null
            echo "  Hardware mic unmuted."
        else
            echo "  Hardware mic was originally muted, left muted."
        fi
    fi

    echo "Recording saved to: $OUTFILE"
    echo "------------------------------------------------"
}

trap cleanup EXIT

# Mic mode auto-detection logic
FINAL_MIC_ON=1
if [ "$MIC_MODE" = "off" ]; then
    FINAL_MIC_ON=0
elif [ "$MIC_MODE" = "auto" ]; then
    # Look for Signal's mic capture stream
    if pactl list source-outputs | grep -qi 'ringrtc'; then
        FINAL_MIC_ON=1
        echo "MIC MODE AUTO: Mic stream found -> ON"
    else
        FINAL_MIC_ON=0
        echo "MIC MODE AUTO: Mic stream NOT found -> OFF"
        echo "Note: Falling back to safe remote-only to prevent keyboard leak."
    fi
else
    FINAL_MIC_ON=1
    echo "MIC MODE: ON"
fi

MIX_FILTER=""
SELF_TEST_FILTER=""
build_live_mix_filter
build_self_test_filter

print_self_test_report() {
    local mean max ch0_mean ch1_mean balance_diff
    local loudness_ok balance_ok
    local num_re='^-?[0-9]+([.][0-9]+)?$'

    mean=$(ffmpeg -hide_banner -i "$OUTFILE" -af volumedetect -f null - 2>&1 | awk -F': ' '/mean_volume/ {print $2}' | awk '{print $1}' | head -n1)
    max=$(ffmpeg -hide_banner -i "$OUTFILE" -af volumedetect -f null - 2>&1 | awk -F': ' '/max_volume/ {print $2}' | awk '{print $1}' | head -n1)
    ch0_mean=$(ffmpeg -hide_banner -i "$OUTFILE" -af "pan=mono|c0=c0,volumedetect" -f null - 2>&1 | awk -F': ' '/mean_volume/ {print $2}' | awk '{print $1}' | head -n1)
    ch1_mean=$(ffmpeg -hide_banner -i "$OUTFILE" -af "pan=mono|c0=c1,volumedetect" -f null - 2>&1 | awk -F': ' '/mean_volume/ {print $2}' | awk '{print $1}' | head -n1)
    if ! [[ "$mean" =~ $num_re ]] || ! [[ "$max" =~ $num_re ]] || ! [[ "$ch0_mean" =~ $num_re ]] || ! [[ "$ch1_mean" =~ $num_re ]]; then
        echo "------------------------------------------------"
        echo "SELF-TEST REPORT"
        echo "File: $OUTFILE"
        echo "SELF-TEST RESULT    : FAIL (unable to parse loudness metrics)"
        echo "------------------------------------------------"
        return 1
    fi

    balance_diff=$(awk -v a="$ch0_mean" -v b="$ch1_mean" 'BEGIN {d=a-b; if (d<0) d=-d; printf "%.2f", d}')

    loudness_ok=$(awk -v m="$mean" 'BEGIN {if (m >= -32.0 && m <= -22.0) print "yes"; else print "no"}')
    balance_ok=$(awk -v d="$balance_diff" 'BEGIN {if (d <= 1.0) print "yes"; else print "no"}')

    echo "------------------------------------------------"
    echo "SELF-TEST REPORT"
    echo "File: $OUTFILE"
    echo "Overall mean volume : ${mean} dB"
    echo "Overall max volume  : ${max} dB"
    echo "Channel mean (L/R)  : ${ch0_mean} dB / ${ch1_mean} dB"
    echo "Channel delta       : ${balance_diff} dB"

    if [ "$loudness_ok" = "yes" ]; then
        echo "Loudness check      : PASS (target mean -32 to -22 dB)"
    else
        echo "Loudness check      : FAIL (target mean -32 to -22 dB)"
    fi

    if [ "$balance_ok" = "yes" ]; then
        echo "Balance check       : PASS (target L/R delta <= 1 dB)"
    else
        echo "Balance check       : FAIL (target L/R delta <= 1 dB)"
    fi

    if [ "$loudness_ok" = "yes" ] && [ "$balance_ok" = "yes" ]; then
        echo "SELF-TEST RESULT    : PASS"
    else
        echo "SELF-TEST RESULT    : FAIL"
        echo "Tip: Self-test only validates the ffmpeg path, not live Signal sink-input loudness."
    fi
    echo "------------------------------------------------"
}

if [ "$SELF_TEST" -eq 1 ]; then
    echo "------------------------------------------------"
    echo "SELF-TEST STARTED (no Signal call needed)"
    echo "Output: $OUTFILE"
    echo "Duration: ${SELF_TEST_SECONDS}s"
    echo "------------------------------------------------"

    # Self-test inputs:
    #   input 0 = deterministic remote tone
    if [ "$FINAL_MIC_ON" -eq 1 ]; then
        ffmpeg -stats -y \
          -f lavfi -i "aevalsrc=0.04*sin(2*PI*997*t)|0.04*sin(2*PI*997*t):s=48000" \
          -f lavfi -i "aevalsrc=0.02*sin(2*PI*400*t):s=48000" \
          -filter_complex "$SELF_TEST_FILTER" \
          -c:a aac -b:a 192k \
          -ac 2 \
          -t "$SELF_TEST_SECONDS" \
          "$OUTFILE"
    else
        if [ -n "$SELF_TEST_FILTER" ]; then
            ffmpeg -stats -y \
              -f lavfi -i "aevalsrc=0.04*sin(2*PI*997*t)|0.04*sin(2*PI*997*t):s=48000" \
              -af "$SELF_TEST_FILTER" \
              -c:a aac -b:a 192k \
              -ac 2 \
              -t "$SELF_TEST_SECONDS" \
              "$OUTFILE"
        else
            ffmpeg -stats -y \
              -f lavfi -i "aevalsrc=0.04*sin(2*PI*997*t)|0.04*sin(2*PI*997*t):s=48000" \
              -c:a aac -b:a 192k \
              -ac 2 \
              -t "$SELF_TEST_SECONDS" \
              "$OUTFILE"
        fi
    fi

    print_self_test_report
    exit 0
fi

# --- Verify Signal is running ---
if ! find_signal_sink_input; then
    exit 1
fi

echo "------------------------------------------------"
echo "RECORDING STARTED (Signal-only isolation)"
echo "Output: $OUTFILE"
echo "------------------------------------------------"

# --- Create virtual sink for Signal ---
if ! pactl list short sinks | awk '{print $2}' | grep -qx "$VIRTUAL_SINK"; then
    SINK_MODULE_ID=$(pactl load-module module-null-sink \
        sink_name="$VIRTUAL_SINK" \
        sink_properties=device.description="Signal_Recording_Sink" 2>/dev/null)
    if [ -z "$SINK_MODULE_ID" ]; then
        echo "ERROR: Failed to create virtual sink ${VIRTUAL_SINK}."
        exit 1
    fi
    echo "Virtual sink created"
else
    echo "Virtual sink already exists"
fi

existing_loopback_id=$(find_existing_module_id "module-loopback" "source=${VIRTUAL_SINK}.monitor")
if [ -n "$existing_loopback_id" ]; then
    echo "Monitor loopback already exists (module ${existing_loopback_id})"
else
    LOOPBACK_MODULE_ID=$(pactl load-module module-loopback \
        source="${VIRTUAL_SINK}.monitor" \
        sink="$SPEAKER" \
        latency_msec=100 2>/dev/null)
    if [ -z "$LOOPBACK_MODULE_ID" ]; then
        echo "ERROR: Failed to create monitor loopback to ${SPEAKER}."
        exit 1
    fi
    echo "Monitor loopback created"
fi

echo "Matched Signal sink-input: ${SIGNAL_SINK_INPUT_ID}"
echo "Original sink: ${SIGNAL_ORIGINAL_SINK}"
echo "Current volume: ${SIGNAL_SINK_INPUT_VOLUME}"
echo "Match details: ${SIGNAL_MATCH_DESC}"
echo "Recording sink: ${VIRTUAL_SINK}"
echo "Resolved mic mode: ${MIC_MODE} -> $([ "$FINAL_MIC_ON" -eq 1 ] && echo on || echo off)"

# Move Signal's stream to the virtual sink via PipeWire metadata
# (pactl move-sink-input is blocked by node.dont-reconnect on ringrtc streams)
move_signal_to_sink() {
    local sink_node_id ringrtc_node_id
    sink_node_id=$(pw-dump 2>/dev/null | python3 -c "
import sys, json
for o in json.load(sys.stdin):
    props = o.get('info', {}).get('props', {})
    if props.get('node.name') == 'signal_sink':
        print(o['id']); break
")
    ringrtc_node_id=$(pw-dump 2>/dev/null | python3 -c "
import sys, json
# Match by pulse sink-input serial to get the exact ringrtc node
target_serial = '${SIGNAL_SINK_INPUT_ID}'
for o in json.load(sys.stdin):
    props = o.get('info', {}).get('props', {})
    serial = str(props.get('object.serial', ''))
    if serial == target_serial and props.get('node.name') == 'ringrtc':
        print(o['id']); break
# Fallback: first ringrtc node
" 2>/dev/null)
    if [ -z "$ringrtc_node_id" ]; then
        ringrtc_node_id=$(pw-dump 2>/dev/null | python3 -c "
import sys, json
for o in json.load(sys.stdin):
    props = o.get('info', {}).get('props', {})
    if props.get('node.name') == 'ringrtc':
        print(o['id']); break
")
    fi
    if [ -z "$sink_node_id" ] || [ -z "$ringrtc_node_id" ]; then
        echo "ERROR: Could not resolve PipeWire node IDs (sink=${sink_node_id:-?}, ringrtc=${ringrtc_node_id:-?})."
        return 1
    fi
    echo "Moving ringrtc node ${ringrtc_node_id} -> signal_sink node ${sink_node_id}"
    pw-metadata "$ringrtc_node_id" target.node "$sink_node_id" 2>/dev/null
}

if ! move_signal_to_sink; then
    echo "ERROR: Failed to move Signal stream to ${VIRTUAL_SINK}."
    exit 1
fi
echo "Signal audio isolated (other apps unaffected)"

# --- Load echo cancellation for mic ---
if [ "$FINAL_MIC_ON" -eq 1 ]; then
    if ! pactl list short modules | grep -q module-echo-cancel; then
        ECHO_MODULE_ID=$(pactl load-module module-echo-cancel \
            source_name=echocancel_source \
            sink_name=echocancel_sink \
            source_master="$ORIGINAL_MIC" \
            aec_method=webrtc \
            aec_args="analog_gain_control=0 digital_gain_control=1" \
            use_master_format=1 2>/dev/null)
        if [ -z "$ECHO_MODULE_ID" ]; then
            echo "ERROR: Failed to load echo cancellation."
            exit 1
        fi
        echo "Echo cancellation loaded"
    else
        echo "Echo cancel module already loaded"
    fi
fi

sleep 1

echo "Press 'q' or Ctrl+C to stop."
echo "------------------------------------------------"

# --- Record: Signal audio (virtual sink monitor) + your mic ---
if [ "$FINAL_MIC_ON" -eq 1 ]; then
    ffmpeg -stats -y \
      -f pulse -i "${VIRTUAL_SINK}.monitor" \
      -f pulse -i "echocancel_source" \
      -filter_complex "$MIX_FILTER" \
      -c:a aac -b:a 192k \
      -ac 2 \
      -t 02:30:00 \
      "$OUTFILE"
else
    ffmpeg -stats -y \
      -f pulse -i "${VIRTUAL_SINK}.monitor" \
      -c:a aac -b:a 192k \
      -ac 2 \
      -t 02:30:00 \
      "$OUTFILE"
fi
