#!/home/dcar/.venvs/transcribe/bin/python
import os
import sys
import argparse
import logging
import json
import time
import subprocess

# --- ROCm 7.2.0 Environment Setup ---
_ROCM_PATH = "/opt/rocm-7.2.0"
_MIOPEN_SO = os.path.join(_ROCM_PATH, "lib", "libMIOpen.so.1")

if os.path.exists(_MIOPEN_SO) and _MIOPEN_SO not in os.environ.get("LD_PRELOAD", ""):
    os.environ["LD_PRELOAD"] = _MIOPEN_SO
    os.environ["LD_LIBRARY_PATH"] = os.path.join(_ROCM_PATH, "lib") + ":" + os.environ.get("LD_LIBRARY_PATH", "")
    os.environ["MIOPEN_SYSTEM_DB_PATH"] = os.path.join(_ROCM_PATH, "share", "miopen", "db")
    os.environ["CPATH"] = os.path.join(_ROCM_PATH, "include") + ":" + os.path.join(_ROCM_PATH, "include", "hip")
    if "HSA_OVERRIDE_GFX_VERSION" not in os.environ:
        os.environ["HSA_OVERRIDE_GFX_VERSION"] = "11.5.1"
    os.execvp(sys.executable, [sys.executable] + sys.argv)

import torch
from pyannote.audio import Pipeline
from pyannote.audio.pipelines.utils.hook import ProgressHook

def setup_logging():
    root = logging.getLogger()
    if root.handlers:
        for handler in root.handlers:
            root.removeHandler(handler)
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        stream=sys.stdout
    )

def check_gpu_strictly():
    if not torch.cuda.is_available():
        logging.error("CRITICAL: CUDA/ROCm is not available. Exiting to avoid CPU execution.")
        sys.exit(1)
    try:
        x = torch.tensor([1.0]).cuda()
        logging.info(f"GPU Probe Successful: {torch.cuda.get_device_name(0)} is active.")
    except Exception as e:
        logging.error(f"CRITICAL: GPU failed probe: {e}.")
        sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="Strict GPU Speaker Diarization (ROCm 7.2.0)")
    parser.add_argument("audio_file", help="Path to input audio")
    parser.add_argument("--device", choices=["cuda"], default="cuda", help="Enforced device (default: cuda)")
    parser.add_argument("--hf-token", help="Hugging Face token")
    parser.add_argument("--output", help="Path to save JSON results")
    
    args = parser.parse_args()
    setup_logging()
    check_gpu_strictly()

    hf_token = args.hf_token or os.environ.get("HF_TOKEN")
    if not hf_token:
        logging.error("Hugging Face token missing. Set HF_TOKEN env var.")
        sys.exit(1)

    audio_path = args.audio_file
    if not os.path.exists(audio_path):
        logging.error(f"File not found: {audio_path}")
        sys.exit(1)

    output_path = args.output or (audio_path + ".diarize.json")

    logging.info(f"Loading Pyannote pipeline onto GPU...")
    try:
        pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", token=hf_token)
        pipeline.to(torch.device("cuda"))
    except Exception as e:
        logging.error(f"Failed to load pipeline to GPU: {e}")
        sys.exit(1)

    logging.info("Starting GPU-accelerated diarization...")
    start_time = time.time()
    try:
        with ProgressHook() as hook:
            result = pipeline(audio_path, hook=hook)
        diarization = getattr(result, "speaker_diarization", result)
        duration = time.time() - start_time
        logging.info(f"Diarization complete in {duration:.2f}s.")
        cache_data = [{"start": t.start, "end": t.end, "speaker": s} 
                      for t, _, s in diarization.itertracks(yield_label=True)]
        with open(output_path, "w") as f:
            json.dump(cache_data, f, indent=2)
        logging.info(f"Results saved to {output_path}")
    except Exception as e:
        logging.error(f"Diarization failed: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
