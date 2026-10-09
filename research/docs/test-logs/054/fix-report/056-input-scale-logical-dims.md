# ADR-056: Input scale transposition — tb_dims must be LOGICAL dims

Status: ACCEPTED (session 053)
Date: 2026-09-27

## Context (found live in session 052, docs/test-logs/052/HC2-injection-check.txt)

The human's four taps (13:10:59) logged `tap page=primary logical=(2,1068) hit=None`.
y=1068 is IMPOSSIBLE in logical space (logical height = 60). The arithmetic is
exact: raw Y≈62 ÷ 127 (ABS_Y max) × **2170** = 1060 ≈ 1068 — the Y scale target
is the portrait WIDTH, not the logical height. The same portrait/logical
transposition disease as ADR-054 (the damage clip), in the input organ.

## Root cause (cited)

- src/main.rs:325-329: `tb_dims = drm.display_info().map(|i| (i.width, i.height))
  .unwrap_or((60, 2170))` — display_info() returns the PORTRAIT fb dims
  (60, 2170) from the DRM mode.
- src/providers/input.rs:519-521: `let (width, height) = (self.tb_dims.0,
  self.tb_dims.1); ... x_transformed(width), y_transformed(height)` — consumed
  as (width, height) for the ABS→logical scale. With tb_dims=(60, 2170):
  raw X (0..32767) → 0..60 (should be 0..2170); raw Y (0..127) → 0..2170
  (should be 0..60). X and Y scale targets are swapped.
- The ADR-024 test (`test_sim_input_scales_real_abs_range_to_logical`) passes
  because SimInputProvider's `new_with_range` receives the same tb_dims tuple —
  the test verified the *wiring* (Geometry-derived denominators), not the
  *semantics* (which axis maps to which logical span). Tenth member of the
  sim/real blind-spot family.

## Consequences

- Every hardware tap so far (sessions 047/051/052) logged but hit NOTHING
  (hit=None): the tap-log "reconfirmations" verified the gesture classifier,
  NOT the hit-test integration. Stage-4 item 3's "tap log" acceptance verified
  classification only.
- SAFETY: on the default page, once this is fixed, a mid-bar touch WOULD inject
  Esc. Session 052's window was protected only by the bug. The runbook rule
  "never touch during default-page observation" is now evidence-backed.

## Decision

The input provider's scale targets must be LOGICAL dims, derived from the same
single source of truth (Geometry) that ADR-020 established for layout: swap
the tb_dims derivation at main.rs (use geometry.logical_width/height), or
transpose inside LibinputProvider::new — pick the ONE place that makes the
semantics explicit and cite it. The ADR-024 test gains an axis-semantic
assertion: real-range X (0..32767) must map to 0..LOGICAL_WIDTH (2170), and
Y (0..127) to 0..LOGICAL_HEIGHT (60) — the (2,1068) datapoint becomes a
regression fixture.

## Erratum

None needed for s051's tap "reconfirmation" wording (it correctly said
"reconfirmed" for classification) — but the Stage-4 acceptance table's item 3
is amended: hit-test integration is owed on hardware after this fix.
