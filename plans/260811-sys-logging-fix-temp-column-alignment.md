# Fix inconsistent column formatting in `sys-logging.sh`

## Context

The telemetry lines written to `~/misc/logs/sys-logging-YYYY-MM-DD.log` do not
line up between rows. Example (real log, note where each column starts):

```
23:50:59 118.8% firefox-bin      32.1% Isolated Web Co  19.0% WebExtensions    a3 2725 2698 1529    67°152°F   48°118° r8169   45°amdgpu   45°mt7925  🌀2
23:51:30  12.6% agy               1.5% Xorg              1.3% konsole          a3    0 1544    0    47°116° r8169   45°113°F   43°mt7925   40°compo1
23:55:25  44.5% cc1plus          44.4% cc1plus           9.4% agy              a3 3433 4934 1508    93°199°F   49°120°amdgpu   45° r8169   40°mt7925  🌀4
```

The process block (`%5s%% %-15s`) and the fan RPM block (`%5d%5d%5d`) are fixed
width ASCII and are fine. **All of the jitter is in the temperature block**,
`get_temp_summary()` (sys-logging.sh:470-556). There are three independent
causes stacking on top of each other.

### Cause 1 — three different cell shapes

The render loop emits three formats:

| cell | format | example | display cols |
|---|---|---|---|
| acpitz | `%5s%6.6s`, label = `c_to_f` (sys-logging.sh:545) | ` 38°100°F` | **9** |
| first non-acpi | `%5s%3d°%6.6s` (sys-logging.sh:525) | ` 45°113° r8169` | **14** |
| all others | `%5s%6.6s`, label = sensor name (sys-logging.sh:545) | ` 43°mt7925` | **10** |

Measured, not estimated. Whichever sensor sorts first gets the 14-wide cell, so
everything to its right shifts.

### Cause 2 — the acpitz-first hoist never fires

sys-logging.sh:452 and :457 match `/^acpitz(\/|$)/`, but this machine's hwmon is
named **`acpitz_0`**:

```
/sys/class/hwmon/hwmon0 acpitz_0
```

so the collected entry is `acpitz_0/temp1` and the regex misses. The *rendering*
check at sys-logging.sh:497 is a glob (`acpitz*`), which does match — so the
acpitz reading gets the special narrow `°F`-label format but is never hoisted to
position 1. It sorts purely by temperature and lands wherever:

- `23:50:59` → acpitz first (`67°152°F`)
- `23:51:30` → acpitz second (`45°113°F`)
- `23:53:17` → acpitz third (`41°105°F`)

With `TEMP_N=4` it can also be pushed off the line entirely (acpitz currently
reads 38°C, tied with the NVMe composites), so some rows have no `°F` cell at
all.

### Cause 3 — `printf` pads by bytes, `°` is two bytes

`°` is U+00B0 = `0xC2 0xB0` in UTF-8. Consequences:

- `%5s` on `"38°"` (4 bytes) adds one space and renders **4** columns, never 5.
- `%6.6s` truncates by *bytes*: `c_to_f` returns `"152°F   "` (9 bytes), the
  precision chops it to 6 bytes = `"152°F"` = **5** columns. The three trailing
  spaces in `c_to_f` (sys-logging.sh:232) are therefore dead code — always cut.
- Latent: raising `TEMP_DECIMALS` to 1 makes `"45.5°"` 6 bytes, overflowing
  `%5s`; a narrower label width could slice the `°` mid-codepoint.

## Approach

Only `get_temp_summary()` and its helpers change. No change to the process, fan,
or event-marker blocks.

### 1. Character-width padding helpers

Add `pad_left`/`pad_right` that pad on `${#str}` (character count under a UTF-8
locale) rather than relying on `printf` field widths for any string containing
`°`. Truncation likewise slices by characters (`${str:0:n}`), so a `°` can never
be split.

### 2. One uniform cell shape

Every sensor gets the same three-part cell, every field right-aligned:

```
<C right-aligned 4><F right-aligned 4><label right-aligned TEMP_LABEL_WIDTH>
```

e.g. ` 45°113° r8169`, cells joined by a **single** space. Right-aligning every
field puts its slack at the *start* of the field, so the visible gap between
cells is a consistent two spaces — one separator plus the one-space pad of the
next cell's two-digit Celsius — instead of varying with label length. (A
three-digit Celsius reading, i.e. ≥100°C, narrows that gap to one space.)

This drops the "only the first non-acpi entry shows
Fahrenheit" special case and the separate acpitz shape — every cell is now the
same width, so `first_non_acpi` and `c_to_f` are no longer needed for layout.

The old acpitz shape existed to *hide* the sensor name: it stuffed the
Fahrenheit reading into the label slot so the row read ` 67°152°F` instead of
naming the sensor. Now that Fahrenheit has its own column that trick is
redundant, so the acpitz cell drops the label field entirely — not padded to
blank, which would leave a wide gap before the second reading. Rows still align
with each other because acpitz is pinned to slot 1.

### 3. Fix the acpitz hoist

Change the regex at sys-logging.sh:452/457 to `/^acpitz/` so `acpitz_0` matches
and the CPU-package reading is pinned to column 1 on every row.

## Verification

Run `get_temp_summary` in isolation and confirm each cell renders the same
number of display columns (`wc -m`), and that acpitz is always first.
