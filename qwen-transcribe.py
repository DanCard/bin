#!/home/dcar/.venvs/transcribe/bin/python
import os
import sys
import torch
import torchaudio
import json
import logging
import time
import argparse
import subprocess
from tqdm import tqdm

# ROCm Environment Setup
_ROCM_PATH = "/opt/rocm-7.2.0"
_MIOPEN_SO = os.path.join(_ROCM_PATH, "lib", "libMIOpen.so.1")
if os.path.exists(_MIOPEN_SO) and _MIOPEN_SO not in os.environ.get("LD_PRELOAD", ""):
    os.environ["LD_PRELOAD"] = _MIOPEN_SO
    os.environ["LD_LIBRARY_PATH"] = os.path.join(_ROCM_PATH, "lib") + ":" + os.environ.get("LD_LIBRARY_PATH", "")
    os.environ["MIOPEN_SYSTEM_DB_PATH"] = "/opt/rocm-7.2.0/share/miopen/db"
    os.environ["CPATH"] = "/opt/rocm-7.2.0/include"
    os.environ["TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL"] = "1"
    os.environ["HSA_OVERRIDE_GFX_VERSION"] = "11.5.1"
    os.execvp(sys.executable, [sys.executable] + sys.argv)

from nemo.collections.speechlm2.models import SALM
from pyannote.audio import Pipeline
from pyannote.audio.pipelines.utils.hook import ProgressHook

MODEL_LABEL = "Qwen 2.5B"
# Upstream model repo still includes "canary" in its official identifier.
MODEL_REPO_ID = "nvidia/canary-qwen-2.5b"
OUTPUT_TAG = "qwen-turns"


def setup_logging(audio_file):
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    log_filename = f"{audio_file}_{timestamp}.{OUTPUT_TAG}.log"
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        handlers=[logging.FileHandler(log_filename), logging.StreamHandler(sys.stdout)],
        force=True
    )
    return log_filename


def get_output_paths(audio_file):
    return audio_file + f".{OUTPUT_TAG}.txt", audio_file + f".{OUTPUT_TAG}.json"


def print_startup_overview(audio_file, args):
    output_txt, output_json = get_output_paths(audio_file)
    overview_lines = [
        "Starting per-turn transcription + speaker diarization pipeline",
        f"Input audio: {audio_file}",
        f"Transcription model: {MODEL_LABEL}",
        "What this script does:",
        "  1. Converts input audio to 16kHz mono WAV",
        "  2. Runs speaker diarization with Pyannote",
        "  3. Builds transcription units directly from diarization turns",
        "  4. Transcribes each turn (split if too long)",
        "  5. Uses diarization speaker labels directly",
        "  6. Writes final outputs to text and JSON",
        f"Max per-turn chunk size: {args.chunk_size}s",
        f"Turn padding: {args.turn_padding}s",
        f"Min chunk duration: {args.min_chunk_size}s",
        f"Force re-diarize: {args.force_diarize}",
        f"Transcription batch size: {args.batch_size}",
        f"Diarization batch size: {args.diarize_batch_size}",
        f"Output text: {output_txt}",
        f"Output JSON: {output_json}",
    ]
    print("\n".join(overview_lines))

def preprocess_audio(input_path):
    output_wav = input_path + ".tmp.wav"
    logging.info(f"Preprocessing audio to 16kHz mono WAV (fixing sample counts): {output_wav}")
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

