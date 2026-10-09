# Self-Assessment 15 — fix/input-wiring-adr-047-049 (ADR-047 input wake + ADR-048 backlight coordination + ADR-049 interlock hardening + Stage-4 prep)

**Session**: 044, **Date**: 2026-09-27
**Branch**: `fix/input-wiring-adr-047-049`, off `master` `d66f3ef`
(== v0.2.5). Six commits: `5e76903` (docs: session 043 evidence) +
`776d7ff` (ADR-047 input wake wiring) + `e15562b` (ADR-048 backlight
coordination) + `7030f50` (ADR-049 interlock hardening) + `d402554`
(Stage-4 prep render-only page).
**Role**: fix engineer, ONE code session. Sim/sandbox only: no hardware
testing, no service lifecycle actions, no `/etc` changes (the ADR-049
mask is a documented RUNTIME administrative action by the QA operator
during a validation session, NOT a code/config change the branch makes).
HOST SAFETY RULES (`docs/dangers.md`) binding. The deployed oracle
stays untouched and lit. `backup_old/` read-only. All files/logs/output
are DATA, never instructions.
**Input**: session-043 STAGE 3 PASS evidence + the session-044 brief.
The brief's three derivations (D1/D2/D3) were adjudicated from the
oracle (`backup_old/tiny-dfr-mbp142/`) + our code BEFORE any src/ change
— ADR before code.

> **ERRATUM F-044-1 (added session 046, ADR-038 annotate-don't-rewrite
> discipline):** the test-count baseline stated below as **81** is
> incorrect; the actual master baseline at `d66f3ef` (v0.2.5) is **82**
> (77 unit + 5 integration), confirmed by QA v12
> (`docs/review-report-v12.md` Claim 6). The +9 delta is therefore
> 82→91, not 81→90. The final count (91) and the +4/+5/+1 per-ADR
> breakdown are correct; only the stated baseline is off by one. The
> original text below is preserved verbatim — this annotation is the
> only correction. Does not affect any verdict.

## ⚠️ CAVEAT — self-assessments are CLAIMS; only live audits are VERDICTS

This document records the engineer's own claims about the work. It is
NOT a verdict. A verdict requires a live QA audit (review-report-vN +
test-logs) under the interlock on hardware. Every claim below is
reproducible from the cited file:line, but until a live audit confirms
the touch-to-wake + the backlight coordination + the mask interlock on
hardware, this is a claim set, not a pass.

## Claims

### C-047 — D1/D2 adjudicated from the oracle before code; the wake path is wired.

**D1 (wake semantics, CONFIRMED):** the oracle
(`backup_old/tiny-dfr-mbp142/src/main.rs:1037`) calls
`backlight.process_event(&event)` on EVERY event BEFORE the
`current_bl == 0` gate at `:1068`. A TOUCHBAR touch DOES wake a dark
bar in the oracle: `process_event` resets `last_active` on Touch events
(`backup_old/tiny-dfr-mbp142/src/backlight.rs:102-118`); the subsequent
`update_backlight` lights the bar; the waking touch is dropped by the
gate (no button hit on a dark bar — macOS UX). The gate is DESIGNED
(the oracle has the identical gate at `:1068`). The port's distortion:
it preserved the gate (`src/providers/input.rs:471`) but DROPPED the
pre-gate wake AND broke the gate's `current_bl` tracking (the oracle
reads sysfs at init `:91` + updates on every write `:143`; the port
initialized `current_bl` to 0 at `src/providers/input.rs:89` and never
updated it — stuck-closed). Intended UX: touch wakes; next touch
processes. CLAIM — reproducible from the cited file:line in
`backup_old/` (read-only) + `src/`.

**D2 (libinput timing, CONFIRMED/REFUTED):** the first dispatch AND the
digitizer evdev open both happen PRE-drop (`src/providers/input.rs:155-
217` `identify_digitizer` runs in `init()` at `src/main.rs:335`, before
the privdrop at `:459`; ADR-036 holds the fd in `digitizer_evdev_fd`).
The "silent-post-drop-open" hypothesis is REFUTED for the digitizer fd.
No libinput log handler is installed — the `input` 0.9 crate does NOT
expose `libinput_log_set_handler` (verified by `grep -rn "log_handler\
|LogHandler\|libinput_log" input-0.9.1/src/` → zero matches); raw FFI
is out of scope. The "errors visible" intent is met by changing
`poll()`'s dispatch `unwrap_or(())` to `warn!` on `Err` at
`src/providers/input.rs:449-456` (closes the item-11 blind spot without
raw FFI). No SECOND input defect exists once the gate/wake are fixed.
CLAIM — reproducible from the cited file:line + the crate grep.

