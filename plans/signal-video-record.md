# Plan: Combined Audio+Video Signal Recording Script

## Context
User has `signal-record.sh` (audio-only, Signal-isolated) and `record-call.sh` (audio-only, general). Wants a combined audio+video recording script. Video may not always be used, so very low framerate to minimize resources/disk. System: X11, Debian 13, ffmpeg 8.0 with `-window_id` support.

## Approach
Create `signal-record-video.sh` in `~/bin` that:

1. **Finds Signal window** via `xdotool search --name "Signal"` → get window ID
2. **Captures video** with `ffmpeg -f x11grab -window_id <id>` — this tracks the window through moves/resizes
3. **Captures audio** using the same PulseAudio isolation approach from `signal-record.sh` (virtual sink for Signal audio + echo-cancelled mic)
4. **Single ffmpeg command** combining x11grab video + pulse audio into one MP4 file
5. **Very low framerate**: 1 fps (default, configurable via variable)
6. **Video codec**: `libx264 -crf 28 -preset ultrafast` — prioritizes low CPU over compression efficiency
7. **Audio codec**: AAC 128kbps stereo (same as existing scripts)
8. **Output**: `signal-video-TIMESTAMP.mp4`

### Reuse from signal-record.sh
- PulseAudio device names (speaker, mic)
- Virtual sink creation + Signal stream isolation
- Echo cancellation module loading
- Cleanup/restore logic on EXIT trap
- Self-test approach (optional, can skip for v1)

### Minimized window behavior
- When minimized, x11grab with `-window_id` will capture blank/frozen frames
- Script will note this in usage info — not a solvable problem at the x11grab level

## Files
- **Create**: `~/bin/signal-record-video.sh`
- **Reference**: `~/bin/signal-record.sh` (reuse audio isolation patterns)

## Verification
1. Open Signal Desktop, run `signal-record-video.sh`
2. Verify video captures Signal window content at low framerate
3. Verify audio has both remote + mic channels
4. Move/resize Signal window during recording, confirm video follows
5. Stop with Ctrl+C, verify clean MP4 output playable in `mpv`/`vlc`
