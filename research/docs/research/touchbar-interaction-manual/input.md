# Touch Bar Input — ground-truth manual (MacBookPro14,2 / T1)

> Direct, unmediated hardware interaction research. Established
> 2026-09-26 (session 038) with the oracle
> (`tiny-dfr-mbp142.service`) RUNNING and lit the entire session.
> Every fact below is cited to a capture in
> `docs/test-logs/038/` or `docs/research/corpus/`.

## 1. The digitizer node

**Device:** `/dev/input/event7`
**sysfs:** `/sys/class/input/input9`
**Name:** `Apple Inc. iBridge Touchpad`
**USB:** `05ac:8600` (iBridge), interface `1-3:2.2`, phys
`usb-0000:00:14.0-3/input2`
**Driver:** `hid-multitouch` (bound via `/sys/bus/hid/devices/0003:05AC:8600.0003`)
**hidraw:** `/dev/hidraw0`
**ID:** bustype=0x0003 (USB), vendor=0x05ac, product=0x8600, version=0x0101

- **Captures:** `docs/test-logs/038/input-discovery.txt` (node
  discovery via `/proc/bus/input/devices` + sysfs) and
  `docs/test-logs/038/evtest-event7-caps.txt` (full evtest header).

> **Node-stability note for the digitizer identity:** the eventN
> number is NOT stable across reboots (Stage-0 s000 captured this
> device at `event4`/`input13`; session 038 captures it at
> `event7`/`input9`). The stable identity is the name
> (`Apple Inc. iBridge Touchpad`) + USB phys
> (`usb-0000:00:14.0-3/input2`) + USB VID:PID (`05ac:8600`). This
> corroborates ADR-041 (unified digitizer identity) — never key on
> `eventN`. (s000 capture: `docs/test-logs/000/evtest-input13.log`;
> s038 capture: `docs/test-logs/038/evtest-event7-caps.txt`.)

## 2. evdev capabilities (full)

**Captured from:** `docs/test-logs/038/evtest-event7-caps.txt`
(evtest header, lines 33-48).

**Input driver version:** 1.0.1
**Properties:** `INPUT_PROP_POINTER` (0) + `INPUT_PROP_DIRECT` (1)
 — a direct-touch pointing device.

**Supported event types:**
- `EV_SYN` (0)
- `EV_KEY` (1)
- `EV_ABS` (3)

**EV_KEY codes (BTN_*):**
| code | name | meaning |
|------|------|---------|
| 325 | `BTN_TOOL_FINGER` | single-finger contact |
| 328 | `BTN_TOOL_QUINTTAP` | five-finger contact |
| 330 | `BTN_TOUCH` | touch in progress (1 = contact, 0 = lift) |
| 333 | `BTN_TOOL_DOUBLETAP` | two-finger contact |
| 334 | `BTN_TOOL_TRIPLETAP` | three-finger contact |
| 335 | `BTN_TOOL_QUADTAP` | four-finger contact |

**EV_ABS axes (ranges + resolution):**
| code | name | min | max | resolution | notes |
|------|------|-----|-----|------------|-------|
| 0 | `ABS_X` | 0 | 32767 | (no `abs/` subdir; units unspecified) | legacy single-touch X, mirrors `ABS_MT_POSITION_X` |
| 1 | `ABS_Y` | 0 | 127 | (units unspecified) | legacy single-touch Y — the bar is 1px "tall" in touch Y |
| 47 | `ABS_MT_SLOT` | 0 | 10 | — | up to 11 simultaneous contacts (slots 0..10) |
| 53 | `ABS_MT_POSITION_X` | 0 | 32767 | (units unspecified) | MT long-axis position (left→right along the bar) |
| 54 | `ABS_MT_POSITION_Y` | 0 | 127 | (units unspecified) | MT short-axis position (essentially unused — see §3) |
| 57 | `ABS_MT_TRACKING_ID` | 0 | 65535 | — | per-slot contact ID; `-1` = slot empty/lifted |
| 59 | `ABS_MT_DISTANCE` | 0 | 1 | — | proximity/distance (0 = touching, 1 = not / hover-edge) |

