# Seborider PR #1 — digitizer not discovered on MBP14,2 (T1)

> Draft upstream issue text. This is the issue to file against the Seborider
> mbp-t1-touchbar project (the upstream of the lineage this engine forks
> from — see `docs/prior-art.md` §200, §262). The fix landed here as ADR 009;
> this document is the upstream-facing write-up.

## Title

Digitizer discovery breaks on MBP14,2 — T1 reports `"Apple Inc. Apple T1 Controller Touchpad"` (name-string matching chases variants)

## Summary

On a MacBookPro14,2 (T1, 2017), the Touch Bar digitizer reports the product
name `"Apple Inc. Apple T1 Controller Touchpad"`, which the current
name-string discovery does not match. The daemon therefore never
enumerates the digitizer and Stage 4 (touch-logging) sees zero touch
events.

The root cause is that discovery matches the digitizer by product-name
substring (`"Touch Bar" || "iBridge Touchpad" || "T1 Controller Touchpad"`)
and the seat-assignment udev rule enumerates product names explicitly
(`"Apple Inc. Touch Bar Display Touchpad"`, `"MacBookPro17,1 Touch Bar"`,
`"Mac14,7 Touch Bar"`). Every new name variant — and the MBP14,2 T1 is one
— requires another patch to both the code and the udev rule.

## Environment

- MacBookPro14,2 (T1), kernel `7.2.6-arch2-1`
- USB `05ac:8600` Apple iBridge, `bConfigurationValue=2` (DRM mode)
- `appletbdrm` 1.2.0 loaded; `hid_multitouch` loaded; `apple_ibridge` NOT
  loaded (T1 stack — `appletbdrm` binds the display interface directly)
- Digitizer: `input13` = `"Apple Inc. iBridge Touchpad"` on this bench
- `/dev/dri/card0` = `appletbdrm` (mode 60×2170, ratio ≈36.2)

### The same model reports DIFFERENT names — name-matching is unstable

This is the central evidence. **The same MacBookPro14,2 model reports
different digitizer product names across units/firmware:**

| Source | Reported name | Where |
|---|---|---|
| This bench (MBP14,2, kernel 7.2.6, `hid_multitouch`) | `Apple Inc. iBridge Touchpad` | `docs/test-logs/000/evtest-input13.log`, `docs/test-logs/000b/pre-deploy-baseline.log` |
| Seborider PR #1 (MBP14,2, upstream report) | `Apple Inc. Apple T1 Controller Touchpad` | `docs/prior-art.md:200` |
| T2 Macs | `Apple Inc. Touch Bar Display Touchpad` | `backup_old/udev-rules/99-touchbar-seat.rules:4` |
| Apple Silicon (ARM) | `MacBookPro17,1 Touch Bar` / `Mac14,7 Touch Bar` | `backup_old/udev-rules/99-touchbar-seat.rules:4-5` |

Both the `iBridge Touchpad` and `Apple T1 Controller Touchpad` names come
from **MBP14,2** hardware. A name-string match that works on one unit
fails on another. This is why ADR-009 matches by USB VID:PID (`05ac:8600`)
in udev and by ABS_MT geometry in code — both are stable across name
variants. See `packaging/udev/99-touchbar-seat.rules` and
`src/providers/input.rs` `is_digitizer` / `geometry_matches_tb`.

## Root cause

Two name-string dependencies:

1. **Code** (`is_digitizer`): `name.contains("Touch Bar") || name.contains("iBridge Touchpad") || name.contains("T1 Controller Touchpad")`. The MBP14,2 T1 name `"Apple Inc. Apple T1 Controller Touchpad"` does contain the substring `"T1 Controller Touchpad"`, so the *code* happens to match it — but only because someone already added that substring. The next variant breaks again.

2. **udev seat rule** (`99-touchbar-seat.rules`): assigns `seat-touchbar`
   by `ATTR{name}=="<exact name>"` for three T2/ARM names and omits both
   T1 names. On this bench the digitizer sits on `seat0`, so the engine's
   `seat-touchbar` libinput context never enumerates it, so `is_digitizer`
   is never even called on it. This is the actual break on MBP14,2.

## Proposed fix

Eliminate the name-string dependency entirely:

- **udev**: assign `seat-touchbar` by USB VID:PID, not by name:
  ```
  SUBSYSTEM=="input", ATTRS{idVendor}=="05ac", ATTRS{idProduct}=="8600", \
    ENV{ID_SEAT}="seat-touchbar", TAG+="uaccess"
  ```
  This covers every T1/T2 name variant (`iBridge Touchpad`, `Apple T1
  Controller Touchpad`, `Touch Bar Display Touchpad`,
  `MacBookPro17,1 Touch Bar`, `Mac14,7 Touch Bar`) without enumerating
  names.

- **code**: match the digitizer by **ABS_MT geometry vs the DRM mode** —
  a candidate is the digitizer iff it has `EV_ABS` + `ABS_MT_POSITION_X/Y`
  axes whose maxima match the Touch Bar dimensions (60×2170, within
  tolerance, allowing for the rotated panel). No `dev.name()` call in the
  matching path.

## Reproduction

1. Boot MBP14,2 with the T1 stack (`appletbdrm` + `hid_multitouch`, no
   `apple_ibridge`).
2. `udevadm info /dev/input/eventN` for the digitizer → `ID_SEAT=seat0`
   (not `seat-touchbar`) because the name is not in the rule.
3. Start the daemon → `seat-touchbar` libinput context enumerates nothing
   → zero `InputEvent::Touch` → Stage 4 touch-logging sees no events.

## Evidence

- `docs/test-logs/000/environment.log` — bench environment
- `docs/test-logs/000/evtest-input13.log` — digitizer capabilities
- `docs/review-report.md` §2.1 — the name-string FAIL
- `docs/adr/009-digitizer-geometry.md` — the fix (accepted, implemented)
- `packaging/udev/99-touchbar-seat.rules` — the VID:PID udev rule

## Impact

Fixing this unblocks touch-event logging and the entire gesture pipeline
on MBP14,2 and makes discovery robust to future name variants without
code changes.