#!/usr/bin/python3
import os
import sys

# ROCm 7.2.4 + Strix Halo (gfx1151) Optimization
os.environ["HSA_OVERRIDE_GFX_VERSION"] = "11.5.1"
os.environ["TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL"] = "1"

import time
import math
import argparse
import json
import logging
import subprocess
import numpy as np
import soundfile as sf
from tqdm import tqdm

# IMPORT ORDER MATTERS: torch (and pyannote, which uses torch) must be imported
# BEFORE faster_whisper/ctranslate2. The ctranslate2 ROCm wheel loads its own
# bundled hip/rocBLAS libs; if it initializes first it clobbers torch's ROCm
# init and torch.cuda.is_available() flips to False. torch-first → both engines
# share the GPU happily. (Verified empirically on this gfx1151 box.)
import torch
from pyannote.audio import Pipeline as DiarizationPipeline
from sklearn.cluster import AgglomerativeClustering
from faster_whisper import WhisperModel

FILE_TAG = "transcribe"

def setup_logging(audio_file, output_dir="."):
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    base_name = os.path.basename(audio_file)
    log_filename = os.path.join(output_dir, f"{base_name}_{timestamp}.{FILE_TAG}.log")
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        handlers=[logging.FileHandler(log_filename), logging.StreamHandler(sys.stdout)],
        force=True
    )
    return log_filename

def format_time(seconds):
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = seconds % 60
    return f"{hours:02d}:{minutes:02d}:{secs:06.3f}"

