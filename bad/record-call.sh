#!/bin/bash

# record-call.sh - Record system audio + mic as TWO SEPARATE CHANNELS
#
# WHAT THIS DOES:
#   Records everything playing through your speakers (all apps) on the LEFT
#   channel, and your microphone on the RIGHT channel, into one stereo file.
#
#   ch0 (left)  = remote participants (speaker output)
#   ch1 (right) = you (local mic, echo-cancelled)
#
#   This layout is what the transcription pipeline expects. Do not collapse
#   these into a single mixed channel -- see "WHY TWO CHANNELS" below.
#
# HOW IT WORKS:
#   1. Loads module-echo-cancel wired to BOTH the mic and the speaker sink,
#      so the canceller has a reference signal and can actually remove
#      speaker bleed from the mic.
#   2. Temporarily makes the echo-cancelling sink the default, so app audio
#      passes through it (this is what gives the canceller its reference).
#   3. Taps that sink's monitor for remote audio and the cancelled source for
#      the mic, and interleaves them as two channels.
#   4. Restores your original audio routing on exit.
#
# WHY TWO CHANNELS:
#   The previous version used `amix`, which merged speaker + mic into a single
#   signal duplicated across both channels. The transcriber treats ch0 as
#   remote and ch1 as local, so it transcribed the same mixed audio twice and
#   merged the results -- producing every word twice ("I'm I'm just just
#   having having"). Keeping the channels separate fixes that, and also gives
#   clean speaker attribution.
#
# USAGE:
#   record-call.sh [name]
#   record-call.sh drone-tech-weekly
#   Press 'q' or Ctrl+C to stop recording
#
# REQUIRES: PulseAudio (or PipeWire with PulseAudio compat), ffmpeg

set -uo pipefail

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NAME=${1:-call}
OUTFILE="audio-${NAME#audio-}-${TIMESTAMP}.m4a"

# --- Device discovery ---------------------------------------------------
# Never hardcode device names: USB webcams/headsets get different names on
# every machine and disappear when unplugged. The old script hardcoded an
# eMeet C950 that was no longer connected, so the echo-cancel module failed
# to load and ffmpeg silently fell back to the raw default mic -- meaning no
# echo cancellation was applied at all.

SINK=$(pactl get-default-sink)
MIC=$(pactl get-default-source)

# If the default source is a monitor, that's not a real mic -- pick a real one.
case "$MIC" in
    *.monitor|"")
        MIC=$(pactl list short sources | awk '$2 !~ /\.monitor$/ {print $2; exit}')
        ;;
esac

if [ -z "$SINK" ] || [ -z "$MIC" ]; then
    echo "ERROR: could not determine audio devices." >&2
    echo "  sink: '${SINK:-<none>}'   mic: '${MIC:-<none>}'" >&2
    exit 1
fi

echo "------------------------------------------------"
echo "RECORDING STARTED (2-channel: remote | mic)"
echo "Output:  $OUTFILE"
echo "Speaker: $SINK"
echo "Mic:     $MIC"
echo "------------------------------------------------"

# --- State we may need to undo on exit ---
EC_MODULE_ID=""
ORIG_DEFAULT_SINK=""
MOVED_INPUTS=()

cleanup() {
    # Put audio routing back the way we found it.
    #
    # ORDER MATTERS. The default sink must be set LAST. When the echocancel
    # sink is unloaded, wireplumber notices a sink disappeared and re-runs its
    # default-device policy, which happily picks the wrong output (e.g. an
    # HDMI/pro sink). Setting the default before unloading gets silently
    # overridden that way, leaving the machine with no audible output.

    # 1. Put any streams we moved back on the real sink.
    if [ -n "$ORIG_DEFAULT_SINK" ]; then
        for si in "${MOVED_INPUTS[@]:-}"; do
            [ -n "$si" ] && pactl move-sink-input "$si" "$ORIG_DEFAULT_SINK" 2>/dev/null || true
        done
    fi

    # 2. Unload the module (this is what triggers wireplumber's re-pick).
    if [ -n "$EC_MODULE_ID" ]; then
        echo "Unloading echo cancellation module..."
        # Unload by ID, not by name: `pactl unload-module module-echo-cancel`
        # is unreliable under PipeWire's Pulse compatibility layer.
        pactl unload-module "$EC_MODULE_ID" 2>/dev/null || true
        EC_MODULE_ID=""
        sleep 1  # let wireplumber finish reacting before we override it
    fi

    # 3. Now force the default sink back, and confirm it actually stuck.
    if [ -n "$ORIG_DEFAULT_SINK" ]; then
        for _ in 1 2 3; do
            pactl set-default-sink "$ORIG_DEFAULT_SINK" 2>/dev/null || true
            [ "$(pactl get-default-sink 2>/dev/null)" = "$ORIG_DEFAULT_SINK" ] && break
            sleep 1
        done
        if [ "$(pactl get-default-sink 2>/dev/null)" != "$ORIG_DEFAULT_SINK" ]; then
            echo "WARNING: could not restore default sink to $ORIG_DEFAULT_SINK" >&2
            echo "  current: $(pactl get-default-sink 2>/dev/null)" >&2
        fi
        ORIG_DEFAULT_SINK=""
    fi
}
trap cleanup EXIT INT TERM

