# ADR 005: `--dry-run` Mode — Sim Providers on Real Kernel Interfaces (vkms + uinput)

## Status: Accepted

## Date: 2026-09-25

## Context

Pre-flight review §2.7 (`docs/review-report.md`) found that the binary has
**no `--dry-run` flag** and no simulated-provider selection in `main`. The
mock providers (`mock_display.rs`, `mock_input.rs`, `mock_backlight.rs`)
exist but are in-memory stubs, never used by `main`, and the review notes
they are "only referenced from their module declarations." The staged test
plan's Stage 1 (dry-run) cannot be executed against the binary as built.

The review also found that `IpcServer` (`src/ipc/server.rs`) is **dead
code**: it is never instantiated by `main`. Its 0600 socket-permission
enforcement is correct but vacuous (no socket = no leak). The architecture
doc and README promise an IPC API the binary does not expose.

The task requires `--dry-run` backed by **real kernel interfaces, not
stubs**: a `SimDisplayProvider` on vkms and a `SimInputProvider` on uinput,
running the full engine against them. This gives a hardware-free confidence
path that exercises the real DRM flush path and the real libinput read path,
without touching the Touch Bar or the eDP panel.

## Root cause

`main` had no argument parsing at all — it jumped straight to
`DrmProvider::new()` + `acquire()`. There was no provider-selection seam.
The mock providers were Phase-1 scaffolding that was never wired in, and the
IPC server was written ahead of its phase (scope drift) and left
disconnected.

## Decision

### 1. Add CLI argument parsing (`--dry-run`)

`main` parses `std::env::args` for `--dry-run`. No new dependency (no
`clap`); a minimal hand-rolled parser keeps the change scoped. In dry-run
mode the engine selects the Sim providers; otherwise it uses the real
providers unchanged.

### 2. `SimDisplayProvider` on vkms (`src/providers/sim_display.rs`)

A new `SimDisplayProvider` implements `DisplayProvider` by opening a
**vkms** DRM card (identified by driver name `vkms` or `faux_driver`, or by
a connector named `Virtual-*` — **not** by the Touch Bar geometry gate,
which would be wrong for a decoy). It acquires master on the vkms card
**only** (vkms is a virtual, headless device — there is no real panel to
black-blink, so master contention is a non-issue). It creates a dumb buffer
and framebuffer at a Touch-Bar-shaped resolution (60×2170, matching the
real panel orientation) so the engine's render/coordinate logic runs
unchanged, and flushes pixel data via `dirty_framebuffer` — the same code
path as the real `DrmProvider`.

If no vkms card is present, `SimDisplayProvider::acquire` returns an error
with a clear message (`modprobe vkms` hint). It does **not** fall back to
opening the eDP card — that would reintroduce the ADR-004 hazard. It does
not fall back to the in-memory `MockDisplay` either, because the point of
dry-run is to exercise the real kernel DRM path. (The existing in-memory
mocks remain for pure unit tests.)

### 3. `SimInputProvider` on uinput (`src/providers/sim_input.rs`)

A new `SimInputProvider` implements `InputProvider` by creating a virtual
multi-touch device via `/dev/uinput` (uinput is a real kernel interface)
and reading touch events back through a libinput context on `seat0` (the
uinput device lands on the default seat). This exercises the real
libinput read + ABS_MT coordinate path. A test harness or operator injects
events into the uinput device; the engine processes them through the same
`InputEvent::Touch` pipeline as on real hardware.

The uinput device is created with `EV_ABS` + `ABS_MT_POSITION_X/Y` axes
sized to 2170×60, so the coordinate transform in the engine is identical to
the real digitizer. `SimInputProvider::init` creates the device; `Drop`
closes the fd (the kernel removes the device).

### 4. Wire `--dry-run` into `main`

