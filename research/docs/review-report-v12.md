# QA Review v12 — fix/input-wiring-adr-047-049 (re-verification)

**Branch:** `fix/input-wiring-adr-047-049`
**Base:** `d66f3ef` (== v0.2.5 tag)
**HEAD:** `6f10ca3`
**Date:** 2026-09-27
**Role:** QA & reliability engineer (FOCUSED re-verification v12)
**Scope:** ADR-047 / ADR-048 / ADR-049 + Stage-4 prep
**FREEZE RULE:** no source changes, findings only. CONFIRMED: working tree
clean at start and end; all adversarial edits reverted; throwaway copies
deleted.

**Host safety:** oracle (`tiny-dfr-mbp142.service`) stayed ACTIVE + sole
master throughout (uid 65534); no service lifecycle actions taken; no
`/etc` changes; `/dev/input` + `/dev/dri` unchanged; `/usr/bin/tbard`
remains v0.2.5 (`90daf3d6…`). See
`docs/test-logs/044/fix-report/host-state-record.txt`.

---

## Per-claim verdicts

### Claim 1 — D1/ADR-047 wiring — **VERIFIED**

- **`InputEvent::Touch` arm calls `backlight.notify_activity()` BEFORE
  the gesture handler (pre-gate equivalent).** `src/main.rs:797`
  (`backlight.notify_activity();`) precedes the `for contact in contacts`
  loop at `:799`. The `current_bl == 0` gate lives in
  `LibinputProvider::poll` at `src/providers/input.rs:504` — it runs
  BEFORE the `InputEvent::Touch` is even emitted, so the render-loop wake
  at `:797` is pre-gate RELATIVE to the gate's effect on the NEXT poll.
  The oracle's pre-gate pattern (`backup_old/tiny-dfr-mbp142/src/main.rs:1037`
  `process_event` before the gate at `:1068`;
  `backup_old/tiny-dfr-mbp142/src/backlight.rs:102-118`) is faithfully
  mirrored: the oracle wakes on the raw `Event` before the gate; the port
  wakes on the `InputEvent::Touch` before the gesture handler (the gate
  already ran in `poll`). The ordering is semantically equivalent.
- **`InputProvider::set_current_backlight` default no-op; `LibinputProvider`
  overrides.** `src/providers/mod.rs:79-87` (default `{}`); `src/providers/input.rs:569-571`
  (`self.current_bl = bl`). Pushed after `backlight.update()` each
  iteration at `src/main.rs:898` (`input.set_current_backlight(backlight.brightness())`).
  This is the stuck-closed gate fix: after the wake's `update()` lights the
  bar, the push opens the gate for the next touch.
