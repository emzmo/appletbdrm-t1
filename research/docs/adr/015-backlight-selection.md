# ADR 015: Backlight Selection — Deterministic Touchbar Backlight (ADR-008 follow-up)

## Status: Accepted

## Date: 2026-09-25

## Context

This machine exposes TWO backlight devices in `/sys/class/backlight/`:
- `appletb_backlight` (driver `hid-appletb-bl`, the Touch Bar backlight),
- `intel_backlight` (the main laptop display backlight).

The hazard: a `BacklightProvider` that picks "the first backlight in
sysfs" could dim/write the **laptop's main screen** by mistake — a
serious user-visible regression distinct from the Touch Bar going dark.

The current `discover_backlight_path()` (`src/providers/mod.rs:296-309`)
already matches `appletb_backlight` by name substring (not first-in-sysfs),
mirroring the oracle (`backup_old/tiny-dfr-mbp142/src/backlight.rs:30-44`).
ADR-008 added the fail-safe-ON policy. This ADR hardens the *selection*
with a driver/device-name match + a unit test that fakes a two-backlight
sysfs and asserts the touchbar one is chosen, so a future regression to
first-in-sysfs is caught.

## Decision

### 1. Deterministic touchbar backlight selection

`discover_backlight_path()` keeps its name-match against
`["appletb_backlight", "display-pipe", "228600000.dsi.0"]` (the Touch Bar
backlight device names across T1/T2/Apple Silicon). It MUST NOT return
`intel_backlight`, `acpi_video0`, `gmux_backlight`, or `apple-panel-bl`
(those are main-display backlights, handled by
`discover_display_backlight_path()` for the adaptive-brightness follower).

Add a guard: if `discover_backlight_path()` would return a path whose
name matches a known main-display backlight, it bails with a typed error
instead. This is a belt-and-suspenders check against a future edit that
conflates the two lists.

### 2. Unit test with a fake two-backlight sysfs

A unit test fakes `/sys/class/backlight/` containing both
`appletb_backlight` and `intel_backlight` (via a tempdir + a test-only
selection function that takes a directory), and asserts the touchbar one
is selected. Marked SIMULATED — the real hazard is dimming the laptop
screen, which the test guards against without touching real sysfs.

To make the selection testable without monkey-patching `/sys`, extract the
selection logic into a pure function `select_touchbar_backlight_path(dir:
&Path) -> Result<PathBuf, HwError>` that `discover_backlight_path()` calls
with `/sys/class/backlight/`. The test calls it with a tempdir.

## Alternatives considered

- **Match by driver (`hid-appletb-bl`) via sysfs `device/driver` symlink.**
  More robust than name match but heavier (extra sysfs reads + symlink
  resolution). The name match is what the oracle uses and is sufficient
  given the belt-and-suspenders guard. Not adopted now; a future ADR may
  add driver matching if name variance grows.
- **First-in-sysfs + filter.** Rejected: the hazard IS first-in-sysfs.

## Impact list

- `src/providers/mod.rs` — extract `select_touchbar_backlight_path(dir)`
  pure function; `discover_backlight_path()` calls it with
  `/sys/class/backlight/`. Add the main-display-name guard.
- No trait change. No behavior change on this bench (already selects
  `appletb_backlight`).

## Regression test

`src/providers/mod.rs` tests: `test_select_touchbar_backlight_ignores_intel`
fakes a tempdir with `appletb_backlight/` + `intel_backlight/` and asserts
`select_touchbar_backlight_path` returns the `appletb_backlight` path.
Marked SIMULATED. Also `test_select_touchbar_backlight_bails_on_no_match`
asserts an `Err` when neither is present.

## References

- `docs/test-logs/004-service-oracle/oracle-runtime.txt` — fd 5 is
  `appletb_backlight/brightness`, never `intel_backlight`
- `backup_old/tiny-dfr-mbp142/src/backlight.rs:30-44` — oracle selection
- `docs/adr/008-backlight-failsafe.md` — the fail-safe policy this builds on