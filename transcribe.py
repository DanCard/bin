#!/home/dcar/.venvs/transcribe/bin/python
import os
import sys

# PyTorch bundles MIOpen without gfx1151 support. The amdrocm 7.11 packages
# provide a MIOpen with gfx1151 kernels. LD_PRELOAD it before torch loads.
_ROCM_PATH = "/opt/rocm-7.2.0"
_MIOPEN_SO = os.path.join(_ROCM_PATH, "lib", "libMIOpen.so.1")
if os.path.exists(_MIOPEN_SO) and _MIOPEN_SO not in os.environ.get("LD_PRELOAD", ""):
    os.environ["LD_PRELOAD"] = _MIOPEN_SO
    os.environ["LD_LIBRARY_PATH"] = os.path.join(_ROCM_PATH, "lib") + ":" + os.environ.get("LD_LIBRARY_PATH", "")
    os.environ["MIOPEN_SYSTEM_DB_PATH"] = "/opt/rocm-7.2.0/share/miopen/db"
    os.environ["CPATH"] = "/opt/rocm-7.2.0/include"
    os.execvp(sys.executable, [sys.executable] + sys.argv)

import time
import argparse
import subprocess
import torch
import json
import logging
import whisper
from pyannote.audio import Pipeline
from pyannote.core import Segment

_CUDA_USABLE = None


def setup_logging(audio_file, output_dir="."):
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    base_name = os.path.basename(audio_file)
    log_filename = os.path.join(output_dir, f"{base_name}_{timestamp}.log")

    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        handlers=[
            logging.FileHandler(log_filename),
            logging.StreamHandler(sys.stdout)
        ],
        force=True
    )
    logging.info(f"Logging initialized. Output saved to: {log_filename}")
    return log_filename


def check_env():
    if "TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL" not in os.environ:
        os.environ["TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL"] = "1"

    token = os.environ.get("HF_TOKEN")
    if not token:
        logging.error("Hugging Face token not found. Please set HF_TOKEN environment variable.")
        sys.exit(1)
    return token


def cuda_transfer_usable():
    """Check CUDA/ROCm tensor transfer in a subprocess to avoid hard crashes."""
    global _CUDA_USABLE
    if _CUDA_USABLE is not None:
        return _CUDA_USABLE

    probe_code = (
        "import torch; "
        "assert torch.cuda.is_available(); "
        "x=torch.tensor([1.0]); "
        "x=x.to('cuda'); "
        "print('ok')"
    )
    probe = subprocess.run(
        [sys.executable, "-c", probe_code],
        capture_output=True,
        text=True,
    )
    _CUDA_USABLE = probe.returncode == 0 and "ok" in probe.stdout
    if not _CUDA_USABLE:
        logging.warning(
            "CUDA/ROCm probe failed (rc=%s). Falling back to CPU to avoid segmentation faults. stderr: %s",
            probe.returncode,
            (probe.stderr or "").strip(),
        )
    return _CUDA_USABLE


def format_time(seconds):
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = seconds % 60
    return f"{hours:02d}:{minutes:02d}:{secs:06.3f}"


def preprocess_audio(input_path, output_dir="."):
    base_name = os.path.basename(input_path)
    output_wav = os.path.join(output_dir, base_name + ".tmp.wav")
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


def transcribe_audio(audio_path, model_size="large-v3", device="cuda", fp16=False):
    cache_file = audio_path + ".whisper.json"
    if os.path.exists(cache_file):
        logging.info(f"Found cached transcription at {cache_file}. Loading...")
        with open(cache_file, "r") as f:
            return json.load(f)

    logging.info(f"Loading Whisper model: {model_size} on {device} (fp16={fp16})...")
    try:
        model = whisper.load_model(model_size, device=device)
    except Exception as e:
        logging.warning(f"Failed to load on {device}. Error: {e}")
        raise e

    logging.info("Starting transcription...")
    # openai-whisper doesn't officially support batching in .transcribe
    result = model.transcribe(audio_path, word_timestamps=True, verbose=True, fp16=fp16)

    segments = result["segments"]
    language = result.get("language", "unknown")

    logging.info(f"Transcription complete. Detected language: {language}")

    logging.info(f"Caching transcription segments to {cache_file}")
    with open(cache_file, "w") as f:
        json.dump(segments, f, indent=2)

    return segments


