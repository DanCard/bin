#!/home/dcar/.venvs/transcribe/bin/python
import os
import sys

# ROCm 7.2.4 + Strix Halo (gfx1151) Optimization
os.environ["HSA_OVERRIDE_GFX_VERSION"] = "11.5.1"
os.environ["TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL"] = "1"

import time
import argparse
import torch
import json
import logging
import subprocess
import soundfile as sf
from transformers import pipeline
from pyannote.audio import Pipeline as DiarizationPipeline

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

def main():
    parser = argparse.ArgumentParser(description="Strix Halo Optimized Transformers Transcription")
    parser.add_argument("audio_file", help="Path to audio file")
    parser.add_argument("--model", default="openai/whisper-large-v3-turbo", help="Whisper model ID")
    parser.add_argument("--batch-size", type=int, default=24, help="Batch size for inference")
    parser.add_argument("--output-dir", default=".", help="Output directory")
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
        # 1. Transcription
        logging.info("Starting transcription...")
        outputs = pipe(
            working_file,
            chunk_length_s=30,
            batch_size=args.batch_size,
            return_timestamps=True,
        )
        
        # 2. Diarization
        # pyannote.audio 4.x reads files via torchcodec, which isn't installed
        # for this ROCm torch build. Preload the WAV as an in-memory waveform
        # dict (the documented fallback in pyannote/audio/core/io.py) instead.
        logging.info("Starting diarization...")
        wav_data, wav_sr = sf.read(working_file, dtype="float32", always_2d=True)
        waveform = torch.from_numpy(wav_data.T).contiguous()  # (channel, time)
        diarization = diarization_pipe({"waveform": waveform, "sample_rate": wav_sr})

        # 3. Merge: assign each Whisper chunk to the speaker active at the
        # chunk's midpoint, then group consecutive same-speaker chunks. This
        # keeps every chunk (no text dropped) and tolerates Whisper returning
        # a None end-timestamp on long-form chunks.
        # pyannote 4.x returns a DiarizeOutput; exclusive_speaker_diarization
        # is the overlap-free Annotation intended for transcript merging.
        logging.info("Merging results...")
        turns = [
            (segment.start, segment.end, speaker)
            for segment, _, speaker in
            diarization.exclusive_speaker_diarization.itertracks(yield_label=True)
        ]

        def speaker_at(t):
            best, best_gap = None, None
            for s, e, spk in turns:
                if s <= t <= e:
                    return spk
                gap = s - t if t < s else t - e
                if best_gap is None or gap < best_gap:
                    best, best_gap = spk, gap
            return best  # nearest turn if no exact containment

        final_output = []
        for chunk in outputs["chunks"]:
            start, end = chunk["timestamp"]
            if start is None:
                continue
            if end is None:
                end = start
            mid = (start + end) / 2
            speaker = speaker_at(mid)
            text = chunk["text"].strip()
            if not text:
                continue
            if final_output and final_output[-1]["speaker"] == speaker:
                # extend the previous same-speaker block
                final_output[-1]["end"] = end
                final_output[-1]["text"] += " " + text
            else:
                final_output.append(
                    {"start": start, "end": end, "speaker": speaker, "text": text}
                )

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