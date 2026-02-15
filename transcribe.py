#!/usr/bin/env python3
"""
Voxtral 24B Transcription - Benchmark & Pipeline
Hardware: AMD Strix Halo (gfx1151) / ROCm 7.11
Firmware: linux-firmware 20260110
"""

import os
import sys
import time
import json
import argparse
import subprocess
import logging

# PyTorch bundles HIP/MIOpen for ROCm 7.1. Since ROCm 7.1 was removed and only
# 7.11 remains, we LD_PRELOAD the system libraries so PyTorch uses the correct
# HIP runtime with native gfx1151 support. Self-re-exec to apply before torch loads.
_ROCM711_LIB = "/opt/rocm/core-7.11/lib"
_PRELOAD_LIBS = f"{_ROCM711_LIB}/libamdhip64.so {_ROCM711_LIB}/libMIOpen.so.1.0"
if os.path.exists(_ROCM711_LIB) and _PRELOAD_LIBS not in os.environ.get("LD_PRELOAD", ""):
    os.environ["LD_PRELOAD"] = _PRELOAD_LIBS
    os.environ["LD_LIBRARY_PATH"] = _ROCM711_LIB + ":" + os.environ.get("LD_LIBRARY_PATH", "")
    os.environ["MIOPEN_SYSTEM_DB_PATH"] = f"{_ROCM711_LIB}/../share/miopen/db"
    os.execvp(sys.executable, [sys.executable] + sys.argv)

os.environ["HSA_OVERRIDE_GFX_VERSION"] = "11.5.1"
os.environ["TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL"] = "1"

import torch
from transformers import AutoProcessor, VoxtralForConditionalGeneration, TextStreamer

MODELS = {
    "mini": "mistralai/Voxtral-Mini-3B-2507",
    "24b": "mistralai/Voxtral-Small-24B-2507",
}
MODEL_ID = MODELS["mini"]  # default to mini
CACHE_DIR = os.path.expanduser("~/llms/mistral/")
CHUNK_SECONDS = 300  # 5 min chunks
OVERLAP_SECONDS = 30
MIN_CHUNK_SECONDS = 30  # skip chunks shorter than this to avoid hallucination

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("voxtral")


