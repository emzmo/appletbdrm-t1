# Stage 1 — Dry-run (sim only) against v0.1.2-test3 — Summary

**Date**: 2026-09-25 (Fri)
**Tag**: `v0.1.2-test3` (HEAD `dd9fdf3`, master post-merge)
**Binary**: `target/release/tbard` (release build from the tag)
**Reviewer role**: session-ops engineer (read-only; FREEZE RULE — no src/ changes)
**Environment**: uid=1000 (emzmo), Hyprland Wayland session 3 on seat0/tty1,
Active=yes, State=active. vkms `card2` tagged `master-of-seat`+`uaccess`;
logind ACL `user:emzmo:rw-` on `/dev/dri/card2`. Oracle `tiny-dfr-mbp142`
(PID 562, nobody) untouched on `card0` throughout — verified before and
after. See `docs/test-logs/006/bench-state.md`.

## Pass criteria (per docs/test-plan.md + session task) vs. result

| Criterion | Result | Evidence |
|---|---|---|
| Hermetic smoke (HOME=$(mktemp -d)) | **PASS** | `run1-smoke.log`, `run2-rerun.log` |
| Widget tap via uinput synthetic touch → correct widget ID logged | **FINDING (not pass)** | `run3-touch-injection.log` + finding S1-F1 below |
| Frame counter advancing (vkms dirtyfb-ENOSYS-tolerant) | **PASS (with finding)** | `run1-smoke.log` + finding S1-F2 below |
| Config hot-reload | **PASS (with finding)** | `run5-hotreload-ok.log` + finding S1-F3 below |
| SIGTERM clean exit | **PASS** | `run1-smoke.log`, `run2-rerun.log`, `run3-touch-injection.log` |
| Immediate rerun (no stale state) | **PASS** | `run2-rerun.log` (master released by RAII Drop) |

## vkms dirtyfb-ENOSYS-tolerant behavior (recorded explicitly)

The render path executes fully every time `needs_redraw` is true or a
widget is dirty: layout → cairo paint (rotate 90° for the 60×2170
framebuffer) → dumb-buffer copy → `card.dirty_framebuffer(fb, &clips)`.
On vkms, `dirty_framebuffer` returns `ENOSYS` (Function not implemented,
os error 38) — vkms does not implement this ioctl. The engine logs it at
`WARN` level (`display flush error: Function not implemented (os error 38)`)
and continues. Non-fatal. The real `appletbdrm` driver supports
`dirty_framebuffer`. This is a **vkms limitation, not an engine bug**
(confirmed in review-v3 Task 4 and re-confirmed here).

In the hermetic smoke (no touch input, no periodic-redraw widget active
in the demo page), exactly ONE frame is rendered (the initial redraw on
startup), producing one ENOSYS warning. The loop then idles because
`needs_redraw=false` and no demo widget's `needs_periodic_redraw()`
returns true. There is no explicit frame counter in the log; "frame
advancing" is evidenced by the ENOSYS warning count (one warning = one
flush attempt = one frame rendered). When a config hot-reload triggers
`needs_redraw=true`, another ENOSYS warning appears (see run5), proving
the render path re-executes on demand.

## Findings (FREEZE RULE — findings only, no src/ fixes this session)

### S1-F1 — Widget tap path produces no widget-ID log line AND hits a coordinate-space mismatch

**Observation**: The session task asked "widget tap via uinput synthetic
touch → correct widget ID logged." Two issues found:

1. **No widget-ID logging exists in the binary.** The render loop's tap
   path (`src/main.rs:408-420`) calls `hit_test` → `tap_action()` →
   `emit_keys` silently. There is no `debug!`/`info!`/`trace!` line
   emitting the matched `widget_id`. So "correct widget ID logged" cannot
   be satisfied by any log line from the current binary. The only
   observable effect of a tap is a uinput key emission (visible on the
   uinput virtual keyboard node, not in the daemon log).

2. **Coordinate-space mismatch between touch input and the layout/hit_test.**
   - `SimDisplayProvider` reports `DisplayInfo { width: 60, height: 2170 }`
     (`src/providers/sim_display.rs:106-108`, SIM_W=60, SIM_H=2170).
   - `real_main` calls `pages[active_page].layout(width, height)` =
     `layout(60.0, 2170.0)` (`src/main.rs:313`).
   - `Page::layout` (`src/widgets/page.rs:33-46`) computes widget rects
     with x ∈ [0, width] = [0, 60] (5 demo widgets share the 60px width).
   - `SimInputProvider` delivers touch contacts with
     `x ∈ [0, SIM_WIDTH=2170]`, `y ∈ [0, SIM_HEIGHT=60]`
     (`src/providers/sim_input.rs:177-188`).
   - `hit_test(x, y)` (`src/widgets/page.rs:50-61`) tests the touch x
     (∈ [0,2170]) against rects with x ∈ [0,60].
   - A tap at x=1000 (touch space) is outside every widget rect → no
     hit → no `tap_action()` → no key emitted.
   - A tap at x=30 (within the 0..60 layout space) ALSO produced no
     observable effect in the daemon log (no second ENOSYS warning →
     `needs_redraw` did not go true → no `Gesture::Tap` was recognized,
     OR the tap was recognized but hit_test found a widget whose
     `tap_action()` returned `None`/emitted keys to a uinput node that
     was not monitored in this run).

   The real `LibinputProvider::poll` (`src/providers/input.rs:178-192`)
   uses the SAME `x_transformed(2170)`, `y_transformed(60)` transform, so
   this mismatch is not sim-only — it affects real hardware too.

