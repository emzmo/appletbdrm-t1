# Issue 000-2 — Six blocking pre-flight FAILs preventing Stages 1–7

**Session**: 000 (pre-flight review, 2026-09-25)
**Severity**: Critical (blocks all hardware contact beyond Stage 0)
**Status**: Logged. Fixes deferred to a branch with ADRs (FREEZE RULE).

This issue consolidates the six blocking findings from
`docs/review-report.md`. Each has a root-cause chain ending at a specific
line, an affected-surface list, and a pointer to the ADR to be written.
No fix is applied in this session.

## Finding A — Name-string digitizer gate + udev seat rules miss T1 names

### Causal chain
1. `src/providers/input.rs:69-72` `is_digitizer()` matches the device by
   substring of its name (`"Touch Bar"` / `"iBridge Touchpad"` /
   `"T1 Controller Touchpad"`). This is the **only** gate that selects
   which libinput device is treated as the Touch Bar digitizer.
2. `src/providers/input.rs:107` drops all touch events from any device
   that is not `self.digitizer`.
3. `src/providers/input.rs:56` assigns the `tb_input` libinput context to
   `seat-touchbar`, so only devices on that seat are even enumerated.
4. The seat assignment is performed by udev. The installed rules
   `/etc/udev/rules.d/99-touchbar-seat.rules:3-5` match only
   `"Apple Inc. Touch Bar Display Touchpad"`, `"MacBookPro17,1 Touch Bar"`,
   `"Mac14,7 Touch Bar"` — all T2/ARM names. They omit the T1 names
   `"Apple Inc. iBridge Touchpad"` (present on THIS bench, confirmed by
   `udevadm info /sys/class/input/input13` showing no `ID_SEAT=`) and
   `"Apple Inc. Apple T1 Controller Touchpad"` (the Seborider PR #1 name,
   `docs/prior-art.md:200`).
5. Therefore on this bench the digitizer sits on `seat0`, `tb_input` never
   sees it, `self.digitizer` stays `None`, and **no touch events ever reach
   the render loop**.

### Affected surface
- `src/providers/input.rs:69-72` (gate), `:107` (drop), `:56` (seat assign)
- `backup_old/udev-rules/99-touchbar-seat.rules:3-5` (deployed copy) and
  `/etc/udev/rules.d/99-touchbar-seat.rules` (installed copy on this host)
- `docs/architecture.md:140-143`, `docs/adr/001-architecture.md:43-45`
  (docs claim geometry-only; code disagrees)
