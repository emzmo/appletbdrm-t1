# Review Report v5.5 — QA Re-Verification of fix/complete-adr-029-030

**Date**: 2026-09-26 (Sat)
**Role**: QA & reliability engineer. FOCUSED re-verification (v5.5).
**Branch under test**: `fix/complete-adr-029-030`
**Stacked on**: `fix/hygiene-adr-016-023` (parent commit `cf7c713` = QA v5
artifacts, "BLOCKED; NF-1..NF-4").
**Scope**: ONLY ADR-029/030 + gates. ADR-019 absent/reserved.
**Freeze rule**: no source changes; findings only.
**Host safety rules**: `docs/dangers.md` binding — no system config, no
login-chain files, no restarts.
**Bench fact**: the 3 master-gated tests CANNOT execute here (Hyprland holds
vkms master; root EBUSY / EACCES — ADR-026 closure, exclusivity). Truthful
ADR-013 skips are the accepted state; live master-release verification is
rescheduled to the Stage-3 interlock (real card0) / VM lane per the v5
rescope. `/dev/uinput` IS granted (input group + uaccess), so the ADR-029
scale test runs LIVE.

## Commits under test

| Commit | Subject | Parent |
|---|---|---|
| `9ea6f89` | ADR-029: complete ADR-024 (sim scale wiring + test truthfulness) | `cf7c713` |
| `2046d13` | ADR-030: complete ADR-028 (spawn-based test migration to CARGO_BIN_EXE) | `9ea6f89` |
| `26cb131` | docs: session 012 + self-assessment-5 (ADR-029/030 completion) | `2046d13` |
| `cf7c713` | docs: QA v5 adversarial re-verification (BLOCKED; NF-1..NF-4) | `c4bd310` |

`git log --oneline cf7c713^..HEAD` confirms the linear stack. ADR-019 is
absent (gap `018`→`020` in `docs/adr/`), reserved for the service session —
not used/renumbered.

---

## Per-Claim Verdicts

### Claim 1 — ADR-029 ROOT CAUSE (BTN_TOUCH isolation) — **VERIFIED**

**Evidence** (`docs/test-logs/012/dbg-harness2-isolate.log`, read directly):

| Variant | BTN_TOUCH? | suspend+resume? | Touch delivered? |
|---|---|---|---|
| A (existing SimInputProvider) | no | no | **no** (`found_touch=false`) |
| B | no | yes | **no** (`found_touch=false`) |
| C | yes | no | **yes** (x=1084.9, y=29.5) |
| D | yes | yes | **yes** (x=1084.9, y=29.5) |

The four-variant harness ISOLATES `BTN_TOUCH` as the determining factor:
A/B (no BTN_TOUCH) never deliver regardless of suspend+resume; C/D
(BTN_TOUCH) always deliver regardless of suspend+resume. This REFUTES the
QA v5 "timing/device issue" skip-guess — the root cause is device
classification, not timing. The v5 skip message
("no touch event delivered by libinput — timing/device issue") was a
guess; the harness proved no wait window surfaces an event libinput never
creates.

`new_with_range` now sets `EV_KEY`/`BTN_TOUCH`
(`src/providers/sim_input.rs:133-134`):
```
uinput.set_evbit(EventKind::Key)?;
uinput.set_keybit(Key::ButtonTouch)?;
```
`inject_touch_down` emits `BTN_TOUCH=1` before the `ABS_MT_*` events
(`sim_input.rs:218-219`):
```
let events = [
    mk(ev_key, Key::ButtonTouch as u16, 1),
    mk(ev_abs, AbsoluteAxis::MultitouchSlot as u16, slot),
    ...
```
This matches the real appletbdrm digitizer protocol (oracle
`backup_old/tiny-dfr-mbp142` advertises `BTN_TOUCH`).

### Claim 2 — ADR-029 SCALE WIRING — **VERIFIED (with NF-5 guard-strength finding)**

