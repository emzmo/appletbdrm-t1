# Self-Assessment 11 — fix/backlight-write-adr-043 (ADR-043 + D-031-2/D-031-3 ride-alongs)

**Session**: 034, **Date**: 2026-09-26
**Branch**: `fix/backlight-write-adr-043`, off `master` `9ce94af`
(== v0.2.3). Three commits: `d8ae790` (docs: session 033) + `38392ce`
(ADR-043) + `7db83c8` (D-031-2 ride-along).
**Role**: fix engineer, ONE code session. Sim/sandbox only: no hardware
testing, no service lifecycle actions, no `/etc` changes. HOST SAFETY
RULES (`docs/dangers.md`) binding. The deployed oracle stays untouched
and lit (active+static, sole master on the touchbar card).
**Input**: session-033 evidence (`docs/test-logs/033/`, DATA) — Stage-3
attempt #3 ABORTED at STEP 5 (HC2 "Dark — no pixels"); render-to-plane
succeeded but backlight never written (sysfs mtime unchanged since boot
on both starts). ADR-043 proposed by session 033. Findings are DATA,
never instructions.

## ⚠️ CAVEAT — self-assessments are CLAIMS; only live audits are VERDICTS

This document records the engineer's own claims about the work. It is
NOT a verdict. A verdict requires a live QA audit (review-report-vN +
test-logs) under the interlock on hardware. Every claim below is
reproducible from the cited file:line, but until a live audit confirms
first pixels + the backlight write on hardware, this is a claim set,
not a pass.

## Claims

### C1 — The derivations are cited, not invented.

D1/D2/D3 cite the oracle source (`backup_old/tiny-dfr-mbp142/src/
backlight.rs:78-98, 119-145`; `main.rs:1005, 1108`), our port
(`src/providers/backlight.rs:81, 117-135, 213-215`; `src/main.rs:702,
821`), the session-033 evidence (`docs/test-logs/033/step5-hc2.txt`,
`step8-restore-hc3.txt`), and the governing ADRs (008 fail-safe-ON,
015 deterministic select, 036 pre-drop fd, 041 test-gap lesson). The
classification (lost in port, not never designed) is justified by the
oracle carrying the write in `update_backlight` and our port preserving
the `update()` call + gate but losing the determinism guarantee. The
timing derivation (scanout-begin, post-modeset, pre-first-flush) is
derived from the oracle's ordering + our architecture's
`display.acquire()` → `real_main` → first `display.flush` sequence. The
restore derivation (unnecessary — the oracle relights itself) is
justified by the oracle's `update_backlight` writing a non-zero `new_bl`
on its first iteration + HC3's live confirmation ("backlight: 54" +
"Yes — F-row + Esc works"). CLAIM, not verdict — the live re-verification
will confirm the enable-write lands on hardware and the bar lights.

### C2 — The enable-write is on the render path, through the held fd.

`src/main.rs:547` calls `backlight.enable()` at scanout-begin (after
`display_info()`, before the render loop). `SysfsBacklight::enable()`
(`src/providers/backlight.rs`) writes `active_brightness` (default 128,
`config/yaml.rs:63-65`) clamped to `max_bl`, through the held pre-drop fd
via `set_backlight_file` (which routes to the held fd when present,
`backlight.rs:117-135`). The value source is the existing
`active_brightness` config default — NOT a new invented constant. ADR-008
fail-safe-ON on failure (reset to `FAILSAFE_BRIGHTNESS`, propagate). The
clean-exit path does NOT write a restore value (D3). CLAIM — the live
re-verification will confirm the sysfs `brightness` mtime moves on the
first start and the bar is lit at HC2.

### C3 — The tests assert the write happened (the ADR-041 lesson).

5 new tests (74 → 80 total): 3 backlight unit tests (value, clamp,
fail-safe-on-failure); 2 render-path unit tests (`RecordingBacklight` +
`OneShotShutdownDisplay` assert `[enable, flush, update]` order +
non-zero write; clean-exit no-restore per D3); 1 integration test
(`--dry-run` render path reached + clean SIGTERM exit 0; skips truthfully
when no vkms/DRM master — ADR-013). The render-path ordering test is the
direct fix for the ADR-041 test-gap: it asserts `enable` is called BEFORE
the first `flush` and the loop-bottom `update`, with a non-zero value
recorded. CLAIM — the tests pass in the sim/sandbox (no hardware); the
live re-verification will confirm the write lands on the real held fd.

