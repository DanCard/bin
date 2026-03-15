## Sys Logging Session Notes

Date: 2026-03-15
Directory: `/home/dcar/bin`

### Summary

- Checked `sys-logging.service` and found it was running, not currently failed.
- Found the prior failure in the user journal on 2026-03-14 07:25:41 PDT.
- Failure reason was `oom-kill`.
- Restarted the service cleanly with `systemctl --user restart sys-logging.service`.

### Root Cause

The most likely cause was the `top` sampling path in `/home/dcar/bin/sys-logging.sh`:

- Previous command: `top -b -n 2 -d "$top_sample_delay" -w 512 -c`
- This collected wide full command lines on each sample.
- Under memory pressure, that appears to have contributed to the service being OOM-killed.

Log file growth was not the issue:

- `~/misc/logs` total size was `9.6M`
- Daily `sys-logging-*.log` files were only a few hundred KB each

### Change Made

Updated `/home/dcar/bin/sys-logging.sh`:

- Removed `-c`
- Reduced width from `-w 512` to `-w 256`

New command:

`top -b -n 2 -d "$top_sample_delay" -w 256`

### Verification

After restart:

- Service status: active
- Current memory: about `11.5M`
- Peak memory since restart: about `12.6M`

### Useful Commands

- Service status:
  `systemctl --user status sys-logging.service`
- Service memory:
  `systemctl --user show sys-logging.service -p MemoryCurrent -p MemoryPeak`
- Total log directory size:
  `du -sh ~/misc/logs`
- Daily log sizes:
  `ls -lh ~/misc/logs/sys-logging-*.log | tail`
- Today's log size:
  `du -h ~/misc/logs/sys-logging-$(date +%F).log`

