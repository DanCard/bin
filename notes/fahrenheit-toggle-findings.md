# Fahrenheit Toggle Bug — Findings

## What works
- `c_to_f()` helper correctly converts millidegrees C to Fahrenheit
- The label swap logic (`if [[ "$sensor" == acpitz* ]]`) correctly matches when the sensor name starts with "acpitz"
- Width alignment fixed with 3 trailing spaces after `°F` to compensate for multi-byte `°` in printf field-width padding

## The toggling problem
The first temp entry alternates between showing `acpitz` and the °F equivalent every other log cycle. The acpitz match (`acpitz*`) works for both normalized forms (`acpitz` and `acpitz/1`), so the sensor name itself must be changing between iterations.

## Likely root cause
The `normalize_sensor_name()` function produces different output depending on the raw hwmon data. The acpitz hwmon device may have a `temp1_label` file that sometimes gets read successfully (producing a different path like `acpitz/SomeLabel`) and sometimes falls back to `temp1` (producing `acpitz/1`). If the label file read produces something unexpected, the normalized name might not start with `acpitz`.

**Not confirmed** — debug logging via `log_msg` inside `get_temp_summary()` never appeared in the log file. This is likely because `get_temp_summary()` is called in a command substitution (`TEMP_SUMMARY=$(get_temp_summary)`) and `log_msg` uses `echo >>` which should still work in a subshell, but something prevented the output. Could be a timing/buffering issue or the systemd service instance was the one producing the visible log lines, not the manually launched test instance.

## Debugging challenges
1. **20-second interval** — each test cycle takes 20s, so iterating is slow
2. **Subshell logging** — `log_msg` calls inside `$(get_temp_summary)` didn't produce visible output in the log, reason unclear
3. **Multiple instances** — a systemd service instance may be running alongside manual test runs, both writing to the same log file, making it hard to tell which instance produced which lines

## Suggested investigation
1. Check if a systemd service is running: `systemctl --user status sys-logging.service`
2. Stop it before testing manually
3. Add debug output using `echo "DEBUG ..." >> /tmp/sys-logging-debug.log` (separate file, avoids interleaving)
4. Log the raw `$sensor` value before and after `normalize_sensor_name` to see what's actually changing
5. Check `ls /sys/class/hwmon/hwmon*/name` for multiple acpitz entries — if there are two hwmon devices named `acpitz*`, the collected data may vary based on read timing
