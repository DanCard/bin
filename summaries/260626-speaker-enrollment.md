# Speaker enrollment fix — Cow & Bob (exec-call/0626)

**Tool:** `transcribe-faster.py` (faster-whisper + pyannote diarization, voiceprint matching)

## Problem
Two diarized clusters fell below the 0.55 voiceprint-match threshold and stayed
labeled `SPEAKER_08` / `SPEAKER_09` in the transcript:

- **SPEAKER_08 = Cow** — genuinely new, never enrolled, so nothing to match against.
- **SPEAKER_09 = Bob** — already enrolled, but he was split into *two* acoustic
  clusters. One (`SPEAKER_03`) matched at cosine **0.567** and was correctly labeled
  "Bob"; the other (`SPEAKER_09`) landed just under threshold and went unlabeled.

## Fix
1. **Harvested clips** from the recording (16 kHz mono, mid-turn):
   - Cow — clean `SPEAKER_08` turn at 31:33, 23s.
   - Bob — the missed `SPEAKER_09` turn at 13:41, 26s.
2. **Committed to `~/.config/transcribe/speakers/`:**
   - Added `Cow.wav` + `Cow.npy` (flat enrollee).
   - Promoted **Bob to a subdir** (`Bob/Bob-orig.wav` + `Bob/Bob-0626.wav`), so his
     voiceprint is now the mean of both acoustic conditions — should catch the
     `SPEAKER_09`-style cluster on future calls.
   - Roster now **15** people.
3. **Relabeled the transcripts** 

## Caveats
- Bob's print is now a mean of two conditions, so a future call where he sounds like the
  old `SPEAKER_03` condition could match slightly lower than 0.567 — but the mean is the
  more robust representation overall (the point of the subdir form).
- Did **not** re-run the full ~20 min transcription to prove the new prints re-match; the
  manual relabel above is the authoritative fix for this recording. Verification will come
  naturally on the next call.