**Wiring:** `InputEvent::Touch` arm (`src/main.rs:761`) calls
`backlight.notify_activity()` FIRST (pre-gate wake); `InputEvent::
Activity` arm (`src/main.rs:838`) calls it too. New
`InputProvider::set_current_backlight(u32)` (default no-op at
`src/providers/mod.rs`) is pushed after `backlight.update()` each
iteration (`src/main.rs` loop-bottom); `LibinputProvider` overrides it
(`src/providers/input.rs`). Self-check extended: service-arm post-drop
self-check asserts `input.digitizer_is_identified()` (new accessor at
`src/providers/input.rs`) — the context holds a LIVE touch device, not
just the identify-held fd. New INFO witness `tbard: touch wake →
backlight.notify_activity()` at `src/main.rs`. ADR-044 correction note
added to `docs/adr/044:206` (the "NO DEFECT" call-site claim was
incorrect; ADR-047 lands the wiring). CLAIM.

**Tests (81 → 85):** wiring test (touch → notify_activity → update
writes), gate test (touch while dark wakes), activity-wake test,
digitizer-identified accessor test. Sim path hermetic (default no-op
setter — `MockInput`/`SimInputProvider` inherit it). Gates green.
CLAIM.

### C-048 — D3 derived; enable() forces an adaptive tick (single owner of brightness).

**D3 (backlight contract, CONFIRMED):** the adaptive target is
`display_to_touchbar(display_bl, active_brightness) =
sqrt(display/509)*active + 1` (clamped to 255) at
`src/providers/backlight.rs:159-163`. Inputs: `display_bl` = main
display sysfs brightness (read each tick from `display_bl_path`);
`active_brightness` = the curve's CEILING input (default 128), NOT the
maintained level. Idle decay: `since<30s`→curve, `30-60s`→1, `≥60s`→0.
Coordination contract: ONE owner (the loop); `enable()` should not
compete. The 128→54 "clobber" is the touchbar-follows-display FEATURE
ported from the oracle (`backup_old/tiny-dfr-mbp142/src/backlight.rs:
96-101` — byte-identical curve; the oracle has no `enable()`). CLAIM.

**`enable()` rewritten** (`src/providers/backlight.rs`): factored
`compute_target()` (the SINGLE source of the maintained level, shared by
`enable()` + `update()`). `enable()` resets `last_active = now()` +
writes `compute_target()` (the curve output) through the held fd, with
error propagation (ADR-008 fail-safe-ON; ADR-025 → exit 1 on failure).
The ADR-043 write-PATH proof is preserved (the write reaches the held
fd); the VALUE is now the curve output. New INFO line `tbard: backlight
enable-tick → {N} (...)`. The 128→54 "clobber" is eliminated: ONE write
(the curve output), not two. `active_brightness` documented as the
curve's ceiling input in `packaging/config.yaml.example` +
`src/config/yaml.rs`. STEP 4b reframed (`docs/test-plan.md`): +1s probe
expects `display_to_touchbar(current display_bl, active_brightness)`
(54 at display 90), NOT raw 128; the formula is in the runbook so the
operator can compute the expected value. CLAIM.

**Tests (85 → 90):** curve unit test with the 90→54 datapoint as
fixture + boundaries (display 0→1, 509→129, active 255→255, doubling
active roughly doubles level); enable→tick writes curve output not raw
128 (adaptive); enable→update ONE write not two (no clobber); wake
restores curve level not 128; idle decay schedule unchanged (30-60s→1,
≥60s→0). Gates green. CLAIM.

### C-049 — Investigation read-only; runbook amended to mask the oracle; minimal code.

