# Improve speaker diarization in `transcribe` via GPU forced alignment

## Context

`transcribe` (→ `/home/dcar/bin/transcribe-transformers.py`) produces poor speaker
attribution on the user's recordings (~15 speakers per meeting). The two confirmed
symptoms are **words landing under the wrong speaker** and **turn timing being off**.

The diarization model itself (`pyannote/speaker-diarization-community-1`, windowed +
embedding-reconciled) is not the main problem. The damage happens in the **merge step**:

- Whisper is run with **segment-level** timestamps only (`return_timestamps=True`, not
  `"word"`), because transformers' word-timestamp DTW is CPU-bound and stalls for hours.
- When a whisper segment spans a speaker change, `split_chunk()` (lines 266–294) allocates
  that segment's words to each overlapping diarization turn **proportionally by time**.
  Speech rate and pauses vary, so words near every speaker boundary land on the wrong side,
  short interjections get swallowed, and block start/end times come from coarse whisper
  segment timestamps rather than real word times — exactly the two reported symptoms.

The fix is the standard WhisperX approach, adapted to this AMD/ROCm box: add a **GPU
forced-alignment pass** to recover real per-word timestamps, then assign each word to the
diarization turn it actually overlaps. Verified available in this venv:
`torchaudio 2.11.0+rocm7.2` has `torchaudio.functional.forced_align`, `merge_tokens`, and
the `MMS_FA` bundle (29-token char dict). This avoids faster-whisper/ctranslate2, which is
NVIDIA-only on this box (see `[[transcribe-rocm-ctranslate2]]`).

Intended outcome: words attributed to the correct speaker, accurate turn boundaries, with
only a modest (~10–25%) runtime increase. All processing stays local (`[[no-cloud-for-audio]]`).

## Approach

Replace the proportional word-splitting merge with **forced-aligned word timestamps +
overlap-based speaker assignment**. Keep the existing windowed diarization unchanged.

All changes are in `/home/dcar/bin/transcribe-transformers.py`.

### 1. Load the alignment model (GPU)

Near the existing model loads (after line 190), add the MMS_FA forced aligner:

```python
from torchaudio.pipelines import MMS_FA as ALIGN_BUNDLE
align_model = ALIGN_BUNDLE.get_model().to(torch.device(device))
align_model.eval()
align_dict = ALIGN_BUNDLE.get_dict()   # char -> index, blank '-' = 0
```

wav2vec2 forward runs on the GPU; `forced_align` itself runs on the (small) emission
matrix and is cheap even if it falls back to CPU.

### 2. New function: `align_words(working_file, chunks, model, vocab, device)`

Produces a flat, time-ordered list of `(word, start, end)` in file time. Align
**per whisper chunk** (bounds the search and keeps memory low), looping with a `tqdm`
bar to match the existing progress-bar style (`desc="Aligning", unit="chunk"`).

For each chunk `cs, ce, text`:
1. Read the chunk audio slice with a small pad (e.g. ±0.2s) via `sf.read(start, frames)`
   (reuse the existing soundfile pattern from `diarize_windowed`).
2. Normalize text to the MMS_FA alphabet: lowercase; keep only chars in `align_dict`
   (a–z + apostrophe); split into words. Track each original word and its char-index list.
   Words that normalize to empty (pure numbers/punctuation, e.g. "2024", "$5") are kept
   as **placeholders** with no tokens.
3. Build flattened `targets` (skip placeholder words). If `targets` is empty or the
   emission is shorter than the target length, **fall back** (see §4) for this chunk.
4. `emission, _ = model(waveform.to(device))`; `aligned, scores =
   F.forced_align(emission, targets.unsqueeze(0), blank=0)`;
   `spans = F.merge_tokens(aligned[0], scores[0])`.
5. Convert token-frame spans → per-word `[start,end]` seconds:
   `ratio = waveform.size(1) / emission.size(1)`, `sec = frame * ratio / sample_rate`,
   then add the chunk's (padded) file-time offset. Group spans back into words by the
   per-word token counts from step 2.
