# QA Review Report v5 — Adversarial Re-Verification of fix/unblock-adr-024-028

**Date**: 2026-09-26 (Sat)
**Reviewer**: QA & reliability engineer (fresh eyes, adversarial)
**Branch under test**: `fix/hygiene-adr-016-023` (single branch; see T0)
**Base**: master `e12284a` (v0.1.2-test3 tag → `dd9fdf3`, unchanged)
**Session**: 011
**FREEZE RULE**: no source changes; findings only. Edits confined to
`docs/test-logs/011/`, `docs/review-report-v5.md`, `devlog.md`.

---

## T0 — Branch Topology (ground truth first)

The fix report's header claims the branch is `fix/hygiene-adr-016-023`,
but the plan called for `fix/unblock-adr-024-028` stacked ON it.

**Verdict: DEVIATION RECORDED (non-blocking, hygiene note).**

```
$ git branch --show-current
fix/hygiene-adr-016-023
$ git log --oneline master..HEAD  (14 commits)
c4bd310 docs: self-assessment-4 + session 007 resume wrap-up
5f6a77c ADR-028: test integrity (ci-gate cargo build --bin tbard step)
cc58081 ADR-027: retry cleanup assertion (partial master release via drop glue)
41ab94d ADR-025: exit-code contract (fn main returns Result; startup failures exit 1)
f18b82a ADR-024: scale wiring (Geometry) + real-range uinput test (sim/real divergence)
9b57c3d baseline: session 010 bench-incident post-mortem + closure docs
1d240d8 docs: amend ADR-016/026 (...)
4c3a6da docs: bench-grant model (ADR-016 fold) + ADR-026 granted-bench procedure
27bbdf5 docs: self-assessment-3 + session 007 wrap-up
00a1689 ADR-016/017/018 + ADR-010 caveat (...)
b457f42 ADR-023: frame counter
075bae3 ADR-022: SIGTERM-responsive DRM card-open retry
2af9513 ADR-021: hot-reload storm
d22c8a6 ADR-020: three-space coordinate model + tap observability
```

- ADR-024..028 landed **directly on** `fix/hygiene-adr-016-023`, not on a
  separate `fix/unblock-adr-024-028` branch. The branch name was merely
  the hygiene branch; the unblock ADRs sit on top of it.
- ADR-024..028 commits (f18b82a, 41ab94d, cc58081, 5f6a77c) sit ABOVE the
  ADR-016..023 commits (d22c8a6..00a1689), with the session-010
  post-mortem docs (9b57c3d, 1d240d8, 4c3a6da) interleaved between them.
- master (`e12284a`) is untouched (merge-base = master HEAD; 14 commits
  ahead, 0 behind).
- Tags stable: `v0.1.2-test3` → `dd9fdf3`, `v0.1.1-test2` → `3e8da1e`
  (unchanged from the merge session).

**Merge guidance adjustment**: this is a SINGLE branch with TWO ADR sets
(hygiene 016..023 + unblock 024..028), not two stacked branches. A single
merge of `fix/hygiene-adr-016-023` into master brings both sets. History
is otherwise clean (one commit per ADR, ADR-before-code). Non-blocking.

**Bookkeeping**: `git status` was clean at session start — no docs-only
post-mortem artifacts to commit (already committed in 9b57c3d / 1d240d8 /
4c3a6da on this branch). Nothing to commit for session-010 post-mortem.

**Boot card mapping (recorded at session start)**:
```
card0 -> faux_driver (vkms)
card1 -> i915
card2 -> appletbdrm
```

---

## Per-Claim Verdicts

### Claim 1 — ADR-024 scale wiring — **PARTIALLY VERIFIED / PARTLY REFUTED**

**Sub-claim 1a: denominators wired to Geometry (no duplicated
2170/60/32767/127 constants outside geometry.rs + test fixtures).**

**VERDICT: REFUTED (partial wiring).**
- `src/providers/input.rs:177-186` (REAL provider): `poll()` uses
  `self.tb_dims` (Geometry-derived, passed from `main.rs:195-199` via
  `drm.display_info()`) for `x_transformed`/`y_transformed`. ✓ WIRED.
- `src/providers/sim_input.rs:223-224, 231-232` (SIM provider): `poll()`
  uses hardcoded `SIM_WIDTH` (2170) / `SIM_HEIGHT` (60) as the
  `x_transformed`/`y_transformed` denominators. ✗ NOT wired to Geometry.
  These constants (`sim_input.rs:43-44`) are the scale denominators for
  the sim path; they happen to match the real logical dims but are
  constants, not Geometry-derived.
