# Issue 000-1 — `hid-multitouch` `hid_field_extract()` warning during Stage 0

**Session**: 000 (pre-flight + Stage 0, 2026-09-25)
**Severity**: Low (warning only, no functional impact observed)
**Status**: Logged, not investigated (read-only session)
**Discovered during**: Stage 0 environment capture (passive, no daemon
running, no touch input).

## Repro steps
1. Boot the machine normally (T1 stack: `appletbdrm` + `hid-multitouch`
   loaded, iBridge in Config 2).
2. Leave the machine idle for ~10 minutes after boot (no touch activity).
3. Capture the kernel log:
   ```bash
   journalctl -b -0 -k | grep hid-multitouch
   ```

## Evidence
From `docs/test-logs/000/journalctl-appletbdrm.log`:

```
Sep 25 08:05:21 phobos kernel: hid-multitouch 0003:05AC:8600.0006: input,hiddev96,hidraw0: USB HID v1.01 Device [Apple Inc. iBridge] on usb-0000:00:14.0-3/input2
...
Sep 25 08:15:15 phobos kernel: hid-multitouch 0003:05AC:8600.0006: hid_field_extract() called with n (64) > 32! (swapper/2)
```

- The `hid-multitouch` driver bound the digitizer cleanly at 08:05:21.
- At 08:15:15 (~10 min later) a single `hid_field_extract()` warning fired.
- The `(swapper/2)` suffix indicates the call happened in a kernel thread
  context (likely during a low-power/idle state or a spontaneous USB
  autoresume), not while any userspace daemon was reading the device (none
  was running — this was Stage 0, before any `tbard` start).

## Root-cause hypothesis (not confirmed — read-only session)
The warning `hid_field_extract() called with n (64) > 32!` is a kernel
`hid-multitouch` driver sanity check: it complains when a HID field's
`report_size` exceeds 32 bits, which the driver does not handle in a single
`FIELD_extract` call. On the T1 iBridge digitizer this most likely comes
from the 64-bit multitouch report descriptor that `hid-multitouch` quirked
in via `MT_CLS_APPLE_TOUCHBAR` (the Seborider patch). The trigger appears to
be an idle/autosuspend event on the USB device at ~10 min after boot, where
the device emits a report whose descriptor field size the driver's
`hid_field_extract` guard rejects.

This is a **kernel-driver-level** warning, not a `touchbar-engine` defect.
The daemon was not running. It is logged here because:
1. It is part of the Stage 0 baseline evidence (the environment is not
   100% quiet).
2. If it recurs *during* a Stage 4/5 touch-logging session while the daemon
   is reading events, it could correlate with dropped touch packets and
   should be cross-referenced.

## Affected surface
- Kernel: `drivers/hid/hid-multitouch.c` `hid_field_extract()` guard (not
  in this repo; out-of-tree DKMS in `backup_old/kernel-hid-t1-0.2/`).
- `touchbar-engine`: none directly. If the warning coincides with a
  userspace read, `LibinputProvider::poll` (`src/providers/input.rs:82-150`)
  may see a truncated or missing contact for that frame. No evidence of
  that in this session (no daemon was running).
- Test plan: noted as a baseline anomaly; future Stage 4 runs should
  `grep hid_field_extract` in the live dmesg stream and correlate with any
  missed touch events.

## Proposed fix
**None in this repo.** This is a kernel `hid-multitouch` issue. If it
becomes disruptive, the fix belongs in the `kernel-hid-t1-0.2` DKMS patches
(`backup_old/kernel-hid-t1-0.2/`), not in `touchbar-engine`. No ADR needed
unless it is shown to cause touch-data loss during a live session.

## Repro status
- Occurred once in the 000 baseline. Not reproduced deliberately (read-only
  session; no touch activity was generated).
- To confirm reproducibility: in a future Stage 4 session, capture
  `dmesg -wT | grep hid_field_extract` while exercising the digitizer for
  10 min and note any correlation with idle/resume events.