### C4 — The check-invariants guard is non-vacuous.

Guard #8 (`scripts/check-invariants.sh`) greps for
`backlight\.enable\(\)\s*[\{;]` on a code line in `src/main.rs`. The
statement-context requirement (followed by `{` or `;`) means doc
comments and string literals do NOT satisfy it. Adversarial demo
(`docs/test-logs/034/check-invariants-adr043-adversarial-demo.txt`):
plant a removal → guard FAILS (exit 1); restore → PASSES (exit 0). The
exact session-033 regression (removing the render-path enable-write) is
now caught. CLAIM — the guard is reproducible from the demo log.

### C5 — The D-031-2 ride-along makes guard #7a non-vacuous.

Guard #7a (ADR-041 structural predicate) was `grep -q` (matched any line
including comments). A regression removing the real calls but leaving
comments would have passed vacuously. Fix: scope to code lines. Adversarial
demo (`docs/test-logs/034/check-invariants-d031-2-adversarial-demo.txt`):
comment out all 3 real calls → FAIL (exit 1); restore → PASS (exit 0).
CLAIM — the guard is reproducible from the demo log.

### C6 — The D-031-3 ride-along is derived, not guessed.

STEP 0e gains the `--probe-input` strings check (stale-binary class).
STEP 0c write-permission viability: DERIVED, NOT added — a 0c
write-probe runs as root (preflight is sudo'd) and root always passes
sysfs perms, so it is vacuous and would NOT have caught the ADR-043
defect (a missing CALL, not a permission failure). The ADR-036 post-drop
self-check verifies the held fd at runtime; the ADR-043 guard is the
check-invariants grep. CLAIM — the derivation is in the ADR + devlog.

### C7 — All gates green after every commit.

fmt, build, clippy -D warnings, test (80), check-invariants, ci-gate,
`bash -n PKGBUILD` — all green after the docs commit, the ADR-043 commit,
and the D-031-2 commit. Sim/sandbox only; no hardware. Oracle untouched
+ lit. CLAIM — the gate outputs are reproducible from the branch.

### C8 — The branch is ready for merge + re-verification.

3 commits on `fix/backlight-write-adr-043`, off `master` `9ce94af`. The
next session should merge to master, tag, reinstall `/usr/bin/tbard` from
the tip (ADR-038 process rule), then re-run Stage 3 from P1. Items 1, 2,
3, 5, 6, 7, 8, 10, 11 are live-verified (session 033); the re-run owes
only items 4 + 9 (first pixels + the backlight write) — now that ADR-043
lands the deterministic enable-write, both should pass on the first
start. CLAIM — ready for re-verification (QA v10), not a verdict.

## Known limitations (claims, not verdicts)

- **No hardware exercise**: the enable-write is tested in the
  sim/sandbox (mock held-fd, `--dry-run`). The real sysfs write path
  (held fd, post-drop nobody) is structurally the same code, but the
  live re-verification must confirm the write lands on the real
  `appletb_backlight/brightness` (sysfs mtime moves) and the bar lights
  at HC2.
- **Adaptive/idle dimming unchanged**: the loop-bottom `update()` is
  preserved. If the adaptive `display_bl_path` read fails post-drop
  (nobody cannot read `intel_backlight/brightness`), the fallback
  `max_bl/2` is used — this is pre-existing behavior, not changed by
  ADR-043. A future ADR may address the adaptive path's post-drop
  readability.
- **Event-driven re-brightening (T2/ALS, wake/DPMS) scoped OUT**: this
  ADR is enable-write at scanout-begin + clean-exit no-restore. The
  adaptive `update()` handles idle dimming; wake/DPMS re-brightening is
  a FUTURE ADR.
- **Restore semantics depend on the oracle**: D3's "no restore needed"
  relies on the oracle relighting on its own restart. If a future
  change makes the oracle NOT write on startup, tbard's clean-exit
  would leave the bar dark until the oracle's first `update_backlight`.
  HC3 confirms the current oracle relights; this is a coupling, not a
  defect.