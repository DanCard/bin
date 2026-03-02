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
import base64
import requests
from tqdm import tqdm
from pathlib import Path

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

from pyannote.audio import Pipeline
from pyannote.core import Segment
from pyannote.audio.pipelines.utils.hook import ProgressHook

# Paths
SERVER_PORT = 8080
SERVER_URL = f"http://localhost:{SERVER_PORT}/v1/chat/completions"
HEALTH_URL = f"http://localhost:{SERVER_PORT}/health"

def setup_logging(audio_file):
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    log_filename = f"{audio_file}_{timestamp}.voxtral.log"
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        handlers=[logging.FileHandler(log_filename), logging.StreamHandler(sys.stdout)],
        force=True
    )
    return log_filename

def preprocess_audio(input_path):
    output_wav = input_path + ".tmp.wav"
    if os.path.exists(output_wav): return output_wav
    logging.info(f"Preprocessing audio to 16kHz mono WAV: {output_wav}")
    cmd = ["ffmpeg", "-y", "-i", input_path, "-ar", "16000", "-ac", "1", output_wav]
    subprocess.run(cmd, check=True, capture_output=True)
    return output_wav

def diarize_audio(audio_path, token, device="cuda", batch_size=32):
    original_audio = audio_path.replace(".tmp.wav", "")
    orig_cache = original_audio + ".diarize.json"
    if os.path.exists(orig_cache):
        logging.info(f"Loading cached diarization from {orig_cache}")
        with open(orig_cache, "r") as f: return json.load(f)
    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", token=token)
    pipeline.to(torch.device(device))
    pipeline.segmentation_batch_size = batch_size
    pipeline.embedding_batch_size = batch_size
    with ProgressHook() as hook:
        output = pipeline(audio_path, hook=hook)
    diarization = getattr(output, "speaker_diarization", output)
    cache_data = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        cache_data.append({"start": turn.start, "end": turn.end, "speaker": speaker})
    with open(orig_cache, "w") as f: json.dump(cache_data, f, indent=2)
    return cache_data

def merge_turns(diarization_data, max_turn_gap=1.5, max_turn_duration=60.0):
    if not diarization_data: return []
    merged = []
    current_turn = diarization_data[0].copy()
    for next_seg in diarization_data[1:]:
        # Merge if same speaker and gap is small
        if (next_seg['speaker'] == current_turn['speaker'] and 
            (next_seg['start'] - current_turn['end']) <= max_turn_gap and
            (next_seg['end'] - current_turn['start']) <= max_turn_duration):
            current_turn['end'] = next_seg['end']
        else:
            merged.append(current_turn)
            current_turn = next_seg.copy()
    merged.append(current_turn)
    return merged

def transcribe_turn_api(chunk_path):
    with open(chunk_path, "rb") as f:
        audio_b64 = base64.b64encode(f.read()).decode("utf-8")
    
    # THE SECRET SAUCE: llama-server multimodal audio marker is usually <|audio|> 
    # for Mistral/Voxtral quants or simply placing the audio object in content.
    payload = {
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Transcribe this audio exactly:"},
                    {"type": "input_audio", "input_audio": {"data": audio_b64, "format": "wav"}}
                ]
            }
        ],
        "temperature": 0.0,
        "max_tokens": 1024
    }
    
    try:
        response = requests.post(SERVER_URL, json=payload, timeout=300)
        if response.status_code != 200:
            # Fallback attempt with explicit marker if first one fails
            payload["messages"][0]["content"][0]["text"] = "<|audio|>\nTranscribe this audio exactly:"
            response = requests.post(SERVER_URL, json=payload, timeout=300)
            
        response.raise_for_status()
        text = response.json()["choices"][0]["message"]["content"].strip()
        # Filter out refusal boilerplate if it still happens
        refusals = ["I'm sorry", "I currently don't have", "capability to process"]
        if any(r in text for r in refusals) and len(text) < 200:
            return "" # Treat as empty rather than noise
        return text
    except Exception as e:
        logging.error(f"API transcription failed: {e}")
        return "[Error]"

def main():
    parser = argparse.ArgumentParser(description="High-Speed Granular Voxtral Transcription")
    parser.add_argument("audio_file", help="Input audio file")
    parser.add_argument("--hf_token", help="HuggingFace token")
    args = parser.parse_args()

    audio_file = os.path.abspath(args.audio_file)
    hf_token = args.hf_token or os.environ.get("HF_TOKEN")
    setup_logging(audio_file)
    wav_file = preprocess_audio(audio_file)

    try:
        # 1. Diarize
        diar_raw = diarize_audio(wav_file, hf_token)
        turns = merge_turns(diar_raw)
        
        # 2. Check Server
        try:
            requests.get(HEALTH_URL, timeout=2).raise_for_status()
            logging.info(f"Connected to Voxtral server on port {SERVER_PORT}")
        except:
            logging.error(f"No server found on {SERVER_PORT}. Please start llama-server manually first!")
            sys.exit(1)
        
        # 3. Transcribe turns
        audio, sr = torchaudio.load(wav_file)
        output_txt = audio_file + ".voxtral.txt"
        
        with open(output_txt, "w") as f:
            f.write(f"Granular Voxtral Transcript: {audio_file}\n" + "="*40 + "\n\n")

        pbar = tqdm(total=len(turns), desc="Transcribing Turns")
        for i, turn in enumerate(turns):
            start_samp, end_samp = int(turn['start'] * sr), int(turn['end'] * sr)
            chunk = audio[:, start_samp:end_samp]
            if chunk.shape[1] < 8000: # Ignore turns shorter than 0.5s
                pbar.update(1); continue
            
            chunk_path = f"/tmp/voxtral_turn_{i}.wav"
            torchaudio.save(chunk_path, chunk, sr)
            
            text = transcribe_turn_api(chunk_path)
            if text:
                timestamp = f"{int(turn['start']//60):02d}:{int(turn['start']%60):02d}"
                line = f"[{timestamp}] {turn['speaker']}: {text}\n\n"
                with open(output_txt, "a") as f: f.write(line)
            
            if os.path.exists(chunk_path): os.remove(chunk_path)
            pbar.update(1)
        pbar.close()
        logging.info(f"Process complete! Output: {output_txt}")

    finally:
        pass

if __name__ == "__main__":
    main()
