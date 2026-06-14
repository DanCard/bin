# 2026-06-14 — Fix broken `transcribe` (ROCm ctranslate2) + adopt transformers path

## Symptom
`transcribe call-20260614-091850.m4a` failed at model load with:
```
RuntimeError: CUDA failed with error CUDA driver version is insufficient for CUDA runtime version
```
inside `ctranslate2.models.Whisper(...)` (via `faster_whisper.WhisperModel`). User: "Not sure what changed." Box is AMD Strix Halo (gfx1151), ROCm 7.2.4.

## Root cause
The previous day (2026-06-13) a ROCm 7.2.0→7.2.4 venv migration (done by another agent) ran `pip` in `~/.venvs/transcribe` (Python 3.13) and **replaced the ROCm build of `ctranslate2` with the stock PyPI wheel, which is NVIDIA-CUDA-only**.

Evidence gathered:
- `ctranslate2`, `faster_whisper`, `torch` all reinstalled 2026-06-13 12:01–13:33.
- Installed `ctranslate2-4.8.0` wheel tag = `manylinux_2_27/2_28_x86_64` (stock PyPI = NVIDIA build; CTranslate2 has no PyPI ROCm wheel).
- `ctranslate2.get_cuda_device_count()` == **0** in that venv → forcing `device="cuda"` reaches for a non-existent NVIDIA driver → the error.
- PyTorch itself was fine: `torch 2.12.0+rocm7.2`, `torch.cuda.is_available()==True`, 1 device. So GPU/ROCm stack works; only ctranslate2 was wrong.

## Decision
Two viable paths:
- **A (chosen):** transformers/Whisper path — runs on torch+ROCm directly, no ctranslate2. The half-finished `transcribe-v3` script already targeted this.
- **B (deferred):** restore a ROCm ctranslate2 build (OpenNMT v4.7.1 release ships native gfx1151 kernels in `rocm-python-wheels-Linux.zip`; needs a cp313 wheel). Not required for working transcription; the old faster-whisper script would also need the pyannote-4.x fixes below.

User chose: **adopt the transformers path as main, and lock down the env.**

## Fixes applied to the transformers script (now `transcribe-transformers.py`)
Validated by running on the real 25-min call; each fix unblocked the next stage:
1. **`NameError: AudioDecoder`** — pyannote.audio 4.x reads files via `torchcodec` (not installed for this torch build). Fix: preload the 16 kHz WAV with `soundfile` and pass pyannote an in-memory `{"waveform","sample_rate"}` dict (its documented fallback).
2. **`DiarizeOutput has no attribute itertracks`** — pyannote 4.x returns a `DiarizeOutput` wrapper. Fix: iterate `diarization.exclusive_speaker_diarization.itertracks(...)`.
3. **`'<=' NoneType and float`** — Whisper long-form chunks can have a `None` end-timestamp; original merge also dropped any chunk not fully contained in a turn. Fix: rewrote merge to assign each chunk to the speaker active at its midpoint, then group consecutive same-speaker chunks (keeps all text, tolerates `None`).

Result: 25-min call transcribed + diarized (3 speakers) in **~126 s (~12× realtime)** on GPU.

## Restructuring (and a mistake)
- Discovered `transcribe` is a **symlink** (since Mar 8) → `fast-whisper.py`, not a regular file.
- MISTAKE: `cp transcribe-v3 transcribe` followed the symlink and **overwrote `fast-whisper.py`**, destroying its **uncommitted** WIP (the faster_whisper/CTranslate2 refactor that threw the original error). Committed version intact in git; the uncommitted edits are unrecoverable (no swap/backup/blob).
- Remediation:
  - Preserved the working transformers code as **`transcribe-transformers.py`** (compiles clean).
  - `git checkout HEAD -- fast-whisper.py` restored the committed engine (note: committed `fast-whisper.py` actually uses **openai-whisper**, not faster-whisper).
  - Repointed symlink: **`transcribe` → `transcribe-transformers.py`**.
  - Removed the abandoned empty `~/.venvs/transcribe-v3` venv (only had `pip`).

## Lock-down
- `~/bin/transcribe-requirements.txt` — `pip freeze` of the known-good venv with a documented header:
  - torch/torchaudio/torchvision are `+rocm7.2` (ROCm wheel index, NOT PyPI).
  - The active path does not use ctranslate2; **never `pip install ctranslate2` from PyPI** (NVIDIA-only — the original break).
  - Restore / regenerate commands.

## Final state
- `transcribe` → `transcribe-transformers.py` (transformers, `whisper-large-v3-turbo`, pyannote community-1) — **working on GPU**.
- `fast-whisper.py` — committed openai-whisper engine, richer (resume/cache, JSON, word timestamps) but not wired to `transcribe`.
- Not committed to git. `git status`: `M transcribe`, `?? transcribe-transformers.py`, `?? transcribe-requirements.txt` (plus pre-existing dirty `power`, `summarize`, a plans file).

## Open / possible follow-ups
- Commit the above changes.
- Optionally port `fast-whisper.py` features (resume/cache, JSON output, word timestamps) into `transcribe-transformers.py`.
- Path B (ROCm ctranslate2 v4.7.1 cp313 wheel) if the faster-whisper engine is wanted back.