- `docs/prior-art.md:200,262` (PR #1 acknowledged, not resolved)
- Any future Stage 4/5 run: would produce a false "touch works" negative

### Proposed ADR
ADR 004: replace `is_digitizer` with a geometry check (ABS_MT_POSITION_X
range/resolution matching the Touch Bar width, as the file header comment
already claims but does not implement), and make the udev seat rules
name-agnostic (match on `ID_INPUT_TOUCHSCREEN=1` + the iBridge USB parent,
or include both T1 names explicitly as a transitional measure).

## Finding B — DRM discovery opens every card and grabs master on the eDP panel

### Causal chain
1. `src/providers/mod.rs:107-118` `discover_touchbar_drm()` iterates
   **all** `/dev/dri/card*`.
2. `src/providers/mod.rs:141-146` `probe_drm_device()` opens each card
   read+write and calls `card.acquire_master_lock()` (line 146) **before**
   the geometry check at line 166.
3. On this bench that takes DRM master on `card1` (i915, the laptop eDP
   panel) during the scan — a master-contention hazard against any running
   compositor (danger D4).
4. The matched Touch Bar card is then **re-opened** by `try_open_card`
   (`src/providers/drm_backend.rs:61-66`) after the probe `Card` is dropped,
   so `card0` is opened twice with a master-less gap between.

### Affected surface
- `src/providers/mod.rs:105-171` (discovery + probe)
- `src/providers/drm_backend.rs:189-236` (`open_with_retry` re-opens)
- `docs/architecture.md:136-140` (doc admits "open each")
- Any live GUI session running Stage 3+ (laptop panel black-blink risk)

### Proposed ADR
ADR 005: in `probe_drm_device`, check the connector mode geometry **before**
acquiring master, and acquire master only on the card that passes; or
short-circuit the scan by checking `/sys/class/drm/<card>-*/modes` from
sysfs without opening the node at all. Open the matched card exactly once.

## Finding C — Infinite loop, no shutdown, hardware-path unwraps/panics

### Causal chain
1. `src/main.rs:165-323` `real_main` is `loop { … }` with no `break`, no
   `return`, no message-driven exit, and no signal handler.
2. `src/main.rs:81` wraps `real_main` in `panic::catch_unwind`, which
   **swallows** any panic and then `main` returns — without calling
   `DisplayProvider::release()`, without removing the IPC socket, without
   dropping DRM resources in order.
3. `src/main.rs:77,85,95,97,99,117,118,121,124,136,142,191,199,205,338,350`
   use `panic!`/`expect`/`unwrap` on DRM, uinput, sysfs-backlight, and
   uinput-write paths. A single uinput `write` failure in `emit_keys`
   (`src/main.rs:338,350`) kills the daemon mid-touch.
4. `src/providers/backlight.rs:30` `read_attr` panics if the brightness
   sysfs file is missing.

### Affected surface
- `src/main.rs:45-82, 84-323, 326-351`
- `src/providers/backlight.rs:28-34`
- `src/widgets/button.rs:65,71,76`, `src/widgets/slider.rs:51,58,69,74`
  (render-path unwraps)
- `src/fonts.rs:81,86,91,95` (FFI unwraps)
- Any stage that starts the daemon: no clean exit on SIGTERM (danger D5);
  DRM resource leak on panic ( Finding D )

### Proposed ADR
ADR 006: add a SIGTERM/SIGINT handler (via `nix::sys::signal` or a
`signal_hook` crate) that sets an `AtomicBool` exit flag and breaks the
loop; call `drm.release()` and `ipc.cleanup()` on exit; add `impl Drop` for
`DrmProvider` as a belt-and-suspenders; replace hardware-path
`unwrap()`/`expect()`/`panic!()` with `Result` propagation + log + fail-safe.

## Finding D — `unsafe` unjustified; error paths do not release DRM resources

### Causal chain
1. `src/fonts.rs:37,42,49,60,82,87,96,107` — `unsafe` FFI blocks have **no
   SAFETY comment**. `FontConfig::new` (`:36-39`) stores the
   `FcInitLoadConfigAndFonts()` return without a NULL check; `Pattern::new`
   (`:80-83`) does not check `FcNameParse`'s return. A NULL pointer would
   crash on the next FFI call.
2. `src/providers/drm_backend.rs:32-40` `DrmProvider` has **no `impl Drop`**.
   `release()` (`:281-297`) destroys the framebuffer and dumb buffer in
   order, but is **never called** on the panic path ( Finding C ) or on
   normal exit (there is none). Resources are reclaimed only by OS fd
   close, which does not destroy the dumb buffer / framebuffer objects on
   the device in an ordered way.

### Affected surface
- `src/fonts.rs:36-39, 80-83, 58-62, 105-108`
- `src/providers/drm_backend.rs:32-40, 239-248, 281-297`
- `src/main.rs:81-82` (`catch_unwind` swallows panic, no cleanup)

### Proposed ADR
ADR 007: add SAFETY comments to every `unsafe` block in `fonts.rs`; check
FFI return pointers for NULL before use; add `impl Drop for DrmProvider`
that calls `release()`'s cleanup; ensure `release()` is called on every
exit path.

## Finding E — Backlight fail-safe not enforced; can leave the bar dark silently

### Causal chain
1. `src/providers/backlight.rs:55-63` `set_backlight_file` opens the
   brightness sysfs file and writes; both the `open` and the `write` errors
   are silently discarded (`if let Ok`, `let _ =`). The in-memory
   `current_bl` is updated before the write (`:107`), so the daemon believes
   the write succeeded even if it failed.
2. `src/providers/backlight.rs:30` `read_attr` panics if the brightness
   file is missing at startup → daemon dies → bar left in kernel-default
   state (could be dark).
3. `src/providers/backlight.rs:100-104` drives `new_bl = 0` after 60 s idle
   by design. This conflicts with "never dark" on the idle path (acceptable
   as a feature) but combines with point 1 to make a silent-write-failure
   indistinguishable from an intentional idle-off.

### Affected surface
- `src/providers/backlight.rs:28-34, 55-63, 85-113`
- `src/main.rs:121` (`expect` on backlight init)
- Any Stage 3+ run: bar may be dark with no alarm (danger D6, D7)

### Proposed ADR
ADR 008: on `set_backlight_file` failure, log loudly and retry with a
bounded backoff; if still failing, set a liveness flag that the render loop
can surface (e.g. render a visible "ERR" pattern). Replace the startup
panic with a `Result` and a fail-safe visible default. Decouple idle-off
(known, intentional) from write-failure (unknown, alarming).

## Finding F — No `--dry-run`; IPC server not wired into `main`

### Causal chain
1. `src/main.rs:45-82` `main` does no CLI parsing (no `clap`, no
   `std::env::args`). There is no `--dry-run` flag and no path that selects
   mock providers. The mock providers (`mock_display.rs`, `mock_input.rs`,
   `mock_backlight.rs`) are compiled but unused at runtime.
2. `src/ipc/server.rs:34-60` `IpcServer::bind` correctly sets socket mode
   0600, but `grep IpcServer src/main.rs` returns zero matches — the IPC
   server is never instantiated. The entire `src/ipc/` module is dead code
   at runtime. The documented IPC API (`README.md:76-89`,
   `proto/protocol.md`) is not delivered by this binary.

### Affected surface
- `src/main.rs:45-82` (no arg parsing, no dry-run)
- `src/ipc/server.rs:34-60, 146-149` (correct but unreachable)
- `src/ipc/mod.rs`, `src/ipc/protocol.rs` (compiled, unused)
- `README.md:76-89`, `proto/protocol.md` (document an API the binary lacks)
- Test plan Stage 1 (dry-run) and Stage 6 (IPC) — both cannot run

### Proposed ADR
ADR 009: add CLI parsing (`clap` or manual `env::args`) with a `--dry-run`
flag that selects `MockDisplay`/`MockInput`/`MockBacklight` and a `--no-input`
flag for Stage 3 render-only; instantiate `IpcServer` in `real_main` and
process incoming messages in the main loop; wire `shutdown` IPC messages to
the exit flag from ADR 006.

## Consolidated next step
Write ADRs 004–009 on a branch, implement the fixes, re-run
`cargo fmt --check` / `cargo clippy --all-targets` / `cargo test` (require
green), re-run the pre-flight review, then advance Stages 1–7 from BLOCKED
to CLEARED in `docs/test-plan.md`.