def format_time(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = seconds % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"


def preprocess_audio(input_path, output_dir):
    """Convert to 16kHz mono WAV for consistent processing."""
    out = os.path.join(output_dir, os.path.basename(input_path) + ".tmp.wav")
    if os.path.exists(out):
        log.info(f"Reusing existing WAV: {out}")
        return out
    log.info(f"Converting to 16kHz mono WAV...")
    subprocess.run(
        ["ffmpeg", "-y", "-i", input_path, "-ar", "16000", "-ac", "1", out],
        check=True, capture_output=True,
    )
    return out


def load_model():
    log.info(f"Loading {MODEL_ID} on {torch.cuda.get_device_name(0)}...")
    log.info(f"GPU memory: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB")

    t0 = time.time()
    processor = AutoProcessor.from_pretrained(MODEL_ID, cache_dir=CACHE_DIR)
    model = VoxtralForConditionalGeneration.from_pretrained(
        MODEL_ID,
        torch_dtype=torch.bfloat16,
        device_map={"": 0},
        cache_dir=CACHE_DIR,
        attn_implementation="sdpa",
    )
    model.eval()
    log.info(f"Model loaded in {time.time() - t0:.1f}s")
    return model, processor


def transcribe_chunk(model, processor, audio_path, stream=False):
    """Transcribe a single audio chunk via Voxtral chat template."""
    conversation = [
        {
            "role": "user",
            "content": [
                {"type": "audio", "path": audio_path},
                {"type": "text", "text": "Transcribe this audio."},
            ],
        }
    ]

    inputs = processor.apply_chat_template(
        conversation,
        tokenize=True,
        return_dict=True,
        return_tensors="pt",
    ).to(model.device)

    streamer = TextStreamer(processor.tokenizer, skip_special_tokens=True) if stream else None

    with torch.inference_mode():
        outputs = model.generate(
            **inputs,
            max_new_tokens=4096,
            do_sample=False,
            streamer=streamer,
        )

    input_len = inputs["input_ids"].shape[1]
    text = processor.decode(outputs[0][input_len:], skip_special_tokens=True)
    return text.strip()


def get_audio_duration(path):
    """Get duration in seconds via ffprobe."""
    result = subprocess.run(
        ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", path],
        capture_output=True, text=True,
    )
    return float(result.stdout.strip())


def parse_voxtral_timestamps(text, chunk_start):
    """Parse Voxtral's inline timestamps and convert to absolute times.

    Voxtral outputs timestamps like:
      [ 0m1s310ms - 0m5s300ms ] Some text here.
    Returns list of {"start": abs_s, "end": abs_s, "text": str}.
    If no timestamps found, returns the whole text as one segment.
    """
    import re
    pattern = r'\[\s*(\d+)m(\d+)s(\d+)ms\s*-\s*(\d+)m(\d+)s(\d+)ms\s*\]\s*(.*?)(?=\[\s*\d+m|\Z)'
    matches = re.findall(pattern, text, re.DOTALL)

    if not matches:
        # No timestamps - return whole text as one segment spanning the chunk
        return [{"start": chunk_start, "end": chunk_start, "text": text.strip()}]

    segments = []
    for m in matches:
        s = chunk_start + int(m[0]) * 60 + int(m[1]) + int(m[2]) / 1000
        e = chunk_start + int(m[3]) * 60 + int(m[4]) + int(m[5]) / 1000
        t = m[6].strip()
        if t:
            segments.append({"start": s, "end": e, "text": t})
    return segments


def merge_transcript_diarization(transcripts, diarization, Segment):
    """Merge Voxtral chunk transcripts with pyannote diarization.

    For each text segment, find the diarization speaker with max overlap.
    """
    # Parse all chunks into segments with absolute timestamps
    all_segments = []
    for chunk in transcripts:
        parsed = parse_voxtral_timestamps(chunk["text"], chunk["start"])
        for seg in parsed:
            # For segments without end time, estimate from text length
            if seg["end"] <= seg["start"]:
                seg["end"] = chunk["end"]
            all_segments.append(seg)

    # Assign speakers from diarization
    merged = []
    for seg in all_segments:
        text_seg = Segment(seg["start"], seg["end"])
        speakers = []
        for turn, _, speaker in diarization.itertracks(yield_label=True):
            overlap = text_seg & turn
            if overlap:
                speakers.append((speaker, overlap.duration))

        if speakers:
            best_speaker = max(speakers, key=lambda x: x[1])[0]
        else:
            best_speaker = "Unknown"

        merged.append({
            "start": seg["start"],
            "end": seg["end"],
            "speaker": best_speaker,
            "text": seg["text"],
        })

    return merged


def run_benchmark(args):
    """Quick benchmark on a single file - no chunking, no diarization."""
    model, processor = load_model()

    wav_path = preprocess_audio(args.audio, args.output)
    duration = get_audio_duration(wav_path)
    log.info(f"Audio duration: {duration:.1f}s")

    log.info("Starting transcription...")
    t0 = time.time()
    text = transcribe_chunk(model, processor, wav_path, stream=True)
    elapsed = time.time() - t0

    rtf = elapsed / duration
    print(f"\n{'='*50}")
    print(f"  BENCHMARK RESULT")
    print(f"{'='*50}")
    print(f"  Audio duration : {duration:.1f}s")
    print(f"  Transcription  : {elapsed:.1f}s")
    print(f"  RTF            : {rtf:.2f}x  ({'faster' if rtf < 1 else 'slower'} than real-time)")
    print(f"{'='*50}\n")

    print("--- TRANSCRIPT ---")
    print(text)
    print("--- END ---\n")

    out_file = os.path.join(args.output, os.path.basename(args.audio) + ".benchmark.txt")
    with open(out_file, "w") as f:
        f.write(f"RTF: {rtf:.2f}x | Audio: {duration:.1f}s | Transcription: {elapsed:.1f}s\n\n")
        f.write(text + "\n")
    log.info(f"Saved to {out_file}")


def run_full(args):
    """Full pipeline: chunk + transcribe + diarize + merge."""
    from pyannote.audio import Pipeline as DiarPipeline
    from pyannote.core import Segment
    from pydub import AudioSegment

    model, processor = load_model()
    wav_path = preprocess_audio(args.audio, args.output)
    duration = get_audio_duration(wav_path)
    log.info(f"Audio duration: {format_time(duration)}")

    # --- Diarization ---
    hf_token = args.hf_token or os.environ.get("HF_TOKEN")
    diar_cache = wav_path + ".diarize.json"

    t0 = time.time()
    if os.path.exists(diar_cache):
        log.info("Loading cached diarization...")
        from pyannote.core import Annotation
        annotation = Annotation()
        with open(diar_cache) as f:
            for item in json.load(f):
                annotation[Segment(item["start"], item["end"])] = item["speaker"]
        diarization = annotation
    else:
        log.info("Running diarization...")
        pipeline = DiarPipeline.from_pretrained("pyannote/speaker-diarization-3.1")
        pipeline.to(torch.device("cuda"))
        result = pipeline(wav_path)
        diarization = result.speaker_diarization if hasattr(result, "speaker_diarization") else result

        cache_data = []
        for turn, _, speaker in diarization.itertracks(yield_label=True):
            cache_data.append({"start": turn.start, "end": turn.end, "speaker": speaker})
        with open(diar_cache, "w") as f:
            json.dump(cache_data, f, indent=2)

    time_diar = time.time() - t0
    log.info(f"Diarization: {time_diar:.1f}s")

    # Unload diarization model to free GPU memory for Voxtral
    if 'pipeline' in dir():
        del pipeline
        torch.cuda.empty_cache()

    # --- Chunked Transcription ---
    t0 = time.time()
    audio = AudioSegment.from_file(wav_path)
    chunk_ms = CHUNK_SECONDS * 1000
    overlap_ms = OVERLAP_SECONDS * 1000
    transcripts = []

    for i, start_ms in enumerate(range(0, len(audio), chunk_ms - overlap_ms)):
        end_ms = min(start_ms + chunk_ms, len(audio))
        chunk_duration_s = (end_ms - start_ms) / 1000
        if chunk_duration_s < MIN_CHUNK_SECONDS:
            log.info(f"Skipping chunk {i}: {chunk_duration_s:.0f}s < {MIN_CHUNK_SECONDS}s minimum")
            continue
        chunk = audio[start_ms:end_ms]
        chunk_path = os.path.join(args.output, f"_chunk_{i}.wav")
        chunk.export(chunk_path, format="wav", parameters=["-ar", "16000", "-ac", "1"])

        log.info(f"Chunk {i}: {start_ms/1000:.0f}s - {end_ms/1000:.0f}s")
        text = transcribe_chunk(model, processor, chunk_path, stream=True)
        transcripts.append({"start": start_ms / 1000, "end": end_ms / 1000, "text": text})
        os.remove(chunk_path)

    time_transcribe = time.time() - t0

    # --- Merge transcription with diarization ---
    merged = merge_transcript_diarization(transcripts, diarization, Segment)

    # Output
    base = os.path.basename(args.audio)
    out_txt = os.path.join(args.output, base + ".txt")
    out_json = os.path.join(args.output, base + ".json")

    with open(out_txt, "w") as f:
        for seg in merged:
            f.write(f"[{format_time(seg['start'])} --> {format_time(seg['end'])}] {seg['speaker']}: {seg['text']}\n")

    with open(out_json, "w") as f:
        json.dump(merged, f, indent=2)

    speakers = set(s["speaker"] for s in merged)
    rtf = (time_transcribe + time_diar) / duration
    print(f"\n{'='*50}")
    print(f"  FULL PIPELINE RESULT")
    print(f"{'='*50}")
    print(f"  Audio duration : {format_time(duration)}")
    print(f"  Diarization    : {time_diar:.1f}s")
    print(f"  Transcription  : {time_transcribe:.1f}s")
    print(f"  RTF            : {rtf:.2f}x")
    print(f"  Segments       : {len(merged)}")
    print(f"  Speakers       : {len(speakers)} ({', '.join(sorted(speakers))})")
    print(f"  Output         : {out_txt}")
    print(f"{'='*50}\n")


def main():
    parser = argparse.ArgumentParser(description="Voxtral 24B Transcription")
    parser.add_argument("audio", help="Path to audio file")
    parser.add_argument("--output", default="output", help="Output directory")
    parser.add_argument("--hf-token", help="HuggingFace token for pyannote")
    parser.add_argument("--model", choices=["mini", "24b"], default="mini",
                        help="Model size: mini (3B) or 24b (default: mini)")
    parser.add_argument("--benchmark", action="store_true",
                        help="Quick benchmark: no chunking, no diarization")
    args = parser.parse_args()

    global MODEL_ID
    MODEL_ID = MODELS[args.model]

    os.makedirs(args.output, exist_ok=True)

    if args.benchmark:
        run_benchmark(args)
    else:
        run_full(args)


if __name__ == "__main__":
    main()
    # Force clean exit to avoid "corrupted fastbins" crash from mixed ROCm versions
    os._exit(0)
