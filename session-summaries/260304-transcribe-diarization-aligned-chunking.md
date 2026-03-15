# transcribe.py diarization alignment fix (2026-03-04)

## Problem
`transcribe.py` was transcribing fixed-size windows (default 30s) and assigning one speaker label per window based on overlap. When a chunk contained multiple speakers, attribution was often wrong.

## What changed
1. Added diarization-aligned chunk planning:
- New function: `build_transcription_chunks(total_duration, diarization, max_chunk_size)`
- Builds chunk boundaries from diarization segment start/end timestamps.
- Further splits long intervals by `max_chunk_size` so chunks stay manageable.

2. Switched transcription loop from timeline windows to planned chunks:
- Old: iterate across full audio at fixed offsets.
- New: iterate through diarization-aligned chunks and transcribe those.
- Each chunk now carries precomputed `speaker`, `start`, and `end` metadata.

3. Speaker assignment behavior:
- Old: speaker chosen after transcription for each fixed window.
- New: speaker chosen during chunk planning for each diarization-aligned chunk and reused for output.

4. CLI/startup changes:
- `--chunk_size` now means **max** chunk size for diarization-aligned splitting.
- Default changed from `30` to `8` seconds.
- Added validation: `--chunk_size` must be > 0.
- Startup overview text updated to reflect diarization-aligned chunking.

## Why this helps
Speaker attribution is now bounded by diarization turn boundaries instead of arbitrary long windows. Mixed-speaker windows are split, so a single label is much less likely to be applied across multiple people.

## Tradeoff
More chunks can increase runtime modestly (more model calls), but improves diarization-to-text label quality.

## Tuning guidance
- Better speaker precision: `--chunk_size 4`
- Balanced default: `--chunk_size 8`
- Faster but less precise labels: `--chunk_size 12` or `16`

## Verification performed
- Python compile check passed: `python -m py_compile transcribe.py`
- Input validation check passed for invalid chunk size (`--chunk_size 0` exits with error).

## File touched
- `/home/dcar/bin/transcribe.py`
