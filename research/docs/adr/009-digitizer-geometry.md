# ADR 009: Digitizer Discovery by ABS_MT Geometry (Zero Name-String Matching)

## Status: Accepted

## Date: 2026-09-25

## Context

Pre-flight review §2.1 (`docs/review-report.md`) found the digitizer
discovery is purely name-string based:

```rust
fn is_digitizer(dev: &InputDevice) -> bool {
    let name = dev.name();
    name.contains("Touch Bar") || name.contains("iBridge Touchpad") || name.contains("T1 Controller Touchpad")
}
```

The architecture doc and ADR 001 claim geometry-only discovery, but the
code contradicts this: there is no ABS_MT resolution / geometry check in
`is_digitizer`. The header comment at `src/providers/input.rs:5` describes
an ABS_MT check that is **not implemented**.

The deployed udev seat rules in `backup_old/udev-rules/` are also
name-string-gated and miss both this bench's name (`"Apple Inc. iBridge
Touchpad"`) and the Seborider PR #1 name (`"Apple Inc. Apple T1 Controller
Touchpad"`). The review's invariant is "ZERO name-string dependencies
anywhere (code, udev, seat rules)."

This is also the upstream fix for **Seborider PR #1**, which is caused by
the MBP14,2 T1 digitizer reporting a product name (`"Apple T1 Controller
Touchpad"`) that the name-list approach has to keep chasing. Matching by
USB VID:PID + ABS_MT geometry instead of by name eliminates the entire
class of "new name variant breaks discovery" bugs.

## Root cause

`is_digitizer` used `dev.name().contains(...)` because it was the obvious
port from tiny-dfr, and the seat-assignment was expected to narrow the
candidate set. But the seat rules themselves were name-gated, so the
"narrowing" was also name-dependent, and the final gate was a substring
match — a double name dependency with no geometry verification. The ABS_MT
resolution match described in the header comment was never written.

## Decision

### 1. Digitizer discovery by ABS_MT geometry vs DRM mode

`is_digitizer` is replaced by a **geometry match**: a candidate input
device is the Touch Bar digitizer iff:

- It has `EV_ABS` capability with `ABS_MT_POSITION_X` and
  `ABS_MT_POSITION_Y` axes (multi-touch digitizer).
- Its ABS_MT axis ranges are consistent with the Touch Bar DRM mode
  dimensions (the X range ≈ the DRM mode width/height that the engine
  renders, within a tolerance). The Touch Bar is 2170×60; the digitizer's
  `ABS_MT_POSITION_X` max is ~2170 and `ABS_MT_POSITION_Y` max is ~60
  (or the transposed pair, since the panel is rotated). The match is by
  ratio + magnitude, not by name.
- It is on the `seat-touchbar` seat (the udev rule assigns the seat by
  VID:PID, not by name — see §2).

No `dev.name()` call remains in the matching path. The header comment
becomes accurate.

### 2. udev rule by USB VID:PID (zero name strings)

Ship a udev rule in `packaging/udev/99-touchbar-seat.rules` that assigns
the digitizer to `seat-touchbar` by **USB VID:PID `05ac:8600`** (the Apple
iBridge Touch Bar), not by product name:

```
# Apple iBridge Touch Bar (T1/T2) — match by USB VID:PID, NOT by product
# name, so MBP14,2 "Apple T1 Controller Touchpad" and any future name
# variant are covered. See ADR 009.
SUBSYSTEM=="input", ATTRS{idVendor}=="05ac", ATTRS{idProduct}=="8600", \
  ENV{ID_SEAT}="seat-touchbar", TAG+="uaccess"
```

This covers every T1/T2 name variant (iBridge, T1 Controller, Touch Bar
Display Touchpad, MacBookPro17,1, Mac14,7) without enumerating names. The
`TAG+="uaccess"` gives the active console user seat-style access without
hardcoding a group.

### 3. Enforce zero name strings via `scripts/check-invariants.sh`

A repo invariant script greps `src/providers/input.rs` (and the matching
path generally) for the product-name substrings (`Touch Bar`,
`iBridge Touchpad`, `T1 Controller Touchpad`, `Apple Inc.`) and fails the
script if any appear outside comments/tests. This makes the invariant
CI-checkable: a future regression that re-introduces a name string is
caught at the gate.

### 4. Document deploy + reload steps

`packaging/udev/README.md` documents: copy the rule to
`/etc/udev/rules.d/`, run `udevadm control --reload-rules` and
`udevadm trigger`, and how to verify the seat assignment
(`udevadm info /dev/input/eventN | grep ID_SEAT`). This is the deploy path
the review flagged as missing.

### 5. Seborider PR #1 issue text

`docs/seborider-pr1-issue.md` drafts the upstream issue text: the MBP14,2
T1 digitizer reports `"Apple Inc. Apple T1 Controller Touchpad"`, which
the name-list approach must chase; the fix is to match by USB VID:PID +
ABS_MT geometry (this ADR), eliminating the name dependency entirely.

## Alternatives considered

- **Add both T1 names to the substring list and the udev rule.** Rejected:
  it perpetuates the name-chasing and does not fix the invariant. The next
  name variant (T2, Apple Silicon) breaks again.
- **Match by `idVendor}/idProduct` in `is_digitizer` only (no geometry).**
  Rejected: a non-Touch-Bar Apple input device on the same VID would
  falsely match. The ABS_MT geometry check disambiguates the digitizer
  from e.g. an Apple keyboard on the same VID.
- **Match by libinput device's `device_group` or sysfs modalias.** More
  robust but heavier; the ABS_MT geometry + seat narrowing is sufficient
  and testable.

## Impact list

- `src/providers/input.rs` — `is_digitizer` rewritten to ABS_MT geometry
  match; `dev.name()` no longer called in the matching path; header
  comment made accurate.
- `packaging/udev/99-touchbar-seat.rules` — new: seat assignment +
  `uaccess` by VID:PID.
- `packaging/udev/README.md` — new: deploy + reload steps.
- `scripts/check-invariants.sh` — new: invariant script that greps for
  forbidden name strings in the matching code.
- `scripts/ci-gate.sh` — extended to run `check-invariants.sh`.
- `docs/seborider-pr1-issue.md` — new: upstream issue draft.
- `docs/architecture.md`, `docs/adr/001-architecture.md` — corrected to
  reflect geometry-only digitizer discovery (the code now matches the doc).

## Regression test

`src/providers/input.rs` tests: `test_is_digitizer_geometry_match` with
mock ABS_MT axis descriptors — a device with 2170×60 ABS_MT axes matches;
a device with 1280×800 axes (a trackpad) does not; a device with no
ABS_MT does not. The test does not construct a real libinput device; it
exercises the geometry predicate directly with axis-range inputs.

`scripts/check-invariants.sh` is itself the regression guard for the
"zero name strings" invariant.

## References

- `docs/review-report.md` §2.1 (the FAIL being fixed)
- `docs/prior-art.md` §200, §262 (Seborider PR #1)
- `docs/adr/001-architecture.md` (corrected by this ADR)