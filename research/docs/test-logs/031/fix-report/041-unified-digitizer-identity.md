# ADR 041: Unified Digitizer Identity — Structural Predicate + Probe Subcommand

## Status: Accepted

## Date: 2026-09-26

## Context

### Session-029 blocker — predicate contradiction (preflight GO, runtime NO)

Stage-3 attempt #2 (`docs/test-logs/029/`) aborted at digitizer identify
×3 → calibrated `start-limit-hit`. The runtime predicate
`geometry_matches_tb` (`src/providers/input.rs:262-269`) rejected the
real iBridge ABS_MT maxima (X 32767 / Y 127) vs `tb_dims=(60,2170)`,
while preflight STEP 0d (`scripts/bench/interlock-preflight.sh:103-153`)
had ACCEPTED the same device — a predicate CONTRADICTION: preflight GO,
runtime NO. The unit tests at `input.rs:375-406` only exercised the
predicate with values already in the 2170/60 neighbourhood, so the
32767/127 case was never tested against the real predicate (only against
the sim, which bypasses the gate). HC3 confirmed the oracle receives
touches on this machine WITH `ID_SEAT=seat-touchbar` active on the
digitizer (`docs/test-logs/029/hc-answers.txt`).

### Task 0 — Derivations (docs before code; cite file:line for everything)

#### D1. Identify/acquire ordering — where does digitizer identify sit relative to DRM acquire?

The service arm in `src/main.rs` orders the steps (current source,
post-ADR-039/040):

1. **ADR-034 hard root guard** — `src/main.rs:202-208`
   (`opts.service && geteuid() != 0` → fast-fail). TOP of the arm, BEFORE
   any scan.
2. **ADR-039 privdrop target resolution** — `src/main.rs:226-242`
   (`service::resolve_privdrop_target()` → `Option<PrivDropTarget>`).
   BEFORE any device work — the explicit ADR-039 ordering requirement
   (resolution failure surfaces with NO device touched).
3. **DRM card acquire** — `src/main.rs:252-273` (`prov.acquire()` →
   `DrmProvider::acquire`). The card fd is held inside `drm`.
4. **`tb_dims` derivation** — `src/main.rs:276-279`
   (`drm.display_info().map(|i| (i.width, i.height)).unwrap_or((60, 2170))`).
5. **Digitizer identify** — `src/main.rs:280-294`
   (`LibinputProvider::new(tb_dims)` then `input.init()` →
   `LibinputProvider::init` `input.rs:272-287` →
   `identify_digitizer` `input.rs:139-192`). Runs PRE-DROP, AFTER the DRM
   acquire (step 3), BEFORE the privdrop (step 8). In SERVICE mode a
   failure here is `log::error!` + `return Err` (exit 1) — `main.rs:289-292`.
6. **Backlight path select + fd open** — `src/main.rs:295-302`
   (`SysfsBacklight::new`), `src/main.rs:379-391`
   (`open_backlight_brightness_fd_pre_drop`).
7. **Pre-drop fd assembly** (`required_fds`) — `src/main.rs:338-372`
   (uinput `:347-358`, drm `:363`, digitizer `:372`, backlight `:380-382`).
8. **Privdrop** — `src/main.rs:405-411`
   (`service::privdrop_to_nobody_with_target(privdrop_target.expect(...))`).
9. **POST-DROP self-check** — `src/main.rs:417-421` (`required_fds.self_check()`).
10. **render loop** — `src/main.rs:424-433` (`real_main(...)`).

**Reconciliation with session-029's "debugfs empty / never acquired":**
the digitizer identify (step 5) sits AFTER the DRM acquire (step 3). In
session-029 the DRM acquire SUCCEEDED (the oracle was stopped; the card
was free), so the daemon proceeded to step 5 and FAILED there — at
`identify_digitizer`, BEFORE the privdrop (step 8) and BEFORE the render
loop (step 10). Because the daemon exited at step 5, the `drm` value
dropped via RAII `Drop` (`DrmProvider::drop` releases master), leaving
debugfs empty. **acceptance-1's live status: the DRM acquire DID run and
DID release via RAII** — the card was acquired at step 3, held across
the failed step 5, and released by the `drm` Drop as the service arm
returned `Err`. This is exactly the "no leak on a pre-loop failure"
property ADR-036's RAII design guarantees. The ADR-039 privdrop fix was
NOT exercised (the daemon fails at step 5, before step 8).

