# ADR 029: Complete ADR-024 — Sim Scale Wiring + Test Truthfulness

## Status: Accepted

## Date: 2026-09-26

## Context

QA v5 (`docs/review-report-v5.md` Claim 1, NF-1/NF-2) partially refuted
ADR-024:

1. **NF-1 (sim scale denominators not Geometry-derived)**:
   `src/providers/sim_input.rs:43-44` defines `SIM_WIDTH: i32 = 2170` and
   `SIM_HEIGHT: i32 = 60` as crate-private constants.
   `SimInputProvider::poll()` (`sim_input.rs:223-224, 231-232`) uses these
   constants as the `x_transformed(SIM_WIDTH as u32)` /
   `y_transformed(SIM_HEIGHT as u32)` scale denominators. They are NOT
   derived from `Geometry`. The real provider (`src/providers/input.rs:177-186`,
   `self.tb_dims` from `main.rs:195-198` ← `drm.display_info()`) IS wired;
   the sim provider is not. A future panel with different dims would need
   a `sim_input.rs` code edit, not just a `DisplayInfo` change. ADR-024's
   "single source of truth" claim is only half-realized.

2. **NF-2 (real-range scale test is vacuous in execution)**:
   `test_sim_input_scales_real_abs_range_to_logical`
   (`sim_input.rs:300-355`) SKIPS 100% of runs on this bench with the
   message "no touch event delivered by libinput — timing/device issue"
   (`sim_input.rs:330-336`) and marks itself "ok" WITHOUT asserting the
   transform. Reproduced 4× (3× as emzmo, 1× under sudo) in QA v5. The
   test is non-vacuous in design (input ranges 32767/127 ≠ output ranges
   2170/60) but vacuous in execution. The test also lacks the
   edges→0/full-span and demo-page widget-tap sub-assertions stated in
   ADR-024's scope.

### Root-cause investigation (libinput delivery link)

A debug harness (`docs/test-logs/012/dbg-harness1-full-trace.log`,
`dbg-harness2-isolate.log`) traced the full path: uinput virtual device
creation (protocol B: `ABS_MT_SLOT`, `ABS_MT_TRACKING_ID`,
`ABS_MT_POSITION_X/Y`) → libinput context type (`new_with_udev` +
`udev_assign_seat("seat0")`) → `inject_touch_down` sequence (values +
`SYN_REPORT`) → `libinput_dispatch` before read → event type filtering.

The harness isolated the broken link by running four variants:

| Variant | BTN_TOUCH? | suspend+resume? | Touch delivered? |
|---|---|---|---|
| A (existing SimInputProvider) | no | no | **no** |
| B | no | yes | **no** |
| C | yes | no | **yes** (x=1084.9, y=29.5) |
| D | yes | yes | **yes** (x=1084.9, y=29.5) |

**Broken link identified (not guessed)**: the existing
`SimInputProvider::new_with_range` (`sim_input.rs:89-146`) does NOT set
`EV_KEY`/`BTN_TOUCH` on the uinput device. libinput classifies a device
as a touch device (and emits `TouchEvent`s for it) when the device
advertises `BTN_TOUCH` (`input_linux::Key::ButtonTouch`) OR the udev
`ID_INPUT_TOUCHSCREEN=1` property is set. The udevadm capture
(`docs/test-logs/012/dbg-harness1-full-trace.log`) shows the uinput
device has NO `ID_INPUT_TOUCHSCREEN` property (only `SUBSYSTEM=input`),
so `BTN_TOUCH` is the determining classification signal. Without it,
libinput sees the `ABS_MT_*` axes but does not create a touch device —
the injected events are dropped at the device-classification stage,
never reaching `Event::Touch`. `suspend()`/`resume()` is NOT required
(the initial `dispatch()` after `udev_assign_seat` is sufficient once
`BTN_TOUCH` is present).

