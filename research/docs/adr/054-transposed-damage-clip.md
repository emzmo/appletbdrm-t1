# ADR-054: Transposed damage clip — F-045-1 root cause

Status: ACCEPTED (session 053)
Date: 2026-09-27

## Context

F-045-1 (bar dark under tbard at any brightness; lit under the oracle) recurred
across sessions 043/047/051. Session 051's closing conclusion — "a DRM-side
panel-activation differential" — was a live-session root-cause CLAIM that failed
the independent-source-re-read rule (the standing meta-rule, devlog session 040:
live root causes are claims, not premises).

## Root cause (three sources, cited)

1. The `drm` crate (drm-0.14.1, verified from the cargo registry source):
   `ClipRect::new(x1, y1, x2, y2)` takes CORNER coordinates, not w/h.
2. Our flush (src/providers/drm_backend.rs:459-462 pre-fix) mapped the
   full-screen FRAMEBUFFER-space rect {x:0, y:0, w:60, h:2170} (portrait) to
   `ClipRect::new(c.y, c.x, c.h, c.w)` = `new(0, 0, 2170, 60)` — extents
   transposed: x2=2170 (clamped to 60 by the kernel), y2=60. On the 60×2170
   framebuffer the damage window covers only x 0..60, y 0..60 — the leftmost
   ~60 px of the bar. Everything else never reaches the panel.
3. The driver (backup_old/appletbdrm-1.2/appletbdrm.c:1055-1068):
   `drm_rect_intersect(&dst_clip, &damage)` CLAMPS the rect (never returns
   EINVAL) and then transmits ONLY the intersected region over USB
   (frame->begin_x/begin_y/width/height). Hence `Ok(())` on every flush and
   silent darkness — matching all observed runs.

The oracle reference (backup_old/tiny-dfr-mbp142/src/main.rs:842,860):
destructures `mode().size()` as `(height, width)` = (60, 2170) and passes
`ClipRect::new(0, 0, height, width)` = `new(0, 0, 60, 2170)` — the FULL
framebuffer, correct. The port misread the oracle's (h, w)-shaped argument
order and applied a transpose to a rect that was ALREADY in framebuffer space.

## Live confirmation (session 052, docs/test-logs/052/)

Prediction stated in advance with specific geometry, then confirmed by human
observation (HC2, verbatim): "Bright fragment at far left, sharply cut off,
rest black" — with tbard sole master, default page, external brightness 255.
Retrodicts every prior F-045-1 observation:
- 043: esc text fragment visible at the left (inside the window);
- 047 Run A glows (esc text), Run B dark (all-text widgets mid-bar);
- 051 shapes page dark (mid-bar shapes; the auto-esc's INACTIVE shape fill is
  black 0.0 and covers the window);
- zero flush errors in every journal (driver clamps silently).

## Decision

The damage clip must be derived from the rect by CORNER construction:
`ClipRect::new(c.x, c.y, c.x + c.w, c.y + c.h)` — no axis swaps anywhere.
The flush contract is documented: DamageRect is in FRAMEBUFFER (portrait)
space; ClipRect corners are in framebuffer space; no transposition happens
inside the mapping.

## Regression guard (the class, not the instance)

A unit test constructs the mapping for the full-screen rect and asserts the
ClipRect corners equal (0, 0, fb_w, fb_h) — plus a sim-level test asserting
that a vkms/dummy flush's damage covers the whole surface. Grep guards cannot
catch geometry bugs; the test asserts exact coordinates. Adversarial
non-vacuity: transposing the mapping (reverting the fix) must FAIL the test.

## Erratum

Session 051's REPORT.md closing paragraph ("DRM-side panel-activation
differential") is mechanism-WRONG — annotated in place (annotate, don't
rewrite; D-027-1/D-031-1 discipline). The differential was the clip geometry.