**Live evidence**: `run3-touch-injection.log`. Two taps injected (x=30,
x=1000) into the sim digitizer evdev node `/dev/input/event18`. Daemon
log unchanged after both injections (no new frame, no widget-tap line,
no panic). Clean SIGTERM exit (exit 0).

**Impact**: On real hardware, touches anywhere with x > 60 (i.e. almost
the entire 2170px-wide Touch Bar) would miss every widget. This is a
**blocking finding for Stage 3/4/5** (render + touch). It does NOT block
Stage 2 (inspect-only, no touch).

**Root-cause hypothesis (for a future fix branch, NOT this session)**:
either (a) the layout should be called with the touch-space dimensions
(2170×60) so rects span the full touch range, or (b) the touch
coordinates should be transformed from touch-space (2170×60) into
layout-space (60×2170) before `hit_test`, or (c) `DisplayInfo` should
report width=2170/height=60 so layout and touch share one space. The
render path's 90° rotation (`ctx.translate(height, 0); ctx.rotate(90°)`)
maps the 60×2170 framebuffer into a 2170×60 cairo space, which suggests
the layout was intended to run in 2170×60 space — i.e. `DisplayInfo`
may have width/height swapped for the rotated Touch Bar. Needs ADR-level
analysis. **Logged for the next fix session; not patched here.**

### S1-F2 — No explicit frame counter in the daemon log

**Observation**: The render loop does not log a frame counter or a
per-frame debug line. "Frame counter advancing" can only be inferred
indirectly from the count of `display flush error: ENOSYS` warnings
(one warning per flush attempt per frame). This is adequate for a
sim smoke but would not surface a stalled render loop (zero new frames)
in a long run unless an operator counts warnings.

**Impact**: Non-blocking for Stage 1. For endurance (Stage 7) a frame
counter or periodic heartbeat log would help detect a silent render
stall. **Logged for a future fix session; not patched here.**

### S1-F3 — Config hot-reload enters a reload storm after the first reload

**Observation**: After a successful config reload (valid YAML replaced
on `/etc/touchbar-engine/config.yaml`), the daemon enters a tight loop
emitting `config reloaded` + `display flush error: ENOSYS` every
iteration (~hundreds of times per second). See `run5-hotreload-ok.log`
(the log is dominated by repeating `config reloaded` + ENOSYS pairs
from the first reload at 22:37:05 until SIGTERM at 22:37:07).

**Root-cause hypothesis (for a future fix branch, NOT this session)**:
`ConfigManager::arm_watch` (`src/config/manager.rs:51-67`) uses
`AddWatchFlags::IN_ONESHOT` (`:54`), so the watch fires once and is
removed. `check_reload` (`:89-99`) re-arms the watch when
`self.watch.is_none()` (`:90-91`). The re-armed watch on the same file
fires again immediately (the inotify event queue still has the pending
IN_CLOSE_WRITE from the file replace, or the file's inode state triggers
a new event on re-add), producing a reload every loop iteration. The
config is genuinely reloaded each time (new pages built, `needs_redraw`
set), so the storm also drives continuous re-rendering.

**Impact**: CPU waste + log flooding after the first config change. Not
a crash, not a correctness bug (the config IS reloaded correctly the
first time, and the demo/real layout stays consistent). But it makes
hot-reload unusable in practice until fixed. **Blocking for any
production use of hot-reload; non-blocking for Stage 2 (inspect-only,
no reload expected).** Logged for the next fix session; not patched here.

## Verdict

Stage 1 **PARTIAL PASS**:
- Hermetic smoke, SIGTERM clean exit, immediate rerun, vkms
  ENOSYS-tolerant render, and config hot-reload (first-reload success)
  all verified.
- Three findings logged (S1-F1 widget-tap coordinate mismatch + no
  widget-ID log, S1-F2 no frame counter, S1-F3 reload storm), all for a
  future fix branch under the FREEZE RULE.
- **S1-F1 (coordinate mismatch) is a blocking finding for Stage 3/4/5**
  (any stage that exercises touch). It does NOT block Stage 2
  (inspect-only, no touch, no render).

No src/ files were modified. The oracle service was not touched.