**Evidence** (re-derived from source, not the report):

- `SimInputProvider` carries a `logical_dims: (u32, u32)` field
  (`sim_input.rs:93`), populated by both constructors
  (`sim_input.rs:103-105` `new`, `sim_input.rs:114-184` `new_with_range`,
  field set at `sim_input.rs:182`).
- `poll()` uses `self.logical_dims` as the scale denominators
  (`sim_input.rs:255`): `let (logical_w, logical_h) = (self.logical_dims.0, self.logical_dims.1);`
  → `dn.x_transformed(logical_w)` (`:270`), `mtn.x_transformed(logical_w)`
  (`:278`), `dn.y_transformed(logical_h)` (`:272`), `mtn.y_transformed(logical_h)` (`:280`).
- `main.rs` dry-run path (ADR-029 diff) builds `Geometry` from
  `SimDisplayProvider::display_info()` and passes the logical dims to
  `SimInputProvider::new(sim_logical.0, sim_logical.1)`, mirroring the real
  path (`drm.display_info()` → `LibinputProvider::new(tb_dims)`).
- `SIM_WIDTH`/`SIM_HEIGHT` constants are REMOVED (grep for
  `const SIM_(WIDTH|HEIGHT)` in `sim_input.rs` → no matches). The only
  crate-private constants are `DEFAULT_LOGICAL_W/H`
  (`sim_input.rs:56-57`), which are the documented default constructor
  args (identity map for the dry-run smoke), NOT scale denominators.

**Stray 2170/60/32767/127 outside `geometry.rs` + test fixtures**
(grep-verified, classified):
- `sim_input.rs:56-57` `DEFAULT_LOGICAL_W=2170`/`DEFAULT_LOGICAL_H=60` —
  documented default constructor args (not `poll()` denominators); in scope
  but not a regression.
- `main.rs:55` `ESC_THRESHOLD: u16 = 2170` — pre-existing bar-width
  threshold, out of ADR-029 scope.
- `main.rs:217` fallback `.unwrap_or((60, 2170))` — pre-existing fallback
  when `display_info()` fails, out of ADR-029 scope.
- `slider.rs:92` `delta_x / 2170.0` — pre-existing widget slider logic, out
  of ADR-029 scope.
- `sim_display.rs:97-98` `SIM_W=60`/`SIM_H=2170` — sim display buffer dims
  (framebuffer space), not input scale denominators.

**ADVERSARIAL (throwaway copy in `/tmp`, deleted after):** planted a
hardcoded scale denominator in `poll()` and ran `check-invariants.sh`:

| Planted form | Caught? | Evidence |
|---|---|---|
| `let (logical_w, logical_h) = (2170u32, 60u32);` (bare numeric literal) | **NO** | `check-invariants: PASS` (exit 0) |
| `let (logical_w, logical_h) = (SIM_WIDTH as u32, SIM_HEIGHT as u32);` (SIM_* ref, no const) | **NO** | `check-invariants: PASS` (exit 0) |
| `dn.x_transformed(SIM_WIDTH as u32)` (x_transformed(SIM_*)) | **YES** | `FAIL: ADR 029 ... x/y_transformed(SIM_*)` (exit 1) |