- Other stray 2170 production constants (out of ADR-024's stated scope
  but still duplicated): `main.rs:55` (ESC_THRESHOLD=2170),
  `main.rs:198` (fallback (60,2170)), `slider.rs:92` (delta_x/2170.0),
  `sim_display.rs:98` (SIM_H=2170).

**Sub-claim 1b: sim ABS ranges derived from Geometry.**

**VERDICT: REFUTED.** `SimInputProvider::new()` delegates to
`new_with_range(SIM_WIDTH, SIM_HEIGHT)` with hardcoded 2170/60
(`sim_input.rs:80-82`). The ABS ranges and the scale denominators are
both the hardcoded constants, NOT derived from `Geometry`. The
`new_with_range` constructor exists for the test but the production
sim path uses the constants.

**Sub-claim 1c: uinput-backed test creates a virtual multitouch device
with REAL ranges (X max 32767, Y max 127), asserts non-identity mappings
(abs 16383/63 → logical ~1085/~29; edges → 0/full span) and a demo-page
widget tap through scaled coordinates.**

**VERDICT: UNVERIFIABLE (test SKIPS 100% on this bench) + INCOMPLETE
(no widget tap, no edges assertion).**
- The test `test_sim_input_scales_real_abs_range_to_logical`
  (`sim_input.rs:301`) creates `SimInputProvider::new_with_range(32767, 127)`
  and injects raw (16383, 63). By design it would assert `x ≈ 1085,
  y ≈ 30` — NON-VACUOUS IN DESIGN (input ranges 32767/127 ≠ output
  ranges 2170/60).
- IN EXECUTION: the test SKIPS 100% of runs on this bench ("no touch
  event delivered by libinput — timing/device issue",
  `sim_input.rs:330-336`). The libinput dispatch path does not surface a
  Touch event within the 50ms sleep window, so the test hits the
  `let Some(contacts) else { return; }` skip branch and marks itself
  "ok" WITHOUT asserting the transform. This is the EXACT vacuous-pass
  hazard flagged in Claim 1's CRITICAL note: the test "passes" by
  skipping, never exercising the real transform. Reproduced 3x as
  emzmo and 1x under sudo (root) — always skips.
- The test does NOT assert edges → 0/full span (only mid-range 16383/63).
- The test does NOT assert a demo-page widget tap through scaled
  coordinates (no `Page::hit_test`, no widget_id assertion). Claim 1's
  "demo-page widget tap through scaled coordinates" sub-claim is NOT
  implemented.

**Evidence**: `docs/test-logs/011/scale-audit.log`

---

### Claim 2 — ADR-025 exit-code contract — **VERIFIED (with W2 resolved)**

- `fn main() -> Result<(), Box<dyn std::error::Error>>` (`main.rs:96`). ✓
- Contract documented in `docs/adr/025-exit-code.md` §2 table: 0 = clean
  (incl. SIGTERM during retry); non-zero = typed startup failure
  (SimDisplay/SimInput/backlight/card-never-appeared/engine Err/panic → 1);
  --help/bad-arg unchanged (0/2). ✓
- **Live exit-code audit (Audit A.1)**: unprivileged `./target/debug/tbard
  --dry-run` → EACCES → exit **1** (was exit 0 in QA v4). Typed error
  logged: `tbard: dry-run SimDisplay acquire failed: Permission denied
  (os error 13)`. ✓
- **No `process::exit` on resource-holding paths**: `process::exit`
  appears only at `main.rs:73` (--help) and `main.rs:78` (bad-arg), both
  BEFORE any provider acquire. ✓ Cleanup via RAII Drop:
  `DrmProvider::Drop` → `release()` → `release_master_lock()`;
  `SimDisplayProvider::Drop` → drops Card; `SimInputProvider::Drop` →
  `dev_destroy()`. ✓
- **Integration test** `tests/exit_code.rs::test_startup_failure_exits_nonzero`
  spawns the binary with `HOME=tempdir`, asserts `!exit.success()`. ✓
  (But see W1: it resolves the binary by path, not CARGO_BIN_EXE.)