The real appletbdrm digitizer advertises `BTN_TOUCH` (verified by the
oracle `backup_old/tiny-dfr-mbp142` using the same libinput path), so
the sim's omission is a divergence from both the real device and the
libinput touch-device contract.

### Why were sim scale denominators hardcoded while the real provider was wired?

ADR-024 wired `input.rs` (real) to `self.tb_dims` but left
`sim_input.rs` using the `SIM_WIDTH`/`SIM_HEIGHT` constants because the
sim constructor (`new()` / `new_with_range()`) did not accept logical
dims — there was no plumbing to carry `Geometry` into the sim provider.
The fix is by construction: add that plumbing and derive the sim scale
denominators from `Geometry` exactly as `input.rs` derives from
`self.tb_dims` (both trace to the display provider's `DisplayInfo`).

## Decision

### 1. Fix the libinput delivery link: advertise `BTN_TOUCH`

`SimInputProvider::new_with_range` must set `EV_KEY` and `BTN_TOUCH`
(`input_linux::Key::ButtonTouch`) on the uinput device, and
`inject_touch_down` must emit `BTN_TOUCH=1` before the `ABS_MT_*` events
(matching the real digitizer protocol and the libinput touch-device
contract). Without this, libinput never classifies the sim device as a
touch device and the test can never receive an event. This is the root
cause of the 100% skip.

### 2. Wire sim scale denominators to Geometry

Replace the `SIM_WIDTH`/`SIM_HEIGHT` constants as scale denominators
with `Geometry`-derived logical dims carried by `SimInputProvider`:

- Add a `logical_dims: (u32, u32)` field to `SimInputProvider`.
- `SimInputProvider::new(logical_w, logical_h)` constructs the uinput
  device with the logical-range ABS axes (identity map for the dry-run
  smoke, preserving the existing behavior) and stores the logical dims
  for `poll()`.
- `SimInputProvider::new_with_range(abs_x_max, abs_y_max, logical_w,
  logical_h)` constructs with configurable ABS max (for the real-range
  test) and stores the logical dims.
- `poll()` uses `self.logical_dims` for `x_transformed`/`y_transformed`
  (was `SIM_WIDTH`/`SIM_HEIGHT` constants).
- `main`'s dry-run path builds `Geometry` from
  `SimDisplayProvider::display_info()` (the same `DisplayInfo`
  `real_main` uses) and passes `geometry.logical` dims to
  `SimInputProvider::new(logical_w, logical_h)`. This mirrors how the
  real path passes `drm.display_info()` dims to `LibinputProvider::new`.

The `SIM_WIDTH`/`SIM_HEIGHT` constants are removed. The sim's scale
denominators now trace to `Geometry` ← `SimDisplayProvider::display_info()`,
the same source of truth as the real provider.

### 3. Test hardening (truthfulness)

`test_sim_input_scales_real_abs_range_to_logical` is rewritten:

- **uinput unavailable (`EACCES` on `/dev/uinput`)** → truthful skip with
  verbatim stderr (ADR-013 class). This is the only legitimate skip.
- **uinput available + device created + injection performed + NO event
  delivered** → HARD FAIL (panic). Silent vacuous pass is the bug class;
  the test must be able to fail. The 50ms single-shot wait is replaced
  with a retry-poll loop (multiple `dispatch()` + read cycles over a
  bounded window) so the injected evdev event is reliably surfaced; if
  it still does not arrive, the test fails with an explicit message.
- **Sub-assertions added**:
  - Edges: raw (0, 0) → logical (0, 0); raw (32767, 127) → logical
    (≈2170, ≈60) (full span).
  - Mid-range: raw (16383, 63) → logical (≈1085, ≈30) (existing).
  - Demo-page widget tap: build the demo page (`demo_config()` +
    `build_pages`), `layout()` at the logical dims, inject a touch at a
    raw coord that scales into a known widget's rect, and assert
    `hit_test()` returns that widget's id. This closes ADR-024's
    "demo-page widget tap through scaled coordinates" sub-claim.
- **Non-vacuity guard**: assert the test's input ranges (32767/127) ≠
  output ranges (2170/60) by construction (a structural assertion that
  the transform is non-identity).

### 4. check-invariants guard (cheap)

`scripts/check-invariants.sh` gains a grep that fails if
`sim_input.rs` re-introduces a hardcoded `2170`/`60`/`32767`/`127`
literal in the `poll()` scale-denominator position (outside test
fixtures and comments). This guards the ADR-029 wiring against
regression the same way ADR-017 guards the `#![deny]` line.

## Alternatives considered

- **Set the udev `ID_INPUT_TOUCHSCREEN=1` property instead of
  `BTN_TOUCH`.** Rejected: uinput-created devices do not get udev
  properties unless a udev rule matches them (the sim device has no
  stable VID:PID udev rule, and adding one would be a new feature /
  system-config change forbidden by HOST SAFETY RULES). `BTN_TOUCH` is
  the in-process libinput classification signal and requires no system
  config.
- **Increase the libinput wait window without fixing the device
  classification.** Rejected: the root cause is device classification,
  not timing. No wait window surfaces an event that libinput never
  creates. The harness proved variants A/B never deliver regardless of
  wait/retry.
- **Test the scale via a mock `LibinputProvider`.** Rejected (same as
  ADR-024): the scale is a libinput `x_transformed` call; a mock would
  not exercise the real libinput code path. The uinput-backed test
  exercises the real path.

## Impact list

- `src/providers/sim_input.rs`:
  - `new_with_range` sets `EV_KEY`/`BTN_TOUCH`; `inject_touch_down`
    emits `BTN_TOUCH=1`.
  - `SIM_WIDTH`/`SIM_HEIGHT` constants removed; `logical_dims` field
    added; `new(logical_w, logical_h)` and
    `new_with_range(abs_x_max, abs_y_max, logical_w, logical_h)`
    constructors; `poll()` uses `self.logical_dims`.
- `src/main.rs`: dry-run path builds `Geometry` from
  `SimDisplayProvider::display_info()` and passes logical dims to
  `SimInputProvider::new`.
- `src/providers/sim_input.rs` tests: rewritten
  `test_sim_input_scales_real_abs_range_to_logical` (hard-fail on no
  event; edges + mid-range + widget-tap sub-assertions; non-vacuity
  guard).
- `scripts/check-invariants.sh`: grep guard for hardcoded sim scale
  denominators.

## Regression test

`test_sim_input_scales_real_abs_range_to_logical` now:
1. creates a uinput device with `BTN_TOUCH` + ABS_MT real range
   (32767/127),
2. injects edges (0/0, 32767/127) and mid-range (16383/63),
3. asserts the libinput-delivered `TouchEvent` contacts scale to
   (0,0), (≈2170, ≈60), (≈1085, ≈30) respectively,
4. builds the demo page, injects a touch that scales into a known
   widget rect, and asserts `hit_test()` returns that widget id,
5. asserts input ranges ≠ output ranges (non-vacuity guard),
6. HARD FAILs if uinput is available but no event is delivered (no
   silent skip), and truthfully skips only on `EACCES` with verbatim
   stderr.

## References

- `docs/review-report-v5.md` Claim 1, NF-1, NF-2 — the refuted sub-claims
- `docs/test-logs/012/dbg-harness1-full-trace.log` — full path trace
- `docs/test-logs/012/dbg-harness2-isolate.log` — four-variant isolation
  (BTN_TOUCH is the determining factor)
- `docs/adr/024-scale-wiring.md` — the ADR this completes
- `docs/adr/020-coordinate-spaces.md` — the `Geometry` type
- `docs/adr/013-seat-gated-tests.md` — truthful skip with verbatim stderr
- `backup_old/tiny-dfr-mbp142` — oracle (uses the same libinput path;
  advertises BTN_TOUCH)