6. **Placeholder words** (no tokens) get timing interpolated between their aligned
   neighbors' boundaries, so numbers/symbols still get a sensible position.

Return the concatenated list across all chunks.

### 3. New merge: assign aligned words to diarization turns

Replace the `split_chunk` / proportional logic (lines 254–318) with:

```python
def word_speaker(ws, we):
    best, best_ov, nearest, nearest_gap = None, 0.0, None, None
    for s, e, spk in turns:
        ov = min(we, e) - max(ws, s)
        if ov > best_ov: best, best_ov = spk, ov
        gap = max(s - we, ws - e, 0.0)
        if nearest_gap is None or gap < nearest_gap: nearest, nearest_gap = spk, gap
    return best if best is not None else nearest
```

(Reuse the existing nearest-turn fallback idea already in `best_speaker`.) Then walk the
aligned words in order, assign each its speaker, and group **consecutive same-speaker
words** into blocks whose `start`/`end` are the first/last word times. This yields the
same `final_output` block shape `{start, end, speaker, text}` the rest of the code expects.

### 4. Per-chunk fallback

If alignment fails for a chunk (empty targets, emission too short, or a forced_align
error), fall back to the **existing** `split_chunk` proportional logic for that chunk only,
so the pipeline never regresses below today's behavior. Keep `split_chunk`/`best_speaker`
for this purpose rather than deleting them.

### 5. Keep — and lightly extend — diarization

- Keep `diarize_windowed` and the `--diar-window` / `--speaker-threshold` / `--min-turn`
  knobs as-is; windowing already handles many speakers well.
- Add optional `--min-speakers` / `--max-speakers` (and `--num-speakers`) args, passed
  through to `diar_pipe(..., min_speakers=, max_speakers=)` per window when set. Low effort,
  helps bound clustering on large meetings; defaults to current unconstrained behavior.
- The `--min-turn` smoothing pass (lines 320–345) still operates on the new blocks and
  remains useful for absorbing 1-word mis-splits; keep it.

## Critical files

- `/home/dcar/bin/transcribe-transformers.py` — only file changed:
  - model-load section (~L186–190): add MMS_FA aligner
  - new `align_words(...)` function
  - replace merge (L254–318) with word→turn assignment + fallback
  - argparse (L147–162): add speaker-count passthrough args

## Verification

Per `[[transcribe-testing-use-small-clips]]`, test on a **short trimmed multi-speaker clip**
(2–3 min with ≥3 distinct speakers and quick turn-taking), not a full recording.

1. Create a clip: `ffmpeg -i <recording> -ss <t> -t 180 -ac 1 -ar 16000 /tmp/clip.wav`.
2. Run the **current** script on the clip, save output as baseline.
3. Run the **modified** script on the same clip.
4. Compare, listening along to a few turn boundaries:
   - Words at speaker changes now land under the correct `SPEAKER_xx` (primary check).
   - Short replies ("Yeah", "Right", "Mm-hmm") are attributed to the right person.
   - Block `[start --> end]` times line up with where each turn actually starts/ends.
5. Confirm runtime increase is modest (time both runs; expect ~10–25% over baseline) and
   that the GPU is used for alignment (no multi-minute CPU stall).
6. Sanity-check the fallback: a clip containing numbers/symbols ("call me at 555-1234",
   "Q4 2025") still aligns and places those tokens reasonably.

## Notes / risks

- MMS_FA is multilingual but tuned for romanized text; assumes the meetings are English
  (its dict is a–z + apostrophe). If non-English audio appears, those chunks hit the
  fallback path rather than failing.
- `forced_align` may run on CPU if the ROCm kernel isn't built, but it operates only on the
  small emission matrix, so this does not reintroduce the DTW-style stall.
- No new pip dependency — `torchaudio` (with `forced_align`/`merge_tokens`/`MMS_FA`) and
  `soundfile` are already installed and verified in `/home/dcar/.venvs/transcribe`.
