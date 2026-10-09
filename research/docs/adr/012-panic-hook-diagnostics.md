# ADR 012: Panic Hook Diagnostics — Backtrace + Single Structured Entry

## Status: Accepted

## Date: 2026-09-25

## Context

The ADR-007 panic hook (`src/lifecycle.rs:68-81`) has two diagnostic
defects exposed by the BUG A panic (`docs/test-logs/dryrun-smoke.log:133-136`):

1. **Backtrace discarded.** The hook logs only `info` (the panic message +
   location). `RUST_BACKTRACE=full` produced zero frames in the log because
   the hook never calls `std::backtrace::Backtrace`. The default hook
   prints a backtrace; our custom hook replaced it and dropped the
   backtrace entirely.
2. **Duplicated panic line.** The hook emits the panic twice:
   - `eprintln!("tbard: panic: {}", info)` (line 72) — a direct stderr line.
   - `log::error!("tbard: panic: {}", info)` (line 73) — a logger line
     (which also goes to stderr under `env_logger`).
   The dryrun log shows both (lines 133-134 direct, 135-136 logger). One
   structured entry is enough; the duplication is noise.

The cleanup chain (DRM master release via RAII `Drop` + socket unlink via
the registered closure) must stay intact — this ADR only changes the
*diagnostic* output, not the cleanup behavior.

## Decision

### 1. Capture and log the backtrace

Use `std::backtrace::Backtrace::force_capture()` (unconditional, ignoring
`RUST_BACKTRACE`) so a panic always has a backtrace in the log regardless
of the env var. `force_capture` is safe to call in the panic hook (it
does not allocate on the unwinding thread in a way that re-panics; it
captures the current backtrace). Format it under the single structured
`log::error!` entry.

### 2. One structured entry (no duplicated lines)

Remove the direct `eprintln!`. Emit exactly one `log::error!` entry
containing: the panic message, the location, and the backtrace (indented).
Under `env_logger` this is a single stderr line (with the multi-line
backtrace in the message body). The `eprintln!` is dropped entirely — the
logger already writes to stderr.

### 3. Cleanup chain unchanged

`run_panic_cleanup()` (the single-fire socket-unlink closure) runs exactly
as before, after the diagnostic log. DRM master release continues to
happen via RAII `Drop` during `catch_unwind` unwind (unchanged from
ADR-007). A test asserts the cleanup still runs when the hook logs a
backtrace.

## Alternatives considered

- **Honor `RUST_BACKTRACE` instead of `force_capture`.** Rejected: the
  dryrun log showed `RUST_BACKTRACE=full` produced zero frames with the
  old hook because the hook never asked for a backtrace. `force_capture`
  guarantees one in the log for triage; operators who want no backtrace
  can set `RUST_BACKTRACE=0` (we can honor it as a secondary signal, but
  the default should capture).
- **Keep both `eprintln!` and `log::error!`.** Rejected: the duplication
  is the defect.

## Impact list

- `src/lifecycle.rs` — `install_panic_hook`: replace the two-line
  `eprintln!`+`log::error!` with one `log::error!` containing message +
  location + `Backtrace::force_capture()`. `run_panic_cleanup` unchanged.
- No dependency change (`std::backtrace` is in `std`).
- No cleanup-behavior change.

## Regression test

`src/lifecycle.rs` tests: `test_panic_hook_logs_backtrace_and_runs_cleanup`
registers a cleanup closure that sets a flag, installs the hook, triggers
a panic via `std::panic::catch_unwind`, and asserts (a) the cleanup flag
was set (cleanup ran) and (b) the captured hook output contains a
backtrace frame marker. The test uses a `static` cleanup flag + an
`Arc<AtomicBool>`/`static` to observe the closure ran.

## References

- `docs/test-logs/dryrun-smoke.log:133-136` — the duplicated panic + no backtrace
- `docs/adr/007-lifecycle.md` — the hook being fixed (cleanup chain preserved)