**Axes NOT present (notably):**
- No `ABS_MT_PRESSURE` — no pressure axis.
- No `ABS_MT_TOUCH_MAJOR` / `ABS_MT_TOUCH_MINOR` — no contact-area axes.
- No `ABS_MT_ORIENTATION`.
- No `ABS_MT_WIDTH_MAJOR` / `ABS_MT_WIDTH_MINOR`.
- No `ABS_TILT_X` / `ABS_TILT_Y`.

The `abs/` sysfs subdir (which would expose per-axis resolution) is
NOT present on this driver (`ls /sys/class/input/input9/abs/` →
"No such file or directory"). Resolution units are unspecified.

## 3. Protocol — what the digitizer emits

Derived from the clean corpus
(`docs/research/corpus/*.evdev`, `docs/research/corpus/corpus-analysis.txt`):

**Contact lifecycle (per slot):**
1. `ABS_MT_SLOT` = N (select slot N)
2. `ABS_MT_TRACKING_ID` = <monotonic id> (assign a new contact)
3. `ABS_MT_POSITION_X` = <0..32767> (the X position)
4. `BTN_TOUCH` = 1, `BTN_TOOL_FINGER` = 1 (touch in progress)
5. `ABS_X` = <same as POSITION_X> (legacy single-touch mirror)
6. `SYN_REPORT` (frame commit)
7. (movement: repeated `ABS_MT_POSITION_X` + `ABS_X` + `SYN_REPORT`)
8. `ABS_MT_TRACKING_ID` = -1 (lift)
9. `BTN_TOUCH` = 0, `BTN_TOOL_FINGER` = 0
10. `SYN_REPORT`

**Key protocol facts (from the corpus):**
- **Y is NOT emitted.** `ABS_MT_POSITION_Y` and `ABS_Y` never appear
  in any gesture's events (corpus-analysis.txt: "Y values:" empty
  for every gesture). The bar is a 1-pixel-tall touch strip; Y is
  always the default (0) and is not reported. **A tbard input
  consumer must NOT rely on Y.** Only X carries meaningful
  position.
- **Tracking IDs are monotonic across the session** (79, 80, 81...
  up to 94 in the palm touch) and never reused within the session.
  `-1` marks a lift.
- **Slots are not stable across gestures** (single-tap used slot 2,
  double-tap slot 3, slow-drag slot 3, fast-swipe slot 4, two-finger
  slots 6+7, etc.). Do NOT key contact identity on slot — use
  `ABS_MT_TRACKING_ID`.
- **`BTN_TOOL_FINGER` is the working contact-class indicator** for
  normal touches. `BTN_TOOL_DOUBLETAP`/`TRIPLETAP`/`QUADTAP`/
  `QUINTTAP` appear occasionally (two-finger-simultaneous,
  palm-broad-touch) but NOT on every multi-finger gesture — do not
  rely on them for contact counting; count active `TRACKING_ID`s
  instead.
- **`ABS_MT_DISTANCE` is almost always 0** (touching). It appeared
  exactly once in the edge-touch gesture (value 1) — likely a
  proximity transition at the extreme edge. Treat `DISTANCE` as
  unreliable for normal touch processing.
- **Idle noise floor is ZERO.** The 10s idle baseline
  (`idle-10s.evdev`) emitted zero events — the digitizer is silent
  when untouched. There is no spurious noise to filter.

## 4. Gesture corpus index

**Directory:** `docs/research/corpus/`
**Labels file:** `docs/research/corpus/labels.md`
**Analysis:** `docs/research/corpus/corpus-analysis.txt`

| file | gesture | events | SYN_REPORTs | slots used | tracking IDs | X range | duration (s) |
|------|---------|--------|-------------|------------|--------------|---------|--------------|
| `single-tap.evdev` | single tap | 10 | 2 | (1) | 79 | 11279 | 0.268 |
| `double-tap.evdev` | double tap | 21 | 4 | 2 | 80, 81 | 8787-8954 | 0.420 |
| `long-press.evdev` | long press (~2s) | 10 | 2 | (1) | 82 | 9452 | 1.718 |
| `slow-drag.evdev` | slow drag | 473 | 156 | 3 | 83 | 11128-21471 | 3.016 |
| `fast-swipe.evdev` | fast swipe | 77 | 24 | 4 | 84 | 11204-24205 | 0.606 |
| `two-finger-simultaneous.evdev` | two-finger simultaneous | 21 | 3 | 6, 7 | 85, 86 | 15432-18663 | 0.252 |
| `two-finger-sequential.evdev` | two-finger sequential | 22 | 4 | 5, 8 | 87, 88 | 16398-21743 | 1.702 |
| `edge-touch.evdev` | edge touch (right edge) | 18 | 4 | 9 | 89 | 32570-32706 | 0.420 |
| `palm-broad-touch.evdev` | palm-ish broad touch | 50 | 9 | 0, 5, 10 | 90-94 | 21698-27210 | 0.454 |
| `idle-10s.evdev` | 10s idle (baseline) | 0 | 0 | — | — | — | 10.0 |

