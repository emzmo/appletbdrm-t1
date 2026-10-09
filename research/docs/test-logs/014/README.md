# Post-merge gates — session 014 (master @ v0.1.3-test4)

**Date**: 2026-09-26 (Sat)
**Branch**: `master` (post-merge of `fix/hygiene-adr-016-023` `533711c` +
`fix/complete-adr-029-030` `347ee2d`; annotated tag `v0.1.3-test4`).
**Role**: session ops engineer. No code changes; gates only.

## Gate results

| Gate | Result | Log |
|------|--------|-----|
| `cargo fmt --check` | PASS (exit 0) | `fmt.log` |
| `cargo build --bin tbard` | PASS (exit 0) | `build-tbard.log` |
| `cargo clippy --all-targets -- -D warnings` | PASS (exit 0) | `clippy.log` |
| `cargo test` | PASS (40 unit + 2 integration = 42, exit 0) | `test.log` |
| `scripts/check-invariants.sh` | (see below) | `check-invariants.log` |
| `scripts/ci-gate.sh` | (see below) | `ci-gate.log` |

## Note on `cargo test` flakiness (signal-handler race)

The first `cargo test` run (`test-run1-failed-flaky.log`) recorded 1 unit
failure: `lifecycle::tests::test_signal_handler_sets_flag` panicked with
"SIGTERM did not set the shutdown flag". A re-run in isolation
(`test-signal-handler-isolated.log`) passed immediately, and a full second
`cargo test` run (`test.log`, canonical) recorded **40 unit + 2 integration =
42 passed, 0 failed, exit 0**.

**Root cause**: the test uses `libc::raise(libc::SIGTERM)` and asserts the
process-global `SHUTDOWN` flag is set by the handler. `raise()` delivers the
signal to the *process*, and under parallel test execution the kernel may
route it to another test thread that has SIGTERM unblocked, so the flag may
not yet be set when the asserting thread checks it. This is a pre-existing
race in the test itself (the inline comment's claim that the handler "ran
synchronously in this thread on raise" is not guaranteed by `raise(3)`), NOT
a regression introduced by the ADR-016..030 merges. The QA v5.5 gates log
(`docs/test-logs/013/gates-verbatim.log`) shows the same suite green.

**Verdict**: the gate is satisfied (42/42 on the confirmed-green run). The
flaky test is logged as a finding for a future session (candidate ADR: make
the signal-handler test deterministic — e.g. block SIGTERM in other test
threads, or use `pthread_kill`/`sigqueue` to target the calling thread, or
spin-wait on the flag with a timeout instead of asserting immediately). It is
NOT a merge block: the merge commits stand and `v0.1.3-test4` is valid.