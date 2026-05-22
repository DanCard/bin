# Rewrite `compare_llm_perf.sh` — ROCm vs Vulkan with MTP

## Context

Gemini wrote `~/bin/compare_llm_perf.sh` to compare ROCm vs Vulkan throughput on
the local `mtp-27B-UD-Q8_K_XL.gguf` model. It doesn't work and isn't measuring
what we want. Concretely:

1. Uses `--device rocm0` / `vulkan0` (lowercase). `llama-bench --list-devices`
   shows them as `ROCm0` / `Vulkan0` — case matters, so the flag is ignored and
   both phases hit the default backend.
2. Phase 1 calls `llama-bench` with `--spec-type draft-mtp` flags pulled from
   `COMMON_ARGS` (via shell expansion of `$COMMON_ARGS` in phase 2 only —
   phase 1 doesn't even apply them). `llama-bench` doesn't support `--spec-type`
   at all (`llama-bench --help` has no such flag), so it can't measure MTP
   behavior.
3. Phase 2 wraps `llama-cli` in `time`, which includes model load + program
   startup. Then `grep -E "eval time|throughput"` filters most useful output.
4. `2>/dev/null` discards stderr where llama.cpp's perf lines are actually
   printed (`LOG_INF` in `common/sampling.cpp:517-521`).
5. No repetition control, no warmup separation, no structured output.

The goal: a working script that measures **real-world MTP performance** —
prompt processing + token generation tok/s — on both backends using the same
flags that the `summarize` / `glm` workflows use, and prints a clean markdown
table.

## Approach

Replace `compare_llm_perf.sh` with a script that:

1. Runs `llama-cli` once per backend (ROCm0, Vulkan0), with the production MTP
   flags (matching `~/bin/summarize` lines 62-73).
2. Adds `--perf`, `-n <fixed>`, `--no-display-prompt`, `--simple-io`, and a
   fixed `--seed` so output is reproducible and parseable.
3. Captures combined stdout+stderr to a per-run log file under `/tmp/`.
4. Parses the three stable perf lines emitted by `common/sampling.cpp`:
   - `prompt eval time = NNN ms / NNN tokens (... NN.NN tokens per second)`
   - `eval time = NNN ms / NNN runs (... NN.NN tokens per second)`
   - `total time = NNN ms / NNN tokens`
5. Supports `-r N` for repetitions per backend (default 3). Reports the
   best run (lowest total ms) plus the median tok/s for pp and tg.
6. Emits one markdown table to stdout: rows = backends, columns = pp tok/s,
   tg tok/s, total tok/s, total ms.

Why `llama-cli` and not `llama-server`: simpler, no port management, exits on
its own, and `--perf` produces the same numbers libllama tracks for the server.
Why not `llama-bench`: no MTP support, as noted above.

## Files

- **Modify**: `/home/dcar/bin/compare_llm_perf.sh` (replace contents).
- **No new files** beyond per-run logs under `/tmp/compare_llm_perf_*.log`.

## Reused references

- Production MTP flags — copy verbatim from `~/bin/summarize:62-73`:
  `--spec-type draft-mtp --spec-draft-n-max 3 -ngl 999 -c 256000 -fa on
  -ctk q8_0 -ctv q8_0 --no-mmap --temp 0`.
- Model path — same as `~/bin/summarize:14`:
  `/home/dcar/llms/qwen3/6/mtp-27B-UD-Q8_K_XL.gguf`.
- Binary — `/home/dcar/github/llama.cpp/build/bin/llama-cli`.
- Perf format strings — `/home/dcar/github/llama.cpp/common/sampling.cpp:517-521`.

## Script structure (sketch)

```bash
#!/bin/bash
set -u
MODEL=/home/dcar/llms/qwen3/6/mtp-27B-UD-Q8_K_XL.gguf
LLAMA_CLI=/home/dcar/github/llama.cpp/build/bin/llama-cli
PROMPT="Explain the origin of the word 'pot' and its etymological..."  # ~longer prompt
N_PREDICT=256
REPS=${REPS:-3}
SEED=42
COMMON=(--spec-type draft-mtp --spec-draft-n-max 3
        -ngl 999 -c 256000 -fa on -ctk q8_0 -ctv q8_0
        --no-mmap --temp 0 --seed "$SEED"
        --perf --no-display-prompt --simple-io
        -n "$N_PREDICT" -p "$PROMPT")

run_backend() {
  local dev="$1" rep="$2"
  local log="/tmp/compare_llm_perf_${dev}_${rep}.log"
  "$LLAMA_CLI" -m "$MODEL" --device "$dev" "${COMMON[@]}" >"$log" 2>&1
  # parse pp tok/s, tg tok/s, total ms from $log
}

# loop: for dev in ROCm0 Vulkan0; do for r in $(seq 1 $REPS); do run_backend ...; done; done
# collect arrays of pp_tps[dev][r], tg_tps[dev][r], total_ms[dev][r]
# print markdown table with median values
```

Parse with `grep -E` + `awk` on the three known lines. `tokens per second`
appears as the last numeric column on the pp/eval lines.

## Verification

1. Run a quick single-rep smoke test:
   `REPS=1 ./compare_llm_perf.sh` — should complete in <1 min/backend on this
   GPU and print a 2-row table. Confirm both ROCm0 and Vulkan0 lines have
   non-zero pp and tg tok/s.
2. Sanity-check device targeting: tail one of the log files; the llama.cpp
   startup banner prints the active backend ("using ROCm device 0" or
   "using Vulkan device 0"). Make sure each log matches its filename.
3. Default run: `./compare_llm_perf.sh` (REPS=3). Should print 2 rows with
   median pp / tg tok/s. ROCm and Vulkan numbers should both be in the
   expected range for Strix Halo (gfx1151) — single-digit to low-double-digit
   tok/s for a 27B Q8 model.
4. Cross-check against existing scripts: run `summarize` on a short transcript
   and eyeball that the tok/s in `llama-server.log` is in the same ballpark as
   the table's "default backend" (whichever ROCm/Vulkan is faster — `summarize`
   doesn't pin a device).
