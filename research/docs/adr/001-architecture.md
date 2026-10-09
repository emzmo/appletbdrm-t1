# ADR 001: Provider-Trait Architecture

## Status: Accepted

## Date: 2026-09-24

## Context

The Touch Bar hardware varies across T1 (2016-2017) and T2 (2018-2020) Intel
Macs, and Apple Silicon Macs have yet another path (`apple_z2` via Device
Tree). The original `tiny-dfr` codebase accesses the DRM device, libinput,
and backlight sysfs paths directly throughout its 1100-line `main.rs`. This
makes unit testing impossible without real hardware and makes porting to
new backends (e.g. `apple_z2`, or a simulated framebuffer for development)
require changes scattered across the entire codebase.

The engine must also support an IPC API so external clients can push UI
without recompiling — this requires the render loop to be decoupled from
hardware specifics.

## Decision

Introduce four provider traits in `src/providers/mod.rs`:

1. **`DisplayProvider`** — acquire/release the DRM device, query dimensions,
   flush pixel data. The real implementation (`DrmProvider`) wraps the `drm`
   crate and handles T1 flush-stall backoff. A `MockDisplay` writes to an
   in-memory buffer for tests.

2. **`InputProvider`** — poll for input events (keyboard, touch, lid).
   `LibinputProvider` reads from `seat-touchbar` + `seat0`. `MockInput`
   queues synthetic events for hit-test and gesture tests.

3. **`BacklightProvider`** — set/get brightness. `SysfsBacklight` writes to
   `/sys/class/backlight/appletb_backlight`. `MockBacklight` is in-memory.

4. **`PowerProvider`** — lid state and idle timer (not yet implemented;
   stub exists for Phase 2).

All device discovery is **geometry-based**, never by device-name strings:
- DRM: scan `/dev/dri/card*` read-only, accept the first connector whose
  mode has `height/width > 30` (the Touch Bar is 2170×60 → ratio ≈ 36).
  Master is taken only on the matched card (ADR 004).
- Digitizer: assigned to `seat-touchbar` by a udev rule matching USB
  VID:PID `05ac:8600` (ADR 009); the input provider matches by
  ABS_MT_POSITION_X/Y axis geometry vs the DRM mode — **zero name
  strings**. (ADR 001 originally described a name-substring
  "supplementary heuristic"; ADR 009 supersedes that — see ADR 009.)

## Consequences

- **Positive**: The render loop, widget engine, and IPC server are testable
  without hardware (using mock providers). New backends slot in by
  implementing the traits. The same binary works on T1, T2, and (future)
  Apple Silicon without conditional compilation.
- **Negative**: One extra indirection layer on every DRM flush and input
  poll. For a 2170×60 display at ~10 fps, this overhead is negligible.
- **Risk**: If the DRM crate's API changes significantly (v0.14 → v0.15),
  only `DrmProvider` needs updating, not the entire codebase.

## References

- `src/providers/mod.rs` — trait definitions and geometry discovery
- `src/providers/drm_backend.rs` — real DRM provider
- `src/providers/mock_display.rs` — test mock
- `docs/prior-art.md` §5 — T1 vs T2 protocol differences (cosmetic gate)