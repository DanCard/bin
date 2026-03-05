# dcar/bin

This repository is mostly a personal script bin for one machine/workflow.

It contains quick utilities, experiments, and helper scripts I use for:
- power and fan tuning
- logging/monitoring
- screen/audio recording
- transcription and summarization

These scripts are not a polished product and may be machine-specific.

## Structure

- `./` (repo root): actively used scripts and symlinks
- `not-used/`: older scripts I keep around but do not currently use
- `failed/` and `doesnt-work/`: attempts that are incomplete or broken
- `old/`: archived older versions
- `notes/`, `plans/`, `summaries/`: supporting notes and implementation writeups
- `crap/`: scratch utilities

## Common scripts

- `power`, `cpu-epp`, `sps`: XFCE/display/system power helpers
- `check_fans.sh`, `fan-curve`, `sys-logging.sh`: fan and thermal monitoring/tuning
- `record-call.sh`, `signal-record.sh`, `screen-record-1080p`: recording helpers
- `whisper.py`, `fast-whisper.py`, `qwen-transcribe.py`, `summarize`: transcription/summarization workflows
- `newest`: quick helper to find most recently modified files

## Usage

Most scripts are executable and intended to run directly, for example:

```bash
./check_fans.sh
./power 10
./sys-logging.sh
```

If you want these commands available globally, add this directory to your `PATH`.

## Notes

- Expect hardcoded paths and environment assumptions.
- Read each script header before running.
- Some scripts require external tools (for example `xfconf-query`, `ffmpeg`, `lm-sensors`, model binaries, or local services).