def diarize_audio(audio_path, token, device="cuda", batch_size=32, force=False):
    cache_file = audio_path + ".diarize.json"
    # If the original file has a cache, we can use it, but usually best to re-run or point to the same cache
    # Check for cache based on the original audio name (without .tmp.wav)
    original_audio = audio_path.replace(".tmp.wav", "")
    orig_cache = original_audio + ".diarize.json"
    
    if os.path.exists(orig_cache) and not force:
        logging.info(f"Loading cached diarization from {orig_cache}")
        with open(orig_cache, "r") as f:
            return json.load(f)

    logging.info("Initializing Pyannote 3.1 for diarization...")
    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", token=token)
    pipeline.to(torch.device(device))
    
    pipeline.segmentation_batch_size = batch_size
    pipeline.embedding_batch_size = batch_size
    
    logging.info(f"Starting diarization (on {device}) with batch_size={batch_size}.")
    with ProgressHook() as hook:
        output = pipeline(audio_path, hook=hook)
    
    diarization = getattr(output, "speaker_diarization", output)
    
    cache_data = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        cache_data.append({"start": turn.start, "end": turn.end, "speaker": speaker})
    
    with open(orig_cache, "w") as f:
        json.dump(cache_data, f, indent=2)
    
    return cache_data


def build_turn_chunks(total_duration, diarization, turn_padding, max_chunk_size, min_chunk_size):
    """
    Build transcription chunks directly from diarization turns.
    Small padding gives the model context; overlap is removed to prevent duplicate coverage.
    """
    sorted_turns = sorted(diarization, key=lambda entry: (float(entry["start"]), float(entry["end"])))
    padded_turns = []
    for entry in sorted_turns:
        raw_start = max(0.0, min(float(total_duration), float(entry["start"])))
        raw_end = max(0.0, min(float(total_duration), float(entry["end"])))
        if raw_end <= raw_start:
            continue

        start = max(0.0, raw_start - turn_padding)
        end = min(float(total_duration), raw_end + turn_padding)
        if end - start < min_chunk_size:
            continue

        padded_turns.append({"start": start, "end": end, "speaker": entry["speaker"]})

    # Remove overlaps created by padding by splitting overlap at midpoint.
    for idx in range(len(padded_turns) - 1):
        left = padded_turns[idx]
        right = padded_turns[idx + 1]
        if left["end"] > right["start"]:
            midpoint = 0.5 * (left["end"] + right["start"])
            left["end"] = midpoint
            right["start"] = midpoint

    chunks = []
    for turn in padded_turns:
        if turn["end"] - turn["start"] < min_chunk_size:
            continue

        current_start = turn["start"]
        while current_start < turn["end"]:
            current_end = min(current_start + max_chunk_size, turn["end"])
            if current_end - current_start >= min_chunk_size:
                chunks.append({"start": current_start, "end": current_end, "speaker": turn["speaker"]})
            current_start = current_end

    return chunks

