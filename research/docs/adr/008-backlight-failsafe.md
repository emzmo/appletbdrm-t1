# ADR 008: Backlight Fail-Safe — Errors Propagate, Default ON, Loud Logging

## Status: Accepted

## Date: 2026-09-25

## Context

Pre-flight review §2.6 (`docs/review-report.md`) found the backlight path
was **fail-silent**, not fail-safe-ON:

1. `set_backlight_file` silently discarded write errors (`if let Ok`, `let
   _ =`), so the daemon's `current_bl` was updated to `new_bl` in memory
   while the hardware could be in any state — the daemon *thought* it set
   the backlight but the bar could be dark.
2. `SysfsBacklight::new` panicked (`read_attr` `panic!`) if the brightness
   sysfs file was missing, so a backlight-device failure at startup killed
   the daemon and left the bar in whatever state the kernel left it
   (could be dark).
3. The idle path intentionally drives the bar to 0 (dark) after 60 s — by
   design (power saving) — but a silent write failure combined with the
   dark idle state means "dark" can mean either "intentionally idle" or
   "write failed and we didn't notice."

The task requires: errors propagate, default ON (visible), loud logging;
a dark bar can never be mistaken for success.

## Root cause

There was no fail-safe policy. The code treated sysfs writes as
fire-and-forget and startup reads as panic-on-missing, with no distinction
between "intentionally dark (idle/lid-closed)" and "dark because the
hardware didn't respond." ADR 006 made the errors propagate as typed
`HwError`s and logged write failures; this ADR defines the **policy**
layered on top: what the daemon does when a backlight operation fails.

## Decision

### 1. Default ON (visible) on failure

On any backlight write or read failure, the daemon's in-memory
`current_bl` is **not** advanced to the requested value if the write
failed. Instead it is reset to a visible, non-zero fail-safe level
(`FAILSAFE_BRIGHTNESS`, default a low-but-visible value like 1, clamped to
`max_bl`). The point is not to blind the user; the point is that **a
dark bar is never the result of an unnoticed failure**. When the bar is
dark, it is *always* because the daemon intentionally chose 0 (idle/lid).

### 2. Loud logging on every failure

Every `SysfsRead` / `SysfsWrite` failure from the backlight path is logged
at `error` level with the structured `HwError` (device path, attr, errno).
A dark-bar-from-failure is therefore accompanied by a loud, greppable log
line — never silent.

### 3. Startup: no panic; degrade to fail-safe

`SysfsBacklight::new` no longer panics on a missing brightness file (ADR
006 made `read_attr` return `Result`). If the backlight device is missing
or unreadable at startup, `new` returns an `Err` that `main` logs loudly;
the daemon does not start with a dark bar and no alarm. If `max_bl` is
unreadable but `brightness` is, the daemon degrades to a conservative
`max_bl` guess and continues with fail-safe-ON behavior.

### 4. Write-failure handling in `update` / `set_brightness`

- `set_brightness`: propagates the write error (returns `Result`); on
  failure `current_bl` is reset to `FAILSAFE_BRIGHTNESS` so the in-memory
  state does not claim a value the hardware never received.
- `update` (the trait hook, `()` return): on write failure, logs at
  `error` and resets `current_bl` to `FAILSAFE_BRIGHTNESS`. It does not
  advance `current_bl` to `new_bl` on failure — so the next iteration
  will retry the write rather than silently believing it succeeded.

### 5. Idle-to-0 unchanged (intentional dark)

The 30 s → dim-to-1 and 60 s → off-to-0 idle policy is unchanged. This is
*intentional* dark and is accompanied by successful writes (which are
verified, not silent). The fail-safe only kicks in on a *failure*.

## Alternatives considered

- **Panic on write failure.** Rejected: panicking drops the bar into an
  unknown state and kills the daemon; fail-safe-ON + loud log is strictly
  better for a daemon that should keep trying.
- **Retry the write forever.** Rejected for now: a tight retry loop on a
  missing device would spin. The render loop already re-runs `update`
  every 10 ms, which is a natural retry cadence; this ADR makes each
  failure visible rather than silent.
- **Drive the bar to `max_bl` on failure.** Rejected: a full-brightness
  bar on a transient glitch would be disruptive. A low-but-visible
  fail-safe level (1) is enough to distinguish "alive but degraded" from
  "dark."

## Impact list

- `src/providers/backlight.rs` — add `FAILSAFE_BRIGHTNESS` constant; on
  write/read failure reset `current_bl` to the fail-safe value; loud
  `error`-level logging on every failure (already partly done by ADR 006);
  `new` no longer panics (ADR 006) and degrades on partial read failure.
- `src/main.rs` — backlight init failure is already propagated (ADR 006);
  this ADR ensures the daemon does not proceed with a silently-dark bar.
- No trait change.

## Regression test

`src/providers/backlight.rs` tests: `test_failsafe_brightness_on_write_failure`
constructs a `SysfsBacklight` pointed at a non-existent sysfs path, calls
`set_brightness`, and asserts (a) the call returns an error and (b)
`current_bl` is the fail-safe value, not the requested value. This
verifies a dark bar can never be mistaken for success.

## References

- `docs/review-report.md` §2.6 (the FAIL being fixed)
- `docs/adr/006-typed-errors.md` (propagation mechanism this ADR builds on)