- **`poll()` dispatch `Err → warn!`.** `src/providers/input.rs:471-477`
  (both `tb_input` and `main_input` dispatch errors logged at `warn!`).
  Visible at INFO+ (ADR-045's `RUST_LOG=info`).
- **Self-check: `digitizer_is_identified()` post-drop assertion.**
  `src/main.rs:476-498` — the service-arm post-drop self-check asserts
  `input.digitizer_is_identified()` is `true`; failure → exit 1 with a
  typed error. Accessor at `src/providers/input.rs:315-322`.

### Claim 2 — D2 adjudication — **VERIFIED**

- **`identify_digitizer` + first dispatch run PRE-drop.** `src/main.rs:335`
  (`input.init()`) runs BEFORE privdrop at `src/main.rs:459`.
  `init()` (`src/providers/input.rs:429-444`) calls `dispatch()` +
  `identify_digitizer()` (`src/providers/input.rs:155-217`) — all pre-drop.
  The digitizer evdev fd is opened read-only pre-drop at `:175-182` and
  held for the daemon's lifetime (`:203`). The post-drop-open hypothesis
  is **DEAD** (refuted by ADR-036's held-fd pattern).
- **`warn!`-on-Err mitigation in place.** See Claim 1 (poll dispatch).
- **Refutation (no log-set API in input-0.9.1) documented honestly.**
  ADR-047 D2b (`docs/adr/047-wire-touch-to-backlight-wake.md:176-199`)
  documents that the `input` 0.9 crate does not expose
  `libinput_log_set_handler`; the `warn!`-on-dispatch-Err closes the
  "errors visible" intent without raw FFI. Honest.

### Claim 3 — D3/ADR-048 — **VERIFIED**

- **`compute_target()` is the SINGLE source shared by `enable()` +
  `update()`.** `src/providers/backlight.rs:165-188` (`compute_target`);
  `enable()` at `:202` calls `self.compute_target()`; `update()` at `:283`
  calls `self.compute_target()`. No competing write path — the raw-128
  write of ADR-043 is gone (the old `let value =
  self.active_brightness.min(self.max_bl)` is replaced by `let value =
  self.compute_target()`).
- **`enable()` writes the curve output (display_to_touchbar), resets
  `last_active`.** `src/providers/backlight.rs:199` (`self.last_active =
  Instant::now()`) then `:200` (`let value = self.compute_target()`).
  The 128→54 clobber is structurally impossible: `enable()` and `update()`
  compute the SAME target from the SAME state (`last_active` just reset →
  active branch → `display_to_touchbar(display_bl, active_brightness)`).
  One write path, one value.
- **Curve: `sqrt(display/509)*active+1`, byte-identical to the oracle.**
  Port `src/providers/backlight.rs:159-163`; oracle
  `backup_old/tiny-dfr-mbp142/src/backlight.rs:96-101`. Both:
  `(normalized.powf(0.5) * active_brightness as f64) as u32 + 1` clamped
  to `MAX_TOUCH_BAR_BRIGHTNESS` (255). The oracle's comment "Add one so
  that the touch bar does not turn off" is preserved in the ADR.
  Datapoint verified by test: `display_to_touchbar(90, 128) == 54`
  (`test_adr048_display_to_touchbar_curve_90_to_54_datapoint`).
- **Idle schedule: `<30s` curve, `30-60s → 1`, `≥60s → 0`.**
  `compute_target` `:168-187`: `since < BRIGHTNESS_DIM_TIMEOUT_MS`
  (30_000) → curve; `since < BRIGHTNESS_OFF_TIMEOUT_MS` (60_000) →
  `DIMMED_BRIGHTNESS` (1); else 0. Verified by
  `test_adr048_idle_decay_schedule_unchanged`.
- **STEP 4b reframed.** `docs/test-plan.md:368-386`: +1s probe expects
  `display_to_touchbar(current display_bl, active_brightness)` (54 at
  display 90), NOT raw 128. The journal line is now
  `tbard: backlight enable-tick → 54 ...` (verified in the diff).

### Claim 4 — ADR-049 — **VERIFIED**

- **Runbook amendments present.** `docs/test-plan.md:280-303` (STEP 1:
  `systemctl mask --now`); `:326-340` (STEP 5/8: `unmask` + `start`);
  `:421-435` (STEP 4f mid-run assertion: `debugfs ... | grep -i tiny-dfr`
  → expect no output). Preflight STEP 3 message: `scripts/bench/interlock-preflight.sh:265-283`
  (`mask --now` not `disable --now`).
- **NO changes to the oracle's unit file.** The deployed unit is at
  `/etc/systemd/system/tiny-dfr-mbp142.service` (mtime Sep 14 — pre-branch;
  untouched). The branch's only script change is the preflight's
  commentary (message text). `git diff d66f3ef..HEAD -- packaging/` shows
  only `config.yaml.example` (a comment addition); NO PKGBUILD change.
- **Static-unit / `Restart=always` investigation cited.** ADR-049
  investigation section (`docs/adr/049-interlock-hardening-mask-oracle.md:30-129`)
  documents `is-enabled=static` + `Restart=always` + why `disable` is a
  no-op for static units + why `stop` does not suppress the restart
  policy. Cites session-043 journal evidence
  (`docs/test-logs/043/step6-stop-tbard.txt:32-55`).

### Claim 5 — Stage-4 prep — **VERIFIED**

- **`examples/render-only-validation-page.yaml` parses.** Verified by
  `test_adr049_render_only_validation_page_has_zero_key_actions` (parses
  via `parse_config`; run alone with `--nocapture` — PASS).
- **ZERO key actions across all widgets.** The test iterates every widget
  on every page and asserts `action.is_empty()` for buttons/time/battery;
  spacers/sliders/dials have no tap action. Cross-checked against
  `src/widgets/button.rs:106-112`: `tap_action()` returns `None` when
  `action.is_empty()` → no `emit_keys` call. The yaml file itself has
  `action: []` on all three buttons; the time widget has no action field
  (serde default empty).
- **Default-page-injects-by-design acknowledgment recorded.**
  `docs/test-plan.md:1432-1444` (Stage-4 note: "the default page's
  auto-added `esc` + F1..F12 are all key-emitting — unsafe for a
  render-only preview") + the example file's header comment
  (`examples/render-only-validation-page.yaml:9-19`).

### Claim 6 — Tests — **VERIFIED with one finding**

- **Test count: 91 passing (86 in `tbard` unittests + 5 integration).**
  Master baseline (`d66f3ef`) is **82** (77 + 5), NOT 81 as the
  self-assessment states. The branch adds **+9** tests (4 ADR-047 + 5
  ADR-048 + 1 ADR-049 = 10 new tests, but one master test was apparently
  refactored/merged — net +9). **Finding F-044-1 (minor, cosmetic):**
  `docs/self-assessment-15.md:79,162,180` states the baseline as 81; the
  actual baseline is 82. The final count (91) and the +4/+5/+1 breakdown
  are correct; only the stated baseline is off by one. Does not affect
  any verdict.
- **New tests present + named as claimed:**
  - ADR-047 (4): `test_adr047_touch_fires_backlight_notify_activity_and_wakes`,
    `test_adr047_touch_while_dark_wakes_gate_opens`,
    `test_adr047_activity_event_wakes_backlight`,
    `test_adr047_digitizer_is_identified_false_without_device`.
  - ADR-048 (5): `test_adr048_display_to_touchbar_curve_90_to_54_datapoint`,
    `test_adr048_enable_writes_curve_output_not_raw_128_adaptive`,
    `test_adr048_enable_then_update_one_write_not_two`,
    `test_adr048_wake_restores_curve_level_not_raw_128`,
    `test_adr048_idle_decay_schedule_unchanged`.
  - ADR-049 (1): `test_adr049_render_only_validation_page_has_zero_key_actions`.
- **Non-vacuity spot-checks (adversarial, throwaway copies, deleted
  after):**
  - **(a) Gate test / pre-gate wake removed:**
    - **ADV-1b (wake removed entirely):** removing the
      `backlight.notify_activity()` call from the `InputEvent::Touch` arm
      makes `test_adr047_touch_fires_backlight_notify_activity_and_wakes`
      FAIL (`notify_count=0`, expected ≥1) and
      `test_adr047_touch_while_dark_wakes_gate_opens` FAIL (poisoned
      mutex). **The guard bites.** Confirms claim (6a) in the "removed"
      sense.
    - **ADV-1a (wake moved post-gate, still in the arm):** moving the
      `notify_activity()` call to AFTER the gesture handler (post-gate)
      makes the test PASS. **Finding F-044-2 (substantive, non-blocking):**
      the gate test proves wake PRESENCE + push PRESENCE, NOT wake
      ORDERING relative to the gate. Reason: `MockInput.current_bl`
      defaults to 255 (no dark-bar concept); `MockInput.poll()` does NOT
      gate on `current_bl` — it emits whatever was pushed. The
      `current_bl == 0` gate at `src/providers/input.rs:504` is only in
      `LibinputProvider::poll`, which the unit tests do not exercise.
      The wake-before-gate ordering invariant is only verifiable on
      hardware (the `LibinputProvider` path). Logged as a finding
      (ADR proposal candidate), NOT implemented (FREEZE). The brief's
      claim (6a) "would fail if the pre-gate wake were removed" is TRUE
      for "removed entirely" but NOT for "moved post-gate." This is a
      non-vacuity GAP, not a non-vacuity FAILURE — the test does guard
      the wake's existence and the push's existence.
  - **(b) Coordination test / enable() writes raw 128:** planting
    `enable()` writing `self.active_brightness.min(self.max_bl)` (raw
    128, ADR-043 behavior) makes
    `test_adr048_enable_writes_curve_output_not_raw_128_adaptive` FAIL
    (left=128, right=54) and
    `test_adr048_enable_then_update_one_write_not_two` FAIL (file=128,
    expected 54). **The guards bite.** Confirms claim (6b).
  - **Throwaway copies deleted:** `/tmp/opencode/adv-047` removed;
    post-revert full suite = 91 passed; `git status` clean.

### Claim 7 — Commit hygiene — **VERIFIED**

- **Chain:** `5e76903` (docs) → `776d7ff` (ADR-047) → `e15562b` (ADR-048)
  → `7030f50` (ADR-049) → `d402554` (Stage-4 prep) → `6f10ca3` (docs).
  Verified via `git log --format='%H %ai %s' d66f3ef..HEAD`.
- **ADR-before-code:** each ADR commit bundles the ADR doc + its code/tests
  in ONE commit (the ADR doc is the commit's rationale; the code lands in
  the same commit). ADR-049 has NO `src/` change (runbook + preflight
  commentary only) — verified via `git show --stat`. Stage-4 prep
  (`d402554`) adds the example yaml + the yaml.rs test (no ADR doc — it
  is a "docs decision + example file" per its commit message, referencing
  ADR-049).

---

## Adversarial results summary

See `docs/test-logs/044/fix-report/adversarial-results.txt` for the full
record. Summary:

| Adversarial | Mutation | Expected | Result | Verdict |
|---|---|---|---|---|
| ADV-1a | wake moved post-gate (in arm) | gate test FAIL | PASS | **Finding F-044-2** (non-vacuity gap) |
| ADV-1b | wake removed entirely | gate test FAIL | FAIL | Guard bites (confirms 6a) |
| ADV-2 | enable() writes raw 128 | coordination test FAIL | FAIL (both) | Guard bites (confirms 6b) |

---

## Gates (verbatim)

All gates GREEN. See `docs/test-logs/044/fix-report/gates-verbatim.txt`
for the full captured output. Summary:

| Gate | Result |
|---|---|
| `cargo fmt --check` | PASS (exit 0) |
| `cargo build --bin tbard` | PASS (exit 0) |
| `cargo clippy --all-targets -- -D warnings` | PASS (exit 0) |
| `cargo test` (expect 91) | PASS — 86 + 1 + 1 + 1 + 1 + 1 = **91** |
| `scripts/check-invariants.sh` | PASS (ADR-009 zero name-string matching) |
| `scripts/ci-gate.sh` | PASS (CI gate: PASS) |
| `bash -n packaging/PKGBUILD` | PASS (exit 0) |
| `bash -n scripts/bench/interlock-preflight.sh` | PASS (exit 0) |
| render-only page test alone (`--nocapture`) | PASS |

---

## Live audits (read-only; oracle active; NO interlock)

- **`/usr/bin/tbard` = `90daf3d6…` (v0.2.5) — expected.** The v0.2.6
  reinstall is the merge session's job. Recorded in
  `docs/test-logs/044/fix-report/host-state-record.txt`.
- **Oracle sole master at start and end.** `systemctl is-active =
  active`, `is-enabled = static`, MainPID 365566, uid 65534 (nobody),
  comm `tiny-dfr-mbp142`. No `tbard` process running during the audit.
  debugfs `/sys/kernel/debug/dri/` is not readable without root (QA
  operator uid 1000); sole-master verified via `systemctl` + `ps`
  (oracle is the only `tiny-dfr`/`tbard` process; no tbard binary
  running).
- **`/dev/input` unchanged.** 23 event devices + mice/mouse + by-id/by-path
  (25 entries total). No uinput device created (no tbard running).
- **`/etc` untouched.** `/etc/systemd/system/tiny-dfr-mbp142.service`
  mtime Sep 14 (pre-branch). `/etc/touchbar/` contains only
  `config.yaml.example` (Sep 26 — pre-branch). No new files.

---

## Findings (FREEZE — logged, not implemented)

- **F-044-1 (minor, cosmetic):** `docs/self-assessment-15.md` states the
  test baseline as 81; the actual `d66f3ef` baseline is 82. The final
  count (91) and the +4/+5/+1 breakdown are correct. ADR proposal: amend
  the self-assessment baseline to 82 (or note the 81 was a pre-merge
  count of a different tree).

- **F-044-2 (substantive, non-blocking):** the ADR-047 gate test
  (`test_adr047_touch_while_dark_wakes_gate_opens`) proves wake PRESENCE
  + `set_current_backlight` push PRESENCE, NOT wake ORDERING relative to
  the `current_bl == 0` gate. Moving the wake post-gate (still in the
  `InputEvent::Touch` arm) makes the test PASS, because `MockInput.poll()`
  does not gate on `current_bl` (the gate is only in
  `LibinputProvider::poll`). The wake-before-gate ordering invariant is
  only verifiable on hardware via `LibinputProvider`. ADR proposal
  candidate: a `RecordingLibinputProvider` wrapper that gates on
  `current_bl` like the real provider, so the unit test can assert a
  dark-bar touch is dropped by the gate BUT still wakes (the wake's
  `update()` + push opens the gate for the next touch). This is a
  non-vacuity GAP, not a non-vacuity FAILURE — the test does guard the
  wake's existence. Hardware acceptance (Stage 4) is the definitive
  proof.

No other findings. No source changes made (FREEZE respected).

---

## What remains hardware-acceptance-only (Stage 4)

The following are NOT unit-test-verifiable and require the Stage-4
hardware session (mask interlock, render-only page, wake-first-touch
protocol) to accept:

1. **Wake-on-touch:** a physical touch on a dark bar fires
   `tbard: touch wake → backlight.notify_activity()` in the journal AND
   lights the bar (the `update()` write is visible in sysfs). This is
   the ADR-047 wake's end-to-end proof — the unit test proves the wiring
   (notify_activity → update → push); hardware proves the WAKE (a real
   touch resets `last_active` and the bar lights).
2. **Gate opens on second touch:** after the waking touch lights the bar
   (`current_bl` pushed to ~54), the NEXT touch passes the
   `current_bl == 0` gate and reaches the gesture handler (tap log with
   widget id). This is the gate's designed semantics — the waking touch
   is consumed by the wake; the next touch processes. Only provable on
   hardware (the `LibinputProvider` gate path).
3. **Tap log with widget id:** `tbard: tap page=... logical=(x,y) hit=...`
   fires on a tap of a visible button. The render-only page's buttons
   have `action: []` (no key emission), but the tap log still fires (the
   gesture classifier runs; the `hit_test` runs; only `emit_keys` is
   skipped). This is the Stage-4 touch-logging criterion.
4. **Curve-maintained brightness:** the bar's maintained level tracks
   `display_to_touchbar(current display_bl, active_brightness)` (~54 at
   display 90) while active, decaying to 1 (30s) then 0 (60s) on idle.
   The unit test proves the curve math; hardware proves the maintained
   level (STEP 4b value-only probe reads `appletb_backlight/brightness`
   within ~1s of start and expects the curve output).
5. **Mid-run oracle-mask assertion:** `sudo cat
   /sys/kernel/debug/dri/<N>/clients | grep -i tiny-dfr` → no output
   (the oracle is masked; no row appears). This requires root + an
   active tbard run under the mask — the Stage-4 session's interlock
   check (ADR-049 STEP 4f).

---

## Final paragraph

**CLEARED FOR MERGE (v0.2.6) + binary reinstall + Stage-4 hardware
session (mask interlock, render-only page, wake-first-touch protocol).**

All seven claim groups are VERIFIED. All eight gates are GREEN (91
tests, fmt/build/clippy/check-invariants/ci-gate/PKGBUILD/preflight).
Both adversarial non-vacuity checks confirm the coordination guards bite
(ADV-2); the wake-removed check confirms the gate test bites (ADV-1b).
One substantive finding (F-044-2: the gate test does not guard wake
ORDERING, only wake PRESENCE — a non-vacuity gap, not a failure) is
logged as an ADR proposal candidate, NOT implemented (FREEZE). One
cosmetic finding (F-044-1: baseline 81 should be 82) is logged. Neither
blocks merge. The wake-before-gate ordering, wake-on-touch, gate-opens-
on-second-touch, tap log with widget id, curve-maintained brightness,
and mid-run oracle-mask assertion remain hardware-acceptance-only
(Stage 4). The merge session's job: merge `fix/input-wiring-adr-047-049`
to master, reinstall `/usr/bin/tbard` from the tip (v0.2.6), then run
the Stage-4 hardware session with ADR-049's `mask --now` interlock, the
render-only validation page, and the wake-first-touch protocol.

---

## Artifacts

- `docs/test-logs/044/fix-report/host-state-record.txt` — host state at
  audit (oracle active+static, sole master; `/usr/bin/tbard` = v0.2.5;
  `/dev/input` + `/dev/dri` + `/etc` untouched).
- `docs/test-logs/044/fix-report/gates-verbatim.txt` — all eight gates
  captured verbatim (exit codes + output).
- `docs/test-logs/044/fix-report/adversarial-results.txt` — ADV-1a,
  ADV-1b, ADV-2 results + revert/clean confirmation.
- `docs/review-report-v12.md` — this report.

Devlog session 045 to be appended to `devlog.md` by the merge session
(this QA session is session 044; the devlog already has a session 044
entry from the fix-engineer — the QA devlog entry is session 045 per the
brief's "devlog session 045" instruction, to be added by the merge
session if not already present).