def preprocess_audio(input_path, output_dir="."):
    base_name = os.path.basename(input_path)
    output_wav = os.path.join(output_dir, f"{base_name}.{FILE_TAG}.tmp.wav")
    logging.info(f"Preprocessing audio to 16kHz mono WAV: {output_wav}")

    cmd = [
        "ffmpeg", "-y", "-i", input_path,
        "-ar", "16000", "-ac", "1",
        output_wav
    ]
    try:
        subprocess.run(cmd, check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        logging.error(f"FFmpeg conversion failed: {e.stderr.decode()}")
        sys.exit(1)
    return output_wav

def diarize_windowed(diar_pipe, working_file, window_s, distance_threshold):
    """Diarize a long recording in fixed-size windows, then reconcile speaker
    labels across windows by clustering per-window speaker embeddings (cosine).

    Why: pyannote's whole-file clustering over-merges nearby/similar voices on
    long, many-speaker recordings (e.g. on a 2.3h call it collapsed three
    distinct speakers into one). Diarizing in windows (~30 min) keeps local
    accuracy; clustering the per-window speaker embeddings keeps the same person
    under one global SPEAKER_xx label across windows.

    Returns (turns, centroids):
      - turns: sorted list of (start, end, "SPEAKER_xx") in file time.
      - centroids: {"SPEAKER_xx": unit-norm mean embedding} for speaker enrollment.
    """
    info = sf.info(working_file)
    sr = info.samplerate
    win_frames = int(window_s * sr)
    n_windows = max(1, math.ceil(info.frames / win_frames))

    node_emb = []        # per-window speaker embeddings
    node_key = []        # parallel list of (win_idx, local_label)
    window_turns = []    # (win_idx, local_label, global_start, global_end)

    for w in tqdm(range(n_windows), desc="Diarizing", unit="win"):
        f0 = w * win_frames
        wav, _ = sf.read(working_file, start=f0, frames=win_frames,
                         dtype="float32", always_2d=True)
        if wav.shape[0] == 0:
            continue
        offset = f0 / sr
        out = diar_pipe({
            "waveform": torch.from_numpy(wav.T).contiguous(),
            "sample_rate": sr,
        })
        emb = out.speaker_embeddings  # (num_speakers, dim), in speaker_diarization.labels() order
        local_emb = {}
        if emb is not None:
            for i, lab in enumerate(out.speaker_diarization.labels()):
                if i < len(emb):
                    local_emb[lab] = emb[i]
        for seg, _, lab in out.exclusive_speaker_diarization.itertracks(yield_label=True):
            window_turns.append((w, lab, seg.start + offset, seg.end + offset))
        for lab, e in local_emb.items():
            node_emb.append(e)
            node_key.append((w, lab))

    # Map each (window, local label) to a consistent global speaker id by
    # clustering the embeddings (cosine, agglomerative). Two constraints:
    #  - Short/empty segments yield degenerate (NaN/zero-norm) embeddings that
    #    break cosine clustering — exclude them and give them fallback ids.
    #  - Speakers from the SAME window must never merge: pyannote already ruled
    #    them distinct, so we forbid it via a large precomputed distance (else a
    #    fixed threshold can re-collapse speakers pyannote correctly separated).
    keymap = {}
    valid = [i for i, e in enumerate(node_emb)
             if np.all(np.isfinite(e)) and np.linalg.norm(e) > 1e-6]
    valid_set = set(valid)
    next_id = 0
    if len(valid) == 1:
        keymap[node_key[valid[0]]] = 0
        next_id = 1
    elif len(valid) > 1:
        X = np.vstack([node_emb[i] for i in valid]).astype("float64")
        X /= np.linalg.norm(X, axis=1, keepdims=True)
        D = np.clip(1.0 - X @ X.T, 0.0, 2.0)  # cosine distance matrix
        np.fill_diagonal(D, 0.0)
        wins = [node_key[i][0] for i in valid]
        for a in range(len(valid)):       # cannot-link same-window speakers
            for b in range(a + 1, len(valid)):
                if wins[a] == wins[b]:
                    D[a, b] = D[b, a] = 1e6
        gids = AgglomerativeClustering(
            n_clusters=None, metric="precomputed", linkage="average",
            distance_threshold=distance_threshold,
        ).fit_predict(D)
        for i, g in zip(valid, gids):
            keymap[node_key[i]] = int(g)
        next_id = max(int(g) for g in gids) + 1
    for key in node_key:  # degenerate-embedding speakers -> unique fallback ids
        if key not in keymap:
            keymap[key] = next_id
            next_id += 1

    turns = [
        (s, e, f"SPEAKER_{keymap.get((w, lab), 0):02d}")
        for (w, lab, s, e) in window_turns
    ]
    turns.sort()

    # Per-global-speaker centroid (unit-norm mean of its member embeddings) so a
    # speaker can be matched against enrolled reference voiceprints by cosine.
    grouped = {}
    for i, key in enumerate(node_key):
        if i not in valid_set:
            continue
        v = node_emb[i] / np.linalg.norm(node_emb[i])
        grouped.setdefault(keymap[key], []).append(v)
    centroids = {}
    for gid, vecs in grouped.items():
        m = np.mean(np.vstack(vecs), axis=0)
        n = np.linalg.norm(m)
        if n > 1e-6:
            centroids[f"SPEAKER_{gid:02d}"] = m / n
    return turns, centroids

def transcribe_words(model, working_file, args):
    """Run faster-whisper with native (GPU, ctranslate2) word timestamps and
    return a flat, time-ordered list of (word, start, end) in file time.

    Unlike the transformers backend, faster-whisper computes word_timestamps
    inside ctranslate2 on the GPU — fast, no CPU-DTW stall — so we can attribute
    speakers per word instead of splitting whisper segments proportionally."""
    info = sf.info(working_file)
    duration = info.frames / info.samplerate
    # condition_on_previous_text=True (faster-whisper default) carries
    # capitalization/punctuation style forward across windows; combined with a
    # punctuated initial_prompt it keeps the whole transcript readable (Whisper
    # otherwise renders this casual speech all-lowercase, unpunctuated). Repeat
    # loops are caught by faster-whisper's temperature fallback +
    # compression_ratio_threshold defaults.
    segments, tinfo = model.transcribe(
        working_file,
        word_timestamps=True,
        vad_filter=args.vad,
        beam_size=args.beam_size,
        initial_prompt=args.initial_prompt,
    )
    logging.info(f"Detected language: {tinfo.language} (p={tinfo.language_probability:.2f})")

    words = []
    last = 0.0
    bar = tqdm(total=round(duration), desc="Transcribing", unit="s")
    for seg in segments:               # generator: iterating drives decoding
        for w in (seg.words or []):
            t = w.word.strip()
            if t:
                words.append((t, w.start, w.end))
        if seg.end and seg.end > last:
            bar.update(round(seg.end - last))
            last = seg.end
    bar.close()
    return words

def snap_boundaries(turns, words, window, min_gap=0.15):
    """Move each speaker-change boundary to the largest inter-word silence within
    +/- `window` seconds of it. Speaker changes happen at pauses, and word
    timestamps are exact, so this corrects boundary words attributed to the wrong
    speaker (e.g. from VAD remap drift between the whisper and pyannote timelines)
    even when the drift spans several words. Pure post-processing on existing
    arrays -- no effect on transcription speed."""
    if window <= 0 or len(turns) < 2 or len(words) < 2:
        return turns
    gaps = []
    for i in range(len(words) - 1):
        cur_end, nxt_start = words[i][2], words[i + 1][1]
        g = nxt_start - cur_end
        if g > min_gap:
            gaps.append(((cur_end + nxt_start) / 2.0, g))
    if not gaps:
        return turns
    t = [list(x) for x in turns]
    for i in range(len(t) - 1):
        if t[i][2] == t[i + 1][2]:
            continue
        b = (t[i][1] + t[i + 1][0]) / 2.0
        lo = max(b - window, t[i][0] + 1e-3)
        hi = min(b + window, t[i + 1][1] - 1e-3)
        best, best_g = None, 0.0
        for c, g in gaps:
            if lo <= c <= hi and g > best_g:
                best, best_g = c, g
        if best is not None:
            t[i][1] = best
            t[i + 1][0] = best
    return [tuple(x) for x in t]

AUDIO_EXTS = {".wav", ".mp3", ".m4a", ".flac", ".ogg", ".oga", ".aac", ".mp4", ".webm", ".opus"}

def embed_clip(diar_pipe, wav_path):
    """Run pyannote on a (16 kHz mono) clip and return the unit-norm embedding of
    its dominant speaker, in the same space as diarize_windowed's embeddings."""
    wav, sr = sf.read(wav_path, dtype="float32", always_2d=True)
    if wav.shape[0] == 0:
        return None
    out = diar_pipe({"waveform": torch.from_numpy(wav.T).contiguous(), "sample_rate": sr})
    emb = out.speaker_embeddings
    if emb is None:
        return None
    labels = out.speaker_diarization.labels()
    durations = {}
    for seg, _, lab in out.speaker_diarization.itertracks(yield_label=True):
        durations[lab] = durations.get(lab, 0.0) + (seg.end - seg.start)
    if not durations:
        return None
    dom = max(durations, key=durations.get)
    idx = labels.index(dom)
    if idx >= len(emb):
        return None
    e = emb[idx]
    n = np.linalg.norm(e)
    if not np.all(np.isfinite(e)) or n < 1e-6:
        return None
    return e / n

def load_enrollment(diar_pipe, speakers_dir, output_dir, rebuild=False):
    """Load (or build) cached voiceprints from a directory of reference clips.
    Returns {name: unit-norm embedding}. Cache lives next to each clip as
    <name>.npy."""
    refs = {}
    if not os.path.isdir(speakers_dir):
        logging.error(f"--speakers dir not found: {speakers_dir}")
        return refs
    for fn in sorted(os.listdir(speakers_dir)):
        stem, ext = os.path.splitext(fn)
        if ext.lower() not in AUDIO_EXTS:
            continue
        path = os.path.join(speakers_dir, fn)
        npy = os.path.join(speakers_dir, stem + ".npy")
        if not rebuild and os.path.exists(npy):
            refs[stem] = np.load(npy)
            continue
        wav = preprocess_audio(path, output_dir)
        try:
            e = embed_clip(diar_pipe, wav)
        finally:
            if os.path.exists(wav):
                os.remove(wav)
        if e is None:
            logging.warning(f"Enrollment: no usable embedding for {fn}, skipping")
            continue
        np.save(npy, e)
        refs[stem] = e
        logging.info(f"Enrolled '{stem}'")
    return refs

def match_speakers(centroids, refs, threshold):
    """Greedy one-to-one cosine matching of diarized speakers to enrolled names.
    Returns {SPEAKER_xx: name} for matches at or above `threshold`."""
    if not refs or not centroids:
        return {}
    sims = []
    for spk, c in centroids.items():
        for name, r in refs.items():
            sims.append((float(np.dot(c, r)), spk, name))
    sims.sort(reverse=True)
    mapping, used_spk, used_name = {}, set(), set()
    for sim, spk, name in sims:
        if sim < threshold:
            break
        if spk in used_spk or name in used_name:
            continue
        mapping[spk] = name
        used_spk.add(spk)
        used_name.add(name)
        logging.info(f"Matched {spk} -> '{name}' (cosine {sim:.3f})")
    return mapping

def main():
    parser = argparse.ArgumentParser(description="Strix Halo faster-whisper transcription + diarization")
    parser.add_argument("audio_file", nargs="?",
                        help="Path to audio file (optional when only (re)building "
                             "voiceprints with --enroll)")
    parser.add_argument("--model", default="large-v3",
                        help="faster-whisper model (e.g. large-v3, large-v3-turbo)")
    parser.add_argument("--compute-type", default="float16", help="ctranslate2 compute type")
    parser.add_argument("--beam-size", type=int, default=5, help="Whisper beam size")
    parser.add_argument("--initial-prompt",
                        default="Hello, everyone. Let's get started with the meeting.",
                        help="Punctuated priming text that biases Whisper toward proper "
                             "capitalization/punctuation (it otherwise renders casual speech "
                             "all-lowercase). Set empty to disable.")
    parser.add_argument("--vad", dest="vad", action="store_true", default=True,
                        help="Enable VAD filtering (default on)")
    parser.add_argument("--no-vad", dest="vad", action="store_false",
                        help="Disable VAD filtering (more stable on noisy long-form)")
    parser.add_argument("--output-dir", default=".", help="Output directory")
    parser.add_argument("--diar-window", type=float, default=30,
                        help="Diarization window size in minutes (default 30). Smaller separates "
                             "speakers better on long files; whole-file over-merges similar voices.")
    parser.add_argument("--speaker-threshold", type=float, default=0.5,
                        help="Cosine-distance threshold for merging per-window speakers into one "
                             "identity across windows (lower = more distinct speakers).")
    parser.add_argument("--min-turn", type=float, default=1.0,
                        help="Absorb speaker blocks shorter than this many seconds into a neighbor "
                             "(removes mis-split 1-word fragments). 0 disables.")
    parser.add_argument("--boundary-snap", type=float, default=1.5,
                        help="Snap each speaker-change boundary to the largest inter-word silence "
                             "within +/- this many seconds (fixes boundary words attributed to the "
                             "wrong speaker, e.g. from VAD timestamp drift). 0 disables.")
    parser.add_argument("--speakers", default="~/.config/transcribe/speakers",
                        help="Directory of known-speaker reference clips (one audio file per "
                             "person, named <Name>.<ext>). Matched speakers are labeled by name "
                             "instead of SPEAKER_xx; embeddings are cached as <Name>.npy. Defaults "
                             "to ~/.config/transcribe/speakers (used automatically if it exists).")
    parser.add_argument("--enroll", action="store_true",
                        help="(Re)build the cached voiceprint for every clip in --speakers. With no "
                             "audio_file, just builds the cache and exits.")
    parser.add_argument("--enroll-threshold", type=float, default=0.5,
                        help="Minimum cosine similarity to label a diarized speaker with an enrolled "
                             "name (higher = stricter; unmatched speakers stay SPEAKER_xx).")
    parser.add_argument("--diar-only", action="store_true",
                        help="Skip transcription; run only diarization and print a per-speaker "
                             "talk-time summary. For quickly sweeping --speaker-threshold / "
                             "--diar-window without paying for transcription.")
    args = parser.parse_args()

    enroll_only = args.enroll and not args.audio_file
    if not args.audio_file and not args.enroll:
        print("Error: audio_file is required (or use --enroll to only build voiceprints).")
        sys.exit(1)

    output_dir = os.path.abspath(args.output_dir)
    os.makedirs(output_dir, exist_ok=True)

    hf_token = os.environ.get("HF_TOKEN")
    if not hf_token:
        print("Error: HF_TOKEN environment variable required.")
        sys.exit(1)

    setup_logging(args.audio_file or "enroll", output_dir)
    if not torch.cuda.is_available():
        logging.error("torch.cuda is not available — pyannote diarization needs the GPU.")
        sys.exit(1)
    device = "cuda:0"

    # faster-whisper is only needed when we actually transcribe.
    model = None
    if not enroll_only and not args.diar_only:
        logging.info(f"Loading faster-whisper {args.model} (ctranslate2 ROCm, {args.compute_type})...")
        model = WhisperModel(args.model, device="cuda", compute_type=args.compute_type)

    logging.info("Loading Pyannote Diarization...")
    diarization_pipe = DiarizationPipeline.from_pretrained(
        "pyannote/speaker-diarization-community-1",
        token=hf_token
    ).to(torch.device(device))

    # Known-speaker voiceprints (load cache, or rebuild with --enroll).
    refs = {}
    speakers_dir = os.path.abspath(os.path.expanduser(args.speakers)) if args.speakers else None
    if speakers_dir and os.path.isdir(speakers_dir):
        refs = load_enrollment(diarization_pipe, speakers_dir, output_dir, rebuild=args.enroll)
        logging.info(f"Loaded {len(refs)} enrolled speaker(s): {', '.join(sorted(refs)) or '(none)'}")
    elif args.enroll:
        logging.error(f"--enroll requested but speakers dir not found: {speakers_dir}")
        sys.exit(1)
    if enroll_only:
        logging.info("Enrollment complete (no audio_file given).")
        return

    audio_file = os.path.abspath(args.audio_file)
    working_file = preprocess_audio(audio_file, output_dir)
    start_time = time.time()

    try:
        # 1. Transcription — faster-whisper with native GPU word timestamps.
        words = []
        if not args.diar_only:
            logging.info("Starting transcription (this is the long step)...")
            words = transcribe_words(model, working_file, args)
            logging.info(f"Transcription: {len(words)} words")

        # 2. Diarization — windowed, embeddings reconciled across windows.
        logging.info(f"Starting windowed diarization ({args.diar_window:g}-min windows)...")
        turns, centroids = diarize_windowed(
            diarization_pipe, working_file,
            window_s=args.diar_window * 60,
            distance_threshold=args.speaker_threshold,
        )
        n_spk = len({spk for _, _, spk in turns})
        logging.info(f"Diarization: {n_spk} speakers across {len(turns)} turns")

        # 2b. Speaker enrollment — rename matched SPEAKER_xx to known names.
        mapping = match_speakers(centroids, refs, args.enroll_threshold)
        if mapping:
            turns = [(s, e, mapping.get(spk, spk)) for s, e, spk in turns]

        # --diar-only: print a per-speaker talk-time summary and stop (for tuning
        # --speaker-threshold / --diar-window without paying for transcription).
        if args.diar_only:
            totals = {}
            for s, e, spk in turns:
                totals[spk] = totals.get(spk, 0.0) + (e - s)
            logging.info("Per-speaker talk time:")
            for spk in sorted(totals, key=totals.get, reverse=True):
                logging.info(f"  {spk}: {format_time(totals[spk])} "
                             f"({totals[spk]:.1f}s) across "
                             f"{sum(1 for _, _, s in turns if s == spk)} turns")
            return

        # 2c. Boundary snapping — move speaker changes to the nearest real pause
        # so boundary words land on the right speaker (corrects timeline drift).
        if args.boundary_snap > 0:
            turns = snap_boundaries(turns, words, args.boundary_snap)

        # 3. Merge — assign each word to the speaker active at its midpoint
        # (more stable at edges than total overlap; nearest turn if it falls in a
        # gap), then group consecutive same-speaker words into blocks.
        logging.info("Merging results...")

        def word_speaker(ws, we):
            mid = (ws + we) / 2.0
            mid_spk = None
            best, best_ov = None, 0.0
            nearest, nearest_gap = None, None
            for s, e, spk in turns:
                if s <= mid < e:
                    mid_spk = spk
                ov = min(we, e) - max(ws, s)
                if ov > best_ov:
                    best, best_ov = spk, ov
                gap = max(s - we, ws - e, 0.0)  # 0 if overlapping
                if nearest_gap is None or gap < nearest_gap:
                    nearest, nearest_gap = spk, gap
            if mid_spk is not None:
                return mid_spk
            return best if best is not None else nearest

        final_output = []
        for text, ws, we in words:
            spk = word_speaker(ws, we) or "SPEAKER_00"
            if final_output and final_output[-1]["speaker"] == spk:
                final_output[-1]["end"] = we
                final_output[-1]["text"] += " " + text
            else:
                final_output.append(
                    {"start": ws, "end": we, "speaker": spk, "text": text}
                )

        # 3b. Smoothing: absorb ultra-short blocks (mis-split fragments, e.g. a
        # single word grabbed by a brief overlapping turn) into a neighbor —
        # bridging when both neighbors are the same speaker — then regroup.
        if args.min_turn > 0 and final_output:
            for i, b in enumerate(final_output):
                if (b["end"] - b["start"]) >= args.min_turn:
                    continue
                prev = final_output[i - 1] if i > 0 else None
                nxt = final_output[i + 1] if i + 1 < len(final_output) else None
                if prev and nxt and prev["speaker"] == nxt["speaker"]:
                    b["speaker"] = prev["speaker"]
                elif prev and nxt:
                    longer = prev if (prev["end"] - prev["start"]) >= (nxt["end"] - nxt["start"]) else nxt
                    b["speaker"] = longer["speaker"]
                elif prev:
                    b["speaker"] = prev["speaker"]
                elif nxt:
                    b["speaker"] = nxt["speaker"]
            regrouped = []
            for b in final_output:
                if regrouped and regrouped[-1]["speaker"] == b["speaker"]:
                    regrouped[-1]["end"] = b["end"]
                    regrouped[-1]["text"] += " " + b["text"]
                else:
                    regrouped.append(b)
            final_output = regrouped

        # 4. Save
        base_name = os.path.basename(audio_file)
        output_txt = os.path.join(output_dir, f"{base_name}.txt")
        with open(output_txt, "w") as f:
            for item in final_output:
                line = f"[{format_time(item['start'])} --> {format_time(item['end'])}] {item['speaker']}: {item['text']}"
                f.write(line + "\n")
                print(line)

        logging.info(f"Done! Total time: {time.time() - start_time:.2f}s")
    finally:
        if os.path.exists(working_file):
            os.remove(working_file)

if __name__ == "__main__":
    main()