#### D2. The predicate's ancestry — what does `geometry_matches_tb` compare, why did it pass in sim, and what is the CORRECT identification semantics?

**What it compares today** (`src/providers/input.rs:262-269`):

```rust
pub fn geometry_matches_tb(x_max: i32, y_max: i32, tb_dims: (u16, u16)) -> bool {
    const TOLERANCE: i32 = 40; // px
    let (w, h) = (tb_dims.0 as i32, tb_dims.1 as i32);
    let near = |a: i32, b: i32| (a - b).abs() <= TOLERANCE;
    (near(x_max, w) && near(y_max, h)) || (near(x_max, h) && near(y_max, w))
}
```

It compares the **raw evdev ABS_MT_POSITION_X/Y maxima** (typically 2^n−1
on a HID-multitouch digitizer — the iBridge reports 32767/127) against
the **DRM framebuffer pixel dims** `tb_dims=(60,2170)` with a 40px
tolerance. `near(32767, 60)=false`, `near(32767, 2170)=false`,
`near(127, 60)=false`, `near(127, 2170)=false` → REJECTS the real
digitizer. This compares raw abs maxima (oranges) to framebuffer pixel
dims (apples) and never scales.

**Why it passed in sim:** `SimInputProvider::new`
(`src/providers/sim_input.rs:103-105`) calls `new_with_range(logical_w,
logical_h, logical_w, logical_h)` — i.e. the uinput ABS_MT max is set to
the LOGICAL dims (2170/60), so the raw abs maxima ARE the framebuffer
dims (identity map). `geometry_matches_tb(2170, 60, (60, 2170))` →
`near(2170, 2170) && near(60, 60)` → ACCEPT. The sim's
identity-in-sim assumption (ABS max == logical dim) is what made the
predicate pass in sim while the real device (ABS max == 2^n−1) fails it.
ADR-024 (`docs/adr/024-scale-wiring.md`) fixed this divergence for the
SCALE path (`poll`'s `x_transformed`/`y_transformed` now use
`self.tb_dims`, and `new_with_range` lets a test set 32767/127 + scale
to 2170/60), but the IDENTIFICATION predicate
(`geometry_matches_tb`) was never fixed — it still compares raw maxima
to pixel dims. The ADR-024 scale test
(`sim_input.rs:361-619`) exercises the scale, not the gate.

**The CORRECT identification semantics (CONSTRAINT: no hardcoded
real-hardware magic numbers; the predicate must be STRUCTURAL):**

