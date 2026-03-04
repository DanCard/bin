# Objective
Enhance the system resume burst profile in `sys-logging.sh` to provide a multi-stage polling rate (5s, 10s, 15s) instead of a single 15s interval.

# Key Files & Context
- `/home/dcar/bin/sys-logging.sh`: The system logging script where resume detection and burst logic are implemented.

# Implementation Steps
1. **Redefine Configuration Variables**: Replace the single `RESUME_BURST_INTERVAL` and `RESUME_BURST_DURATION_MS` variables with three stages:
   - Phase 1: 5s interval, 30s duration.
   - Phase 2: 10s interval, 30s duration.
   - Phase 3: 15s interval, 60s (another minute) duration.
2. **Update Validation Logic**: Add validation for the new phase-based environment variables.
3. **Initialize State Variables**: Add `RESUME_PHASE*_UNTIL_MS` variables to track phase transitions.
4. **Implement Phase Transitions in Main Loop**: Add a logic block at the start of the loop to select the correct interval based on the current phase. This will be placed before the manual `USR2` override to ensure manual triggers still have precedence.
5. **Refactor Resume Detection**: Update the detection block at the end of the loop to initialize all three phase timestamps upon resume.

# Verification & Testing
- **Manual Verification**: Run the script and simulate a resume event (or wait for one) to observe the sampling intervals in the log file.
- **Log Inspection**: Verify that the log shows:
  - 5s samples for 30s (~6 lines)
  - 10s samples for 30s (~3 lines)
  - 15s samples for 60s (~4 lines)
- **Signal Interaction**: Verify that `SIGUSR2` still correctly overrides the polling rate if triggered during a resume burst.