→ The guard catches the `SIM_*`-named `x/y_transformed` regression but NOT
a bare numeric literal re-inlined as the denominator. This is **NF-5**
(see New Findings) — a guard-strength finding, NOT a defect in the
ADR-029 fix itself (the fix's `poll()` is correct). Baseline restored and
re-verified PASS after the adversarial runs.

### Claim 3 — ADR-029 TEST TRUTHFULNESS — **VERIFIED (LIVE)**

**Live run** (`docs/test-logs/013/live-runs.log`, uinput granted on this bench):
```
ok: mid-range scale 32767/127 → logical (1084.9337768554688, 29.53125) [expected ≈(1085, 30)]
ok: edges-lo scale (0, 0) → logical (0, 0)
ok: edges-hi scale (32767, 127) → logical (2169.9337768554688, 59.53125) [expected ≈(2170, 60)]
ok: widget-tap raw (16383, 63) → logical (1084.9337768554688, 29.53125) → hit_test widget_id=1
test providers::sim_input::tests::test_sim_input_scales_real_abs_range_to_logical ... ok
```

All four sub-assertions EXECUTED (no skip, no vacuous pass):
- edges 0,0 → 0,0 ✓
- edges 32767,127 → ≈2170,≈60 (2169.93, 59.53) ✓
- mid-range 16383,63 → ≈1085,≈30 (1084.93, 29.53) ✓
- demo-page tap → `hit_test` → `widget_id=1` ✓
- non-vacuity guard (`assert_ne!` 32767≠2170, 127≠60) executed (structural
  assertion at `sim_input.rs:370-379`).

**From code:**
- uinput-EACCES → verbatim-stderr skip (`sim_input.rs:384-396`):
  `eprintln!("...skipped (cannot open /dev/uinput or create device):\n--- error ---\n{}\n-------------", e); return;`
- uinput-OK + no event → HARD FAIL `panic!` (`sim_input.rs:440-447`):
  `panic!("REGRESSION (ADR-029): no touch event delivered by libinput within the retry window despite BTN_TOUCH + ABS_MT axes + injection. ...")`
- retry-poll loop exists (`sim_input.rs:416-428`): 20 iterations × 25ms
  sleep + `sim.poll()` per iteration, returning `None` only after the
  bounded window expires (the `None` path is the HARD FAIL above).

The test CAN fail (the HARD FAIL panic is reachable when uinput is
available but libinput does not deliver). The ADR-024 vacuous-skip bug
class is closed.

### Claim 4 — ADR-030 MIGRATION — **VERIFIED**

**Evidence** (re-derived from source):
- `tests/exit_code.rs:24`: `let exe = env!("CARGO_BIN_EXE_tbard");`
- `tests/sigterm_master_release.rs:76`: `let exe = env!("CARGO_BIN_EXE_tbard");`
- No `current_exe` in `src/` or `tests/` code: grep across `*.rs` → 3 hits,
  ALL in doc comments (`src/lifecycle.rs:193`, `tests/sigterm_master_release.rs:6`,
  `tests/exit_code.rs:11`). Zero code calls.
- `test_sigterm_releases_master` lives in `tests/sigterm_master_release.rs`
  (216 lines, `#[test] fn test_sigterm_releases_master` at `:71`). Removed
  from `src/lifecycle.rs` (lifecycle.rs:191 carries only a comment:
  `// ADR-030: test_sigterm_releases_master MOVED to`). The other lifecycle
  tests (`test_shutdown_flag_round_trip`, `test_signal_handler_sets_flag`,
  `test_panic_hook_logs_backtrace_and_runs_cleanup`) remain.

**ADVERSARIAL** (`docs/test-logs/013/live-runs.log`):
- `rm -f target/debug/tbard` → `cargo test --no-run` REBUILT the bin:
  `Compiling touchbar-engine v0.1.0 ...` + `Finished test profile`; bin
  present again after `--no-run` (`-rwxr-xr-x ... target/debug/tbard`).
  This is the structural rebuild via `CARGO_BIN_EXE_tbard` (Cargo tracks
  the bin as a test-crate dependency).
- `exit_code` test RAN live (not a skip):
  `ok: startup failure exited non-zero (code=Some(1)) per ADR-025`
  — non-zero exit observed, the ADR-025 exit-code contract holds.
- `sigterm_master_release` test produced a truthful ADR-013 skip (case 2:
  master EACCES) with verbatim stderr:
  ```
  test_sigterm_releases_master: skipped (daemon could not acquire DRM master in this session — seat/privilege; re-run on an active VT or under sudo per ADR-010).
  --- child stderr ---
  [2026-09-26T10:03:55Z ERROR tbard] tbard: dry-run SimDisplay acquire failed: Permission denied (os error 13)
  Error: Permission denied (os error 13)
  --------------------
  ```
  This is NOT a stale-binary false-pass: the binary was spawned (the
  EACCES is from the child's DRM master acquire, not from
  binary-not-found). The ADR-013 classification (panicked / EACCES /
  clean-exit, distinguished in code at `sigterm_master_release.rs:118-147`)
  is non-vacuous.

### Claim 5 — GATES (verbatim + reconciliation) — **VERIFIED**

All gates green. Verbatim log: `docs/test-logs/013/gates-verbatim.log`.

| Gate | Command | Result |
|---|---|---|
| 1 | `cargo fmt -- --check` | exit 0 |
| 2 | `cargo build --bin tbard` | exit 0 (`Finished dev profile`) |
| 3 | `cargo clippy --all-targets -- -D warnings` | exit 0 (`Finished dev profile`) |
| 4 | `cargo test` | 40 unit + 2 integration = 42 passed; 0 failed; 0 ignored |
| 5 | `bash scripts/check-invariants.sh` | `check-invariants: PASS` (exit 0) |
| 6 | `bash scripts/ci-gate.sh` | `CI gate: PASS` (exit 0) |

**Test count reconciliation** (from the 42 baseline):
- ADR-029: +0 net (rewrote `test_sim_input_scales_real_abs_range_to_logical`;
  already counted) → 41 unit + 1 integration.
- ADR-030: −1 unit (`test_sigterm_releases_master` moved out of
  `src/lifecycle.rs`), +1 integration (new
  `tests/sigterm_master_release.rs`) → **40 unit + 2 integration = 42**.
- Observed: 40 unit + 2 integration = 42. ✓ Matches.

**Commit hygiene:** `9ea6f89` (ADR-029), `2046d13` (ADR-030), `26cb131`
(docs) present and linear; parent `cf7c713` = v5 artifacts. ADR-019
absent/reserved (gap `018`→`020` in `docs/adr/`).

### Claim 6 — Master-gated trio status + prebuilt binary names — **VERIFIED**

The 3 master-gated tests CANNOT execute here (Hyprland holds vkms master).
Current status (truthful ADR-013 skips, verbatim from
`docs/test-logs/013/live-runs.log`):

1. **`test_sim_display_acquires_vkms`** (unit, `src/providers/sim_display.rs`):
   ```
   test_sim_display_acquires_vkms: skipped (SimDisplayProvider::acquire failed):
   --- error ---
   Permission denied (os error 13)
   -------------
   ```
2. **`test_retry_partial_alloc_releases_master_on_failure`** (unit,
   `src/providers/drm_backend.rs`):
   ```
   test_retry_partial_alloc_releases_master_on_failure: skipped (master not acquired — bench not granted; re-run per ADR-026 or on a clean VT). Err: Touch Bar DRM card never appeared: master acquire failed (bench not granted): Permission denied (os error 13)
   ```
3. **`test_sigterm_releases_master`** (integration,
   `tests/sigterm_master_release.rs`): see Claim 4 verbatim stderr above.

(`test_retry_aborts_on_shutdown` does NOT require master and runs clean —
not part of the gated trio.)

**Exact prebuilt binary names** for the granted-VT/VM path (from
`target/debug/deps/`, hash-suffixed):
- `target/debug/deps/exit_code-d565d17a8b2d77e9`
- `target/debug/deps/sigterm_master_release-732e5141a06bf9cc`
- `target/debug/deps/tbard-024090071b748d61` (unit-test binary; carries
  `test_sim_display_acquires_vkms` and
  `test_retry_partial_alloc_releases_master_on_failure`)

Per ADR-026 / ADR-010: `cargo test --no-run` (as the user) builds these,
then `sudo ./target/debug/deps/<name> --nocapture` runs each under root on
a clean VT (no compositor). This bench's lane is CLOSED; live
master-release verification is rescheduled to the Stage-3 interlock (real
card0) / disposable VM.

---

## Adversarial Results Summary

| Adversarial | Target | Result | Evidence |
|---|---|---|---|
| ADR-029: plant `(2170u32, 60u32)` in `poll()` | check-invariants guard | **NOT caught** (guard gap → NF-5) | `docs/test-logs/013/adr-029-adversarial-scale-guard.log` |
| ADR-029: plant `x_transformed(SIM_WIDTH as u32)` | check-invariants guard | **Caught** (FAIL exit 1) | same log |
| ADR-030: `rm -f target/debug/tbard` → `cargo test --no-run` | structural rebuild | **Rebuilt** (bin present again) | `docs/test-logs/013/live-runs.log` |
| ADR-030: `exit_code` test live | non-zero exit observed | **RAN** (code=Some(1)) | same log |
| ADR-030: `sigterm_master_release` live | truthful ADR-013 skip | **Truthful skip** (verbatim EACCES stderr) | same log |

---

## New Findings → ADR Proposals (logged, NOT implemented — freeze rule)

### NF-5 — check-invariants ADR-029 grep guard is incomplete (guard-strength)

**Class:** guard-strength (NOT a defect in the ADR-029/030 fix).
**Bench:** `scripts/check-invariants.sh:100-112`.
**Observation:** the guard catches `const SIM_(WIDTH|HEIGHT)` and
`x/y_transformed(SIM_*)` regression forms, but NOT a bare numeric literal
re-inlined as the `poll()` scale denominator
(e.g. `let (logical_w, logical_h) = (2170u32, 60u32);`). The bare-numeric
form is the more natural regression (a future edit could re-inline the
numbers without reintroducing the `SIM_*` names). Adversarial proof:
`docs/test-logs/013/adr-029-adversarial-scale-guard.log` —
`check-invariants: PASS` (exit 0) with the planted literal.
**Proposal for next session:** extend the guard to fail if `poll()`'s
`x_transformed`/`y_transformed` calls receive anything other than
`logical_w`/`logical_h`, OR add a regex anchored to the
`let (logical_w, logical_h) = ...` binding requiring
`self.logical_dims`. (ADR proposal for the next session — logged, not
implemented per the freeze rule.)
**Merge impact:** NONE — the ADR-029 fix's `poll()` is correct
(`self.logical_dims`); NF-5 is a guard-strength finding for future
regression hardening.

---

## Final Verdict

**CLEARED FOR MERGE** (`fix/hygiene-adr-016-023` then
`fix/complete-adr-029-030`) + ADR-019 service session, with live
master-release verification rescheduled to the Stage-3 interlock (real
card0) per the v5 rescope.

NF-5 is a guard-strength finding (not a defect in the ADR-029/030 fix
itself); it is logged as an ADR proposal for the next session, not a merge
block. All six claims are VERIFIED; all six gates are green (42 tests
pass); the ADR-029 scale test ran LIVE with all sub-assertions executed
(non-vacuous); the ADR-030 structural rebuild closes the stale-binary
false-pass hazard; the 3 master-gated tests skip truthfully with verbatim
EACCES stderr per ADR-013, with live master-release verification
rescheduled to the Stage-3 interlock / VM lane.

---

## Artifacts

- `docs/test-logs/013/gates-verbatim.log` — all 6 gates, verbatim
- `docs/test-logs/013/live-runs.log` — ADR-029 live scale test + ADR-030
  adversarial rm-tbard + spawn-based tests live + master-gated trio skips
- `docs/test-logs/013/adr-029-adversarial-scale-guard.log` — NF-5
  adversarial proof (guard gap)
- `docs/test-logs/013/fix-report/self-assessment-5.md` — fix report
  archived as data
- `devlog.md` Session 013 entry