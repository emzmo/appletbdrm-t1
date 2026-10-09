# ADR 030: Complete ADR-028 — Spawn-Based Test Migration to CARGO_BIN_EXE

## Status: Accepted

## Date: 2026-09-26

## Context

QA v5 (`docs/review-report-v5.md` Claim 4, NF-3 / W1) partially refuted
ADR-028:

1. **ZERO tests use `env!("CARGO_BIN_EXE_tbard")`** (grep across `src/`,
   `tests/`). ADR-028's claim "binary-spawning tests live in `tests/` via
   `env!("CARGO_BIN_EXE_tbard")`" is refuted:
   - `test_startup_failure_exits_nonzero` (`tests/exit_code.rs:14-23`)
     resolves the binary by
     `std::env::current_exe().parent().parent().join("tbard")` — a
     computed path, NOT the Cargo-provided macro.
   - `test_sigterm_releases_master` (`src/lifecycle.rs:207-367`) is a UNIT
     test in `src/lifecycle.rs` (NOT in `tests/`), and ALSO resolves the
     binary by `current_exe()` path-resolution (`lifecycle.rs:212-219`).

2. **Adversarial stale-binary false-pass confirmed (Audit C.3)**: after
   `rm -f target/debug/tbard`, bare `cargo test` does NOT rebuild the
   binary. Both spawn-based tests SKIP (binary-not-found →
   `.filter(|p| p.exists())` returns `None` → `eprintln` skip → `return`
   → "ok" pass). The tests PASS against NOTHING. This is the exact QA v4
   live regression (stale/absent binary → false pass), reproducible at
   will outside `ci-gate.sh`. `ci-gate` builds `--bin tbard` first, so
   the hazard is contained WITHIN ci-gate, but NOT within bare
   `cargo test` (the common dev invocation).

### Why the migration closes the hazard (structural, not procedural)

`env!("CARGO_BIN_EXE_tbard")` is a compile-time macro that expands to the
absolute path of the built `tbard` binary. The macro references the bin
target by name, so Cargo tracks the bin as a dependency of the test
crate: `cargo test` (and `cargo test --no-run`) rebuild the bin whenever
it is stale, BEFORE the test runs. This makes the rebuild structural —
there is no "forgot to build" path. The `current_exe()` approach does
not create this dependency; the test binary and the `tbard` binary are
built independently, so a stale/absent `tbard` is invisible to the test
harness (the test just skips).

ADR-028's `cargo build --bin tbard` step in `scripts/ci-gate.sh` remains
valuable (it validates the bin builds independently of the test
harness, and it is the honest precondition within ci-gate), but it is a
procedural guard, not a structural one. The `CARGO_BIN_EXE` migration
makes the rebuild structural and closes the bare-`cargo-test` hazard.

## Decision

### 1. Migrate `test_sigterm_releases_master` to `tests/sigterm_master_release.rs`

Move the test OUT of `src/lifecycle.rs` (where it was a unit test) into
a new integration test `tests/sigterm_master_release.rs`, and resolve
the binary via `env!("CARGO_BIN_EXE_tbard")` instead of
`current_exe()` path-resolution.

The test's in-process master-release verification (re-open the vkms
card and assert `acquire_master_lock()` succeeds) requires the `drm`
crate and a vkms-card finder. The `drm` crate is a project dependency
(available to integration tests). The `find_vkms_card` helper lives in
`src/providers/sim_display.rs` (not accessible from `tests/` because
this is a bin-only crate with no lib target). Rather than add a lib
target (a structural change out of scope for a test-integrity ADR), the
integration test inlines the vkms-card finder (a small std-only helper
that reads `/dev/dri/` + `/sys/class/drm/` driver symlinks). This keeps
the test self-contained and the master-release assertion non-vacuous.

### 2. Migrate `test_startup_failure_exits_nonzero` to `env!("CARGO_BIN_EXE_tbard")`

`tests/exit_code.rs` replaces the `current_exe()` path-resolution
(`exit_code.rs:16-23`) with `env!("CARGO_BIN_EXE_tbard")`. The test
location (already in `tests/`) and the ADR-013 classification logic are
unchanged.

### 3. Keep the ADR-013 classification (verbatim stderr)

Both migrated tests keep the ADR-013 classification: the spawned
child's stderr is captured verbatim, and three early-exit cases are
distinguished in code (NO GUESSING):
- child panicked at startup → `panic!` (REGRESSION, code bug), embedding
  the verbatim stderr;
- master `EACCES` (seat/privilege) → skip with verbatim stderr;
- clean early exit → skip with verbatim stderr.