`real_main` is parameterised by the provider choices: in dry-run mode it
constructs `SimDisplayProvider` + `SimInputProvider` + `MockBacklight` (the
backlight is not a kernel-interface concern for dry-run; the in-memory mock
is sufficient and avoids writing to real sysfs). In normal mode it uses the
real `DrmProvider` + `LibinputProvider` + `SysfsBacklight` unchanged. The
render loop, widget engine, and config hot-reload run identically against
either set.

### 5. IpcServer dead-code decision: DEFER wiring to the IPC phase

**Recommendation: defer.** Do not wire `IpcServer` into `main` in this ADR.

**Justification:**

- The IPC server is Phase 2 scope (`docs/adr/003-ipc-protocol.md`,
  README §"Known Issues"). Wiring it now (spawning the accept thread,
  dispatching `IpcMessage` into the render loop, broadcasting
  `IpcResponse`) is scope drift beyond the dry-run goal. Dry-run only
  needs the engine to run against sim providers — it does not need IPC
  to be useful.
- The review's concern was that the 0600 enforcement is "correct in dead
  code." Deferring the wiring does not regress security: no socket is
  opened, so there is no leak surface. The `IpcServer::bind` 0600
  enforcement and `Drop` socket cleanup are preserved for the phase that
  actually wires it in.
- The lifecycle ADR (ADR 007) adds the panic-hook + signal-handler cleanup
  that will also cover the IPC socket once wired. Wiring the server now
  would require reworking that cleanup twice.
- The dead code stays compilable (crate-level `allow(dead_code)` from W1)
  and its serde round-trip tests stay green. It is a known, tracked stub,
  not silent rot.

**The one thing this ADR does wire now**: the `shutdown` IPC message path
is *not* wired. Instead, dry-run (and normal mode) get a clean shutdown via
the signal handler from ADR 007. When the IPC phase lands, `shutdown` will
map to the same shutdown signal.

### 6. Regression test

`test_dry_run_sim_providers`: constructs `SimDisplayProvider` and
`SimInputProvider` in-process, calls `init`/`acquire`, and asserts the
uinput device was created and the vkms card was opened (skipped if vkms is
not loadable). This guards the provider-selection seam.

## Alternatives considered

- **Use the in-memory mocks for dry-run.** Rejected: the task explicitly
  requires real kernel interfaces (vkms + uinput), and in-memory mocks do
  not exercise the DRM flush or libinput read paths — they would give a
  false-confidence green.
- **Wire IpcServer now.** Rejected as scope drift (see §5). The IPC phase
  will wire it with proper message dispatch and the lifecycle cleanup from
  ADR 007.
- **Open the eDP card as the dry-run render target.** Rejected: reintroduces
  the ADR-004 master-contention hazard on a real panel. vkms is the correct
  headless target.
- **Add `clap` for arg parsing.** Rejected for scope: one flag does not
  justify a new dependency and the macro/import surface it brings.

## Impact list

- `src/main.rs` — add `--dry-run` arg parsing; parameterise `real_main`
  with provider selection; branch into Sim vs real providers.
- `src/providers/sim_display.rs` — new: `SimDisplayProvider` on vkms.
- `src/providers/sim_input.rs` — new: `SimInputProvider` on uinput.
- `src/providers/mod.rs` — declare the new modules; re-export the types.
- `Cargo.toml` — no new dependencies (vkms is a kernel module; uinput is
  already used via `input-linux`/`input-linux-sys`).
- `src/ipc/server.rs` — unchanged (dead code stays, deferred to IPC phase).

## Regression test

`src/providers/sim_input.rs` tests module: `test_sim_input_creates_uinput_device`
asserts the uinput device is created and the ABS_MT axes are sized 2170×60.
`src/providers/sim_display.rs` tests module: `test_sim_display_acquires_vkms`
asserts the vkms card is opened and master acquired (skipped if no vkms).

## References

- `docs/review-report.md` §2.7 (the FAIL being fixed)
- `docs/adr/003-ipc-protocol.md` (IPC is Phase 2; this ADR defers wiring)
- `docs/adr/004-drm-discovery.md` (vkms decoy identification reused here)