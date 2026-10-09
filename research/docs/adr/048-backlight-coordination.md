# ADR 048: Backlight coordination — `enable()` forces an adaptive tick (single owner of brightness)

## Status: Accepted

## Date: 2026-09-27

## Context

Session 043 finding (b)/Fact 3 derived read-only in
`docs/test-logs/043/findings-abc-code-derived.txt`: the enable-write of
128 (`src/providers/backlight.rs:175-199`, called at `src/main.rs:547`)
is CLOBBERED by the first adaptive `update()` tick (~10ms later,
`src/main.rs:845`) which writes 54 =
`display_to_touchbar(display_bl=90, active_brightness=128)` =
`(sqrt(90/509)*128)+1` (`src/providers/backlight.rs:159-163`). The
journal-proven enable-write of 128 is real and logged, but the adaptive
loop's first tick overwrites it with the curve output because
`current_bl(128) != new_bl(54)` so the `current_bl == new_bl` gate at
`:243` does not short-circuit, and `set_backlight_file(54)` is called at
`:249`.

This is NOT a defect — it is a ported FEATURE. The oracle
(`backup_old/tiny-dfr-mbp142/src/backlight.rs:96-101,119-146`) has the
identical `display_to_touchbar` curve and the identical `update_backlight`
loop; it does NOT have a separate `enable()` write at all (the oracle's
`BacklightManager::new` reads the current sysfs brightness at init
`:91` and the loop maintains it from there). The port added `enable()`
(ADR-043) to fix the session-033 "panel dark because no enable-write
reached the held fd" defect — a DIFFERENT problem (the write PATH was
missing, not the value). ADR-043's acceptance criterion ("+1s probe
expects 128") was correct for the write-PATH proof but is SUPERSEDED for
the maintained VALUE: the adaptive loop is the single owner of the
maintained level, and 54 is the correct display-linked level at display
brightness 90.

## Task 0 — Derivation D3 (backlight contract) — CONFIRMED

### D3a — The adaptive loop's full target computation

`SysfsBacklight::update` (`src/providers/backlight.rs:222-266`):
```rust
let since = self.last_active.elapsed().as_millis() as u64;
let new_bl = self.max_bl.min(if self.lid_closed {
    0
} else if since < BRIGHTNESS_DIM_TIMEOUT_MS {        // 30_000 (backlight.rs:17)
    if self.adaptive {                               // true (main.rs:349)
        let brightness = self.display_bl_path.as_ref()
            .and_then(|p| read_attr(p, "brightness").ok())
            .unwrap_or(self.max_bl / 2);
        Self::display_to_touchbar(brightness, self.active_brightness)
    } else { self.active_brightness }
} else if since < BRIGHTNESS_OFF_TIMEOUT_MS {        // 60_000 (backlight.rs:18)
    DIMMED_BRIGHTNESS                                // 1 (backlight.rs:19)
} else { 0 });
```

`display_to_touchbar` (`:159-163`):
```rust
fn display_to_touchbar(display: u32, active_brightness: u32) -> u32 {
    let normalized = display as f64 / MAX_DISPLAY_BRIGHTNESS as f64;  // 509 (:16)
    let adjusted = (normalized.powf(0.5) * active_brightness as f64) as u32 + 1;
    adjusted.min(MAX_TOUCH_BAR_BRIGHTNESS)                            // 255 (:15)
}
```

**Inputs:**
- `display_bl` — the main display's current sysfs `brightness`, read
  each tick from `display_bl_path` (discovered at `:65`). Falls back to
  `max_bl / 2` if the read fails (a sane mid-level default, not a
  panic).
- `active_brightness` — the curve's CEILING input (default 128, set at
  `src/main.rs:349` `SysfsBacklight::new(true, 128)`). NOT the
  maintained level — it is the multiplier the curve scales by
  `sqrt(display/509)`. Doubling `active_brightness` roughly doubles the
  touchbar level at a given display brightness (modulo the sqrt + the
  `+1` + the clamp to 255).
