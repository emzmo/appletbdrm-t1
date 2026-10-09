# ADR 022: SIGTERM-Responsive DRM Card-Open Retry (S2-F1)

## Status: Accepted

## Date: 2026-09-26

## Context

Stage 2 finding **S2-F1** (`docs/test-logs/007/SUMMARY.md:74-92`): when
`tbard` runs in real mode and `try_open_card` fails (e.g. EBUSY because
the oracle holds master), `open_with_retry` (`src/providers/drm_backend.rs:200-247`)
retries 30× with 2s sleeps but does NOT check `lifecycle::should_shutdown()`.
A SIGTERM during the retry loop is ignored — the signal handler sets the
atomic flag, but nothing in the retry loop reads it. The daemon only
checks `should_shutdown()` in the render loop (`src/main.rs:264`), which
is never reached. `timeout --signal=SIGTERM` had no effect; `kill -KILL`
was required. This violates ADR-007's "clean shutdown on SIGTERM"
guarantee during the startup phase.

## Decision

### 1. Retry loop checks `should_shutdown()` each iteration

`open_with_retry` checks `lifecycle::should_shutdown()` at the top of
each retry iteration. If set, it breaks immediately, releasing any
partial resources, and returns an `Err` (typed, distinct from the
"card never appeared" exhaustion). `main`'s real-mode path treats a
SIGTERM-during-retry as a clean exit (logs + exits 0 via the graceful
path), not a panic.

### 2. Distinct error for SIGTERM exit

A `HwError` variant (or a distinct bail message) distinguishes "retry
aborted by shutdown signal" from "card never appeared after N attempts"
so `main` can exit 0 on the former and non-zero on the latter. The
existing `HwError::NotFound` / a new explicit message is used.

### 3. Injectable open for the unit test

`open_with_retry` calls `crate::providers::discover_touchbar_drm()` +
`try_open_card`. To unit-test the SIGTERM-responsiveness without a real
EBUSY card, make the attempted open injectable: `open_with_retry` takes
a closure (or a trait object) that attempts the open, defaulting to the
real `discover + try_open_card`. The test injects a closure that always
returns `Err(EBUSY)`, SIGTERMs the shutdown flag, and asserts the retry
loop exits cleanly in < 2s (not 60s).

## Alternatives considered

- **Check `should_shutdown` only between retries (in the sleep).**
  Rejected: the 2s sleep itself blocks; checking only before the sleep
  still waits up to 2s after a signal. Checking at the top of each
  iteration + shortening the sleep into a shutdown-aware wait is
  cleaner. This ADR checks at the top of each iteration.
- **signalfd / self-pipe in the retry loop.** Rejected for scope: the
  atomic-flag poll is sufficient and already exists.

## Impact list

- `src/providers/drm_backend.rs` — `open_with_retry` checks
  `lifecycle::should_shutdown()` each iteration; breaks + returns a
  distinct `Err` on shutdown. The attempted-open becomes injectable
  (closure parameter with a default for production).
- `src/main.rs` — real-mode retry caller treats a shutdown-during-retry
  as a clean exit (no panic).
- No new dependency.

## Regression test

`src/providers/drm_backend.rs` tests: `test_retry_aborts_on_shutdown` —
injects a closure returning persistent `EBUSY`, sets
`lifecycle::should_shutdown()`, calls `open_with_retry` with a short
retry interval, asserts it returns `Err` (the shutdown message) in
< 2s (not the full 60s). No real DRM card needed.

## References

- `docs/test-logs/007/SUMMARY.md:74-92` — S2-F1
- `docs/adr/007-lifecycle.md` — the SIGTERM guarantee being extended to
  the startup retry phase