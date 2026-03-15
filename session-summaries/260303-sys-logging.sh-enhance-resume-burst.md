# Summary: Enhanced Resume Burst Profile for sys-logging.sh
**Date:** March 3, 2026
**Task:** Upgrade the system resume detection burst logic from a single-stage 15s interval to a 3-stage profile.

## Changes Implemented
- **3-Stage Burst Profile**: Replaced the single `RESUME_BURST_INTERVAL` (15s) with three phases of decreasing intensity after wake-up:
  1. **Phase 1**: 5s interval for 30s duration.
  2. **Phase 2**: 10s interval for another 30s.
  3. **Phase 3**: 15s interval for the final 60s of the burst period.
- **Environment Variables**: Introduced new configuration variables with safe defaults:
  - `RESUME_PHASE1_INTERVAL` (5), `RESUME_PHASE1_DURATION_MS` (30000)
  - `RESUME_PHASE2_INTERVAL` (10), `RESUME_PHASE2_DURATION_MS` (30000)
  - `RESUME_PHASE3_INTERVAL` (15), `RESUME_PHASE3_DURATION_MS` (60000)
- **Validation Logic**: Added logic to ensure these variables are positive integers and within reasonable bounds.
- **Main Loop Logic**: Added a transition block at the start of the main loop to calculate the active interval based on the current phase. This logic respects manual `USR2` overrides which take precedence.
- **Resume Detection Update**: Modified the resume detection block (at the end of the loop) to initialize the timestamps for all three phases upon system wake-up.

## Impact
- **Higher Resolution**: Captures system activity at a much higher resolution (5s) immediately after resume, which is critical for diagnosing performance issues during system wake-up.
- **Graceful Tapering**: Gradually slows down the polling rate as the system stabilizes, reducing log bloat once the initial wake-up peak has passed.

## Verification
- Syntax check passed using `bash -n`.
- Implementation plan created in `/home/dcar/bin/plans/resume-burst-stages.md`.