def main():
    parser = argparse.ArgumentParser(description="Transcribe diarization turns using a speech model and Pyannote")
    parser.add_argument("audio_file", help="Input audio file")
    parser.add_argument("--chunk_size", type=float, default=8.0, help="Max per-turn chunk size in seconds")
    parser.add_argument("--turn_padding", type=float, default=0.15, help="Padding around each diarization turn (seconds)")
    parser.add_argument("--min_chunk_size", type=float, default=0.20, help="Skip chunks shorter than this duration (seconds)")
    parser.add_argument("--batch_size", type=int, default=16, help="Batch size for transcription")
    parser.add_argument("--diarize_batch_size", type=int, default=32, help="Batch size for diarization")
    parser.add_argument("--force-diarize", action="store_true", help="Ignore diarization cache and recompute")
    parser.add_argument("--hf_token", help="HuggingFace token for Pyannote")
    args = parser.parse_args()
    if args.chunk_size <= 0:
        print("Error: --chunk_size must be greater than 0.")
        sys.exit(1)
    if args.turn_padding < 0:
        print("Error: --turn_padding cannot be negative.")
        sys.exit(1)
    if args.min_chunk_size <= 0:
        print("Error: --min_chunk_size must be greater than 0.")
        sys.exit(1)

    audio_file = os.path.abspath(args.audio_file)
    hf_token = args.hf_token or os.environ.get("HF_TOKEN")
    print_startup_overview(audio_file, args)
    
    if not hf_token:
        print("Error: HF_TOKEN not found. Required for Pyannote diarization.")
        sys.exit(1)

    setup_logging(audio_file)
    
    # 0. Preprocess to WAV (Crucial for sample count consistency)
    wav_file = preprocess_audio(audio_file)

    try:
        # 1. Diarization
        diarization_data = diarize_audio(
            wav_file,
            hf_token,
            batch_size=args.diarize_batch_size,
            force=args.force_diarize,
        )

        # 2. Transcription
        logging.info(f"Loading {MODEL_LABEL} transcription model...")
        model = SALM.from_pretrained(MODEL_REPO_ID, cache_dir='/home/dcar/llms/')
        model = model.to("cuda").half().eval()

        logging.info(f"Loading and resampling audio for transcription...")
        audio, sr = torchaudio.load(wav_file)
        # WAV is already 16kHz mono, but we check just in case
        if audio.shape[0] > 1: audio = torch.mean(audio, dim=0, keepdim=True)
        if sr != 16000:
            resampler = torchaudio.transforms.Resample(sr, 16000)
            audio = resampler(audio)
        audio = audio.squeeze(0)
        
        total_samples = audio.shape[0]
        total_duration = total_samples / 16000.0
        chunk_samples = int(args.chunk_size * 16000)
        transcription_chunks = build_turn_chunks(
            total_duration,
            diarization_data,
            turn_padding=args.turn_padding,
            max_chunk_size=args.chunk_size,
            min_chunk_size=args.min_chunk_size,
        )
        final_output = []
        text_lines = []

        logging.info(
            f"Transcribing {len(transcription_chunks)} diarization-turn chunks with batch_size={args.batch_size}..."
        )
        
        for i in tqdm(range(0, len(transcription_chunks), args.batch_size), desc="Transcribing"):
            batch_chunks = []
            batch_lens = []
            batch_metadata = []
            
            for meta in transcription_chunks[i : i + args.batch_size]:
                start_idx = int(meta["start"] * 16000)
                end_idx = min(int(meta["end"] * 16000), total_samples)
                chunk = audio[start_idx : end_idx]
                if chunk.shape[0] < 1600: continue
                
                if chunk.shape[0] < chunk_samples:
                    padding = torch.zeros(chunk_samples - chunk.shape[0])
                    padded_chunk = torch.cat([chunk, padding])
                    batch_chunks.append(padded_chunk)
                else:
                    batch_chunks.append(chunk)
                    
                batch_lens.append(chunk.shape[0])
                batch_metadata.append(meta)
                
            if not batch_chunks: continue
            
            batch_gpu = torch.stack(batch_chunks).cuda().half()
            batch_lens_gpu = torch.tensor(batch_lens, device="cuda")
            prompts = [[{"role": "user", "content": f"Transcribe the following: {model.audio_locator_tag}", "audio": []}]] * len(batch_chunks)
            
            with torch.no_grad():
                output_ids = model.generate(prompts=prompts, audios=batch_gpu, audio_lens=batch_lens_gpu, max_new_tokens=256)
            
            for idx, ids in enumerate(output_ids):
                text = model.tokenizer.ids_to_text(ids.cpu()).strip()
                meta = batch_metadata[idx]
                if text:
                    final_output.append({"start": meta["start"], "end": meta["end"], "speaker": meta["speaker"], "text": text})
                    text_lines.append(f"[{meta['speaker']} {meta['start']:.1f}-{meta['end']:.1f}]: {text}")

        # Save results
        output_txt, output_json = get_output_paths(audio_file)
        with open(output_txt, "w") as f:
            f.write("\n".join(text_lines))
        with open(output_json, "w") as f:
            json.dump(final_output, f, indent=2)
        
        logging.info(f"Process complete! Output: {output_txt}")

    finally:
        if os.path.exists(wav_file):
            logging.info(f"Cleaning up temporary file: {wav_file}")
            os.remove(wav_file)

if __name__ == "__main__":
    main()
