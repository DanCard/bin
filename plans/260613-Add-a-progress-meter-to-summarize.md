# Add a progress meter to `summarize`

## Context
`~/bin/summarize` streams a transcript to a local llama.cpp server and writes an
exhaustive meeting record. Today the only feedback during `generate_summary()` is
a single `⏳ Generating: N characters written...` line (summarize:154-156). The
real problem: while the server **ingests the large transcript into the 128k
context** (prompt processing), the first token can take a long time, and during
that whole window the counter never moves — the script looks frozen.

A genuine progress meter is possible because the installed llama.cpp build
(current, supports the flags below) can report both prompt-processing progress and
generation timing over the streaming API. Goal: show a real % bar with ETA while
the prompt loads, then a live tokens/sec meter during generation. Display style:
**tqdm bars** (tqdm 4.67.3 already installed).

## Approach

Modify only `generate_summary()` in `/home/dcar/bin/summarize`.

### 1. Request the progress + timing fields
Add two flags to the `payload` (summarize:117-126):
```python
"return_progress": True,    # emits prompt_progress: {total, cache, processed, time_ms}
"timings_per_token": True,  # emits timings: {predicted_n, predicted_per_second, ...}
```
Per llama.cpp README (`tools/server/README.md:523-524`):
- `prompt_progress` overall = `processed/total`; timed = `(processed-cache)/(total-cache)`.
- `timings.predicted_n` = tokens generated so far; `predicted_per_second` = tok/s.

### 2. Two-phase tqdm display in the SSE loop
Reuse the existing `for line in response.iter_lines()` loop (summarize:139-159).
Parse each `data:` JSON chunk for `prompt_progress` and/or `timings` in addition
to the existing `choices[0].delta.content`.

- **Phase 1 — Prompt processing:** when a chunk carries `prompt_progress`, drive a
  determinate tqdm bar with `total = prompt_progress["total"]` and update to
  `processed`. This is the true % bar with ETA:
  `Prompt: 100%|████| 48k/48k tok [00:22<00:00, 2.1k tok/s]`.
  Close this bar once the first content token arrives (transition to phase 2).
- **Phase 2 — Generation:** open a second tqdm in indeterminate/manual mode
  (`total=None` since output length is open-ended; if `max_tokens > 0`, use it as
  `total` for a real %). Update postfix from `timings` each chunk:
  `Generating: 1,432 tok • 38.4 tok/s • 00:37 elapsed`.
  Keep writing `content` to `f_out` exactly as today (summarize:151-152).

Use `tqdm(..., file=sys.stderr)` so progress goes to stderr and does not interfere
with the existing stdout messages or the `tail -f` of the output file. Wrap bars in
`try/finally` (or `with`) so they `close()` cleanly on completion or error.

### 3. Cleanup
- Remove the old `char_count` / `sys.stdout.write("\r⏳ Generating...")` lines
  (summarize:155-156, 137) — superseded by the tqdm generation bar.
- Add `from tqdm import tqdm` near the top imports (summarize:1-10).
- Leave `start_server()`, `create_google_doc()`, and `main()` unchanged.

### Edge cases
- Some chunks contain only `prompt_progress` (no content) and some only timings —
  guard each `.get()` and `continue` on missing keys, mirroring the existing
  `except (json.JSONDecodeError, KeyError): continue`.
- If the server build ignores `return_progress`, no `prompt_progress` chunks
  arrive; fall back to an indeterminate spinner bar for phase 1 so behavior never
  regresses.

## Files
- `/home/dcar/bin/summarize` — `generate_summary()` only (imports + lines ~117-161).

## Verification
1. Run against a real transcript:
   `summarize ~/path/to/transcript.txt /tmp/out.md`
   Confirm: a filling **Prompt** bar appears immediately (no frozen gap), reaches
   100%, then a **Generating** bar shows rising token count + tok/s, and
   `/tmp/out.md` fills as before (`tail -f /tmp/out.md` in another terminal).
2. Confirm final `✅ Detailed record saved to:` line still prints and the Google
   Doc step still runs.
3. Quick API sanity check that the flags are honored by this build:
   `curl -s localhost:8080/v1/chat/completions -d '{"model":"...","stream":true,"return_progress":true,"timings_per_token":true,"messages":[{"role":"user","content":"hi"}]}'`
   and verify chunks contain `prompt_progress` and `timings`.
