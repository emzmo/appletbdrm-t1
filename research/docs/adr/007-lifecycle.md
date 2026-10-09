# ADR 007: Lifecycle — Signal Handler, RAII Master Guard, Panic Hook

## Status: Accepted

## Date: 2026-09-25

## Context

Pre-flight review §2.3 and §2.5 (`docs/review-report.md`) found:

- The main render loop is an **infinite `loop {}` with no exit condition**
  — no `SIGTERM`/`SIGINT` handler, no shutdown message. The only "shutdown"
  is `panic::catch_unwind` which swallows panics silently.
- **`DrmProvider` has no `impl Drop`** — `release()` (which destroys the
  framebuffer and dumb buffer in the correct order) is never called on the
  panic path or on normal exit. DRM master is released only when the
  kernel closes the fd on process death. A framebuffer/dumb-buffer leak on
  the device is possible across restarts.
- **`unsafe` blocks** in `fonts.rs` have no SAFETY justification (overlap
  with ADR 006 — the NULL checks are now added; this ADR adds the
  remaining SAFETY comments and the resource-release guarantees).
- `IpcServer::Drop` unlinks the socket, but the server is not wired in
  (ADR 005 defers wiring). When it is wired, the panic hook must also
  unlink the socket.

The task requires: SIGTERM/SIGINT handler, RAII guard releasing DRM master,
panic hook releasing master + unlinking socket, and a regression test that
starts the daemon, sends SIGTERM, and asserts master was released (a second
instance can acquire it).

## Root cause

There was no structured shutdown path: the loop never returned, signals
were not handled, and `DrmProvider` relied on Rust's default drop glue
(which closes the fd and lets the kernel release master) instead of an
explicit `Drop` that destroys GPU resources in order and drops master
cleanly. The panic hook was the default (prints + aborts-ish via
`catch_unwind` swallowing), with no cleanup.

## Decision

### 1. RAII DRM master guard (`DrmMasterGuard`)

A `DrmMasterGuard` wraps the DRM `Card` fd and, on `Drop`, calls
`drop_master_lock()` (best-effort, logged on error) **before** the fd is
closed. This makes master release deterministic and testable independent of
process exit. `DrmProvider` holds the guard; `DrmProvider::release()` is
kept as the explicit documented path and `Drop` forwards to it.

`SimDisplayProvider` gets the same RAII treatment (it holds master on the
vkms card; releasing it on shutdown keeps the vkms card clean for the next
test run).

### 2. Signal handler (SIGTERM / SIGINT)

Install a signal handler via `nix::sys::signal` (already a dependency) on a
dedicated `SIGTERM` and `SIGINT` handler that sets a process-global
`AtomicBool` shutdown flag. The render loop checks the flag each iteration
and breaks cleanly, running `Drop` glue (which releases master via the
guard) as the stack unwinds normally. `real_main` returns `Ok(())` on a
signal shutdown.

The handler is async-signal-safe (it only sets an atomic) — no allocation,
no I/O, no locks. A self-pipe / signalfd alternative was considered; the
atomic-flag + poll-loop check is sufficient because the loop already wakes
every 10 ms.

### 3. Panic hook (master release + socket unlink)

Install a `std::panic::set_hook` that, on panic, logs the panic location and
calls a registered cleanup closure (release DRM master, unlink the IPC
socket path if present). The cleanup closure is registered once at startup
and stored in a `OnceLock<Box<dyn FnOnce() + Send>>`. Because the panic
hook runs on the panicking thread before unwinding, and `catch_unwind`
catches the unwind, the hook ensures cleanup happens even when the loop
panics (e.g. a residual cairo OOM `unwrap`). After the hook runs,
`catch_unwind` returns `Err` and `main` logs + exits.

The socket-unlink part is a no-op today (IPC server deferred per ADR 005)
but the hook infrastructure is in place for the IPC phase.

### 4. SAFETY comments

All remaining `unsafe` blocks in `fonts.rs` (and any new ones in the signal
handler / drop paths) get `// SAFETY:` comments stating the invariant
(typed pointer non-NULL, async-signal-safety, etc.). ADR 006 added the
NULL checks; this ADR adds the justification prose the review §2.5 asked
for.

### 5. Regression test

`test_sigterm_releases_master`: spawn the daemon (or a minimal harness that
acquires master on a vkms card), send `SIGTERM`, wait for exit, then
assert a second acquisition of master on the same card succeeds (proving
the first instance released it). Uses vkms (headless) so no real panel is
disturbed. Skipped when vkms/master is unavailable in the test environment.

## Alternatives considered

- **`signalfd` / self-pipe.** Rejected for scope: the render loop already
  polls every 10 ms; an atomic flag checked in the loop is simpler and
  avoids a second fd in the select/poll set. signalfd is the right choice
  if the loop later blocks on a multi-fd poll.
- **`Drop` for `DrmProvider` only, no signal handler.** Rejected: without
  a signal handler the loop never exits, so `Drop` never runs on SIGTERM.
  Both halves are required.
- **`panic = "abort"` + no hook.** Rejected: abort skips drop glue, which
  is the resource leak the review flagged. We want unwinding + a hook +
  `Drop`.

## Impact list

- `src/providers/drm_backend.rs` — add `impl Drop for DrmProvider`
  forwarding to `release()`; `release()` drops master explicitly.
- `src/providers/sim_display.rs` — `impl Drop` already calls `release()`;
  ensure master is dropped explicitly.
- `src/lifecycle.rs` — new: signal handler installation, shutdown flag,
  panic-hook registration with a cleanup closure.
- `src/main.rs` — install the signal handler + panic hook at startup; loop
  checks the shutdown flag and breaks; `main` exits 0 on signal shutdown.
- `src/fonts.rs` — SAFETY comments on all `unsafe` blocks.
- No new dependencies (`nix` signal feature already enabled).

## Regression test

`src/lifecycle.rs` tests module: `test_sigterm_releases_master` spawns a
minimal harness process that acquires master on vkms, sends SIGTERM, and
asserts a second master acquisition succeeds. Skip when vkms/master
unavailable.

## References

- `docs/review-report.md` §2.3 (infinite loop / no shutdown), §2.5
  (no `impl Drop`, no SAFETY comments)
- `docs/adr/006-typed-errors.md` (NULL checks added there; SAFETY prose
  here)