# Fix `transcribe` diarization via faster-whisper on ROCm GPU (Path B)

## Context

`transcribe` (→ `/home/dcar/bin/transcribe-transformers.py`) attributes words to the wrong
speaker and produces off turn-timing on the user's many-speaker (~15) meeting recordings.

Root cause is the **merge step**: Whisper runs with *segment-level* timestamps only (word
timestamps were disabled because the transformers backend computes them via CPU-bound DTW,
which stalls for hours). When a whisper segment spans a speaker change, `split_chunk()`
allocates its words to each diarization turn **proportionally by time** — misplacing words
at every boundary and deriving block times from coarse segment timestamps.

**Decision (Path B, chosen by user):** switch ASR to **faster-whisper on the GPU**.
faster-whisper computes `word_timestamps=True` efficiently *inside ctranslate2* (not the
slow transformers DTW), so we get real per-word times **and** faster ASR in one move, then
assign each word to the pyannote diarization turn it actually overlaps. This fixes both
symptoms and likely speeds up transcription (Strix Halo benchmark ≈11.5× realtime).

This is now possible because OpenNMT ships an **official ctranslate2 v4.7.1 ROCm wheel with
gfx1151 kernels** — superseding the old "ctranslate2 is NVIDIA-only" situation in
`[[transcribe-rocm-ctranslate2]]`. Confirmed facts:
- The v4.7.1 ROCm zip contains a **cp313** wheel matching the Python 3.13.14 environments.
- **System ROCm is 7.2.4**, matching the wheel's ROCm 7.2 build target.
- The **system (native) Python already has the rest of the stack**: `torch …+rocm`,
  `pyannote.audio 4.0.4`, `soundfile`, `sklearn`. Only `faster-whisper` + `ctranslate2`
  are missing. The venv has the same stack on `torch 2.12+rocm7.2`.
- Diarization keeps the newer/better `pyannote/speaker-diarization-community-1` model and
  the existing windowed reconciliation. All processing stays local (`[[no-cloud-for-audio]]`).

## Step 1 — Install ctranslate2-rocm + faster-whisper (native first, venv fallback)

User preference: install **natively (system Python) by default; fall back to the venv if
native has issues.** The cp313 ROCm wheel is already downloaded/extracted at
`/tmp/ct2wheel/ctranslate2-4.7.1-cp313-cp313-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl`.

Native install:
```bash
/usr/bin/python3 -m pip install --break-system-packages \
  /tmp/ct2wheel/ctranslate2-4.7.1-*-cp313-*.whl faster-whisper
```
(installs ctranslate2 4.7.1 ROCm + faster-whisper 1.2.1 + av/onnxruntime/tokenizers natively)

**GPU decision gate — must pass before continuing (native), else fall back to venv):**
1. `python3 -c "import ctranslate2; print(ctranslate2.get_cuda_device_count())"` → **≥ 1**
   (currently 0 with the dead PyPI CUDA wheel).
2. Tiny faster-whisper run on a few-second clip with `device="cuda"`, `compute_type="float16"`
   → produces text with no HIP/library errors.
3. `python3 -c "import torch; print(torch.cuda.is_available())"` → **True** (pyannote needs torch).

If any gate fails (e.g. HIP lib mismatch against the native `rocm7.13a` torch build), **fall
back**: install the *same wheel* into `~/.venvs/transcribe` (`torch 2.12+rocm7.2`, closest to
the wheel) and run the script from the venv instead. The venv currently has the dead CUDA
ctranslate2 4.8.0; the ROCm 4.7.1 wheel replaces it (rollback: `pip install ctranslate2==4.8.0`).

Note: ctranslate2 bundles its own HIP kernels but links system `/opt/rocm/lib` (7.2.4, present).
Ensure `/opt/rocm/lib` is on `LD_LIBRARY_PATH` if the import fails to find hipBLAS/rocBLAS.

## Step 2 — New script `/home/dcar/bin/transcribe-faster.py`

Create a **new** file (do not overwrite the working `transcribe-transformers.py` until the new
path is validated). **Reuse, largely verbatim, from `transcribe-transformers.py`:**
`preprocess_audio`, `format_time`, `setup_logging`, **`diarize_windowed`** (the windowed
embedding reconciliation — unchanged), the `--min-turn` smoothing pass, and the output line
format. **Drop** the transformers `pipeline`, `split_chunk`, and proportional-allocation code.

**ASR (new):**
```python
from faster_whisper import WhisperModel
model = WhisperModel(args.model, device="cuda", compute_type="float16")
segments, info = model.transcribe(
    working_file, word_timestamps=True, vad_filter=True,
    beam_size=5, condition_on_previous_text=False,
)
words = [(w.word.strip(), w.start, w.end)
         for seg in segments for w in (seg.words or [])]
```
- `--model` default `large-v3` (allow `large-v3-turbo`); auto-downloads the ct2 model from HF.
- Wrap the `segments` generator in a `tqdm(total=info.duration, unit="s")` progress bar
  (advance by `seg.end - prev_end`) to match the existing progress-bar style.
- Expose `--vad/--no-vad` (default on); the long-form-stability alternative is
  `vad_filter=False, condition_on_previous_text=False`.

**Merge (new — replaces proportional split):** assign each word to its best-overlap turn,
reusing the nearest-turn fallback idea already in `best_speaker`:
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
Walk words in order, assign each its speaker, group consecutive same-speaker words into
`{start, end, speaker, text}` blocks (block start/end = first/last word time), then run the
existing `--min-turn` smoothing. Keep `diarize_windowed` as-is; add optional
`--min-speakers`/`--max-speakers` passthrough to `diar_pipe(...)` per window.

**Env / shebang:** keep `HSA_OVERRIDE_GFX_VERSION=11.5.1` + `TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1`
(as the transformers script does) for the torch/pyannote side — verify in the gate, since the
native torch is a different ROCm build. Shebang `#!/usr/bin/python3` for the native path, or
`#!/home/dcar/.venvs/transcribe/bin/python` for the venv fallback.

## Step 3 — Switch entrypoint after validation

Once the new script passes verification, repoint `transcribe` (currently a symlink →
`transcribe-transformers.py`) to `transcribe-faster.py`. Keep `transcribe-transformers.py`
as the rollback path.

## Critical files

- **new:** `/home/dcar/bin/transcribe-faster.py`
- reuse from `/home/dcar/bin/transcribe-transformers.py` (`diarize_windowed`, helpers, smoothing)
- `/home/dcar/bin/transcribe` symlink (repoint in Step 3)

## Verification

Per `[[transcribe-testing-use-small-clips]]`, test on a **short trimmed multi-speaker clip**,
not a full recording:
1. `ffmpeg -i <recording> -ss <t> -t 180 -ac 1 -ar 16000 /tmp/clip.wav`
2. Run the current `transcribe` on the clip → baseline.
3. Run `transcribe-faster.py` on the same clip.
4. Listening along at a few turn boundaries, confirm: words at speaker changes land on the
   correct `SPEAKER_xx`; short replies ("Yeah", "Right") are attributed correctly; block
   `[start --> end]` times line up with the audio.
5. Time both runs — expect the ASR phase to be **faster** (ctranslate2 GPU) and word
   timestamps to add no CPU stall.

## Rollback

- `transcribe` symlink → `transcribe-transformers.py`.
- (venv path only) `pip install ctranslate2==4.8.0` to restore the prior wheel; harmless
  either way since it was non-functional on GPU.
