#!/bin/bash

# video-signal-record.sh - Record Signal calls: periodic window snapshots + audio
#
# WHAT THIS DOES:
#   Captures the Signal window as periodic snapshots (xwd) and records audio,
#   then encodes everything into a single MP4 after the call ends.
#
#   Audio routing is NOT managed by this script — it reads from whatever is
#   already set up:
#     - signal_sink.monitor  if signal-record.sh is running (Signal-isolated)
#     - Speaker monitor      otherwise (all system audio)
#
# HOW IT WORKS:
#   1. Finds Signal's X11 window via xdotool
#   2. Starts audio recording in background (no routing changes)
#   3. Captures window snapshots every INTERVAL seconds via xwd
#      - Follows window moves/resizes (captures by window ID each time)
#      - When minimized: holds the last good frame
#   4. On Ctrl+C: stops audio, encodes frames → video, muxes with audio → MP4
#      Frames are scaled to the largest captured size and padded with black bars
#      so the output has consistent dimensions even if the window was resized.
#
# TYPICAL WORKFLOW:
#   1. Start record-call.sh and/or signal-record.sh
#   2. Start this script
#   3. Press Ctrl+C to stop — MP4 is produced automatically
#
# USAGE:
#   video-signal-record.sh [options] [name]
#   video-signal-record.sh --interval 5 weekly-meeting
#   video-signal-record.sh --mic-mode off demo
#
# REQUIRES: ffmpeg (with x11grab), xdotool, xwd, PulseAudio/PipeWire

# --- Hardware-specific device names ---
ORIGINAL_MIC="alsa_input.usb-EMEET_HD_Webcam_eMeet_C950_A230803002402311-02.analog-stereo"
VIRTUAL_SINK="signal_sink"

# --- Tunables ---
INTERVAL="${SIGNAL_VIDEO_INTERVAL:-3}"   # seconds between frame captures
VIDEO_CRF="${SIGNAL_VIDEO_CRF:-28}"
SIGNAL_MIC_MODE="${SIGNAL_MIC_MODE:-auto}"
SIGNAL_MIC_GAIN_DB="${SIGNAL_MIC_GAIN_DB:-0}"

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [options] [name]

Options:
  --interval N           Seconds between frame captures (default: ${INTERVAL})
  --mic-mode auto|on|off Microphone capture mode (default: ${SIGNAL_MIC_MODE})
  -h, --help             Show this help

Environment:
  SIGNAL_VIDEO_INTERVAL  Seconds between frame captures (default: 3)
  SIGNAL_VIDEO_CRF       x264 CRF value (default: 28, higher=smaller)
  SIGNAL_MIC_GAIN_DB     Mic gain trim in dB (default: 0)
EOF
}

MIC_MODE="$SIGNAL_MIC_MODE"
NAME=""

while [ $# -gt 0 ]; do
    case "$1" in
        --interval)
            if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
                echo "ERROR: --interval requires a positive integer."
                exit 1
            fi
            INTERVAL="$2"
            shift 2
            ;;
        --mic-mode)
            if [[ "$2" != "auto" && "$2" != "on" && "$2" != "off" ]]; then
                echo "ERROR: --mic-mode must be auto, on, or off."
                exit 1
            fi
            MIC_MODE="$2"
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
    NAME="signal-video"
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTFILE="${NAME}-${TIMESTAMP}.mp4"
AUDIO_TMPFILE="${NAME}-${TIMESTAMP}-audio.mkv"
mkdir -p tmp
FRAME_DIR="tmp/frames-${TIMESTAMP}"
mkdir -p "$FRAME_DIR"

# --- Find Signal window (largest window matching "Signal", to avoid sub-windows) ---
WINDOW_ID=$(xdotool search --name "Signal" 2>/dev/null | while read -r wid; do
    geom=$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)
    w=$(echo "$geom" | awk -F= '/^WIDTH/{print $2}')
    h=$(echo "$geom" | awk -F= '/^HEIGHT/{print $2}')
    [[ "$w" =~ ^[0-9]+$ ]] && [[ "$h" =~ ^[0-9]+$ ]] && echo "$((w*h)) $wid"