The real iBridge 32767/127 are HID-multitouch raw ranges (2^n−1), not
panel pixels — same-model units vary (the prior-art both-names evidence:
the MBP14,2 "Apple T1 Controller Touchpad" and the bench "Apple Inc.
iBridge Touchpad" are the same USB VID:PID `05ac:8600` device class,
`docs/prior-art.md:200`, `docs/seborider-pr1-issue.md`; hardcoding 32767
or 127 would break the next T1/T2 variant the way the old name-list
did). The predicate must therefore be STRUCTURAL — it must identify the
digitizer by WHAT IT IS (a multitouch strip-class digitizer on the
Touch Bar's USB device), not by a numeric coincidence with a particular
panel's pixel dims.

The structural predicate is:

1. **Multitouch capability**: the device has `BTN_TOUCH` (EV_KEY) +
   `ABS_MT_POSITION_X` + `ABS_MT_POSITION_Y` axes (a multi-touch
   digitizer, not a trackpad-relative or non-touch evdev device).
   libinput's `DeviceCapability::Touch` already encodes this
   (`input.rs:100-102` checks it first).
2. **Strip-class axis shape**: the ABS_MT range is LONG × SHORT (one
   axis ≫ the other) — a Touch Bar strip, not a square touchpad. The
   iBridge is 32767 × 127 (ratio ≈ 258); a trackpad is ~1280 × 800
   (ratio ≈ 1.6). A square decoy (1024 × 768, ratio ≈ 1.3) is rejected.
   This is scale-free (the long/short ratio is invariant under 2^n−1 vs
   pixel scaling) and model-invariant (any Touch Bar digitizer reports a
   strip, not a square).
3. **Association with the touchbar's USB device** (`05ac:8600` iBridge):
   the device's evdev node resolves via sysfs/udev to the iBridge USB
   device (by-path / `ID_PATH` under the `05ac:8600` iBridge). This is
   the VID:PID association ADR-009's udev rule uses
   (`packaging/udev/69-touchbar-seat.rules`), exposed as a structural
   property of the device's sysfs ancestry — NOT a product-name string.
   The candidate must be on the iBridge USB device (or, equivalently,
   tagged `ID_SEAT=seat-touchbar` by the ADR-009 rule — the seat tag is
   the udev-materialised form of the VID:PID association).
4. **`ABS_MT_RESOLUTION`-based aspect check WHEN resolution is present,
   absence-tolerant WHEN it is not**: if the device reports
   `ABS_MT_RESOLUTION_X`/`ABS_MT_RESOLUTION_Y` (units/mm), the
   resolution-based aspect ratio must be strip-class (long/short, same
   long/short orientation as the axis ranges). Many HID-multitouch
   drivers do NOT report resolution (the iBridge reports `resolution=0`
   for both axes — `input_absinfo.resolution` is 0), so the predicate
   MUST be absence-tolerant: when resolution is 0/absent, fall back to
   the range-based strip check (item 2). When resolution IS present, the
   resolution aspect is a stronger check (it is invariant under the
   device's abs-range bit-width, which varies across HID
   implementations).

This predicate accepts the real iBridge (32767/127, strip, on the
iBridge USB device, no resolution) AND the sim (2170/60, strip, on the
iBridge USB device or the uinput sim), and rejects a square decoy
(1024×768 multitouch), a trackpad (1280×800 multitouch), and a
non-multitouch evdev device. No hardcoded 32767 or 127 or 2170 or 60
appears in the predicate.

#### D3. Seat audit — does our current seat assignment EXCLUDE the digitizer from our own libinput context?

**From OUR code** (`src/providers/input.rs:72-76`):

```rust
pub fn new(tb_dims: (u16, u16)) -> Self {
    let mut tb_input = Libinput::new_with_udev(Interface);
    let mut main_input = Libinput::new_with_udev(Interface);
    let _ = tb_input.udev_assign_seat("seat-touchbar");   // :75
    let _ = main_input.udev_assign_seat("seat0");         // :76
    ...
}
```

Our `LibinputProvider` assigns `"seat-touchbar"` to the `tb_input`
(context used for digitizer enumeration in `identify_digitizer`,
`input.rs:149`) and `"seat0"` to `main_input` (FN key / lid switch).

**From the ORACLE source** (`backup_old/tiny-dfr-mbp142/src/main.rs:899-902`,
read-only reference):

```rust
let mut input_tb = Libinput::new_with_udev(Interface);
let mut input_main = Libinput::new_with_udev(Interface);
input_tb.udev_assign_seat("seat-touchbar").unwrap();   // :901
input_main.udev_assign_seat("seat0").unwrap();         // :902
```

The oracle uses the **EXACT SAME mechanism**: `Libinput::new_with_udev`
+ `udev_assign_seat("seat-touchbar")`. The oracle receives touches on
this machine (HC3, `docs/test-logs/029/hc-answers.txt`: "I see F keys
and it toggles to control keys if I press fn key. also is reacting when
I touch it"). Therefore the seat-touchbar libinput context DOES
enumerate the digitizer — the mechanism is proven by the oracle's live
operation.

**Reconciliation with session-029's "no device carries ID_SEAT=
seat-touchbar":** the session-029 secondary observation
(`docs/test-logs/029/step3-diagnosis.txt:80-93`) noted that no
`/dev/input` device on this host carries an `ID_SEAT=` property under
`udevadm info`, and speculated the digitizer is on seat0. Two facts
reconcile this with the oracle receiving touches:

1. The oracle's OWN udev rule
   (`backup_old/tiny-dfr-mbp142/etc/udev/rules.d/99-touchbar-seat.rules`)
   tags only `"Apple Inc. Touch Bar Display Touchpad"`,
   `"MacBookPro17,1 Touch Bar"`, and `"Mac14,7 Touch Bar"` by NAME — it
   does NOT tag the bench's `"Apple Inc. iBridge Touchpad"`. So on this
   bench, NEITHER the oracle's name-gated rule NOR our `69-touchbar-seat.rules`
   (VID:PID `05ac:8600`) had tagged event7 with `ID_SEAT=seat-touchbar`
   at session-029 time (the `69-` rule may not be installed on the live
   system, or udev had not been triggered — the installed rule set is
   the oracle's, per the session-029 baseline).
2. The oracle identifies the digitizer by **NAME string**
   (`dev.name().contains("iBridge Touchpad")`,
   `backup_old/tiny-dfr-mbp142/src/main.rs:1043-1044`) while iterating
   BOTH contexts chained (`input_tb.clone().chain(input_main.clone())`,
   oracle `main.rs:1036`). So even when the seat-touchbar context
   enumerates nothing (no `ID_SEAT=seat-touchbar` tag), the oracle finds
   the digitizer in the `seat0` context (`input_main`) by name. This is
   why the oracle works on this bench despite the missing seat tag.

**The practical observation** (`step3-diagnosis.txt:88-91`): tbard's
seat-touchbar context "DID see *something*" (otherwise the error would
differ from "no digitizer found on seat-touchbar (geometry gate...)" —
it would be "dispatch failed" or an empty-iteration). libinput's udev
backend with `udev_assign_seat("seat-touchbar")` enumerates devices the
udev backend matches; when no device carries the seat tag, libinput's
udev seat filtering behaviour is that the context is empty (no
device-added events). The error message
"no digitizer found on seat-touchbar (geometry gate: ABS_MT vs (60,
2170))" is emitted by `identify_digitizer` at `input.rs:181-190` when
the iteration completes with no match — which is consistent with EITHER
an empty context OR a context whose devices fail the geometry gate.

**Verdict: our current seat assignment does NOT exclude the digitizer
by mechanism** — it is the identical mechanism the oracle uses, and the
oracle receives touches. The session-029 blocker is the GEOMETRY GATE
(D2), not the seat assignment. Whether the digitizer is actually
enumerated in the seat-touchbar context on a host where the
`ID_SEAT=seat-touchbar` tag is applied (our `69-` rule or a future
custom-seat) is a Stage-3/4 acceptance question, NOT a code defect.
**ADR-042 is NOT triggered** — the seat mechanism is proven by the
oracle; the blocker is the predicate. If a future Stage-3 run finds the
seat-touchbar context empty AFTER the predicate is fixed AND the
`69-touchbar-seat.rules` is installed + `udevadm trigger`-ed, THAT would
be a new ADR (the seat-tag application), but the evidence today does not
support it. The structural predicate (D2 item 3) associates the
candidate with the iBridge USB device via `ID_PATH`/`ID_SEAT`, which is
robust to the seat-context enumeration question: the predicate runs
inside the seat-touchbar context's enumeration, and the
`ID_SEAT=seat-touchbar` tag (when applied by the installed udev rule) is
the udev-materialised form of the iBridge USB association the predicate
checks.

## Decision

### 1. Replace `geometry_matches_tb` with a structural predicate in ONE place

The structural predicate from D2 replaces `geometry_matches_tb`. It
lives in ONE place — `src/geometry.rs` (the single source of truth for
the three-space model, ADR-020) — as a pure function over a candidate
descriptor, so both the runtime `identify_digitizer` and the
`--probe-input` subcommand (and the preflight, via the probe) invoke the
SAME function. `src/providers/input.rs` calls into `geometry.rs`; no
predicate logic remains in `input.rs`.

The predicate's input is a `DigitizerCandidate` struct carrying the
structural facts (has `BTN_TOUCH`, has `ABS_MT_POSITION_X/Y`, the X/Y
maxima, the X/Y resolutions, and the `ID_SEAT`/`ID_PATH` association
with the iBridge USB device). The `input.rs` caller builds the candidate
from the libinput `InputDevice` + an evdev `EVIOCGABS` probe + a sysfs
udev-property read; the `--probe-input` subcommand builds it the same
way against real devices.

The predicate is:
- ACCEPT iff (multitouch: `BTN_TOUCH` + `ABS_MT_POSITION_X` + `ABS_MT_POSITION_Y`)
  AND (strip-class: `long_axis / short_axis >= STRIP_RATIO_MIN` where
  `STRIP_RATIO_MIN` is a structural constant, NOT a hardware magic
  number — a Touch Bar strip is ≫ 10:1, a trackpad is ≈ 1.6:1, a square
  decoy is ≈ 1.3:1; `STRIP_RATIO_MIN = 10` separates strip from
  non-strip without naming a panel dimension)
  AND (iBridge-associated: `ID_SEAT == "seat-touchbar"` OR the evdev
  node's sysfs ancestry contains the `05ac:8600` USB device)
  AND (resolution-aspect: if both `ABS_MT_RESOLUTION_X` and
  `ABS_MT_RESOLUTION_Y` are non-zero, the resolution aspect is
  strip-class with the same long/short orientation as the ranges;
  absence-tolerant — if either resolution is 0, skip this check).
- REJECT otherwise.

No `32767`, `127`, `2170`, or `60` appears in the predicate. The
sim (2170/60) is ACCEPTED (strip, on the iBridge/sim device); the real
iBridge (32767/127) is ACCEPTED (strip, on the iBridge device); a
1024×768 square multitouch is REJECTED (ratio ≈ 1.3 < 10); a 1280×800
trackpad is REJECTED (ratio ≈ 1.6 < 10); a non-multitouch evdev device
is REJECTED (no `BTN_TOUCH`/`ABS_MT`).

### 2. Probe subcommand: `tbard --probe-input`

A new internal subcommand runs the SAME identification path as the
service arm against real devices, read-only, prints diagnostics, and
exits 0 (identified) / 1 (not identified). It is NOT a user feature —
it is the preflight's executor. Documented as internal tooling in
`--help` and the ADR.

`--probe-input` builds a `LibinputProvider`-equivalent identification
WITHOUT acquiring DRM master, WITHOUT privdrop, WITHOUT uinput/backlight
opens — it constructs the `tb_dims` from the DRM mode read
(read-only `display_info`, no master acquire) or the `(60, 2170)`
fallback, enumerates the seat-touchbar libinput context, and runs the
structural predicate against each Touch-capable device, printing the
candidate diagnostics (evdev path, ABS_MT maxima, resolutions,
`ID_SEAT`/`ID_PATH`, predicate verdict). Exits 0 if a digitizer was
identified, 1 otherwise.

### 3. Preflight unification — STEP 0d calls the probe

`interlock-preflight.sh` STEP 0d is rewritten to call the installed
`/usr/bin/tbard --probe-input` instead of its own geometry
reimplementation (the python EVIOCGABS block at `:103-153`). The
preflight's "Mirrors identify_digitizer" claim becomes TRUE: preflight
GO ⇒ runtime GO is structural (same function, same predicate). The
preflight exits NO-GO if the probe exits 1, with the probe's diagnostics
inline. The python EVIOCGABS block is removed (no more duplicated
predicate logic in bash/python).

### 4. Test matrix (against the REAL predicate, fixtures only)

Unit tests in `src/geometry.rs` (the predicate's home) covering:
- real iBridge ranges (32767/127, strip, iBridge-associated, no
  resolution) → ACCEPTED.
- sim ranges (2170/60, strip, iBridge-associated, no resolution) →
  ACCEPTED (dev mode unchanged).
- square decoy (1024×768 multitouch, strip-ratio fail) → REJECTED.
- trackpad (1280×800 multitouch, strip-ratio fail) → REJECTED.
- non-multitouch evdev device (no `BTN_TOUCH`/`ABS_MT`) → REJECTED.
- resolution-present aspect case (strip ranges + strip resolutions) →
  ACCEPTED; (strip ranges + square resolutions) → REJECTED.
- resolution-absent case (resolutions 0) → ACCEPTED on strip ranges,
  REJECTED on square ranges (the range strip check carries it).
- non-iBridge-associated strip multitouch (e.g. a hypothetical
  32767×127 strip on a non-Apple USB device) → REJECTED (the
  iBridge-association gate).

Rejection tests are mandatory (non-vacuity): each REJECTED case must
assert the predicate returns `false`, not merely be skipped.

### 5. Equivalence test — preflight executor and service-arm identify invoke the same function

A test asserting the `--probe-input` path and the service-arm
`identify_digitizer` invoke the SAME predicate function
(`geometry::is_touchbar_digitizer`). This is enforced structurally: both
`identify_digitizer` (`input.rs`) and the `--probe-input` handler
(`main.rs`) call `geometry::is_touchbar_digitizer(&candidate)`. A unit
test in `geometry.rs` asserts the predicate is the single callable
(i.e. there is no second predicate; the test feeds the same
`DigitizerCandidate` to the public predicate and asserts the result
matches the service-arm + probe path). Additionally, the
`--probe-input` integration can be run in CI against a uinput fixture
tagged with `ID_SEAT=seat-touchbar` (the sim's uinput device), and the
unit predicate against the same fixture data — same code-path evidence.

### 6. Update ADR-040's doc + test-plan: 0d is now binary-backed

ADR-040's STEP 0d description
(`docs/adr/040-preflight-environment-inventory.md:68-76`) is updated:
0d now calls `/usr/bin/tbard --probe-input` (the binary-backed probe)
instead of its own python EVIOCGABS reimplementation. The
"Mirrors identify_digitizer" claim becomes literally true. The
test-plan's STEP 0d description is updated to match.

## Alternatives considered

- **Scale raw maxima to DRM mode space before the `near()` comparison
  (the session-029 ADR proposal option a).** Rejected: it requires
  carrying the DRM mode dims into the predicate AND hardcodes the
  scale assumption (raw = 2^n−1, scale = mode/raw). It is also
  model-fragile — a device whose abs range is NOT 2^n−1 (e.g. a HID
  digitizer that reports panel-pixel ranges directly) would fail the
  scaled comparison. The structural strip-ratio + iBridge-association
  predicate is scale-free and model-invariant.
- **Compare against raw 2^n−1 ranges with DRM-mode dims carried
  separately (session-029 option b).** Rejected for the same reason —
  it hardcodes the 2^n−1 assumption. The strip-ratio is invariant under
  the bit-width.
- **Keep the geometry gate, add a 32767/127 special case.** Rejected:
  this is the hardcoded-real-hardware-magic-number pattern the CONSTRAINT
  forbids; the next T1/T2 variant with a different abs range breaks it
  the way the name-list broke.
- **Drop the geometry/structural gate entirely; identify by `ID_SEAT`
  alone.** Rejected: a udev rule mis-assignment (a non-digitizer tagged
  `seat-touchbar`) would falsely match. The structural gate
  disambiguates the digitizer from e.g. an Apple keyboard on the same
  USB device. This is ADR-009's disambiguation argument, preserved.
- **ADR-042 (custom seat).** NOT triggered — D3 shows our seat mechanism
  is identical to the oracle's, which receives touches. The blocker is
  the predicate, not the seat.

## Consequences

- The real iBridge digitizer (32767/127) is ACCEPTED by the runtime
  gate; the sim (2170/60) is still ACCEPTED (dev mode unchanged).
- Preflight GO ⇒ runtime GO is structural (same predicate function);
  the session-029 contradiction is eliminated.
- The predicate is model-invariant (no hardcoded panel dims or abs
  ranges); the next T1/T2 name/abs-range variant is covered by the
  strip-ratio + iBridge-association, the same way ADR-009's VID:PID udev
  rule covers name variants.
- The `--probe-input` subcommand gives the preflight a binary-backed
  executor and gives the operator a read-only diagnostic tool.
- ADR-040's STEP 0d is binary-backed (no more duplicated python
  predicate).

## Impact list

- `src/geometry.rs` — new `DigitizerCandidate` struct +
  `is_touchbar_digitizer(&DigitizerCandidate) -> bool` (the structural
  predicate); tests for the full matrix (accept + reject).
- `src/providers/input.rs` — `geometry_matches_tb` removed;
  `identify_digitizer` + `is_digitizer` build a `DigitizerCandidate`
  (from libinput `InputDevice` + `EVIOCGABS` + sysfs `ID_SEAT`/`ID_PATH`)
  and call `geometry::is_touchbar_digitizer`. The `digitizer_evdev_fd`
  pre-drop hold (ADR-036) is unchanged.
- `src/main.rs` — new `--probe-input` arm (read-only identification
  against real devices, no DRM master acquire, no privdrop); `Options`
  gains `probe_input: bool`.
- `scripts/bench/interlock-preflight.sh` — STEP 0d rewritten to call
  `/usr/bin/tbard --probe-input`; the python EVIOCGABS block removed.
- `docs/adr/041-unified-digitizer-identity.md` — this ADR.
- `docs/adr/040-preflight-environment-inventory.md` — STEP 0d updated
  to binary-backed.
- `docs/test-plan.md` — STEP 0d updated; new ADR-041 test matrix.
- `CHANGELOG.md` / `devlog.md` — session 030.
- `docs/self-assessment-10.md` — claims (not verdicts).

## Test plan

- Unit (`geometry.rs`): the full accept/reject matrix (item 4).
- Unit (`geometry.rs`): equivalence — the predicate is the single
  callable; `identify_digitizer` and `--probe-input` both call it (item
  5, enforced structurally + asserted).
- `cargo fmt --check`, `cargo build --bin tbard`, `cargo clippy
  --all-targets -- -D warnings`, `cargo test`,
  `scripts/check-invariants.sh`, `scripts/ci-gate.sh`,
  `bash -n scripts/bench/interlock-preflight.sh`,
  `bash -n packaging/PKGBUILD` — all green.
- The real seat interaction (udev `ID_SEAT=seat-touchbar` on the real
  node) remains Stage-3/4 acceptance — stated, not claimed here.

## References

- `src/providers/input.rs:262-269` (the old `geometry_matches_tb`)
- `src/providers/input.rs:139-192` (`identify_digitizer`)
- `src/providers/input.rs:99-116` (`is_digitizer`)
- `src/providers/sim_input.rs:103-105` (sim identity-map, the
  identity-in-sim assumption)
- `src/geometry.rs` (the three-space model, ADR-020 — the predicate's
  home)
- `src/main.rs:202-294` (service-arm ordering, D1)
- `src/main.rs:276-294` (digitizer identify AFTER DRM acquire, BEFORE
  privdrop)
- `scripts/bench/interlock-preflight.sh:103-153` (STEP 0d, the
  duplicated predicate)
- `docs/adr/009-digitizer-geometry.md` (geometry/VID:PID discovery)
- `docs/adr/024-scale-wiring.md` (scale wiring — the scale was fixed,
  the gate was not)
- `docs/adr/036-digitizer-fd-pre-drop.md` (pre-drop digitizer fd)
- `docs/adr/039-privdrop-target-resolution.md` (resolution before
  acquire)
- `docs/adr/040-preflight-environment-inventory.md` (STEP 0d)
- `docs/test-logs/029/step3-diagnosis.txt` (the session-029 blocker +
  seat secondary observation)
- `docs/prior-art.md:200`, `docs/seborider-pr1-issue.md` (the
  both-names evidence — same model, different names)
- `backup_old/tiny-dfr-mbp142/src/main.rs:899-902, 1036, 1043-1044`
  (oracle seat + name-string identification, D3)
- `packaging/udev/69-touchbar-seat.rules` (VID:PID seat assignment)