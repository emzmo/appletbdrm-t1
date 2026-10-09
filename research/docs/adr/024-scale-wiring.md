# ADR 024: Touch Coordinate Scale Wiring + Real-Range uinput Test

## Status: Accepted

## Date: 2026-09-26

## Context

QA review-v4 Investigation C (`docs/review-report-v4.md:200-228`)
confirmed the input provider applies an ABS→logical scale today:
`src/providers/input.rs:178-184` uses `dn.x_transformed(2170)` /
`dn.y_transformed(60)`, libinput's raw→logical scale (matches the oracle
`backup_old/tiny-dfr-mbp142/src/main.rs:1073-1074`). **However**:
1. The scale target is **hardcoded** `(2170u32, 60u32)` at `input.rs:178`
   instead of being wired to the `Geometry` logical dims (ADR-020). A
   future panel with different dims would need a code edit, not just a
   `DisplayInfo` change.
2. The sim NEVER exercises the real scale. `SimInputProvider` sets the
   uinput ABS_MT max to 2170/60 (`sim_input.rs:38-39,100-104`), so
   `x_transformed(2170)` is the identity map. The real digitizer reports
   `ABS_MT_POSITION_X` max=32767, `ABS_MT_POSITION_Y` max=127 (verified
   live via `EVIOCGABS` on `/dev/input/event4`, ADR-020), so the real
   path scales 32767→2170 and 127→60 — a scale the sim does not test.

This is a **Stage-4 blocker only** (does not hold Stage 3/merge) — the
real-input scale is correct by code + oracle provenance, but the untested
sim/real divergence is a latent gap.

## Decision

### 1. Wire `LibinputProvider`'s scale target to `Geometry`

Replace the hardcoded `(2170u32, 60u32)` at `input.rs:178` with the
`Geometry` logical dims passed into `LibinputProvider::new(tb_dims)`.
`main` already passes `tb_dims` from `drm.display_info()` (`main.rs:188-192`);
`LibinputProvider::new` already takes `tb_dims: (u16, u16)` and stores it
as `self.tb_dims` (`input.rs:62-71`). The `poll` method uses
`self.tb_dims` for the geometry gate; this ADR makes `poll` ALSO use it
for the scale target, so the scale and the geometry match share one
source of truth. The hardcoded `(2170, 60)` is removed.

### 2. Real-range uinput test

Add a `SimInputProvider`-backed test where the uinput ABS_MT max is
DISJOINT from the logical dims (e.g. abs_max=32767/127, the real
digitizer's raw range), and assert that `x_transformed(logical_width)`
scales 32767→2170 (and 127→60) correctly. This exercises the real scale
path without real hardware.

To do this, `SimInputProvider::new` must accept configurable ABS_MT max
values (instead of the hardcoded `SIM_WIDTH=2170/SIM_HEIGHT=60`). A
new constructor `SimInputProvider::new_with_range(abs_x_max, abs_y_max)`
(or a parameter on `new`) sets the uinput axes to the real digitizer's
raw range while the `x_transformed` target stays the logical dims. The
test injects touches at raw coords and asserts the `InputEvent::Touch`
contacts are scaled to logical coords.

### 3. `SimInputProvider` stays at logical-range for the dry-run smoke

The dry-run smoke (`real_main` dry-run path) keeps using
`SimInputProvider::new()` with the logical-range axes (2170/60) so the
smoke's identity-map behavior is unchanged. Only the test uses the
real-range constructor.

## Alternatives considered

- **Hardcode the real range in `SimInputProvider`.** Rejected: the
  dry-run smoke's identity map is the correct sim behavior (the sim
  digitizer reports logical coords directly); forcing a raw range would
  make the smoke's coords non-deterministic relative to the demo layout.
- **Test the scale via a mock `LibinputProvider`.** Rejected: the scale
  is a libinput `x_transformed` call; a mock would not exercise the real
  libinput code path. The uinput-backed test exercises the real path.

## Impact list

- `src/providers/input.rs` — `poll` uses `self.tb_dims` for the scale
  target (was hardcoded `(2170, 60)`).
- `src/providers/sim_input.rs` — add `SimInputProvider::new_with_range`
  (configurable ABS_MT max) for the test; `new()` keeps 2170/60.
- `src/providers/sim_input.rs` tests — real-range scale test.

## Regression test

`src/providers/sim_input.rs` tests:
`test_sim_input_scales_real_abs_range_to_logical` — creates a
`SimInputProvider` with ABS_MT max 32767/127, injects a touch at raw
(16383, 63) (≈half of each range), and asserts the `InputEvent::Touch`
contact's `x` ≈ 1085 (half of 2170) and `y` ≈ 30 (half of 60). This
exercises the real 32767→2170 / 127→60 scale via libinput's
`x_transformed`/`y_transformed`, closing the sim/real divergence gap.

## References

- `docs/review-report-v4.md:200-228` — Investigation C (the finding)
- `docs/adr/020-coordinate-spaces.md` — the `Geometry` type this wires to
- `backup_old/tiny-dfr-mbp142/src/main.rs:1073-1074` — oracle scale
- Live `EVIOCGABS` on `/dev/input/event4` (ADR-020): X max=32767, Y max=127