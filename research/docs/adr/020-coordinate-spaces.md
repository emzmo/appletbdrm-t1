# ADR 020: Three-Space Coordinate Model + Tap Observability (S1-F1)

## Status: Accepted

## Date: 2026-09-26

## Context

Stage 1 finding **S1-F1** (`docs/test-logs/006/stage1/SUMMARY.md:48-106`)
is a HARD BLOCKER for any touch stage: taps produce no widget-ID log AND
hit a coordinate-space mismatch. The smoke "passed" because nothing
inspected pixels or hit outcomes (silent-false-negative class).

### Root cause (re-derived from code, not assumed)

The Touch Bar has **three coordinate spaces** that the prior code conflated:

1. **Framebuffer space (portrait)**: the DRM dumb buffer / `appletbdrm`
   mode is **60×2170** (width=60, height=2170). `DisplayInfo` reports
   this (`src/providers/sim_display.rs:106-108` `SIM_W=60, SIM_H=2170`;
   `drm_backend.rs` `mode.size()`).
2. **Logical bar space (landscape)**: the bar as the user sees it —
   **2170×60** (width=2170, height=60). Widgets are laid out left-to-right
   along the 2170px long axis. This is the space the existing unit tests
   already assume (`src/widgets/page.rs:111` `page.layout(2170.0, 60.0)`).
3. **Digitizer space (raw → landscape)**: the digitizer reports
   `ABS_MT_POSITION_X` max=32767, `ABS_MT_POSITION_Y` max=127 (raw HID
   ranges, verified live via `EVIOCGABS` on `/dev/input/event4` this
   session — the Stage-0 evtest capture at `docs/test-logs/000/evtest-input13.log`
   did NOT record the ranges; the "abs MT position x/y:" line is empty).
   libinput's `x_transformed(2170)` / `y_transformed(60)` scales raw
   → **landscape** (x∈0..2170, y∈0..60). So the digitizer (after
   transform) delivers logical-landscape coords, NOT framebuffer coords.

### Hypotheses (verified against code)

- **H1 — `layout()` is fed framebuffer dims instead of logical dims.**
  CONFIRMED. `src/main.rs:204-206` reads `display_info { width: 60,
  height: 2170 }` into `width=60, height=2170`; `src/main.rs:313` calls
  `pages[active_page].layout(width, height)` = `layout(60.0, 2170.0)`.
  `Page::layout` (`src/widgets/page.rs:33-46`) computes widget rects with
  x∈[0,60] — portrait. The existing tests call `layout(2170.0, 60.0)`
  (landscape), so tests pass but production is broken.
- **H2 — the transform is fed the wrong dimension at the seam.**
  CONFIRMED. `src/main.rs:315` `ctx.translate(height as f64, 0.0)` =
  `translate(2170, 0)` (height=2170). The oracle does
  `translate(height=60, 0)` (`backup_old/tiny-dfr-mbp142/src/main.rs:599`,
  after `let (height, width) = drm.mode().size();` at `:842` swaps to
  height=60). Our translate-by-the-long-dim draws off-canvas.
- **H3 — `hit_test` compares landscape touch coords against portrait-space
  rects.** CONFIRMED. Touch delivers x∈0..2170 (landscape);
  `hit_test(x,y)` tests against rects with x∈0..60 (portrait). A tap at
  x=1000 is outside every rect → no hit → no key → silent.

### Proven convention (oracle source, read-only)

`backup_old/tiny-dfr-mbp142/src/main.rs` (the deployed, lit oracle):
- `:842` `let (height, width) = drm.mode().size();` — **swaps** DRM
  (60,2170) into locals `height=60, width=2170`.
- `:599-600` `c.translate(height as f64, 0.0); c.rotate(90°);` =
  `translate(60, 0) ∘ rotate(90°)` — rotate the 60-tall canvas to draw
  landscape.
- `:1073-1074` `x_transformed(width as u32)=x_transformed(2170)`,
  `y_transformed(height as u32)=y_transformed(60)` — touch in landscape.
- `:1075` `hit(width, height, x, y)` = `hit(2170, 60, x, y)` — hit-test
  in landscape.

**The oracle runs layout + hit_test + touch ALL in logical landscape
2170×60.** Rotation is confined to the paint path. Our code must match.

### Paint transform as an explicit affine matrix

The CTM is `translate(H, 0) ∘ rotate(90° CCW)`. For a drawing point
(x,y) in logical space, the device-space point is:
```
device = (H − y, x)
```
For the oracle H=60 (short dim): drawing (x∈0..2170, y∈0..60) →
device (60−y ∈ 0..60, x ∈ 0..2170) — device-x ∈ [0,60] (fb width),
device-y ∈ [0,2170] (fb height). **In bounds.**
For our broken H=2170 (long dim): drawing (x∈0..2170, y∈0..60) →
device (2170−y ∈ 2110..2170, x ∈ 0..2170) — device-x ∈ [2110,2170]
(OUT of fb width 60). **Off-canvas.**