def diarize_audio(audio_path, token, device="cuda", batch_size=32):
    cache_file = audio_path + ".diarize.json"
    if os.path.exists(cache_file):
        logging.info(f"Found cached diarization at {cache_file}. Loading...")
        from pyannote.core import Annotation, Segment
        annotation = Annotation()
        with open(cache_file, "r") as f:
            data = json.load(f)
            for item in data:
                annotation[Segment(item['start'], item['end'])] = item['speaker']
        return annotation

    logging.info(f"Loading Pyannote pipeline (batch_size={batch_size})...")
    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", token=token)

    torch_device = torch.device(device)
    pipeline.to(torch_device)
    
    # Set batch sizes for parallelization
    pipeline.segmentation_batch_size = batch_size
    pipeline.embedding_batch_size = batch_size

    logging.info("Starting diarization...")
    from pyannote.audio.pipelines.utils.hook import ProgressHook
    with ProgressHook() as hook:
        result = pipeline(audio_path, hook=hook)

    # In pyannote-audio 4.0+, the pipeline returns a DiarizeOutput object
    diarization = getattr(result, "speaker_diarization", result)

    logging.info("Diarization complete.")

    logging.info(f"Caching diarization to {cache_file}")
    cache_data = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        cache_data.append({
            "start": turn.start,
            "end": turn.end,
            "speaker": speaker
        })
    with open(cache_file, "w") as f:
        json.dump(cache_data, f, indent=2)

    return diarization


def merge_results(whisper_segments, diarization):
    logging.info("Merging transcription and diarization...")
    with open(output_txt, "w") as f:
        for item in result:
            line = f"[{format_time(item['start])} --> {format_time(item['end])}] {item['speaker]}: {item['text']}"
            f.write(line + "\n")
            print(line)
        start_time = seg['start']
        end_time = seg['end']
        text = seg['text'].strip()

        whisper_seg = Segment(start_time, end_time)

        # Find overlapping diarization segments
        speakers = []
        for turn, _, speaker in diarization.itertracks(yield_label=True):
            overlap = whisper_seg & turn
            if overlap:
                speakers.append((speaker, overlap.duration))

        # Assign speaker with max overlap
        if speakers:
            best_speaker = max(speakers, key=lambda x: x[1])[0]
        else:
            best_speaker = "Unknown"

        final_output.append({
            "start": start_time,
            "end": end_time,
            "speaker": best_speaker,
            "text": text
        })

    return final_output


def main():
    parser = argparse.ArgumentParser(description="Transcribe and Diarize Audio")
    parser.add_argument("audio_file", help="Path to the input audio file")
    parser.add_argument("--fp16", action="store_true", help="Enable FP16 inference (default is FP32)")
    parser.add_argument("--output-dir", help="Directory to save outputs and cache files", default=".")
    parser.add_argument("--batch-size", type=int, default=32, help="Batch size for diarization phases")
    parser.add_argument(
        "--device",
        choices=["auto", "cuda", "cpu"],
        default="auto",
        help="Inference device (default: auto). Auto uses CUDA only if a transfer probe is stable.",
    )
    args = parser.parse_args()

    audio_file = args.audio_file
    output_dir = args.output_dir

    if not os.path.exists(audio_file):
        logging.error(f"File not found: {audio_file}")
        sys.exit(1)

    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    log_file = setup_logging(audio_file, output_dir)

    hf_token = check_env()

    if args.device == "cpu":
        device = "cpu"
    elif args.device == "cuda":
        device = "cuda"
    else:
        device = "cuda" if cuda_transfer_usable() else "cpu"
    logging.info(f"Using inference device: {device}")

    fp16 = args.fp16
    if device == "cpu" and fp16:
        logging.warning("FP16 requested on CPU; disabling FP16.")
        fp16 = False

    # Preprocess
    working_file = preprocess_audio(audio_file, output_dir)

    start_total = time.time()

    # 1. Transcribe
    start_transcribe = time.time()
    whisper_segments = transcribe_audio(working_file, device=device, fp16=fp16)
    time_transcribe = time.time() - start_transcribe

    # 2. Diarize
    start_diarize = time.time()
    diarization_result = diarize_audio(working_file, hf_token, device=device, batch_size=args.batch_size)
    time_diarize = time.time() - start_diarize

    # 3. Merge
    start_merge = time.time()
    result = merge_results(whisper_segments, diarization_result)
    time_merge = time.time() - start_merge

    # 4. Output
    base_name = os.path.basename(audio_file)
    output_txt = os.path.join(output_dir, base_name + ".txt")
    output_json = os.path.join(output_dir, base_name + ".json")

    logging.info(f"Saving results to {output_txt} and {output_json}...")

    with open(output_txt, "w") as f:
        for item in result:
            line = f"[{format_time(item['start'])} --> {format_time(item['end'])}] {item['speaker']}: {item['text']}"
            f.write(line + "
")
            print(line)

    with open(output_json, "w") as f:
        json.dump(result, f, indent=2)

    total_time = time.time() - start_total

    print("
" + "="*40)
    print("       PERFORMANCE SUMMARY")
    print("="*40)
    print(f"Transcription : {format_time(time_transcribe)}")
    print(f"Diarization   : {format_time(time_diarize)}")
    print(f"Merging       : {format_time(time_merge)}")
    print("-" * 40)
    print(f"Total Time    : {format_time(total_time)}")
    print("="*40 + "
")

    logging.info("Done.")

    # Cleanup temp WAV
    if os.path.exists(working_file):
        os.remove(working_file)

    # Force clean exit to avoid "corrupted fastbins" crash from mixed ROCm library versions
    os._exit(0)


if __name__ == "__main__":
    main()