done | sort -rn | awk 'NR==1{print $2}')
if [ -z "$WINDOW_ID" ]; then
    echo "ERROR: No Signal window found. Is Signal Desktop running?"
    exit 1
fi
echo "Signal window found: ${WINDOW_ID} ($(xdotool getwindowname "$WINDOW_ID" 2>/dev/null))"

# --- Determine audio source (no routing changes made) ---
if pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$VIRTUAL_SINK"; then
    AUDIO_SOURCE="${VIRTUAL_SINK}.monitor"
    echo "Audio source: ${VIRTUAL_SINK}.monitor (signal-record.sh is active)"
else
    AUDIO_SOURCE="alsa_output.pci-0000_c6_00.6.analog-stereo.monitor"
    echo "Audio source: speaker monitor (signal_sink not found)"
fi

# --- Mic mode ---
FINAL_MIC_ON=1
if [ "$MIC_MODE" = "off" ]; then
    FINAL_MIC_ON=0
elif [ "$MIC_MODE" = "auto" ]; then
    if pactl list source-outputs | grep -qi 'ringrtc'; then
        FINAL_MIC_ON=1
        echo "MIC MODE AUTO: Mic stream found -> ON"
    else
        FINAL_MIC_ON=0
        echo "MIC MODE AUTO: Mic stream NOT found -> OFF"
    fi
else
    FINAL_MIC_ON=1
    echo "MIC MODE: ON"
fi

AUDIO_PID=""

encode_video() {
    local frame_count
    frame_count=$(ls "$FRAME_DIR"/frame-*.png 2>/dev/null | wc -l)
    if [ "$frame_count" -eq 0 ]; then
        echo "No frames captured — skipping video encode."
        return
    fi
    echo "Encoding ${frame_count} frames..."

    # Find max dimensions across all frames
    local max_w=0 max_h=0 w h dims
    for f in "$FRAME_DIR"/frame-*.png; do
        dims=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=width,height -of csv=p=0 "$f" 2>/dev/null)
        w=$(echo "$dims" | cut -d, -f1)
        h=$(echo "$dims" | cut -d, -f2)
        [[ "$w" =~ ^[0-9]+$ ]] && [ "$w" -gt "$max_w" ] && max_w=$w
        [[ "$h" =~ ^[0-9]+$ ]] && [ "$h" -gt "$max_h" ] && max_h=$h
    done

    # Ensure dimensions are even (required by yuv420p)
    max_w=$(( (max_w + 1) / 2 * 2 ))
    max_h=$(( (max_h + 1) / 2 * 2 ))
    echo "Max frame size: ${max_w}x${max_h}"

    local scale_pad="scale=${max_w}:${max_h}:force_original_aspect_ratio=decrease,pad=${max_w}:${max_h}:(ow-iw)/2:(oh-ih)/2:black"

    if [ -f "$AUDIO_TMPFILE" ]; then
        ffmpeg -hide_banner -y \
          -framerate "1/${INTERVAL}" \
          -i "${FRAME_DIR}/frame-%06d.png" \
          -i "$AUDIO_TMPFILE" \
          -vf "$scale_pad" \
          -c:v libx264 -crf "$VIDEO_CRF" -preset ultrafast -pix_fmt yuv420p \
          -c:a copy \
          -shortest \
          "$OUTFILE" && echo "Output: $OUTFILE"
    else
        ffmpeg -hide_banner -y \
          -framerate "1/${INTERVAL}" \
          -i "${FRAME_DIR}/frame-%06d.png" \
          -vf "$scale_pad" \
          -c:v libx264 -crf "$VIDEO_CRF" -preset ultrafast -pix_fmt yuv420p \
          "$OUTFILE" && echo "Output: $OUTFILE"
    fi
}

