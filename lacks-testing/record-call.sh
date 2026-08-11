#!/bin/bash

# record-call.sh - Record system audio + mic as TWO SEPARATE CHANNELS
#
#   ch0 (left)  = remote participants (speaker output)
#   ch1 (right) = you (local mic)
#
# This layout is what the transcription pipeline expects. Do NOT collapse them
# into one mixed channel -- see "WHY TWO CHANNELS" below.
#
# WHY TWO CHANNELS:
#   The previous version used ffmpeg `amix`, which summed speaker + mic into a
#   single signal duplicated across both channels. The transcriber treats ch0
#   as remote and ch1 as local, so it transcribed the same mixed audio twice
#   and merged the results -- producing every word doubled ("I'm I'm just just
#   having having"). `amerge` interleaves instead of summing, which fixes it.
#
# WHAT THIS DELIBERATELY DOES NOT DO:
#   It does not load module-echo-cancel, and it does not touch the default sink
#   or move any playback streams. An earlier attempt routed call audio through
#   an echo-cancelling sink to give the canceller a reference signal. That
#   silenced call playback: audio entered the echo-cancel sink and showed up on
#   its monitor (so the *recording* looked perfect) but never reached the
#   speakers. Speaker bleed is removed after the fact instead -- ch0 is a clean
#   copy of the remote audio, so it works as a reference for offline
#   cancellation. Live audio routing is left completely alone.
#
# USAGE:
#   record-call.sh [name]
#   Press 'q' or Ctrl+C to stop recording
#
# REQUIRES: PulseAudio (or PipeWire with PulseAudio compat), ffmpeg

set -uo pipefail

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NAME=${1:-call}
OUTFILE="audio-${NAME#audio-}-${TIMESTAMP}.m4a"

# --- Device discovery ---------------------------------------------------
# Don't hardcode device names: USB webcams/headsets get different names on
# every machine and vanish when unplugged. The old script named an eMeet C950
# that is no longer connected.
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
MONITOR="${SINK}.monitor"

echo "------------------------------------------------"
echo "RECORDING STARTED (2-channel: remote | mic)"
echo "Output:  $OUTFILE"
echo "Remote:  $MONITOR"
echo "Mic:     $MIC"
echo "------------------------------------------------"
echo "Press 'q' or Ctrl+C to stop."
echo "------------------------------------------------"

# --- Channel alignment ---------------------------------------------------
# The two pulse inputs do not arrive with the same latency. The speaker monitor
# lags the mic by ~493 ms on this machine: an event reaches ch1 nearly half a
# second before the same event reaches ch0. Measured at -494 ms and -492 ms on
# two separate recordings, so it is a stable property of the capture pipeline,
# not clock drift.
#
# Left uncorrected this skews the transcript -- your speech gets timestamped
# ~0.5 s earlier than the remote speech it was responding to -- and it makes
# offline echo cancellation impossible, since the reference arrives after the
# echo it is supposed to explain.
#
# Re-measure if the mic or output device changes:
#   measure-offset.py <recording>
MIC_DELAY_MS=${MIC_DELAY_MS:-493}

# --- Record: remote on ch0, mic on ch1 ----------------------------------
#   aformat=...channel_layouts=mono = downmix each input to mono so the merge
#       yields exactly 2 channels whether the mic reports mono or stereo
#   adelay = hold the mic back so both channels line up (see above)
#   amerge=inputs=2 = interleave as ch0=remote, ch1=mic (NOT amix, which sums)
ffmpeg -stats -y \
  -f pulse -i "$MONITOR" \
  -f pulse -i "$MIC" \
  -filter_complex "[0:a]aformat=sample_fmts=fltp:channel_layouts=mono[remote];[1:a]aformat=sample_fmts=fltp:channel_layouts=mono,adelay=${MIC_DELAY_MS}:all=1[mic];[remote][mic]amerge=inputs=2[out]" \
  -map "[out]" \
  -c:a aac -b:a 192k \
  -t 03:00:00 \
  "$OUTFILE"

echo -e "\n------------------------------------------------"
echo "Recording saved to: $OUTFILE"
echo "  ch0 (left)  = remote participants"
echo "  ch1 (right) = your mic"
echo "------------------------------------------------"