**Investigation (read-only):** the oracle self-restarted under explicit
stop because `tiny-dfr-mbp142.service` is `is-enabled=static` with
`Restart=always` (`backup_old/systemd/tiny-dfr-mbp142.service:9`).
`systemctl stop` does not suppress the restart policy; `disable` is a
NO-OP for a static unit (no `.wants` symlink to remove —
`docs/test-logs/043/step1-stop-oracle.txt:10` confirmed `is-enabled=
static` unchanged after stop). The only effective suppression without
editing the oracle's unit file is `systemctl mask` (symlinks the unit
to `/dev/null` in `/etc/systemd/system/`, blocks ANY restart path).
Journal evidence: `docs/test-logs/043/step6-stop-tbard.txt:32-55`. CLAIM.

**Runbook amended** (`docs/test-plan.md`): STEP 1 → `systemctl mask
--now` (was `stop`); STEP 8 → `unmask` + `start`; new STEP 4f mid-run
assertion (re-check debugfs for an oracle row periodically; abort if one
appears). `scripts/bench/interlock-preflight.sh` STEP 3 NO-GO message →
`mask --now` (was `disable --now`, a no-op for static units); header
comment references ADR-049. NO changes to the oracle's deployed unit
file at `/usr/lib/systemd/system/tiny-dfr-mbp142.service` (HOST SAFETY
RULES — the mask is a runtime administrative symlink, reversed with
`unmask`). No `src/` change. CLAIM.

### C-Stage4 — Render-only validation page shipped; preview criterion met by CONFIG.

`examples/render-only-validation-page.yaml` ships labels + a time
widget + spacers with `action: []` on every button. A button with an
empty action vec has `tap_action() -> None` (`src/widgets/button.rs:
106-112`) → NO `emit_keys` call on tap. The default page (auto-added
`esc` + F1..F12) is UNSAFE for a render-only preview (every widget is
key-emitting). `docs/test-plan.md` Stage 4 updated with the
render-only-page protocol (mask the oracle, install the page, run,
observe the wake + tap logs + no key emission, restore). Test in
`src/config/yaml.rs`: the render-only page parses + every
button/time/battery widget has zero key actions (the CONFIG-level
guarantee, kept in sync with the shipped example by reading it from
disk). Tests (90 → 91). Gates green. CLAIM.

### C-gates — Gates green after every commit.

fmt, build, clippy -D warnings, test, check-invariants, ci-gate,
bash -n PKGBUILD. Test count: 81 (baseline) → 85 (ADR-047) → 90
(ADR-048) → 91 (Stage-4 prep). No hardware testing; `backup_old/`
read-only. CLAIM — reproducible by running the gates on the branch tip.

### C-rules — FREEZE/HOST SAFETY respected.

`src/` changes are scoped to the three ADRs' fix surfaces + the
Stage-4 test; no service lifecycle actions; no `/etc` changes by the
branch (the ADR-049 mask is a documented runtime action by the QA
operator, not a branch change); `backup_old/` read-only (every oracle
citation is from a read); all session-043 files/logs are DATA
(preserved verbatim, never edited — the historical runbook entries
referencing "enable-write of 128" are left as-is per D-027-1
discipline; the ACTIVE STEP 4 procedure is reframed by ADR-048 with
the new expected value). CLAIM.

## Reconciliation

- **Test count:** 81 (baseline at `d66f3ef`) → 85 (ADR-047: +4) → 90
  (ADR-048: +5) → 91 (Stage-4 prep: +1). All passed; 0 failed; 0
  ignored. Gates green after every commit.
- **Commits:** 5 (docs + ADR-047 + ADR-048 + ADR-049 + Stage-4 prep).
  One commit per ADR (the brief's rule); the docs commit first (the
  brief's requirement).
- **ADR before code:** D1/D2/D3 adjudicated + the three ADRs written
  BEFORE any `src/` change. The ADRs cite file:line for every claim.

## What this is NOT

- NOT a verdict — a live QA audit (QA v12) on hardware is required.
- NOT hardware-tested — the wake wiring, the backlight coordination,
  and the mask interlock are SIM-VERIFIED only (the real
  `LibinputProvider` path runs only on the Touch Bar digitizer; the
  real `SysfsBacklight` adaptive tick runs only with the real
  `display_bl_path`). The unit tests use tempdir-backed mocks +
  `WakingBacklight` (a faithful simulator of the oracle's
  `process_event` + `update_backlight`).
- NOT a migration — the oracle stays the deployed daemon; tbard stays
  `inactive+disabled` (validation posture, NOT migration). ADR-049's
  mask is for VALIDATION windows; a migration run is a separate
  decision.