**W2 — panic path (resolved)**: `main.rs:140,211` wraps `real_main` in
`panic::catch_unwind(AssertUnwindSafe(...))`. On panic: (1) the ADR-007
panic hook fires FIRST (`lifecycle.rs:80-97` — logs backtrace + runs
`run_panic_cleanup`), (2) `catch_unwind` catches the unwind, (3) `main`
matches `Err(_) => Err("engine panicked".into())` → Rust runtime exits
**1**. The ACTUAL exit code for a panic path is **1** (NOT std 101,
because `catch_unwind` catches before the runtime's default abort).
ADR-025 §2 table line 49 maps "engine panic (`Err(_)`)" → exit 1 —
UNAMBIGUOUS. The hook-fires-first ordering is confirmed by
`lifecycle.rs:96` (`run_panic_cleanup()` called inside the hook, before
the unwind proceeds to `catch_unwind`).

**Limitation (Audit A.2)**: the privileged SIGTERM→exit 0 path CANNOT be
live-verified on this bench (Hyprland holds vkms master → EBUSY → the
render loop never starts). The code path is correct by inspection
(`main.rs:164` `return Ok(())` on `should_shutdown()` during card-open
retry; `real_main` returns `Ok(())` on loop break), but the live
SIGTERM→exit 0 + immediate-rerun-acquires-cleanly assertion is
UNVERIFIABLE here. This is a bench limitation, not a code defect.

**Evidence**: `docs/test-logs/011/exit-code-audit.log`

---

### Claim 3 — ADR-027 retry-assertion hardening — **VERIFIED IN DESIGN /
UNVERIFIABLE IN EXECUTION (bench-limited)**

- `test_retry_partial_alloc_releases_master_on_failure`
  (`drm_backend.rs:497`) injects a closure that (a) opens vkms, (b)
  acquires master (tracked by `Arc<AtomicBool>`), (c) returns `Err`
  (simulated post-master failure). The `Card` is dropped on `Err` →
  master released via drop glue. The test then reopens the same card and
  asserts `acquire_master_lock()` succeeds. ✓ DESIGN is non-vacuous:
  the `acquired` AtomicBool tracks whether the closure actually acquired
  master (vs EACCES), and the second-acquisition assertion CAN fail if
  master was not released.
- **IN EXECUTION (Audit T4.2.c)**: under sudo, the test SKIPS —
  `acquire_master_lock()` EBUSYes (Hyprland holds vkms master), so
  `acquired` stays false → skip branch ("master not acquired — bench
  not granted"). The assertion is NOT exercised on this bench.
- The `test_retry_aborts_on_shutdown` test (ADR-022, `drm_backend.rs:452`)
  remains as before — injects always-EBUSY closure, asserts shutdown
  abort. It is NOT the ADR-027 test; ADR-027 added the new partial-alloc
  test alongside it.

**Verdict**: the hardening is real by code inspection (the new test CAN
fail if master leaks), but the assertion is UNVERIFIABLE on this bench
because the closure never acquires master. Non-vacuous in design;
bench-limited in execution.

**Evidence**: `docs/test-logs/011/t4-live-verification.log`

---

### Claim 4 — ADR-028 test integrity — **PARTIALLY VERIFIED / PARTLY REFUTED**

**Sub-claim 4a: binary-spawning tests live in tests/ via
env!("CARGO_BIN_EXE_tbard").**

**VERDICT: REFUTED.**
- ZERO tests use `env!("CARGO_BIN_EXE_tbard")` (grep across `src/`,
  `tests/`).
- `test_startup_failure_exits_nonzero` lives in `tests/exit_code.rs` ✓
  (integration test location), BUT it resolves the binary by
  `std::env::current_exe().parent().parent().join("tbard")`
  (`exit_code.rs:16-23`), NOT via `CARGO_BIN_EXE`.
- `test_sigterm_releases_master` lives in `src/lifecycle.rs:208` (a UNIT
  test, NOT in `tests/`), and also resolves the binary by `current_exe()`
  path-resolution (`lifecycle.rs:212-219`).

**Sub-claim 4b: NO test spawns target/debug/tbard by path.**

**VERDICT: REFUTED.** Both spawn-based tests resolve `target/debug/tbard`
by relative path from `current_exe()` (deps → debug → tbard). This IS
"by path" (a computed path, but a path nonetheless).

**Sub-claim 4c: scripts/ci-gate.sh builds --bin tbard before tests.**

**VERDICT: VERIFIED.** `scripts/ci-gate.sh` runs `cargo build --bin tbard`
BEFORE clippy/check-invariants. Within ci-gate, the stale-binary hazard
is mitigated. ✓

**Adversarial check (Audit C.3)**: after `rm -f target/debug/tbard`,
bare `cargo test` does NOT rebuild it. Both spawn-based tests SKIP
(binary-not-found → `.filter(|p| p.exists())` returns None → eprintln
skip → `return` → "ok" pass). The tests PASS against NOTHING. This is
the EXACT QA v4 live regression (stale/absent binary → false pass),
reproducible at will outside ci-gate. The hazard is contained WITHIN
ci-gate but NOT within bare `cargo test` (the common dev invocation).

**W1 confirmed**: the CARGO_BIN_EXE migration is PARTIAL (effectively
zero — no test uses the macro). `test_sigterm_releases_master` STILL
spawns `target/debug/tbard` by path as a unit test in `src/lifecycle.rs`.
The stale-binary hazard persists for bare `cargo test` runs outside
ci-gate.

**Evidence**: `docs/test-logs/011/test-integrity-audit.log`

---

### Claim 5 — Docs state — **VERIFIED**

- **ADR-016 matrix 007 row = PASS/mechanism UNVERIFIED**: ✓
  `docs/adr/016-logind-seat-acl.md` §1: "Session 007 / QA v3 PASS —
  mechanism UNVERIFIED. The prior text credited 'AQ_DRM_DEVICES→i915'
  as the mechanism. This is PROVEN FALSE by the 2026-09-26 environ
  capture." (lines 45-50, 244-246).
- **ADR-026 = closure + procedure with debugfs-canonical check
  (fuser documented sufficient-only), config-discovery, logind caveat**:
  ✓ `docs/adr/026-granted-bench-procedure.md`: Status CLOSED (line 3);
  step 5 debugfs `clients` canonical check (lines 82-100); `fuser` is
  "quick SUFFICIENT check only" (line 89); step 2 config-discovery
  (lines 41-60); logind caveat (lines 135-146).
- **devlog records the 026/028 reassignment**: ✓
  `devlog.md:1384-1390`: "ADR-026 = granted-bench procedure ... ADR-028
  = test integrity ... Moved OUT of ADR-026".
- **ADR-019 absent/reserved**: ✓ no `docs/adr/019*` file exists.
  `devlog.md:1393`: "ADR-019 (reserved, service session)".
- **ADR-010 amendments + /proc caveat present**: ✓
  `docs/adr/010-master-acquisition-input.md:26-29`: "Privilege caveat
  (ADR-016): the `/proc/562/fd` capture required root ... `ls
  /proc/562/fd/` as uid 1000 → Permission denied; under sudo →
  succeeds." §"Amendment (ADR-016)" at line 190.

---

## Live Audits A–D

### Audit A — Exit-Code Audit
- **A.1 Unprivileged**: `./target/debug/tbard --dry-run` → EACCES →
  **exit 1** (typed failure logged). ✓ PASS (was exit 0 in QA v4).
- **A.2 Privileged**: `sudo env HOME=$(mktemp -d) ./target/debug/tbard
  --dry-run` → EBUSY (Hyprland holds vkms master on card0) → **exit 1**.
  The SIGTERM→exit 0 + immediate-rerun path CANNOT be live-verified
  (render loop never starts). UNVERIFIABLE (bench-limited).
- **A.3 Code audit**: no `process::exit` on resource-holding paths; RAII
  Drop releases master/sockets BEFORE exit. ✓
- **W2**: panic → exit 1 (catch_unwind → Err); ADR-007 hook fires first.
  Unambiguous. ✓

Raw log: `docs/test-logs/011/exit-code-audit.log`

### Audit B — Scale Audit
- The real-range test SKIPS 100% on this bench (libinput delivery
  timing). VACUOUS IN EXECUTION.
- Stray 2170/60 constants outside geometry.rs + test fixtures: sim_input.rs
  (scale denominators, NOT Geometry), main.rs (ESC_THRESHOLD, fallback),
  slider.rs, sim_display.rs. PARTIAL WIRING (real provider ✓, sim ✗).
- No demo-page widget tap assertion in the test.

Raw log: `docs/test-logs/011/scale-audit.log`

### Audit C — Test-Integrity Audit
- ZERO tests use `env!("CARGO_BIN_EXE_tbard")`. Both spawn-based tests
  resolve the binary by `current_exe()` path.
- ci-gate builds --bin tbard first ✓. Bare `cargo test` does NOT.
- Adversarial: `rm -f target/debug/tbard` → `cargo test` false-passes
  (both spawn-based tests skip → "ok"). STALE-BINARY FALSE-PASS
  CONFIRMED outside ci-gate.

Raw log: `docs/test-logs/011/test-integrity-audit.log`

### Audit D — Invariant Guard
- Throwaway copy: remove `#![deny(clippy::indexing_slicing)]` from
  src/main.rs → `scripts/check-invariants.sh` FAILS (exit 1). The
  ADR-017 guard is non-vacuous. ✓ PASS

Raw log: `docs/test-logs/011/invariant-guard-audit.log`

---

## T4 — Live Re-Verification (sudo path)

**VERDICT: CANNOT EXECUTE on this bench.**

- **Hermetic smoke**: `sudo env HOME=$(mktemp -d) ./target/debug/tbard
  --dry-run` → EBUSY (Hyprland holds vkms master on card0) → exit 1.
  The render loop never starts: NO frame counter, NO synthetic tap
  (S1-F1 acceptance line), NO hot-reload, NO SIGTERM→exit 0, NO
  immediate-rerun. All UNVERIFIABLE.
- **Three master-gated tests under sudo**: ALL THREE SKIP:
  - `test_sim_display_acquires_vkms`: SKIP (EBUSY)
  - `test_sigterm_releases_master`: SKIP (child EBUSY at acquire)
  - `test_retry_partial_alloc_releases_master_on_failure`: SKIP (master
    not acquired — bench not granted)
- The T4 instruction "Skips are NOT acceptable here — this environment
  grants them" is CONTRADICTED by live evidence. This environment does
  NOT grant vkms master on card0 because Hyprland (uid 1000) holds it,
  and the bench-grant lane is CLOSED (ADR-026; `docs/dangers.md` HOST
  SAFETY RULES forbid AQ_DRM_DEVICES / login-chain edits / compositor
  restarts). The sudo path EBUSYes identically (master-exclusivity is
  privilege-agnostic — ADR-016 §1). ADR-026 step 8 explicitly states
  "sudo works ONLY on a VT where Hyprland is not running" — this is a
  running-Hyprland Wayland session, NOT a clean VT. Switching to a clean
  VT would risk the host (compositor restart forbidden) and is NOT
  attempted per the binding HOST SAFETY RULES.

This is a **BENCH LIMITATION**, not a code defect. The test logic is
correct for a granted bench / clean VT (ADR-026 / ADR-010), but this
bench cannot provide that environment without violating HOST SAFETY
RULES. The three tests are UNVERIFIABLE on this bench.

Raw log: `docs/test-logs/011/t4-live-verification.log`

---

## Gates (verbatim)

| Gate | Result |
|---|---|
| `cargo fmt --check` | exit 0 ✓ |
| `cargo clippy --all-targets -- -D warnings` | exit 0 ✓ |
| `cargo test` | 41 unit + 1 integration = 42 passed; 0 failed (39 baseline + 3 new = 42 ✓) |
| `scripts/check-invariants.sh` | PASS ✓ |
| `scripts/ci-gate.sh` | PASS ✓ |

**Commit hygiene**: one commit per ADR (f18b82a=024, 41ab94d=025,
cc58081=027, 5f6a77c=028); ADR-before-code ✓; ADR-019 untouched ✓ (no
file). No logged exceptions in the ADR-024..028 commits.

Raw log: `docs/test-logs/011/gates-verbatim.log`

---

## New Findings → ADR Proposals (logged, NOT implemented)

### NF-1 — ADR-024 sim scale denominators not Geometry-derived (REFUTED sub-claim)
`SimInputProvider::poll()` (`sim_input.rs:223-224, 231-232`) hardcodes
`SIM_WIDTH`/`SIM_HEIGHT` (2170/60) as the `x_transformed`/`y_transformed`
denominators, NOT derived from `Geometry`. The real provider (`input.rs`)
IS wired to `self.tb_dims`; the sim provider is not. **Proposal for next
fix session**: pass `Geometry` (or the logical dims) into
`SimInputProvider` so the sim scale denominators trace to the same
source of truth as the real provider. ADR-024's claim of "single source
of truth" is only half-realized.

### NF-2 — ADR-024 real-range scale test is vacuous in execution (SKIP-pass)
`test_sim_input_scales_real_abs_range_to_logical` SKIPS 100% on this
bench ("no touch event delivered by libinput — timing/device issue")
and marks itself "ok" without asserting the transform. The test is
non-vacuous in design but vacuous in execution. **Proposal for next fix
session**: (a) increase the libinput dispatch wait / add a retry-poll
loop so the injected evdev event is reliably surfaced; (b) convert the
skip into a hard failure (panic) when the touch event is not delivered
on a bench that has uinput — a silent skip on a test that exists to
catch a scale regression is itself a regression-hiding hazard; (c) add
the missing sub-assertions: edges → 0/full span, and a demo-page widget
tap through scaled coordinates (Claim 1's stated scope).

### NF-3 — ADR-028 CARGO_BIN_EXE migration is partial (W1 confirmed)
ZERO tests use `env!("CARGO_BIN_EXE_tbard")`. Both spawn-based tests
(`test_sigterm_releases_master` in `src/lifecycle.rs`,
`test_startup_failure_exits_nonzero` in `tests/exit_code.rs`) resolve
the binary by `current_exe()` path. After `rm -f target/debug/tbard`,
bare `cargo test` false-passes (both skip → "ok"). ci-gate builds first,
but bare `cargo test` does NOT. **Proposal for next fix session**:
migrate both spawn-based tests to `env!("CARGO_BIN_EXE_tbard")` (the
canonical Cargo-provided path to the built binary). This makes `cargo
test` rebuild the binary as a test dependency (the macro references the
bin target, so Cargo tracks it). Move `test_sigterm_releases_master` to
`tests/` as an integration test (it already spawns a subprocess; it is
not a unit test). This completes the ADR-028 migration and closes the
stale-binary hazard for bare `cargo test`.

### NF-4 — T4 bench limitation (not a code defect, no ADR needed)
The three master-gated tests + hermetic smoke CANNOT execute on this
bench because Hyprland holds vkms master and the bench-grant lane is
CLOSED. This is documented (ADR-026 closure, `docs/dangers.md`). No
code change; the next service session (ADR-019) should run these tests
on a clean VT or a disposable VM per ADR-026's "disposable environment"
recommendation.

---

## Final Verdict

**BLOCKED.**

Blocking list (with ADR pointers):

1. **ADR-024 scale wiring — PARTIALLY REFUTED (NF-1, NF-2)**: the sim
   provider scale denominators are NOT Geometry-derived
   (`sim_input.rs:223-224` hardcode 2170/60), and the real-range test is
   vacuous in execution (SKIP-pass 100% on this bench). The "single
   source of truth" and "non-identity mapping asserted" claims are not
   met. → ADR-024 needs: (a) wire sim denominators to Geometry, (b) fix
   the test's libinput delivery so it ASSERTS the transform instead of
   skipping, (c) add the missing edges + widget-tap sub-assertions.

2. **ADR-028 test integrity — PARTIALLY REFUTED (NF-3 / W1)**: the
   CARGO_BIN_EXE migration is partial (zero tests use the macro; both
   spawn-based tests resolve by path). The stale-binary false-pass
   hazard persists for bare `cargo test` outside ci-gate (adversarial
   `rm -f target/debug/tbard` → `cargo test` false-passes confirmed).
   → ADR-028 needs: migrate both spawn-based tests to
   `env!("CARGO_BIN_EXE_tbard")` + move `test_sigterm_releases_master`
   to `tests/`.

Non-blocking (do not hold merge):

- **ADR-025 exit-code contract — VERIFIED** (live exit 1 on EACCES;
  panic → exit 1 unambiguous; no process::exit on resource-holding
  paths). The SIGTERM→exit 0 live verification is bench-limited
  (UNVERIFIABLE here, not a code defect).
- **ADR-027 retry cleanup — VERIFIED IN DESIGN / UNVERIFIABLE IN
  EXECUTION** (bench-limited; non-vacuous by code inspection).
- **Claim 5 docs state — VERIFIED**.
- **T0 topology deviation — non-blocking hygiene note** (single branch,
  two ADR sets; merge guidance adjusted).
- **Gates — all PASS** (fmt, clippy, test 42/42, check-invariants,
  ci-gate).

**ADR-019 service session**: NOT cleared — the exit-code contract
(ADR-025) is verified, but the daemon's SIGTERM→exit 0 + master-release
path remains UNVERIFIED live (bench-limited), and the ADR-024 scale gap
means the sim/real divergence is not closed. The service session should
wait for the blocking items to be resolved AND run the master-gated
tests on a clean VT / disposable VM (per ADR-026) to verify the
runtime paths ADR-019 will depend on.

---

*Fix report archived as data: `docs/test-logs/011/fix-report/self-assessment-4.md`.
Raw audit logs: `docs/test-logs/011/`. Devlog session 011 appended.*