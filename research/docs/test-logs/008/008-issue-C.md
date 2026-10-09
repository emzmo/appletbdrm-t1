# Investigation C — Touch Coordinate Scaling (abs → logical)

Date: 2026-09-26T01:02+01:00
uid: 1000, session: wayland/seat0 active

## Hypothesis (from the review prompt)

The REAL digitizer reports `ABS_MT_POSITION_X` max=32767, `ABS_MT_POSITION_Y`
max=127 — 2^15 × 2^7 raw HID buckets, NOT pixels. Stage-1 sim touches were
`x ∈ 0..2170` (`SimInputProvider` emits logical pixels). Hypothesis: the real
input path needs an abs→logical scale transform the SIM NEVER EXERCISES
(sim/real divergence).

## Code findings

### Does the input provider apply an ABS→logical scale today? YES — via libinput.

`src/providers/input.rs:177-184` (real `LibinputProvider`):
```rust
// Use a default 2170x60 resolution for coordinate transformation
let (width, height) = (2170u32, 60u32);
match te {
    TouchEvent::Down(dn) => {
        events.push(InputEvent::Touch(vec![TouchContact {
            slot: dn.seat_slot(),
            x: dn.x_transformed(width),    // scales raw 0..32767 → 0..2170
            y: dn.y_transformed(height),   // scales raw 0..127   → 0..60
            is_down: true,
        }]));
    }
    ...
```

`dn.x_transformed(width)` is libinput's scale: it maps the raw ABS_MT value
`v ∈ [0, abs_max]` linearly to `[0, width]` using the abs info maximum from
the evdev node. So for the real digitizer (abs_max X=32767, Y=127) a touch at
raw (16383, 63) → logical (16383 * 2170 / 32767, 63 * 60 / 127) ≈ (1085, 30).
**The abs→logical scale IS applied.**

`src/providers/sim_input.rs:177-186` (sim `SimInputProvider`):
```rust
x: dn.x_transformed(SIM_WIDTH as u32),   // SIM_WIDTH = 2170
y: dn.y_transformed(SIM_HEIGHT as u32),  // SIM_HEIGHT = 60
```
But the sim sets `SIM_WIDTH=2170, SIM_HEIGHT=60` as the **ABS_MT maximum**
(`sim_input.rs:38-39, 100-104`: `abs_info(SIM_WIDTH)` → `maximum: 2170`). So
the sim's raw range == logical range, and `x_transformed(2170)` is the
identity map (`v * 2170 / 2170 = v`). **The sim NEVER exercises the
32767→2170 scale — the divergence is real.**

### Oracle's proven transform

`backup_old/tiny-dfr-mbp142/src/main.rs`:
- `:842` `let (height, width) = drm.mode().size();` — swaps DRM (60,2170) →
  `height=60, width=2170`.
- `:1073-1074` `let x = dn.x_transformed(width as u32);` =
  `x_transformed(2170)`; `let y = dn.y_transformed(height as u32);` =
  `y_transformed(60)`.

The oracle uses the **same** `x_transformed`/`y_transformed` scale to
logical-landscape. Our `LibinputProvider` matches the oracle exactly. The
transform is PROVEN (the oracle is deployed and lit).

### Does libinput return mm or raw units?

`x_transformed(width)` returns units of `width` (here logical px 2170), using
the abs info `maximum` as the scale denominator. It does NOT use
`ABS_MT_RESOLUTION` (which would give mm). If `ABS_MT_RESOLUTION` were set,
libinput's `x_transformed` would still scale to the supplied `width`, not mm;
the resolution field affects libinput's internal mm-based APIs, not
`x_transformed`. The real digitizer's abs info (per the live EVIOCGABS in
ADR-020) has `resolution: 0` (the sim also sets `resolution: 0` at
`sim_input.rs:95`). So no mm path is in play; the oracle and our engine both
use raw-bucket→logical-px scaling via `x_transformed`. Consistent.

## Correctness assessment

The transform is **present and correct** for the real device (matches the
oracle). It is **not tested** by the sim (sim's raw range == logical range ⇒
identity). A regression that broke `x_transformed` (e.g. swapped to a raw
value, or dropped the scale) would pass the sim but fail on hardware.

## Classification

**Stage-4 blocker ONLY — does NOT hold Stage 3.** The real-input scale is
correct by code inspection + oracle provenance; Stage 3 (sim harness,
merge) does not depend on exercising the real scale. Stage 4 (real-hardware
touch validation) must verify the scale with a live tap, which is the
standing Stage-4 precondition.

## Proposed test coverage (ADR-024 candidate — NEXT fix session, do NOT fix now)

A unit test that constructs a `TouchEvent`-shaped value with a raw range
disjoint from the logical range (e.g. abs_max=32767) and asserts
`x_transformed(2170)` yields the expected scaled logical px. This requires
either a mock libinput device (the `input` crate does not expose
constructors) or an evdev/uinput device with a non-2170 abs max (the sim
already uses uinput — change `SIM_WIDTH` abs max to 32767 in a test fixture
and assert the scale). The latter is the cheaper path: a test-only uinput
device with abs_max X=32767, Y=127, inject a touch at raw (16383, 63),
assert `InputEvent::Touch` delivers x≈1085, y≈30.

## Standing Stage-4 precondition (shared evidence capture)

The Stage-4 precondition "hid_field_extract once-vs-per-report via
hid-recorder" can share a future evidence-capture session with a live
`EVIOCGABS` re-capture (the `docs/test-logs/000/evtest-input13.log` abs-MT
line is empty; ADR-020 references a live capture not archived). Both are
real-hardware evidence items; capture them together when the bench is on
the metal.

## Recommendation for ADR-024

Two items for the next fix session:
1. **Test the abs→logical scale**: a uinput-backed test with abs_max
   disjoint from logical (32767/127), asserting `x_transformed(2170)`
   scales correctly. Closes the sim/real divergence in the test suite.
2. **Wire the scale target to `Geometry`**: `LibinputProvider` currently
   hardcodes `(2170, 60)` (`input.rs:178`). Derive from the `Geometry`
   (logical dims) so a future panel change doesn't silently descale.
   Non-blocking; the magic constant is correct for the Touch Bar.