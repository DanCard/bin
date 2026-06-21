# High-fidelity speaker ID for `transcribe-faster.py`

## Context

The user wants higher-fidelity speaker identification in `~/bin/transcribe-faster.py`
**without slowing down transcription**. Two clarifications during planning reshaped the goal:

1. **The ASR leaderboard is irrelevant to this.** The [Open ASR Leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)
   ranks by Word Error Rate (transcription accuracy), not speaker attribution.
   `microsoft/azure-speech-05-2026` is a **cloud** service (violates the local-only rule
   for this audio — see `[[no-cloud-for-audio]]`) and `ibm-granite/granite-speech-4.1-2b`
   (base) is **transcription-only, no diarization**. Neither improves speaker ID.
2. **The real symptom is boundary attribution: "off by several words, often."**
   This is *not* global speaker confusion (merge/split). It is words near a speaker
   transition being assigned to the wrong speaker, by a consistent multi-word margin.

Speaker ID lives entirely in the **diarization + merge stages**, which are decoupled from
transcription — so improving them does not slow transcription. The user chose
**tune + enrollment** and has **mostly-known, recurring participants**.

Reprioritized accordingly: **boundary accuracy is the primary fix**; enrollment (named,
consistent identities) is the secondary, user-requested layer.

## Root-cause hypothesis (boundary drift)

A consistent "several words off" indicates a **timeline mismatch**, not random jitter:

- Transcription runs `vad_filter=True` (`transcribe-faster.py:171`). faster-whisper's VAD
  drops silence and remaps word timestamps back to the original timeline; on long files this
  remap can drift ~1–3s.
- `diarize_windowed` (`:66`) runs pyannote on the **un-filtered** timeline.
- Two clocks → words land in the wrong turn. `word_speaker` (`:268`) assigns purely by
  max temporal overlap, so drift propagates directly into wrong-speaker words, and the
  `--min-turn` smoothing (`:294`) can't fix a several-word systematic shift.

## Plan

### Phase 0 — Diagnose (small clip first, per `[[transcribe-testing-use-small-clips]]`)
On a short trimmed clip with a couple of clear speaker changes:
- Run current pipeline, note boundary error magnitude/direction.
- Re-run with `--no-vad`. If boundaries tighten markedly, VAD timestamp drift is confirmed
  as the dominant cause and informs Phase 1 (snap window can be smaller; consider
  decoupling VAD from the timestamp path).
This is read-only experimentation; it decides tuning defaults, it is not a code change.

### Phase 1 — Pause-aware boundary snapping (primary fix)
Add a post-processing step in `main()` between diarization (`:254`) and word assignment
(`:280`), or fold into the merge. Speaker changes occur at pauses, and per-word timings
already exist (faster-whisper word timestamps), so:

- Build the inter-word gap list from `words`: for consecutive words, `gap = next.start - cur.end`,
  `gap_center = (cur.end + next.start)/2`.
- For each **speaker-change boundary** in `turns` (where adjacent turns differ in speaker),
  search inter-word gaps within `±W` seconds of the boundary (`W` = new `--boundary-snap`,
  default ~1.5s, informed by Phase 0). Snap the boundary to the **largest** qualifying gap
  (must exceed a small floor, e.g. 0.15s); adjust the neighboring turns' `end`/`start`.
- Then assign words. Net effect: the speaker switch lands at the real pause, correcting
  multi-word drift in either direction.

Equivalent word-space formulation (cleaner, also acceptable): assign words first, group into
blocks, then for each block→block speaker switch, move the switch point to the largest
inter-word gap within a `±W` window and reassign the words on the wrong side.

Keep `word_speaker`'s overlap logic but switch the primary criterion to the diarization label
at each word's **midpoint** (more stable at edges than total-overlap), with nearest-turn fallback.

Cost: pure post-processing on existing arrays — **zero transcription slowdown**.

### Phase 2 — Speaker enrollment (named, consistent identities)
Reuse the embedding mechanism already in `diarize_windowed` (`out.speaker_embeddings`, `:98`)
so reference voiceprints live in the **same embedding space** as the pipeline's.

- **Enrollment store**: a directory (e.g. `~/.config/transcribe/speakers/`) with one short
  reference clip per known person, plus a cached `.npy` embedding (computed once by running
  the pyannote pipeline on the clip and reading `out.speaker_embeddings`). New CLI:
  `--speakers DIR` to use, and an `--enroll` mode to (re)build the cache.
- **Matching**: after cross-window clustering produces global `SPEAKER_xx` labels (`:146`),
  compute each global speaker's centroid from its `node_emb` members, cosine-compare to
  enrolled references, and rename to the person's name when the best match ≥ `--enroll-threshold`
  (and is an unambiguous winner). Unmatched speakers keep `SPEAKER_xx`.
- Cost: a handful of cosine comparisons — negligible, no transcription slowdown.

### Phase 3 — Tuning helper (faster iteration)
Add a `--diar-only` mode that runs only preprocessing + diarization (+ optional snapping) and
prints a per-speaker talk-time summary / RTTM, so `--speaker-threshold`, `--diar-window`,
`--min-turn`, and the new `--boundary-snap` can be swept on a clip without paying for
transcription each time.

## Out of scope (considered, rejected)
- **Cloud Azure / any upload** — violates `[[no-cloud-for-audio]]`.
- **Granite base / ASR-model swaps** — improve word accuracy only, not speaker ID.
- **NeMo Sortformer / Granite Speech 4.1 Plus** — higher accuracy ceiling but unproven on
  ROCm/gfx1151, big rewrite, and Plus likely *slower* than faster-whisper. Revisit only if
  Phases 1–2 prove insufficient.
- **Per-word embedding classification at every boundary** — heavier; optional future step for
  residual errors after snapping (extract a short window embedding only for the few ambiguous
  boundary words and assign to the nearer adjacent-speaker centroid). Not in initial scope.

## Files to modify
- `transcribe-faster.py` only:
  - `main()` merge section (`:246`–`:316`) — boundary snapping + midpoint assignment.
  - `diarize_windowed` / new helpers (`:66`–`:151`) — expose per-global-speaker centroids for enrollment.
  - new enrollment helpers + CLI args in `main()` arg parser (`:191`–`:217`).

## Verification
1. **Small-clip regression** (`[[transcribe-testing-use-small-clips]]`): a short clip with
   2–3 known speakers and 1–2 clear turn changes. Confirm boundary words land on the correct
   speaker after snapping; compare before/after transcripts.
2. **Drift check**: confirm boundaries are correct late in a long file (where VAD drift would
   accumulate), not just at the start.
3. **Enrollment**: run `--enroll` on reference clips, then transcribe a clip containing those
   speakers; confirm `SPEAKER_xx` labels are replaced with correct names and unknown speakers
   remain `SPEAKER_xx`.
4. **No transcription slowdown**: compare logged transcription-stage time before/after — the
   "Transcribing" stage time should be unchanged (all new work is in diarization/merge).
5. **Tuning**: use `--diar-only` to sweep `--boundary-snap` / `--speaker-threshold` and pick
   defaults from Phase 0/1 results.
