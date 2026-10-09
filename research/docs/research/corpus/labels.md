# Touch Bar digitizer corpus — labels

**Source device:** `/dev/input/event7` — "Apple Inc. iBridge Touchpad"
(`/sys/class/input/input9`, USB 05ac:8600, hid-multitouch, hidraw0,
phys `usb-0000:00:14.0-3/input2`).

**Capture method:** `evtest /dev/input/event7` (default, NO `--grab` —
non-exclusive read). Line-buffered (`stdbuf -oL -eL`), 10s window per
gesture, graceful SIGINT kill. Oracle `tiny-dfr-mbp142.service` RUNNING
and lit the entire corpus session (verified active before/after each
gesture). The human confirmed the oracle's F-row UI reacted to touches
WHILE evtest recorded — this is the multi-reader coexistence proof
(legitimizes future field-debug readers alongside tbard).

**Coordinate space:** ABS_MT_POSITION_X 0..32767 (long axis of the bar,
left→right), ABS_MT_POSITION_Y 0..127 (short axis, the bar is 1 pixel
"tall" in touch Y — a thin strip). ABS_MT_SLOT 0..10 (up to 11
simultaneous contacts). ABS_MT_TRACKING_ID 0..65535. ABS_MT_DISTANCE
0..1. BTN_TOUCH + BTN_TOOL_FINGER/DOUBLETAP/TRIPLETAP/QUADTAP/QUINTTAP.

**Gestures (one file each):**

| file | gesture | label | notes |
|------|---------|-------|-------|
| `single-tap.evdev` | single tap | `single-tap` | one brief contact on the F-row (Esc area); oracle reacted (Esc highlight) |
| `double-tap.evdev` | double tap | `double-tap` | two quick taps in succession on the same area |
| `long-press.evdev` | long press | `long-press` | sustained contact (~2s) without movement |
| `slow-drag.evdev` | slow drag | `slow-drag` | contact + slow lateral movement along the bar |
| `fast-swipe.evdev` | fast swipe | `fast-swipe` | quick lateral swipe along the bar |
| `two-finger-simultaneous.evdev` | two-finger simultaneous | `two-finger-simultaneous` | two fingers down at the same time |
| `two-finger-sequential.evdev` | two-finger sequential | `two-finger-sequential` | one finger down, lift, then a second finger down |
| `edge-touch.evdev` | edge touch | `edge-touch` | touch at the far left or right edge of the bar |
| `palm-broad-touch.evdev` | palm-ish broad touch | `palm-broad-touch` | broad/multi-point contact (palm or multiple fingers spread) |
| `idle-10s.evdev` | 10s idle | `idle-10s` | no contact for 10s (baseline / noise floor) |

**Coexistence proof (verbatim human checkpoint):**
- Gesture 1 (single tap): "Done (oracle reacted)" — the oracle's F-row
  UI reacted to the tap WHILE evtest was recording. This confirms
  non-exclusive read: evtest does NOT EVIOCGRAB by default, and the
  oracle's input path is undisturbed. A future field-debug reader
  alongside tbard can read the same node without disturbing the
  production input consumer.

**Caveats:**
- The first single-tap recording attempt used `timeout 10 evtest` which
  produced only the evtest header (no event lines) — likely a SIGTERM
  flush issue. The re-record used `stdbuf -oL -eL` + graceful SIGINT and
  captured the events. See each file's header for the actual event count.
- Each file begins with the evtest capability header (the "Event type"
  listing is the device's supported events, NOT captured events). The
  actual captured events are the lines with a leading timestamp like
  `1234.567890` — wait, evtest's format is `Event: time  TYPE...`. The
  real event lines are those beginning with `Event: time ...`.