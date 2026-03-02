#!/usr/bin/env python3
import os
import sys

os.environ["TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL"] = "1"
os.environ["HSA_XNACK"] = "0"
os.environ["HSA_OVERRIDE_GFX_VERSION"] = "11.0.0"

import time
import argparse
import subprocess
import torch
import librosa
from transformers import Qwen2AudioForConditionalGeneration, AutoProcessor


def preprocess_audio(input_path, output_dir="."):
    base_name = os.path.basename(input_path)
    output_wav = os.path.join(output_dir, base_name + ".qwen.wav")
    print(f"Preprocessing audio to 16kHz mono WAV: {output_wav}")

    cmd = ["ffmpeg", "-y", "-i", input_path, "-ar", "16000", "-ac", "1", output_wav]

    try:
        subprocess.run(cmd, check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        print(f"FFmpeg conversion failed: {e.stderr.decode()}")
        sys.exit(1)

    return output_wav


def transcribe_audio(audio_path, model_path):
    print(f"Loading Qwen2-Audio model from {model_path}...")
    print(
        f"GPU Memory available: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.0f} GB"
    )

    processor = AutoProcessor.from_pretrained(model_path)
    model = Qwen2AudioForConditionalGeneration.from_pretrained(
        model_path,
        torch_dtype=torch.bfloat16,
        device_map={"": "cuda"},
        low_cpu_mem_usage=True,
    )

    print(f"Model loaded on device: {model.device}")

    audio, sr = librosa.load(audio_path, sr=processor.feature_extractor.sampling_rate)

    prompt = "<|audio|><|en|><|asr|>Transcribe the following audio accurately."
    inputs = processor(
        text=prompt, audios=audio, return_tensors="pt", sampling_rate=sr
    ).to(model.device)

    print("Starting Qwen2-Audio inference...")
    generate_ids = model.generate(**inputs, max_new_tokens=1024)

    generate_ids = generate_ids[:, inputs.input_ids.size(1) :]
    transcription = processor.batch_decode(
        generate_ids, skip_special_tokens=True, clean_up_tokenization_spaces=False
    )[0]

    return transcription


def main():
    parser = argparse.ArgumentParser(description="Transcribe with Qwen2-Audio")
    parser.add_argument("audio_file", help="Path to input audio file")
    parser.add_argument(
        "--model-path",
        default=os.path.expanduser("~/llms/qwen2/Qwen2-Audio-7B-Instruct"),
        help="Path to Qwen2-Audio model",
    )
    args = parser.parse_args()

    if not os.path.exists(args.audio_file):
        print(f"Error: File not found {args.audio_file}")
        sys.exit(1)

    if not os.path.exists(args.model_path):
        print(f"Error: Model not found at {args.model_path}")
        sys.exit(1)

    working_file = preprocess_audio(args.audio_file)
    transcription = transcribe_audio(working_file, args.model_path)

    print("\n=== Transcription ===")
    print(transcription)
    print("====================\n")

    base_name = os.path.basename(args.audio_file)
    output_txt = base_name + ".qwen2.txt"
    with open(output_txt, "w") as f:
        f.write(transcription)

    print(f"Saved to {output_txt}")


if __name__ == "__main__":
    main()