cleanup() {
    echo -e "\n------------------------------------------------"
    echo "Stopping..."

    if [ -n "${CAPTURE_PID:-}" ]; then
        kill "$CAPTURE_PID" 2>/dev/null
        wait "$CAPTURE_PID" 2>/dev/null
    fi

    if [ -n "$AUDIO_PID" ]; then
        # Only signal if still running — Ctrl+C already sent SIGINT to the group
        if kill -0 "$AUDIO_PID" 2>/dev/null; then
            kill -INT "$AUDIO_PID" 2>/dev/null
        fi
        wait "$AUDIO_PID" 2>/dev/null
        echo "Audio recording stopped."
    fi

    encode_video

    rm -rf "$FRAME_DIR"
    rm -f "$AUDIO_TMPFILE" "${AUDIO_TMPFILE}.log"
    echo "------------------------------------------------"
}

trap cleanup EXIT

echo "------------------------------------------------"
echo "VIDEO RECORDING STARTED"
echo "Output:   $OUTFILE"
echo "Interval: ${INTERVAL}s between frames | CRF: $VIDEO_CRF"
echo "Frames:   $FRAME_DIR"
echo "Audio:    $AUDIO_SOURCE"
echo "------------------------------------------------"

# --- Start audio recording in background ---
if [ "$FINAL_MIC_ON" -eq 1 ]; then
    if pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "echocancel_source"; then
        MIC_SOURCE="echocancel_source"
    else
        MIC_SOURCE="$ORIGINAL_MIC"
    fi
    if [ "${SIGNAL_MIC_GAIN_DB}" = "0" ]; then
        MIX_FILTER="[0:a][1:a]amix=inputs=2:duration=longest:normalize=0"
    else
        MIX_FILTER="[1:a]volume=${SIGNAL_MIC_GAIN_DB}dB[mic];[0:a][mic]amix=inputs=2:duration=longest:normalize=0"
    fi
    echo "Mic source: $MIC_SOURCE"
    ffmpeg -nostdin -y \
      -f pulse -i "$AUDIO_SOURCE" \
      -f pulse -i "$MIC_SOURCE" \
      -filter_complex "$MIX_FILTER" \
      -c:a aac -b:a 128k -ac 2 \
      -t 02:30:00 \
      -f matroska "$AUDIO_TMPFILE" >"${AUDIO_TMPFILE}.log" 2>&1 &
else
    ffmpeg -nostdin -y \
      -f pulse -i "$AUDIO_SOURCE" \
      -c:a aac -b:a 128k -ac 2 \
      -t 02:30:00 \
      -f matroska "$AUDIO_TMPFILE" >"${AUDIO_TMPFILE}.log" 2>&1 &
fi
AUDIO_PID=$!
sleep 1
if ! kill -0 "$AUDIO_PID" 2>/dev/null; then
    echo "ERROR: Audio recording failed to start. Log:"
    cat "${AUDIO_TMPFILE}.log"
    exit 1
fi
echo "Audio recording started (PID ${AUDIO_PID})."
echo "Press [q] + Enter to stop."
echo "------------------------------------------------"

# --- Frame capture loop (background) ---
FRAME_NUM=0
LAST_GOOD_FRAME=""

capture_loop() {
    local frame_num=0 last_good=""
    while true; do
        local frame_file="${FRAME_DIR}/frame-$(printf '%06d' $frame_num).png"
        if import -window "$WINDOW_ID" -silent "$frame_file" 2>/dev/null && [ -s "$frame_file" ]; then
            last_good="$frame_file"
            echo -n " ${frame_num} "
        else
            rm -f "$frame_file"
            if [ -n "$last_good" ]; then
                cp "$last_good" "$frame_file"
                echo "Frame ${frame_num} held (window minimized)."
            else
                echo "Frame ${frame_num} skipped (no window content yet)."
            fi
        fi
        frame_num=$((frame_num + 1))
        sleep "$INTERVAL"
    done
}

capture_loop &
CAPTURE_PID=$!

# --- Wait for 'q' to stop ---
while read -r key; do
    [[ "$key" == "q" ]] && break
done

kill "$CAPTURE_PID" 2>/dev/null
wait "$CAPTURE_PID" 2>/dev/null
