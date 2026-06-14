#!/home/dcar/.venvs/transcribe/bin/python
import os
import sys

# ROCm 7.2.4 + Strix Halo (gfx1151) Optimization
os.environ["HSA_OVERRIDE_GFX_VERSION"] = "11.5.1"
os.environ["TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL"] = "1"

import time
import math
import argparse
import torch
import json
import logging
import subprocess
import numpy as np
import soundfile as sf
from tqdm import tqdm
from transformers import pipeline
from pyannote.audio import Pipeline as DiarizationPipeline
from sklearn.cluster import AgglomerativeClustering

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

    Returns a sorted list of (start, end, "SPEAKER_xx") turns in file time.
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
    return turns

def main():
    parser = argparse.ArgumentParser(description="Strix Halo Optimized Transformers Transcription")
    parser.add_argument("audio_file", help="Path to audio file")
    parser.add_argument("--model", default="openai/whisper-large-v3-turbo", help="Whisper model ID")
    parser.add_argument("--batch-size", type=int, default=24, help="Batch size for inference")
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
    args = parser.parse_args()

    audio_file = os.path.abspath(args.audio_file)
    output_dir = os.path.abspath(args.output_dir)
    os.makedirs(output_dir, exist_ok=True)

    hf_token = os.environ.get("HF_TOKEN")
    if not hf_token:
        print("Error: HF_TOKEN environment variable required.")
        sys.exit(1)

    setup_logging(audio_file, output_dir)
    device = "cuda:0"
    torch_dtype = torch.float16

    logging.info(f"Loading {args.model} on {device}...")
    pipe = pipeline(
        "automatic-speech-recognition",
        model=args.model,
        dtype=torch_dtype,
        device=device,
        model_kwargs={"attn_implementation": "sdpa"}  # Optimized for ROCm
    )

    logging.info(f"Loading Pyannote Diarization...")
    diarization_pipe = DiarizationPipeline.from_pretrained(
        "pyannote/speaker-diarization-community-1", 
        token=hf_token
    ).to(torch.device(device))

    working_file = preprocess_audio(audio_file, output_dir)
    start_time = time.time()
    
    try:
        # 1. Transcription with segment-level timestamps. Single stitched pass so
        # the pipeline's internal 30s chunking overlap-stitches correctly (no
        # boundary duplication). NOTE: we intentionally do NOT use
        # return_timestamps="word" — transformers computes word timestamps via
        # cross-attention DTW on the CPU, which is pathologically slow (one core
        # pegged, GPU idle) and stalls long files for hours. Segment timestamps
        # run on the GPU; the merge below recovers speaker accuracy via overlap.
        #
        # Progress bar: we tick from inside the pipeline's per-batch _forward
        # rather than chunking the audio ourselves, so stitching is unaffected.
        # chunk_iter steps by chunk_length_s - 2*stride (stride defaults to
        # chunk_length_s/6), i.e. 2/3 of the chunk length, which gives the total.
        logging.info("Starting transcription (this is the long step)...")
        chunk_length_s = 30
        step_s = chunk_length_s * 2 / 3
        info = sf.info(working_file)
        n_chunks = max(1, math.ceil((info.frames / info.samplerate) / step_s))

        _orig_forward = pipe._forward
        bar = tqdm(total=n_chunks, desc="Transcribing", unit="chunk")

        def _forward_with_progress(model_inputs, **kwargs):
            feats = model_inputs.get("input_features")
            bar.update(feats.shape[0] if feats is not None else 1)
            return _orig_forward(model_inputs, **kwargs)

        pipe._forward = _forward_with_progress
        try:
            outputs = pipe(
                working_file,
                chunk_length_s=chunk_length_s,
                batch_size=args.batch_size,
                return_timestamps=True,
            )
        finally:
            bar.close()
            pipe._forward = _orig_forward
        
        # 2. Diarization — windowed, with embeddings reconciled across windows
        # (see diarize_windowed). pyannote reads the WAV via in-memory waveforms
        # internally; here we pass file-time turns to the merge below.
        logging.info(f"Starting windowed diarization ({args.diar_window:g}-min windows)...")
        turns = diarize_windowed(
            diarization_pipe, working_file,
            window_s=args.diar_window * 60,
            distance_threshold=args.speaker_threshold,
        )
        n_spk = len({spk for _, _, spk in turns})
        logging.info(f"Diarization: {n_spk} speakers across {len(turns)} turns")

        # 3. Merge: Whisper can emit very long segments (e.g. a 200s chunk
        # spanning several speakers), so attributing a whole chunk to one
        # speaker collapses dialogue. Instead, split each chunk across the
        # diarization turns it overlaps, allocating the chunk's words to each
        # turn in proportion to that turn's time share. Consecutive
        # same-speaker pieces are then grouped into blocks.
        logging.info("Merging results...")

        def best_speaker(cs, ce):
            best, best_ov = None, 0.0
            nearest, nearest_gap = None, None
            for s, e, spk in turns:
                ov = min(ce, e) - max(cs, s)
                if ov > best_ov:
                    best, best_ov = spk, ov
                gap = max(s - ce, cs - e, 0.0)  # 0 if overlapping
                if nearest_gap is None or gap < nearest_gap:
                    nearest, nearest_gap = spk, gap
            return best if best is not None else nearest

        def split_chunk(cs, ce, words):
            # diarization turns overlapping [cs,ce], clipped, time-ordered,
            # with adjacent same-speaker turns merged
            segs = sorted(
                ((max(cs, s), min(ce, e), spk) for s, e, spk in turns
                 if min(ce, e) > max(cs, s)),
                key=lambda x: x[0],
            )
            merged = []
            for a, b, spk in segs:
                if merged and merged[-1][2] == spk:
                    merged[-1][1] = b
                else:
                    merged.append([a, b, spk])
            if not merged:
                return [(best_speaker(cs, ce), words, cs, ce)]
            n = len(words)
            total = sum(b - a for a, b, _ in merged) or 1.0
            pieces, idx = [], 0
            for i, (a, b, spk) in enumerate(merged):
                take = (n - idx) if i == len(merged) - 1 else round(n * (b - a) / total)
                take = max(0, min(take, n - idx))
                if take:
                    pieces.append((spk, words[idx:idx + take], a, b))
                    idx += take
            if idx < n and pieces:  # rounding leftover -> last piece
                spk0, w0, a0, b0 = pieces[-1]
                pieces[-1] = (spk0, w0 + words[idx:], a0, b0)
            return pieces

        final_output = []
        last_t = 0.0
        for chunk in outputs["chunks"]:
            cs, ce = chunk["timestamp"]
            if cs is None:
                cs = last_t
            if ce is None:
                ce = cs
            last_t = ce
            words = chunk["text"].split()
            if not words:
                continue
            for speaker, piece, ps, pe in split_chunk(cs, ce, words):
                if not piece:
                    continue
                text = " ".join(piece)
                if final_output and final_output[-1]["speaker"] == speaker:
                    final_output[-1]["end"] = pe
                    final_output[-1]["text"] += " " + text
                else:
                    final_output.append(
                        {"start": ps, "end": pe, "speaker": speaker, "text": text}
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