**Coverage:** single tap, double tap, long press, slow drag, fast
swipe, two-finger simultaneous, two-finger sequential, edge touch,
palm/broad touch, idle baseline. The brief's 10 gestures are all
covered.

**Notable gesture signatures:**
- **single-tap:** 1 tracking ID, 2 SYN_REPORTs (down + up), ~268ms.
- **double-tap:** 2 tracking IDs, 4 SYN_REPORTs (down/up/down/up).
- **long-press:** 1 tracking ID, 2 SYN_REPORTs, ~1.7s gap between
  down and up (the sustained contact).
- **slow-drag:** 1 tracking ID, 156 SYN_REPORTs — many X updates
  across a 10343-unit X range (11128→21471).
- **fast-swipe:** 1 tracking ID, 24 SYN_REPORTs, 12901-unit X range
  in 0.606s (faster than slow-drag: fewer samples, longer X travel
  per sample).
- **two-finger-simultaneous:** 2 tracking IDs (85, 86), 2 slots
  (6, 7), 3 SYN_REPORTs — both contacts in the same frame.
- **two-finger-sequential:** 2 tracking IDs (87, 88), 2 slots
  (5, 8), 4 SYN_REPORTs (down/up/down/up).
- **edge-touch:** X=32570-32706 (near the max 32767 — the far
  RIGHT edge). `ABS_MT_DISTANCE`=1 appeared once.
- **palm-broad-touch:** 5 tracking IDs (90-94), 3 slots (0, 5,
  10) — a broad contact registers as multiple simultaneous
  contacts spread across the bar (X 21698-27210). `BTN_TOOL_*`
  fired `QUADTAP`/`QUINTTAP` here.

## 5. Multi-reader coexistence proof

**The oracle's F-row UI reacted to touches WHILE evtest recorded,
for all 10 gestures.** evtest was run WITHOUT `--grab` (no
`EVIOCGRAB`), so the read is non-exclusive. The oracle
(`tiny-dfr-mbp142.service`, PID 241900) remained `active` throughout
and the human confirmed its UI reacted to every gesture.

- **Human checkpoint (verbatim):** for every gesture the human
  answered "Done (oracle reacted)"; the final confirmation was
  "Yes — coexistence confirmed" (the F-row stayed visible AND
  reacted to touches the entire time).
- **Capture:** `docs/research/corpus/labels.md` (coexistence proof
  section) + the per-gesture HC answers in the session transcript.
- **Significance:** this legitimizes a future field-debug reader
  alongside tbard — an unprivileged `evtest`/libevdev reader on
  `/dev/input/event7` does NOT disturb the production input
  consumer. `evtest --grab` (exclusive) WOULD disturb it and must
  NOT be used in production.

## 6. Findings feeding ADR-044 / 045 / 046

- **ADR-041 (unified digitizer identity) — corroborated:** the
  eventN number is unstable (s000: event4/input13; s038:
  event7/input9). The stable identity is name + phys + VID:PID.
  Never key on eventN.
- **ADR-046 (STEP 4b) — input-side unaffected** by the backlight
  mtime quirk; the digitizer identity probe in the runbook is
  sound (name + phys). No input-side change recommended.
- **NEW (for a future input ADR, not yet numbered):** a tbard input
  consumer must (a) ignore Y (never emitted), (b) key contact
  identity on `ABS_MT_TRACKING_ID` not slot, (c) count active
  tracking IDs for multi-touch — not `BTN_TOOL_DOUBLETAP` etc.
  (which are unreliable), (d) treat `ABS_MT_DISTANCE` as
  unreliable, (e) expect zero idle noise. These are ground-truth
  constraints from the corpus, logged here not implemented.