The skip on `EACCES` is the truthful-skip class (the bench does not
grant master); the skip on binary-not-found is REMOVED — with
`CARGO_BIN_EXE_tbard`, the binary is always present when the test runs
(Cargo rebuilds it as a test dependency), so the "binary not found"
skip branch is deleted. If the macro path ever points at a missing
binary, that is a Cargo bug, not a skip condition.

### 4. `current_exe` self-spawn dispatch in main

There is NO `current_exe` self-spawn dispatch in `main.rs` — the only
`current_exe` usages in the codebase were the two spawn-based tests'
binary resolution (grep-verified: `src/lifecycle.rs:212`,
`tests/exit_code.rs:16`). After migration, both use
`env!("CARGO_BIN_EXE_tbard")`; `current_exe` no longer appears anywhere
in `src/` or `tests/`. Nothing else depends on the `current_exe`
resolution; nothing to remove from `main`.

### 5. Keep the ci-gate `cargo build --bin tbard` step

`scripts/ci-gate.sh` keeps the `cargo build --bin tbard` step (ADR-028).
Its honest role: it validates the bin builds INDEPENDENTLY of the test
harness (a separate `cargo build` invocation that fails the gate if the
bin does not compile, even if the test crate would compile). The
`CARGO_BIN_EXE` migration makes the test rebuild structural, but the
ci-gate step remains a useful independent-build check.

### 6. Adversarial self-check (regression closure)

The adversarial check from QA v5 Audit C.3 is re-run after migration:
`rm -f target/debug/tbard` → `cargo test` must REBUILD the bin as a
test dependency (via `CARGO_BIN_EXE_tbard`) and NOT false-pass. With the
macro, this is structural — the test references the bin target, so
Cargo rebuilds it. The observed behavior is documented in the final
report as the regression closure.

### 7. Granted-environment execution path (human's VT run)

For a human running the master-gated tests on a granted VT (clean VT
with no compositor, per ADR-026), the prebuilt-binary path is:

1. `cargo test --no-run` (as the user) — builds the test binaries +
   the `tbard` bin (as a test dependency via `CARGO_BIN_EXE_tbard`).
2. `sudo ./target/debug/deps/<test-binary> --nocapture` — run each
   prebuilt test binary under root on the VT.

The exact prebuilt binary names are listed in the final report (they
include a hash suffix; the exact names are enumerated from
`target/debug/deps/`).

## Alternatives considered

- **Add a lib target and re-export `find_vkms_card`.** Rejected: adding
  a `src/lib.rs` and refactoring `main.rs`'s `mod` declarations is a
  structural change beyond a test-integrity ADR's scope ("no new
  features"). Inlining the std-only vkms finder in the test is minimal
  and keeps the test self-contained.
- **Keep `current_exe()` and rely on ci-gate's build step.** Rejected:
  QA v5 proved the hazard persists for bare `cargo test` (the common
  dev invocation). The procedural guard does not close the structural
  gap.
- **Make the tests `cargo build` the bin themselves.** Rejected (same
  as ADR-028): a test should not invoke `cargo build` (side effects +
  slow); `CARGO_BIN_EXE` is the canonical Cargo-provided path.

## Impact list

- `tests/sigterm_master_release.rs` — NEW integration test (moved from
  `src/lifecycle.rs`); uses `env!("CARGO_BIN_EXE_tbard")`; inlines the
  vkms-card finder; keeps ADR-013 verbatim-stderr classification.
- `src/lifecycle.rs` — `test_sigterm_releases_master` removed (the
  other lifecycle tests — shutdown flag, signal handler, panic hook —
  remain).
- `tests/exit_code.rs` — `current_exe()` resolution replaced with
  `env!("CARGO_BIN_EXE_tbard")`; binary-not-found skip branch removed.
- `scripts/ci-gate.sh` — no change (the `cargo build --bin tbard` step
  stays; its honest role is documented above).

## Regression test

The adversarial `rm -f target/debug/tbard` → `cargo test` check is the
regression closure: after migration, `cargo test` rebuilds the bin (via
`CARGO_BIN_EXE_tbard`) and the spawn-based tests run against the fresh
binary instead of skipping. The ADR-013 classification remains
non-vacuous (panicked / EACCES / clean-exit distinguished in code).

## References

- `docs/review-report-v5.md` Claim 4, NF-3, W1, Audit C.3 — the refuted
  sub-claims and the stale-binary false-pass
- `docs/adr/028-test-integrity.md` — the ADR this completes
- `docs/adr/013-seat-gated-tests.md` — verbatim-stderr classification
- `docs/adr/010-master-acquisition-input.md` — the sudo prebuilt-binary
  bench path
- `docs/adr/026-granted-bench-procedure.md` — the granted-VT procedure
  (closed lane on this machine; tests re-run on a clean VT / disposable
  VM)
- Cargo book: `CARGO_BIN_EXE_<name>` — the compile-time path to the
  built binary