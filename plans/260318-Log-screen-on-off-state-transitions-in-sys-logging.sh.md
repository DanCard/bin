# Plan: Log screen on/off state transitions in sys-logging.sh

## Context
The script already detects screen power state via `get_display_power_state()` (line 667) and uses it to adjust sampling delay (lines 772-788). We want to log `■` (on) or `□` (off) as event markers when the screen state **transitions**, not on every line.

## Changes (all in `/home/dcar/bin/sys-logging.sh`)

1. **Add constants** (near line 44, with other event codes):
   ```
   SCREEN_ON_EVENT_CODE="■"
   SCREEN_OFF_EVENT_CODE="□"
   ```

2. **Add state tracking variable** (near line 77):
   ```
   LAST_SCREEN_STATE=""
   ```

3. **Log transitions in the main loop.** The screen state is already read in the non-burst branch (line 772). We also need it checked in the burst branch so transitions are never missed. The approach:
   - Move `get_display_power_state` to always run each loop iteration (currently it's only called inside the `else` of the burst check at line 772, and during resume at line 823).
   - After getting the state, compare to `LAST_SCREEN_STATE`. If changed (and `LAST_SCREEN_STATE` is non-empty, to skip the initial read), enqueue the appropriate event marker.
   - Update `LAST_SCREEN_STATE`.

   Specifically, **before** the burst/screen-off delay logic block (line 766), add:
   ```bash
   DISPLAY_POWER_STATE=$(get_display_power_state)
   if [[ -n "$LAST_SCREEN_STATE" && "$DISPLAY_POWER_STATE" != "$LAST_SCREEN_STATE" ]]; then
       if [[ "$DISPLAY_POWER_STATE" == "off" ]]; then
           enqueue_event_marker "$SCREEN_OFF_EVENT_CODE"
       elif [[ "$DISPLAY_POWER_STATE" == "on" ]]; then
           enqueue_event_marker "$SCREEN_ON_EVENT_CODE"
       fi
   fi
   LAST_SCREEN_STATE="$DISPLAY_POWER_STATE"
   ```

   Then update the existing block (lines 772-788) to remove the redundant `DISPLAY_POWER_STATE=$(get_display_power_state)` call since it was already fetched above. The existing `if [[ "$DISPLAY_POWER_STATE" == "off" ]]` block stays as-is.

4. **Update the abbreviation legend comment** (top of file) to document `■` / `□`.

## Verification
- Run `bash sys-logging.sh` briefly, toggle screen off/on with `xset dpms force off` / `xset dpms force on`, check the log for `□` (off) and `■` (on) markers appearing only on transition lines.
