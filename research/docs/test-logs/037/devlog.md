# Devlog — session 037 (Stage-3 attempt #4, 2026-09-26)

**Goal:** render-only hardware validation attempt #4 under the Stage-3
interlock. This run owed ONLY acceptance item 9 (backlight write — the
two-candidate mechanism's empirical closure) and item 4 (first pixels,
via HC2). The other nine items were pre-verified in attempt #3 (s033).

**Headline: ABORTED at STEP 5 (dark bar). Root cause isolated to a
one-line code-level trait-dispatch defect (ADR-043 enable-write is dead
code). Lifecycle contract re-verified. Oracle restored. FREEZE intact.**

## What happened (timeline)

- P1 baseline clean: HEAD `ccd7024` == `v0.2.4`; oracle sole master
  (name+uid, tgid 146352); 25 /dev/input nodes; `appletb_backlight`
  54/255 mtime boot+7s; tbard disabled+inactive.
- HC1: "All three confirmed" (Esc fallback + Esc-on-bar + recovery.md).
- STEP 1: oracle stopped, stays inactive +10s; touchbar card empty.
- STEP 2: preflight GO (exit 0); STEP 0 a–f PASS; probe ACCEPTS event7.
- STEP 3: `systemctl start tbard.service` → active, PID 237628. ZERO
  application journal lines (env_logger default `error` + no RUST_LOG →
  INFO suppressed; stdout/stderr ARE wired to journald — verified).
- STEP 4a: tbard sole master on dev 2, uid 65534 (real privdrop); eDP
  unaffected; /dev/input unchanged; no dmesg delta.
- STEP 4b DECISIVE: `appletb_backlight/brightness` = 0 (expect 128),
  mtime unchanged from baseline. Render-to-plane SUCCEEDED (fb 41 tbard
  64×2170 XR24 on plane-0, crtc-0 active) — panel dark ONLY because
  backlight=0. tbard HOLDS fd 23 → brightness sysfs (pre-drop, w-only).
  **Item 9 FAILS.**
- STEP 5 / HC2: "Dark / no pixels". **Item 4 FAILS.**
- STEP 6: SIGTERM → exit 0 (`ExecMainCode=0`, `Result=success`);
  debugfs empty (RAII release). Success-path release ×1 (×3 total).
- STEP 7: SKIPPED — deterministic code-level failure; rerun can't
  change the outcome.
- STEP 8: oracle restored (active+static, sole master, tgid 241900);
  bar relit (value 0→54, fb re-allocated by tiny-dfr-mbp142).
- STEP 8 / HC3: "Both confirmed" (oracle F-row + Esc). Window CLOSED.
- STEP 9: tbard disabled+inactive; oracle active+static; FREEZE intact.

## The defect (read-only source analysis; NO fix on the air)

ADR-043 enable-write is dead code via trait-default dispatch:

- `BacklightProvider::enable()` default = no-op `Ok(())`
  (`src/providers/mod.rs:120-122`).
- `SysfsBacklight` has an inherent `enable()` (`backlight.rs:175`) that
  does the actual write of `active_brightness.min(max_bl)` = 128 via
  the held fd.
- `impl BacklightProvider for SysfsBacklight` (`backlight.rs:269`)
  overrides `update`/`notify_activity`/`set_lid_closed`/etc. but NOT
  `enable()`.
- `real_main` is generic over `B: BacklightProvider` (`main.rs:502`);
  `backlight.enable()` (`main.rs:547`) dispatches through the trait →
  the no-op default, never the inherent method.
- The inherent method's unit tests (`backlight.rs:379-508`) call on a
  CONCRETE type → exercise the inherent method → PASS, masking the gap.
  The integration test (`main.rs:1435`) wraps in `RecordingBacklight<B>`
  whose `enable()` forwards to `self.inner.update()`, not
  `self.inner.enable()` → also misses it.

Dark-panel chain: `SysfsBacklight::new` reads sysfs brightness=54 at
construction → `current_bl=54`. `enable()` no-op → `current_bl` stays
54. `update()` every 10ms computes `new_bl = display_to_touchbar(90,
128)` with `MAX_DISPLAY_BRIGHTNESS=509` → `sqrt(90/509)*128+1` ≈ 54 →
`new_bl == current_bl` → `update()` no-op via the
`current_bl == new_bl` gate (`backlight.rs:243`). No write ever
happens. This is EXACTLY the session-033 stale-read coincidence ADR-043
was designed to break — but ADR-043's breaker is inert.

## Methodology discovery (important for future runs)

The appletbdrm `brightness` sysfs file does NOT update mtime on writes.
The oracle's STEP-8 restore lit the bar (value 0→54, fb re-allocated)
WITHOUT moving mtime off boot+7s. So:

- The runbook's "mtime moved since boot" criterion is structurally
  unsatisfiable on this driver (by EITHER daemon).
- The VALUE probe is reliable (tbard: value=0 dark; oracle: value=54
  lit). Use value, not mtime.
- Attempt #3's "mtime unchanged" evidence is reinterpreted: consistent
  with both "no write" and "write that didn't move mtime"; #3's "no
  effective write lit the panel" conclusion stands (panel was dark,
  value would have read 0), but the mtime reasoning is discounted.

## ADR proposals (for a future branch; NOT on the air)

- **ADR-044**: ADR-043 enable-write must override the
  `BacklightProvider` trait method. One-line fix:
  `fn enable(&mut self) -> anyhow::Result<()> { SysfsBacklight::enable(self) }`
  in `impl BacklightProvider for SysfsBacklight` (`backlight.rs:269`).
  Regression guard: a trait-object (`&mut dyn BacklightProvider`) test
  that asserts the write occurred.
- **ADR-045**: `Environment=RUST_LOG=info` in `tbard.service` so the
  boot sequence + enable-write line are observable in the journal.
- **ADR-046**: revise STEP 4b — drop the mtime probe (structurally
  invalid on appletbdrm), keep the value probe (value > 0 AND matches
  the expected `active_brightness` clamp).

## Acceptance items (full board)

Nine pre-verified (s033) + this run's item 9 (FAIL) + item 4 (FAIL):

| # | item | this run |
|---|------|----------|
| 1 | real acquire | VERIFIED |
| 2 | real privdrop 65534 | VERIFIED |
| 3 | post-drop self-check | VERIFIED |
| 4 | first pixels (HC2) | **NOT MET** ("Dark / no pixels") |
| 5 | SIGTERM → exit 0 | VERIFIED ×1 |
| 6 | RAII release success-path | VERIFIED ×1 (×3 total) |
| 7 | immediate rerun | SKIPPED (deterministic failure) |
| 8 | preflight GO | VERIFIED |
| 9 | backlight write via held fd | **NOT MET** (value=0; enable no-op) |
| 10 | digitizer identify runtime | VERIFIED |
| 11 | no open_restricted post-drop | VERIFIED |

## Final state

tbard disabled+inactive (validation, NOT migration); oracle active+
static, sole master (name+uid); bar lit (value=54, F-row, Esc works —
HC3). FREEZE intact (only `docs/test-logs/036/` swept + `docs/test-logs/037/`
+ docs commits; no `src/` changes).

## Next

After ADR-044 (+045/046) lands on a branch, merges, and `/usr/bin/tbard`
is reinstalled from the tip, re-run Stage 3 from P1. The interlock
protocol is reusable verbatim. The fix is a one-line trait-override +
a trait-object regression test. The re-run owes only items 4 + 9 — the
same two items this run owed, now with a sharp root cause.