- The `+1` — keeps the bar from going fully dark at low display
  brightness (the curve's floor is `0 * active + 1 = 1`, visible).
  Comment in the oracle: "Add one so that the touch bar does not turn
  off" (`backup_old/tiny-dfr-mbp142/src/backlight.rs:98`).

**Idle decay schedule** (a step function, NOT a ramp —
`docs/test-logs/043/findings-abc-code-derived.txt` Fact 3c):
- `since < 30s` → `display_to_touchbar(display_bl, active_brightness)`
  (the display-linked level; ~54 at display 90, active 128).
- `30s ≤ since < 60s` → `DIMMED_BRIGHTNESS = 1` (dim but visible).
- `since ≥ 60s` → `0` (dark; a touch wakes per ADR-047).

### D3b — The coordination contract: ONE owner of brightness.

The current design has TWO writers competing on the same sysfs file:
1. `enable()` writes a raw `active_brightness` (128) once at scanout-
   begin.
2. `update()` writes the curve output (~54) every tick (~10ms).

The 128 from `enable()` survives only until the first `update()` tick
(~10ms), then is overwritten. The STEP 4b "+1s probe expects 128"
criterion (`docs/test-plan.md:416-421`) is unsatisfiable by design: the
+1s read catches the curve output (54), not the enable-write (128),
because the loop ticks at ~10ms.

**The contract this ADR lands:** the adaptive loop (`update()`) is the
SINGLE owner of the maintained brightness level. `enable()` STOPS
writing a raw value; instead it forces an immediate adaptive `update()`
tick (which writes the curve output through the held fd). The 128→54
"clobber" becomes correct behavior: the bar lights at the display-linked
level (~54 at display 90) — exactly what the oracle does (the oracle has
no `enable()`; its loop is the sole writer).

`Config::active_brightness` is documented as the curve's CEILING input
(the multiplier), NOT the maintained level. The maintained level is
`display_to_touchbar(current display_bl, active_brightness)` while
active, decaying to 1 then 0 on idle.

### D3c — The "clobber" is the ported tiny-dfr FEATURE.

`backup_old/tiny-dfr-mbp142/src/backlight.rs:96-101` (the oracle's
`display_to_touchbar`) is byte-identical to `src/providers/backlight.rs:159-163`
(the port). The oracle's `update_backlight` (`:119-146`) calls it every
loop iteration; the oracle has no separate enable-write. The touchbar-
follows-display behavior is a FEATURE of tiny-dfr-mbp142 (the upstream
project this ports from): the Touch Bar brightness tracks the main
display brightness via the sqrt curve, so the bar is readable relative
to the screen. The port's `enable()` (ADR-043) was added to fix a
DIFFERENT defect (the write PATH was missing — sysfs mtime unchanged
since boot); its raw-128 value was never the intended maintained level.
This ADR reconciles `enable()` with the loop so the write-PATH proof
(ADR-043's actual contribution) is preserved while the maintained VALUE
is the curve output.

## Decision

### 1. `enable()` forces an immediate adaptive `update()` tick (no raw write).

`SysfsBacklight::enable` (`src/providers/backlight.rs:175-199`) is
changed: instead of computing `value = active_brightness.min(max_bl)`
and writing it, it:
1. Resets `last_active = Instant::now()` (so the tick computes the
   ACTIVE branch, not the dim/off branch — the bar is "just woken" at
   scanout-begin). This matches the oracle's `new()` which starts
   `last_active = Instant::now()` (`:92`) so the first
   `update_backlight` tick is in the active branch.
2. Calls `self.update()` (the adaptive tick), which writes the curve
   output through the held fd (or per-write).
3. Logs the result at INFO: `tbard: backlight enable-tick → {curve
   output} (display_bl={d}, active_brightness={a}, adaptive={})`.

The render-path call at `src/main.rs:547` (`backlight.enable()`) is
unchanged (still called once at scanout-begin); its SEMANTICS change
from "write raw 128" to "force the adaptive tick that lights the bar at
the display-linked level". The ADR-043 write-PATH proof (the enable
write reaches the held fd) is preserved — `update()` writes through the
same held fd; the journal INFO line now reports the curve output instead
of raw 128.

### 2. `Config::active_brightness` documented as the curve's ceiling input.

`src/config/yaml.rs:63-65` (`default_brightness() -> 128`) is the
curve's CEILING input — the multiplier `sqrt(display/509) * active`. It
is NOT the maintained level. The maintained level is
`display_to_touchbar(current display_bl, active_brightness)` while
active, decaying to 1 (30s) then 0 (60s) on idle. Doubling
`active_brightness` roughly doubles the touchbar level at a given
display brightness. Documented in the config example + this ADR.

### 3. STEP 4b reframed: +1s probe expects the curve output, not raw 128.

`docs/test-plan.md` STEP 4b ("backlight write VALUE-ONLY, read within
~1s") is reframed: the +1s read expects
`display_to_touchbar(current display_bl, active_brightness)`, NOT raw
128. At display 90 + active 128, that is 54. The ADR-045 journal INFO
line changes from `backlight enable-write 128 ...` to
`backlight enable-tick → {curve output} (display_bl={d}, ...)`. The
PROOF the write fired is still the journal line + the value read; the
VALUE is now the curve output. The runbook notes the formula so the
operator can compute the expected value from the current display
brightness.

### 4. Tests: curve unit test with the 90→54 datapoint; enable→tick does not fight the loop.

- Curve unit test: `display_to_touchbar(90, 128) == 54` (the observed
  datapoint, as a fixture). Plus boundary cases: display 0 → 1 (the
  `+1` floor), display 509 → 128 (full display), active 255 → clamped
  to 255.
- `enable()` → `update()` does not fight the loop: after `enable()`,
  `current_bl` equals the curve output (NOT 128); a subsequent
  `update()` tick with no state change is a no-op (`current_bl ==
  new_bl` → short-circuit). The loop is the single owner.
- Wake restores the curve level: `notify_activity()` → `update()` writes
  the curve output (not 128).
- Idle decay still works: `since ≥ 60s` → 0.

## Alternatives considered

- **Hold the enable-write value (128) for a grace period before the
  adaptive update() may overwrite it.** Rejected (the session-043 ADR
  proposal listed this as option (a)): it introduces a second owner of
  brightness during the grace window, racing the loop. The grace period
  is arbitrary and the maintained level after it would still be 54 —
  the grace only delays the curve, it does not change the steady-state.
  The oracle has no grace period; the port should not either.
- **Make `enable()` set `last_active = now()` and write 128, then let
  the loop take over.** Rejected (the session-043 proposal's option
  (b)): this is what the port does TODAY and it is the "clobber" — the
  128 is overwritten on the first tick. Setting `last_active` is
  correct (the active branch), but writing 128 is the competing-write
  problem. This ADR keeps the `last_active` reset but DROPS the raw
  write, letting `update()` write the curve output.
- **Reframe the acceptance criterion only (no code change).** Rejected
  (the session-043 proposal's option (c)): the runbook reframe is
  necessary but NOT sufficient — the code still writes 128 then 54
  ~10ms later, which is two writes where one suffices, and the
  `current_bl(128) != new_bl(54)` gate does not short-circuit the
  second write. The code change (enable → tick) makes the behavior
  match the contract: ONE write (the curve output), no clobber.
- **Remove `enable()` entirely (the oracle has no enable).** Rejected:
  ADR-043 added `enable()` to fix the write-PATH defect (sysfs mtime
  unchanged since boot — no write reached the held fd at all). The
  render-path call at `src/main.rs:547` is the deterministic
  "lights the panel for frame 1" guarantee. Removing it would regress
  the session-033 defect: if the first `update()` tick's
  `current_bl == new_bl` coincidence re-occurs (stale sysfs read),
  the bar stays dark. `enable()` forcing a tick (with `last_active`
  reset) is the deterministic guarantee that the FIRST write reaches
  the held fd, independent of the stale-read coincidence.

## Impact list

- `src/providers/backlight.rs` — `SysfsBacklight::enable` rewritten to
  reset `last_active` + call `update()` (no raw write); the trait
  override at `:305-307` forwards unchanged; INFO log reports the curve
  output. Existing `enable()` tests updated (the value is now the curve
  output, not 128; the held-fd write still lands).
- `src/config/yaml.rs` — doc comment on `default_brightness` /
  `active_brightness` (the curve's ceiling input).
- `docs/adr/048-backlight-coordination.md` — this file (new).
- `docs/test-plan.md` — STEP 4b reframed (+1s expects curve output);
  HC2 timing note updated.
- `packaging/config.yaml.example` — comment on `active_brightness`.
- `CHANGELOG.md` — `[Unreleased — ADR-048 backlight coordination]`.
- `devlog.md` — session 044 entry (ADR-048 section).
- `docs/self-assessment-15.md` — claims C-048.

Tests (one commit, gates green):
- Curve unit test: `display_to_touchbar(90, 128) == 54` + boundaries.
- `enable()` → `update()` does not fight the loop (current_bl == curve
  output; subsequent tick is a no-op).
- Wake restores the curve level (notify_activity → update writes curve,
  not 128).
- Idle decay still works (since ≥ 60s → 0).
- Existing ADR-043 tests updated: the enable-write value is the curve
  output, not 128; the write-PATH proof (the write landed) is preserved.

## References

- `src/providers/backlight.rs:159-163` — `display_to_touchbar` (the
  curve).
- `src/providers/backlight.rs:175-199` — `enable` (the raw-128 write
  this ADR replaces with a tick).
- `src/providers/backlight.rs:222-266` — `update` (the adaptive loop,
  the single owner after this ADR).
- `src/main.rs:547` — the render-path `backlight.enable()` call.
- `src/main.rs:845` — the loop-bottom `backlight.update()` call.
- `src/config/yaml.rs:63-65` — `default_brightness() -> 128` (the
  curve's ceiling input).
- `backup_old/tiny-dfr-mbp142/src/backlight.rs:96-101,119-146` — the
  oracle's identical curve + loop (no `enable()`; the loop is the sole
  writer).
- `docs/test-logs/043/findings-abc-code-derived.txt` Fact 3 — the
  read-only audit that derived 54 = display_to_touchbar(90, 128).
- `docs/adr/043-backlight-enable-write-render-path.md` — ADR-043 (the
  write-PATH fix this ADR preserves; the value criterion this ADR
  supersedes).
- `docs/adr/046-runbook-value-only-probe.md` — the +1s value probe this
  ADR reframes (expects curve output, not 128).