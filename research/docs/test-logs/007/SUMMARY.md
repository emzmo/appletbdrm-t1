# Stage 2 — Inspect-only (real hardware, oracle STAYS RUNNING) — Summary

**Date**: 2026-09-25 (Fri)
**Tag**: `v0.1.2-test3` (HEAD `dd9fdf3`, master post-merge)
**Binary**: `target/release/tbard` (real mode, NOT --dry-run)
**Reviewer role**: session-ops engineer (read-only; FREEZE RULE — no src/ changes)
**Constraint**: the deployed oracle (`tiny-dfr-mbp142`, PID 562, `nobody` on
`/dev/dri/card0`) STAYS RUNNING and lit — no master taken, no render, no
backlight write.

## Expected vs. actual verdicts

| Card | Expected | Actual (sudo, read-only scan) | Evidence |
|---|---|---|---|
| card0 (appletbdrm) | ACCEPT 60×2170 | **Touch Bar geometry (60×2170, ratio 3616) [ACCEPTED]** ✓ | `stage2-run2-sudo.log` |
| card1 (i915 eDP) | REJECT | **rejected: aspect ratio 1600/2560 (2560×1600)** ✓ | `stage2-run2-sudo.log` |
| card2 (vkms decoy) | REJECT | **rejected: aspect ratio 768/1024 (1024×768)** ✓ | `stage2-run2-sudo.log` |

All three verdicts match expectations under sudo (root can read card0
read-only; the read-only scan takes NO master).

## Oracle preservation

- Oracle state BEFORE: `nobody 562 tiny-dfr-mbp142` on `/dev/dri/card0`.
- Oracle state AFTER: `nobody 562 tiny-dfr-mbp142` on `/dev/dri/card0`.
- **Oracle untouched throughout.** The daemon's `try_open_card` on card0
  failed with `Device or resource busy (os error 16)` (EBUSY) because the
  oracle holds card0 master — the daemon NEVER acquired master, NEVER
  rendered, NEVER wrote backlight. It retried (30×, 2s apart) and was
  killed. See `stage2-run2-sudo.log` ("DRM card open failed (10/30)...
  Device or resource busy (os error 16)").

## Digitizer found by geometry (no name dependency in the log path)

- input13 = "Apple Inc. iBridge Touchpad", VID:PID `05ac:8600`.
- The engine matches by ABS_MT_POSITION_X/Y geometry vs the Touch Bar DRM
  mode (60×2170), NOT by name (ADR-009). The udev rule matches by
  VID:PID `05ac:8600`.
- card0 mode: `60x2170`, status `connected`, driver `appletbdrm`.
- See `stage2-digitizer.log`. (Note: input10 "Apple SPI Touchpad"
  06cb:0557 is the laptop trackpad, correctly NOT matched — different
  VID:PID and geometry.)

## dmesg / journal deltas

- `dmesg -T --level=err,warn` after Stage 2: **empty** (no new kernel
  warnings/errors). See `stage2-delta.log`.
- `journalctl -b -k` filtered for appletbdrm/drm/vkms/touchbar since
  Stage 2 start: **empty** (no new kernel messages).
- The read-only scan + EBUSY retries produced zero kernel log noise. No
  `appletbdrm: *ERROR*`, no `usb 1-3: reset`, no probe failure.

## Exit code

- The binary has no `--inspect` subcommand. Running `tbard` in real mode
  performs the read-only discovery (verdicts logged) then attempts
  `try_open_card` which fails with EBUSY (oracle holds master). The
  daemon retries 30× then `panic!`s ("Touch Bar card never appeared").
  Under `timeout --signal=SIGTERM`, the daemon did NOT exit on SIGTERM
  during the retry loop (see finding S2-F1) and required `kill -KILL`.
  **The daemon did not exit 0 on its own** — it was force-killed. The
  task's "Exit 0" criterion is not satisfiable with the current binary
  in real mode against an occupied card; the inspect-only intent was
  met (verdicts captured, no master/render/backlight), but the process
  exit was forced. See finding S2-F1.

## vkms decoy present

- `lsmod | grep vkms` → `vkms 102400 2` (loaded, 2 refs). Decoy present.
- `sudo modprobe vkms` was run pre-check (no-op, already loaded).

## Findings (FREEZE RULE — findings only, no src/ fixes this session)

### S2-F1 — SIGTERM not handled during DRM card-open retry loop

**Observation**: When `tbard` runs in real mode and `try_open_card` fails
(e.g. EBUSY because the oracle holds master), the daemon retries up to 30
times with 2s sleeps in `open_with_retry` (`src/providers/drm_backend.rs:200-247`).
The retry loop does NOT check `lifecycle::should_shutdown()`. A SIGTERM
during the retry loop is ignored — the signal handler sets the atomic
flag, but nothing in the retry loop reads it. The daemon only checks
`should_shutdown()` in the render loop (`src/main.rs:264`), which is
never reached. `timeout --signal=SIGTERM` had no effect; `kill -KILL`
was required.

**Impact**: A real-mode daemon that cannot acquire the card (e.g. boot
race, oracle still holding it) will ignore SIGTERM/SIGINT for up to 60s
(30×2s) and then panic. This violates ADR-007's "clean shutdown on
SIGTERM" guarantee during the startup phase. **Non-blocking for Stage 2**
(inspect-only, force-kill acceptable) but **blocking for the service
session** (systemd needs responsive SIGTERM). Logged for the next fix
session; not patched here.

### S2-F2 — Read-only DRM scan requires read access to card nodes; unprivileged user cannot scan card0

**Observation**: The unprivileged run (`stage2-run.log`) could not scan
card0 — "rejected: open error (Permission denied (os error 13))".
card0 is `root:video` mode `crw-rw----` with NO ACL for emzmo; emzmo is
NOT in the `video` group (only cosmic-greeter/greeter are). The read-only
scan opens each card `O_RDONLY` but EACCES on card0. Under sudo (root),
the scan succeeded and accepted card0.

This means the engine's DRM discovery, as built, REQUIRES either root or
`video` group membership (or a udev-granted ACL) to scan the Touch Bar
card. The ADR-010 production model (root start → acquire master →
privdrop) satisfies this (root can read card0). But an unprivileged
user running `tbard` directly cannot discover the Touch Bar card on this
bench — the scan fails with EACCES, not EBUSY.

**Impact**: Consistent with ADR-010's privilege model (the production
service runs as root pre-drop). Non-blocking for Stage 2 (sudo path
works). But it means "inspect-only by an unprivileged user" is not
supported without a udev rule granting `uaccess` on the Touch Bar DRM
card (our `99-touchbar-seat.rules` only tags input devices, not DRM
cards). Logged for the next fix session (consider a udev rule tagging
the appletbdrm DRM card with `uaccess`); not patched here.

## Verdict

Stage 2 **PASS (with findings)**:
- All three DRM verdicts match expectations (card0 ACCEPT 60×2170,
  card1 REJECT, card2 REJECT) — captured under sudo with the oracle
  running and lit.
- No master taken, no render, no backlight write (EBUSY on card0
  acquire; oracle preserved).
- Digitizer found by geometry (input13, 05ac:8600, no name dependency).
- dmesg/journal deltas empty (no kernel noise).
- Two findings logged (S2-F1 SIGTERM during retry, S2-F2 unprivileged
  scan EACCES), both for a future fix branch under the FREEZE RULE.
- The "Exit 0" criterion was not met (binary has no --inspect; daemon
  was force-killed after verdicts captured) — recorded as a limitation,
  not a failure of the inspect intent.

No src/ files were modified. The oracle service was not touched.