# --- Load echo cancellation ---------------------------------------------
# Both source_master AND sink_master matter. module-echo-cancel can only
# subtract speaker bleed from the mic if it can see what is being played --
# that reference comes from audio passing through its companion sink. The old
# script omitted sink_master and never routed playback through the sink, so
# even when it loaded, the canceller had no reference and did nothing.
#   aec_method=webrtc      = Google's echo cancellation algorithm
#   analog_gain_control=0  = don't auto-adjust mic hardware gain
#   digital_gain_control=1 = do auto-adjust volume in software
echo "Loading echo cancellation module..."
EC_MODULE_ID=$(pactl load-module module-echo-cancel \
    source_name=echocancel_source \
    sink_name=echocancel_sink \
    source_master="$MIC" \
    sink_master="$SINK" \
    aec_method=webrtc \
    aec_args="analog_gain_control=0 digital_gain_control=1" \
    use_master_format=1 2>&1)

if ! [[ "$EC_MODULE_ID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: failed to load module-echo-cancel:" >&2
    echo "  $EC_MODULE_ID" >&2
    EC_MODULE_ID=""
    exit 1
fi
echo "Module loaded with ID: $EC_MODULE_ID"

sleep 1  # Give PulseAudio a moment to initialize the new source and sink

# --- Route playback through the echo-cancelling sink --------------------
# This is what feeds the canceller its reference signal. We also move streams
# that are already playing (your meeting app is probably already running).
ORIG_DEFAULT_SINK="$SINK"
pactl set-default-sink echocancel_sink 2>/dev/null || true
while read -r si _; do
    [ -z "$si" ] && continue
    if pactl move-sink-input "$si" echocancel_sink 2>/dev/null; then
        MOVED_INPUTS+=("$si")
    fi
done < <(pactl list short sink-inputs)
echo "Routed ${#MOVED_INPUTS[@]} active stream(s) through echo canceller."

echo "Press 'q' or Ctrl+C to stop."
echo "------------------------------------------------"

# --- Record: remote on ch0, mic on ch1 ----------------------------------
# ffmpeg flags:
#   -f pulse -i "echocancel_sink.monitor" = input 0: everything played to
#       speakers (remote participants)
#   -f pulse -i "echocancel_source"       = input 1: echo-cancelled mic (you)
#   -filter_complex:
#       aformat=...channel_layouts=mono   = downmix each input to mono so the
#           merge produces exactly 2 channels regardless of whether the mic
#           reports as mono or stereo
#       amerge=inputs=2                   = interleave as ch0=remote, ch1=mic.
#           NOT amix -- amix would sum them into one signal and lose the
#           speaker separation the transcriber depends on.
#   -c:a aac -b:a 192k = AAC at 192 kbps (good quality for voice)
#   -t 03:00:00        = max recording length 3 hours (safety limit)
ffmpeg -stats -y \
  -f pulse -i "echocancel_sink.monitor" \
  -f pulse -i "echocancel_source" \
  -filter_complex "[0:a]aformat=sample_fmts=fltp:channel_layouts=mono[remote];[1:a]aformat=sample_fmts=fltp:channel_layouts=mono[mic];[remote][mic]amerge=inputs=2[out]" \
  -map "[out]" \
  -c:a aac -b:a 192k \
  -t 03:00:00 \
  "$OUTFILE"

echo -e "\n------------------------------------------------"
echo "Recording saved to: $OUTFILE"
echo "  ch0 (left)  = remote participants"
echo "  ch1 (right) = your mic (echo-cancelled)"
echo "------------------------------------------------"
