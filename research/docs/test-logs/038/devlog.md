# Devlog — session 038 (hardware-interaction research, 2026-09-26)

**Role:** hardware interaction researcher. **Goal:** establish direct,
unmediated ground truth about the MacBookPro14,2 Touch Bar (T1) input and
backlight surfaces — independent of the tbard engine's abstractions. The
engine's bugs will later be validated AGAINST what is written here.

**Safety bound honored:**
- The ONLY system writes permitted: brightness values to
  `/sys/class/backlight/appletb_backlight/brightness`, within [1..max],
  ALWAYS restored to the pre-session value (54) at the end. NEVER 0.
- Oracle (`tiny-dfr-mbp142.service`) stayed RUNNING and lit the entire
  session. No interlock, no service lifecycle actions, no /etc writes.
- tbard remained disabled+inactive throughout (FREEZE on src/).
- Human checkpoints for observations: asked, waited, recorded verbatim.

**Pre-session reference value:** 54 (per the task brief and session-037).

## Live state at session start (21:24:33 +01:00)

- Oracle: `tiny-dfr-mbp142.service` active (running) since 21:00:55,
  Main PID 241900, static unit.
- tbard: disabled + inactive (confirmed).
- `/sys/class/backlight/appletb_backlight`: brightness=54, max=255,
  bl_power=0, type=raw, mtime=2026-09-26 21:24:15.939835979.
- appletbdrm DRM card: `/dev/dri/card2` (driver-resolved name:
  appletbdrm; by-path `pci-0000:00:14.0-usb-0:3:2.3-card`).
- Digitizer: `/dev/input/event7` (`/sys/class/input/input9`,
  "Apple Inc. iBridge Touchpad", phys `usb-0000:00:14.0-3/input2`,
  USB 05ac:8600, hid-multitouch, hidraw0).
- iBridge active USB config: **2** (8 interfaces; DRM-mode layout).

## Headline findings (data, not instructions)

1. **NEW: sysfs `brightness` does NOT track panel luminance while a DRM
   master is scanning out.** At 21:24:33 sysfs read 54; by 21:24:50 it
   read 1; by 21:25:13 it read 0 — all WITHOUT any userspace write (mtime
   frozen at 21:24:15). The human reported the F-row STILL LIT at the
   same moment sysfs read 0. This is a NEW ground-truth finding beyond
   session-037: the backlight sysfs knob is DECOUPLED from the panel-
   enable / scanout path on this T1 fork (appletbdrm owns both the DRM
   card AND the `appletb_backlight` sysfs on interface 1-3:2.3).
   Re-confirms the session-037 mtime quirk (mtime reflects userspace
   writes only; kernel-internal changes do not move it).
2. **T1 architecture differs from prior-art.md's T2 framing:** on this
   T1 fork, `appletb_backlight` is owned by `appletbdrm` (USB interface
   1-3:2.3), NOT by `hid-appletb-bl`. No `hid-appletb-bl` binding exists
   (`/sys/bus/hid/drivers/hid-appletb-bl` absent). No IIO/ALS surfaced
   (`hid-sensor-hub` loaded, zero devices bound). The digitizer is
   `hid-multitouch` on interface 1-3:2.2 (hidraw0).
3. **DRM mode 60×2170, panel orientation "Right Side Up" (value 3).**
   modetest -M appletbdrm (driver-resolved) confirms connector USB-1
   connected, mode 60×2170 @60Hz, fb 41 on crtc-0 at 60×2170, plane-0
   supports BG24/XR24 LINEAR. The 64×2170 fb observed in session-037's
   debugfs is NOT visible in modetest's "Frame buffers" section here
   (modetest may not list already-allocated fbs the way debugfs does);
   the 64-vs-60 question is carried forward to display-open-questions.md.
4. **Digitizer evdev caps (full):** see evtest-event7-caps.txt. ABS_X
   0..32767, ABS_Y 0..127, ABS_MT_SLOT 0..10 (11 slots), ABS_MT_POSITION_X
   0..32767, ABS_MT_POSITION_Y 0..127, ABS_MT_TRACKING_ID 0..65535,
   ABS_MT_DISTANCE 0..1. BTN_TOUCH + BTN_TOOL_FINGER/DOUBLETAP/TRIPLETAP/
   QUADTAP/QUINTTAP. Properties: INPUT_PROP_POINTER + INPUT_PROP_DIRECT.
   No pressure/major/minor axes. No resolution units (no `abs/` subdir).

