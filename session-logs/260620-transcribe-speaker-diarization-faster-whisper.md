# 2026-06-20 — Improve `transcribe` speaker diarization (faster-whisper on ROCm)

## Goal
Fix poor speaker diarization in `transcribe` without massively slowing it down. Outcome:
switched ASR to **faster-whisper on the GPU** (ctranslate2 ROCm wheel), giving real per-word
timestamps so words are attributed to the correct speaker; kept pyannote `community-1`
windowed diarization. `transcribe` → `transcribe-faster.py`.

## Prompts (verbatim, in order)

1. `/usage`
2. **"speaker diarization: transcribe is very bad. Can we improve it without massively slowing it down?"**
3. *(AskUserQuestion answers)* Symptom = **"Words on wrong speaker, Boundaries/timing off"**;
   Typical speaker count = **"15"**; Speed budget = **"Add GPU forced-align (Recommended)"**.
4. **"faster-whisper/ctranslate2 doesn't work? Should we try to fix? Copy plan to plans/ dir"**
5. **"Linux Setup (ROCm): Recent versions of ctranslate2 offer wheels built for ROCm. On an
   Ubuntu system with ROCm installed (such as ROCm 7.x), you can download and install the
   official CTranslate2 ROCm wheel and then install faster-whisper. When running your script,
   you still set device=\"cuda\" (as CTranslate2 retains the naming convention even on ROCm)."**
6. *(AskUserQuestion answer)* Path = **"B: faster-whisper ROCm"**.
7. **"Can we install this natively and with venv? Use native as default and switch to venv if
   there is an issue?"**
8. **"write a session log including prompts to session-logs/"**

## Diagnosis
- Root cause of bad diarization was the **merge step**, not pyannote. The transformers backend
  (`transcribe-transformers.py`) ran Whisper with *segment-level* timestamps only (word
  timestamps were disabled — transformers computes them via CPU-DTW, which stalls for hours).
  When a Whisper segment spanned a speaker change, `split_chunk()` allocated words to turns
  **proportionally by time** → words misplaced at every boundary; block times from coarse
  segment timestamps.
- Confirmed symptom on a test clip: old output split one sentence across two speakers
  (*"...going to take"* | *"up a lot of time"*).

## Key turn: ctranslate2 on ROCm (I was initially wrong)
- First claimed faster-whisper was unfixable here: PyPI `ctranslate2 4.8.0` reports
  `get_cuda_device_count()==0` (CUDA-only wheel, no NVIDIA driver on this AMD box).
- User pushed back (prompt 5). Verified: OpenNMT ships an **official ctranslate2 v4.7.1 ROCm
  wheel with gfx1151 kernels**; the release zip contains a **cp313** wheel matching the venv;
  system ROCm is **7.2.4** (matches the wheel's ROCm 7.2 target). My "not fixable" was stale.
- This made **faster-whisper word_timestamps** (computed in ctranslate2 on GPU, no CPU stall)
  the cleaner fix than hand-rolled torchaudio alignment. User chose Path B.

## Install (native-first, venv fallback — per prompt 7)
- **Native FAILED the GPU gate.** Installed wheel + faster-whisper into `~/.local`
  (`--break-system-packages`). `import ctranslate2` → `import torch` →
  `OSError: .../libamdhip64.so.7: undefined symbol: hsa_ext_image_create_v2, version ROCR_1`.
  Native torch bundles its own `rocm_sdk` (ROCm 7.13-alpha) that collides with the system
  ROCm 7.2.4 runtime the wheel loads — two ROCm runtimes can't coexist in one process.
- **Venv WORKED.** Installed the cp313 ROCm wheel into `~/.venvs/transcribe`
  (`torch 2.12.0+rocm7.2`, matches the wheel). Gates:
  - ctranslate2 4.7.1 `get_cuda_device_count() == 1`, supports float16. ✅
  - faster-whisper `large-v3`, `compute_type=float16`, `word_timestamps=True` on a 60s clip:
    **7.5× realtime**, 181 clean per-word timestamps, no HIP errors. ✅
  - `torch.cuda.is_available()` True for pyannote. ✅

## CRITICAL gotcha: import order
- `import ctranslate2` **before** `torch` flips `torch.cuda.is_available()` to **False**
  (ctranslate2's bundled hip/rocBLAS libs clobber torch's ROCm init). Tested:
  - torch alone → True; torch **then** ctranslate2 → both work; ctranslate2 **then** torch → torch False.
- Fix: script imports `torch` + pyannote **before** `faster_whisper`. Env:
  `HSA_OVERRIDE_GFX_VERSION=11.5.1`, `TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1`.

## Punctuation gotcha
- faster-whisper rendered this casual meeting speech **all-lowercase, unpunctuated** (segment
  text itself, not a word-split bug). Not fixed by `condition_on_previous_text`.
- Fixed with a punctuated **`initial_prompt`** (script default:
  *"Hello, everyone. Let's get started with the meeting."*) + leaving
  `condition_on_previous_text=True` (default) so style carries across windows. Repetition
  loops are caught by faster-whisper's temperature fallback + compression-ratio defaults.

## Implementation
- **New `~/bin/transcribe-faster.py`**: faster-whisper ASR → flat `(word, start, end)` list
  (`transcribe_words`, tqdm over `info.duration`); reuses `diarize_windowed` + `preprocess_audio`
  + `format_time` + `setup_logging` + min-turn smoothing from `transcribe-transformers.py`.
  New merge `word_speaker(ws,we)`: assign each word to best-overlap turn (nearest if in a gap),
  group consecutive same-speaker words into blocks with real word-time start/end.
- Args: `--model` (default `large-v3`), `--compute-type`, `--beam-size`, `--vad/--no-vad`,
  `--initial-prompt`, `--diar-window`, `--speaker-threshold`, `--min-turn`.
- **Repointed `transcribe` symlink** → `transcribe-faster.py` (was `transcribe-transformers.py`,
  kept as rollback).

## Before → after (same 120s clip, both detect 2 speakers / 61 turns)
- Old: `"because it's going to take"` [SPK01] / `"up a lot of time um"` [SPK00] — sentence
  split across speakers; first ~30s all-lowercase.
- New: `"Because it's going to take up a lot of time."` [SPK01] — whole, correct speaker,
  punctuated throughout. 120s pipeline ≈ 25 s.

## Validation
- End-to-end on `/home/dcar/tmp/short_test.m4a` (per the "test on short clips" rule). Word-level
  attribution, natural boundaries, block times aligned, punctuation restored. All local.

## State / follow-ups
- **Not committed to git.** Changed: new `transcribe-faster.py`, `transcribe` symlink,
  `plans/speaker-diarization-forced-alignment.md`, memory files.
- Native `~/.local` `ctranslate2`/`faster-whisper` are broken/unused — candidate for cleanup.
- Default `large-v3`; `--model large-v3-turbo` for more speed.
- Rollback: `ln -sfn transcribe-transformers.py ~/bin/transcribe`.
- Memories updated: [[transcribe-rocm-ctranslate2]], [[transcribe-diarization-word-alignment]].
