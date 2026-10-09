# ADR 032: Deterministic Signal-Handler Test

## Status: Accepted

## Date: 2026-09-26

## Context

Session 014 finding (`docs/test-logs/014/README.md`): the unit test
`lifecycle::tests::test_signal_handler_sets_flag` is flaky under
`cargo test`'s parallel harness. The test does:

```rust
reset_shutdown();
install_signal_handlers();
unsafe { libc::raise(libc::SIGTERM); }
assert!(should_shutdown(), "SIGTERM did not set the shutdown flag");
```

The inline comment claims "The signal handler ran synchronously in this
thread on raise." This is **not guaranteed by `raise(3)`**. `raise(3)`
delivers the signal to the *process* (per POSIX: "the raise() function
shall send the signal sig to the executing thread or process"). On Linux
glibc, `raise()` uses `pthread_kill(pthread_self(), sig)` for threaded
processes, which targets the calling thread — BUT the signal may be
delivered to **any thread that has it unblocked**, and under `cargo
test`'s parallel harness multiple test threads exist. If the kernel
routes the SIGTERM to another test thread (one that is not the asserting
thread), the `SHUTDOWN` flag is set by that other thread's handler, but
the asserting thread's `should_shutdown()` check may race the store
becoming visible — or, more precisely, the test is non-deterministic
because the signal delivery thread is not guaranteed to be the asserting
thread, so the immediate `assert!` after `raise()` can fire before the
flag is observable.

The first `cargo test` run in session 014
(`docs/test-logs/014/test-run1-failed-flaky.log`) recorded 1 failure:
"SIGTERM did not set the shutdown flag". An isolated re-run passed
immediately (`test-signal-handler-isolated.log`), and the full second
run was 42/42 green. This is a pre-existing race in the test itself, NOT
a regression.

## Decision

### 1. Make the unit test deterministic via a spin-wait with timeout

Replace the immediate `assert!(should_shutdown())` after `raise()` with a
**spin-wait with a bounded timeout** (e.g. 500ms). The signal handler's
atomic store is eventually visible to the asserting thread; the spin-wait
gives it time to become visible regardless of which thread the kernel
routed the signal to. This is the minimal, lowest-risk fix: it does not
change the signal-delivery mechanism, only the observation window.

The spin-wait polls `should_shutdown()` every ~1ms and bails with a clear
"REGRESSION" message if the flag is not set within the timeout. The
timeout is generous (500ms) — in practice the store is visible within
microseconds, but 500ms tolerates any scheduler latency.

### 2. Keep the integration test as the authoritative check

The integration test `tests/sigterm_master_release.rs`
(`test_sigterm_releases_master`) spawns the **real binary**
(`env!("CARGO_BIN_EXE_tbard")`) in dry-run mode, sends SIGTERM, waits for
exit, and asserts `exit.success()` (exit 0). This is the **authoritative**
end-to-end check that the signal handler works in the real daemon — it
exercises the actual binary's signal handler → render-loop break → RAII
drop → master release path. The unit test is the fast in-process check;
the integration test is the production-faithful check. Together they make
the signal-handler contract deterministic at both layers.

### 3. Adversarially re-run the previously flaky case ~10x to demonstrate

After the fix, run the unit test ~10x in the full `cargo test` suite (and
in isolation) to demonstrate the flake is gone. Evidence captured in
`docs/test-logs/015/signal-test-10x.log`.

## Alternatives considered

- **`pthread_kill(pthread_self(), SIGTERM)` explicitly.** This is what
  glibc's `raise()` already does for threaded processes, so it does not
  change the behavior. The race is in the observation, not the delivery
  target. Rejected as a no-op.
- **Block SIGTERM in all other test threads via `sigprocmask`.** This
  would force delivery to the test thread, but `sigprocmask` is
  process-wide on Linux (the per-thread mask is inherited but
  `pthread_sigmask` is per-thread) and coordinating it across all test
  threads is complex and fragile. The spin-wait is simpler and
  sufficient.
- **Remove the unit test entirely, rely only on the integration test.**
  Rejected: the unit test is the fast in-process check that the handler
  *sets the flag*; the integration test requires vkms master and skips
  in many session classes. Keeping both (with the unit test made
  deterministic) is the robust shape.
- **Use `sigtimedwait` with the signal blocked.** This would deterministically
  consume the signal on the calling thread, but it changes the test's
  shape significantly (block → raise → timedwait → check) and requires
  the handler to NOT fire (so the flag would not be set — defeating the
  purpose of testing the handler). Rejected.

## Impact list

- `src/lifecycle.rs` — `test_signal_handler_sets_flag`: replace the
  immediate `assert!` with a bounded spin-wait (poll `should_shutdown()`
  every 1ms, timeout 500ms, REGRESSION assert on timeout).
- No production code change (the signal handler is unchanged).
- `docs/test-logs/015/signal-test-10x.log` — adversarial 10x re-run
  evidence.

## Regression test

The existing `test_sigterm_releases_master` integration test is the
end-to-end guard. The (now-deterministic) unit test is the fast in-process
guard. The 10x re-run demonstrates the flake is gone.

## References

- `docs/test-logs/014/README.md` — the flaky-test finding
- `docs/test-logs/014/test-run1-failed-flaky.log` — the failure
- `docs/test-logs/014/test-signal-handler-isolated.log` — isolated pass
- `tests/sigterm_master_release.rs` — the authoritative integration test
- `docs/adr/007-lifecycle.md` — the signal-handler guarantee