## T2 — backlight knob (controlled writes, oracle running)

Precondition: fallback-Esc confirmed by human ("Yes, fallback Esc
works"). The brief's 54→100→200→54 protocol was run, then the human
requested a restart from a lower baseline (50→100→200), then 54
restore, then the downward sweep (32, 16, 8, 4, 2, 1), then restore
54. Every write landed (value + mtime confirmed); every read-back
survived.

**Upward (per human request, from 50 baseline):**
- 50 (baseline): "Dim but visible"
- 100: "Clearly brighter than 50"
- 200: "Clearly brighter than 100"

**Restore reference:**
- 54: "Dim (like 50)"

**Downward sweep:**
- 32: "Visible (dimmer than 54)"
- 16: "Visible (dimmer than 32)"
- 8: "Visible (dimmer than 16)"
- 4: "Visible (dimmer than 8)"
- 2: "Visible (dimmer than 4)"
- 1 (floor): "Visible (dimmer than 2)"
- 54 (final restore): "Back to dim reference (like 54)"

**Minimum visible brightness = 1** (the floor of [1..255]; 0 was
NEVER written per the safety bound). The perceptual curve is
**smooth/monotonic, not stepped** — every step was reported as a
proportional dim/brighten.

**Oracle independence (the brief's proof):** throughout the entire
sweep the oracle's rendered F-row content stayed UNCHANGED — only
luminance moved. Human checkpoint verbatim: "Content unchanged;
only brightness moved." This proves the knob is independent of the
DRM master and of the renderer.

**Captures:** `t2-step1-write100.txt`, `t2-step2-write200.txt`,
`t2-restart-write50.txt`, `t2-restart-write100.txt`,
`t2-restart-write200.txt`, `t2-write54.txt`, `t2-sweep-{32,16,8,4,2,1}.txt`,
`t2-restore54.txt`.

## T3 — input corpus (zero-risk, oracle running)

**Corpus directory:** `docs/research/corpus/`
**Labels:** `docs/research/corpus/labels.md`
**Analysis:** `docs/research/corpus/corpus-analysis.txt`

10 labeled gestures captured with `evtest /dev/input/event7` (NO
`--grab` — non-exclusive read), 10s window per gesture, oracle
active and reacting throughout. The first recording attempt used
`timeout` which failed to flush evtest on signal (0 events); a
second attempt with `stdbuf` left stray evtest processes that
contaminated the files. The FINAL clean approach (`evtest &` +
`pgrep -n evtest` + `sudo kill -INT $EVPID` + `pkill -KILL`
sweeps) produced clean per-gesture files.

**Clean corpus (event counts):**

| file | gesture | events |
|------|---------|--------|
| `single-tap.evdev` | single tap | 10 |
| `double-tap.evdev` | double tap | 21 |
| `long-press.evdev` | long press | 10 |
| `slow-drag.evdev` | slow drag | 473 |
| `fast-swipe.evdev` | fast swipe | 77 |
| `two-finger-simultaneous.evdev` | two-finger simultaneous | 21 |
| `two-finger-sequential.evdev` | two-finger sequential | 22 |
| `edge-touch.evdev` | edge touch (right edge) | 18 |
| `palm-broad-touch.evdev` | palm-ish broad touch | 50 |
| `idle-10s.evdev` | 10s idle baseline | 0 |

**Coexistence proof (verbatim human checkpoint):** "Yes —
coexistence confirmed" — the oracle's F-row UI stayed visible AND
reacted to touches the entire time evtest was recording. This
legitimizes a future field-debug reader alongside tbard (non-
exclusive read, no EVIOCGRAB).

**Key protocol findings (from corpus):** Y is NEVER emitted
(the bar is a 1px-tall touch strip); tracking IDs are monotonic
(79→94 across the session), -1 = lift; slots are NOT stable
across gestures (key on TRACKING_ID, not slot); BTN_TOOL_FINGER
is the working contact-class indicator (DOUBLETAP/TRIPLETAP/etc.
are unreliable for contact counting); ABS_MT_DISTANCE is almost
always 0 (appeared once in edge-touch); idle noise floor is ZERO.

## T4 — the manual (the deliverable)

- `docs/research/touchbar-interaction-manual/README.md`
- `docs/research/touchbar-interaction-manual/backlight.md`
- `docs/research/touchbar-interaction-manual/input.md`
- `docs/research/touchbar-interaction-manual/display-open-questions.md`

## Final session state (21:59:43 +01:00)

- brightness: 54/255 (restored; read-back confirmed; mtime moved
  to 21:59:43 on the final restore write). Note: brightness had
  auto-dimmed back to 0 (kernel-side, mtime frozen at 21:37:09)
  during T3/T4 — the decoupled regime re-occurred. A final write
  of 54 restored it. This is the SECOND occurrence of the
  autonomous-dim finding (the first was HC0 at session start).
- bl_power: 0 (unchanged; never written).
- oracle: active (static) — `tiny-dfr-mbp142.service`, sole DRM
  master on card2 throughout.
- tbard: disabled + inactive (FREEZE intact, no `src/` writes).
- digitizer: /dev/input/event7 (input9) untouched (no --grab used).
- All evtest processes killed (verified `pgrep evtest` empty).
- NO /etc writes. NO service lifecycle actions on the oracle.
- The ONLY system writes this session: brightness values to
  `/sys/class/backlight/appletb_backlight/brightness`, within
  [1..255], restored to 54. NEVER 0.

## Captures (this session, all read-only unless noted)

- `backlight-sysfs.txt` — full attribute set + stat + power/ + driver link
- `drm-sysfs.txt` — /dev/dri, by-path, driver-resolved card resolution
- `drm-connector.txt` — card2-USB-1 sysfs + modetest -M appletbdrm dump
- `input-discovery.txt` — /dev/input, by-path, /proc/bus/input/devices
- `evtest-event7-caps.txt` — full evdev capability dump of the digitizer
- `lsusb-verbose.txt` — lsusb -v 05ac:8600 + lsusb -t
- `ibridge-bindings.txt` — active config 2 + interface→driver map
- `hc0-autonomous-dim.txt` — the autonomous-dim finding + human checkpoint
- `brightness-watch.txt` — 5s value/mtime watch proving kernel-side dim
- `t2-*.txt` (12 files) — the controlled brightness-write sweep
- `session-end-restore.txt` — final state verification

## Inventory diffs vs prior captures

| topic | Stage 0 (s000) | s000b/b2 | s010-bench | s037 | **s038 (this)** |
|-------|----------------|----------|------------|------|-----------------|
| backlight sysfs attrs | max=255, cur=26, no full set | — | — | value=0, max=255, mtime frozen | **full set: actual_brightness, bl_power, brightness, max_brightness, scale=unknown, type=raw; device→1-3:2.3; driver=appletbdrm** |
| backlight mtime quirk | not observed | — | — | **discovered** (mtime not moved by appletbdrm writes) | **re-confirmed + extended: kernel-side value changes 54→1→0 do NOT move mtime; sysfs value decoupled from panel luminance** |
| DRM card | card0 (appletbdrm) | — | — | dev 2, card2 (tbard master) | **card2, driver-resolved appletbdrm, by-path pci-0000:00:14.0-usb-0:3:2.3-card** |
| DRM mode | 60×2170 (s000 env.log) | — | — | 60×2170 (debugfs), fb 64×2170 | **modetest: 60×2170 @60Hz, fb 41 on crtc-0 60×2170, plane BG24/XR24 LINEAR, panel orientation Right Side Up** |
| digitizer node | input13/event4 (s000, wrong-by-seat) | — | — | event7 (preflight ACCEPT) | **event7 / input9, hid-multitouch, hidraw0, phys usb-0000:00:14.0-3/input2** |
| evdev caps | sysfs bitmap only (no evtest binary) | — | — | not captured | **full evtest dump: ABS_X/Y, ABS_MT_SLOT 0..10, POSITION_X/Y, TRACKING_ID, DISTANCE; BTN_TOUCH+TOOL_*; no pressure/major/minor** |
| iBridge USB | lsusb summary (s000) | — | — | not captured | **lsusb -v full descriptor + active config 2 + interface→driver map (8 ifaces: uvc, uvc, usbhid→digitizer, appletbdrm→DRM+backlight, CDC, CDC-data×2, appletbdrm, vendor-ff/f9)** |
| ALS | not surfaced | — | — | not captured | **NOT surfaced on T1 fork (hid-sensor-hub loaded, zero bindings; no IIO devices)** |
| backlight driver | assumed hid-appletb-bl (T2 framing) | — | — | not examined | **appletbdrm (interface 1-3:2.3), NOT hid-appletb-bl** |