The fix: logical space is landscape (width=2170, height=60); the
translate uses the SHORT dim (logical height=60).

## Decision

### 1. `Geometry` type — logical dims + explicit mapping

Introduce a `Geometry` type (in `src/widgets/mod.rs` or a new
`src/geometry.rs`) carrying:
- `logical: (width, height)` = (2170, 60) — the ONLY space for
  `layout()`, `hit_test()`, gestures, config rect validation, and the
  future web mirror.
- `framebuffer: (width, height)` = (60, 2170) — the DRM/dumb-buffer dims.
- an explicit `paint_matrix()` returning the affine
  `translate(logical.height, 0) ∘ rotate(90°)` mapping logical → device.

`real_main` constructs `Geometry` from `DisplayInfo` by swapping the
short/long dims (logical.width = max(fb.w, fb.h), logical.height = min).
`Page::layout` / `hit_test` take logical dims (or the `Geometry`).

### 2. Rotation confined to the paint path

`real_main`'s render block calls `pages[active_page].layout(logical.width,
logical.height)` and applies `ctx.translate(logical.height, 0);
ctx.rotate(90°)` before `page.render(&ctx, ...)`. Layout + hit_test +
gestures NEVER see the rotation. Pixel-shift applies in logical space
post-rotate (the shift is a small logical-space delta; the CTM maps it).

### 3. Touch stays in logical space

`LibinputProvider` / `SimInputProvider` already deliver
`x_transformed(logical.width=2170)`, `y_transformed(logical.height=60)`.
No change to the input providers' coordinate space — they already emit
logical-landscape. The fix is on the layout/hit_test side, not the input
side. `SimInputProvider`'s `SIM_WIDTH/SIM_HEIGHT` become derived from
`Geometry` (or stay 2170/60 constants matching the logical dims).

### 4. Tap observability

The tap path (`src/main.rs` gesture handler) logs an `info!` line with:
page id, widget id, logical (x,y), gesture classification
(`Tap`/`HorizontalSwipe{...}`). This makes a tap observable in the daemon
log (the Stage-1 criterion "correct widget ID logged"). The log is the
observability; the uinput key emission stays as-is.

### 5. `DisplayInfo` / `demo_config` rects

`DisplayInfo` keeps reporting framebuffer dims (that's what the DRM
backend owns). `demo_config` rects are validated in logical space. No
change to `DisplayInfo`'s meaning; the swap happens in `Geometry`.

## Impact list

- `src/widgets/mod.rs` (or `src/geometry.rs`) — new `Geometry` type.
- `src/widgets/page.rs` — `layout`/`hit_test` take logical dims (already
  do in tests); `render` doc comment corrected (remove the misleading
  "width=60, height=2170" comment at `:65-67`).
- `src/main.rs` — construct `Geometry` from `DisplayInfo`; feed logical
  dims to `layout`; fix the translate to use `logical.height` (short
  dim); add the tap `info!` log. The `pages[active_page].layout(width,
  height)` calls and the `ctx.translate(height, 0)` call switch to
  logical dims.
- `src/providers/sim_input.rs` / `input.rs` — no coordinate change
  (already landscape); optionally take `Geometry` for the dims instead of
  hardcoded 2170/60.
- Pixel-shift — verify it still applies in logical space (the shift delta
  is logical; the CTM carries it to device).
- Web mirror (future) — documented to use logical space.

## Regression tests (sim, no hardware)

- **PIXEL-PROBE**: demo page with one widget filling a known logical rect
  in a solid color; read the dumb buffer directly; assert pixels at the
  framebuffer coords the matrix predicts. This test MUST FAIL on the
  pre-fix tree — demonstrated from a worktree at `v0.1.2-test3` with only
  the test added (output recorded in devlog), then landed test+fix in one
  commit (gates green per commit).
- **TAP**: synthetic uinput touch inside that rect → the expected
  widget-ID log/assert.
- **ROUND-TRIP**: touch at logical (x,y) hits exactly the widget whose
  rect contains it, across ≥3 widgets spanning the bar.

## References

- `docs/test-logs/006/stage1/SUMMARY.md:48-106` — S1-F1
- `backup_old/tiny-dfr-mbp142/src/main.rs:842,599-600,1073-1075` — oracle
- `src/main.rs:204-206,313,315` — the bug (framebuffer dims fed to
  layout + translate)
- `src/widgets/page.rs:111` — tests already use landscape dims
- Live `EVIOCGABS` on `/dev/input/event4`: ABS_MT_POSITION_X max=32767,
  ABS_MT_POSITION_Y max=127 (raw HID; libinput scales to landscape)