# ADR 028: Test Integrity — ci-gate `cargo build --bin tbard` Step

## Status: Accepted

## Date: 2026-09-26

## Context

QA review-v4 (`docs/review-report-v4.md:163-172`) observed a
test-harness fragility: `cargo test` builds the test binary in
`target/debug/deps/` but does NOT rebuild the main `tbard` binary in
`target/debug/`. `test_sigterm_releases_master` (`src/lifecycle.rs`)
spawns `target/debug/tbard` — a stale binary (from a prior build) makes
the test FAIL with a REGRESSION panic from the OLD binary (observed with
the 00:29 binary before `cargo build --bin tbard` was run). This is a
real hazard for CI reproducibility: a green `cargo test` can hide a
stale-binary regression in the spawn-based tests.

## Decision

### 1. Add `cargo build --bin tbard` to `scripts/ci-gate.sh`

Insert a `cargo build --bin tbard` step BEFORE the clippy/test steps in
`scripts/ci-gate.sh`. This guarantees `target/debug/tbard` is fresh when
`cargo test` runs the spawn-based tests. The step is cheap when the bin
is already up-to-date (cargo's fingerprint cache).

### 2. Document the prerequisite in the test

`test_sigterm_releases_master` and `test_startup_failure_exits_nonzero`
both spawn `target/debug/tbard`; their skip messages already mention
"run `cargo build --bin tbard` first" (added in ADR-013/025). The
ci-gate step makes this automatic.

## Alternatives considered

- **`cargo test --bins`** instead of a separate build step. Rejected:
  `--bins` changes the test invocation semantics (tests the bin's unit
  tests, not the integration tests); the spawn-based tests need the
  actual `tbard` binary present, which `cargo test` alone does not
  guarantee for the main bin.
- **Make the spawn-based tests build the binary themselves.** Rejected:
  a test should not invoke `cargo build` (side effects + slow); the
  ci-gate is the right place.

## Impact list

- `scripts/ci-gate.sh` — add `cargo build --bin tbard` step.

## Regression test

The ci-gate itself is the guard: a stale `target/debug/tbard` is
rebuild before tests run, so the spawn-based tests see a fresh binary.

## References

- `docs/review-report-v4.md:163-172` — the stale-binary fragility
- `docs/adr/013-seat-gated-tests.md` — the spawn-based test pattern
- `docs/adr/025-exit-code.md` — the other spawn-based test
  (`test_startup_failure_exits_nonzero`)