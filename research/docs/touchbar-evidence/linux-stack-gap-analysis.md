# Linux Touch Bar Stack — Current State and Gap Analysis
# Research document for the touchbar-evidence project
# Date: 2026-08-25

## 1. Current Linux Touch Bar Stack (3 components)

### 1.1 appletbdrm — kernel DRM driver (display substrate)

- Repo: in-tree at drivers/gpu/drm/tiny/appletbdrm.c (Linux 6.15+)
  - Author: Kerem Karabay (kekrby@gmail.com)
  - Merged via LKML patch series (lwn.net/Articles/1011636/)
- T1 fork: github.com/moerdowo/appletbdrm-t1 (DKMS package)
  - Also: github.com/Surinder005/appletbdrm-t1
  - Adds PID 0x8600 (T1) support + fixes 16-byte echo bug

What it is:
  - Standard Linux DRM (Direct Rendering Manager) driver
  - DRIVER_MODESET | DRIVER_GEM | DRIVER_ATOMIC
  - Exposes Touch Bar as /dev/dri/cardN
  - Connector: DRM_MODE_CONNECTOR_USB, non_desktop
  - Panel orientation: RIGHT_UP
  - Pixel format: DRM_FORMAT_BGR888 (24-bit)
  - XRGB8888 emulated via drm_fb_xrgb8888_to_bgr888

USB protocol (interface 3, class 0x10, 2 bulk endpoints):
  - Opcodes: CLRD (clear), GINF (get info), REDY (ready), UDCL/UPDC (ack)
  - Framebuffer: struct appletbdrm_frame { begin_x, begin_y, width, height,
    buf_size, u8 buf[] } — raw BGR888 pixels per damage rectangle
  - Footer: magic 0xfffe, 0x80001, 0x80002, 0xffff, 64-bit timestamp
  - Uses drm_atomic_helper_damage_iter for dirty-rect tracking
  - SAME wire protocol as macOS TouchBarServer

T1-specific quirk (the appletbdrm-t1 patch):
  - T1 echoes a 16-byte copy of the request header on IN endpoint before
    the real response; T2 does not
  - Without patch: ~3 fps with 1-second stalls (stream gets one message behind)
  - With patch: ~19 fps sustained at 20 Hz requested
  - Patch: skip too-short messages, drain one stale frame at probe,
    add 0x8600 to ID table

### 1.2 apple-ib-drv — older HID-mode driver (alternative path)

- Repo: github.com/t2linux/apple-ib-drv (branch mbp15)
  - Forked from roadrunner2/macbook12-spi-driver
  - Three modules: apple-ibridge, apple-ib-tb, apple-ib-als

What it is:
  - HID driver, NOT a DRM/framebuffer driver
  - Only supports 3 predefined layouts: escape-only, esc+special keys,
    esc+function keys
  - Explicitly notes: "MacOS supports a fancy mode where arbitrary buttons
    can be defined; this driver currently only supports the simple mode"
  - Mode switching via HID feature reports (HID_USAGE_MODE, HID_USAGE_DISP)
  - On T1: mode-set sent as vendor USB control message (not standard HID)
  - Scope: idle/dim timeouts, FN-mode switching, sysfs attributes
  - No arbitrary UI, no custom rendering

Relevance: the LESS capable alternative. Use appletbdrm + tiny-dfr instead
if you want custom rendering. apple-ib-drv is only useful if you don't need
anything beyond the 3 hardcoded layouts.

### 1.3 tiny-dfr — userspace renderer (the "what to show" layer)

- Repo: github.com/AsahiLinux/tiny-dfr (upstream, active, 117 stars)
  - Fork: github.com/AdityaGarg8/tiny-dfr (archived, branch app5)
- Dependencies: cairo, libinput, freetype, fontconfig, librsvg >=2.59, uinput

Architecture:
  - Opens appletbdrm DRM card directly (DrmBackend::open_card)
  - Allocates cairo ImageSurface matching the dumb framebuffer
  - Renders into it with cairo + librsvg
  - memcpy surface into DRM mmap
  - Calls drm.dirty(&clips) to push dirty rects to T1
  - Touch input: libinput on seat-touchbar
  - Output: uinput keyboard events (key combos)

Source files (6 total):
  main.rs, display.rs, backlight.rs, config.rs, fonts.rs, pixel_shift.rs

Current widget vocabulary (from config.toml):
  ButtonImage enum:
  - Text — a text label (e.g. "F1")
  - Svg — an SVG icon loaded via librsvg (from /etc/tiny-dfr/,
    /usr/share/tiny-dfr/, or XDG icon themes)
  - Bitmap — a PNG loaded and resampled via cairo
  - Time — a live clock with chrono strftime format + locale
  - Battery — battery percentage and/or icon, polled from
    /sys/class/power_supply, with color states (green=charging, red=low)
  - Spacer — empty slot

  Button properties:
  - Stretch field (sizing)
  - Action: single Key or key combo (e.g. ["LeftCtrl","LeftAlt","F1"])

  Layers:
  - PrimaryLayer (F-keys)
  - MediaLayer (media keys)
  - Swappable via configurable double-FN-press timeout
  - Pixel-shift (anti-burn-in) supported

What tiny-dfr CANNOT render (missing vs macOS):
  - Sliders (no NSSliderTouchBarItem equivalent)
  - Color pickers (no NSColorPickerTouchBarItem equivalent)
  - Tabs/segmented controls (no NSPickerTouchBarItem equivalent)
  - Popovers (no NSPopoverTouchBarItem equivalent)
  - Steppers (no NSStepperTouchBarItem equivalent)
  - Scrubbers (no NSScrubber equivalent)
  - Candidate lists (no NSCandidateListTouchBarItem equivalent)
  - Sharing pickers (no NSSharingServicePickerTouchBarItem equivalent)
  - Per-app items (no responder chain equivalent)
  - Dynamic/remote images (no HTTP fetch/decode pipeline)
  - Custom drawing/views (no NSCustomTouchBarItem equivalent)

### 1.4 Hyprland/Sway/Wayland integration

Status: NONE EXISTS.

Evidence:
  - GitHub repo search for "touch bar" wayland protocol: 0 results
  - Hyprland issue search for "touchbar"/"touch bar": no relevant hits
  - Local checklist item 9.4.4: "reproducing macOS's responder-chain context
    system on Linux" is an UNRESOLVED design question
  - No Wayland protocol extension for Touch Bar items
  - No compositor integration (Hyprland cannot tell tiny-dfr what window
    is focused, what its app-id is, or what items it wants to publish)
  - tiny-dfr reads a static TOML file; no IPC, no compositor involvement

---

## 2. Gap Analysis — What's Missing for Rich UI

### 2.1 Widget vocabulary gap

macOS has 10 NSTouchBarItem subclasses + NSScrubber + arbitrary NSView.
tiny-dfr has: Text, Svg, Bitmap, Time, Battery, Spacer.

The display SUBSTRATE (appletbdrm DRM) can show anything cairo can draw.
cairo + librsvg can render: sliders, color pickers, tabs, popovers, steppers,
scrubbers, arbitrary custom UI, images from any source. The limitation is
purely in tiny-dfr's render loop — it only knows how to draw discrete buttons
and emit uinput key events on touch.

To close this gap: extend tiny-dfr (or build a new renderer) to:
  - Draw sliders with continuous drag tracking (libinput provides touch-motion)
  - Draw color pickers (hue/saturation surface + drag)
  - Draw tabs/segmented controls (state + re-render)
  - Draw popovers (collapsed → expanded state)
  - Draw scrubbers (horizontal scrolling picker)
  - Handle continuous gestures (pan, press-and-hold) not just taps

This is IMPLEMENTATION WORK, not a substrate limit. cairo can do all of it.

### 2.2 Per-app/per-window context gap (the biggest gap)

macOS: ControlStrip agent watches the responder chain. The frontmost app's
NSTouchBar delegate is asked for items. Apps publish their own items
dynamically. The Touch Bar changes when you switch apps.

Linux: tiny-dfr shows the same static TOML regardless of what's focused.
No compositor integration. No IPC. No per-app context.

To close this gap, three possible approaches:

  Approach A: New Wayland protocol extension
    - Define a new wlr-protocol (e.g. wlr-touchbar-unstable-v1)
    - Compositor (Hyprland/Sway) implements the server side
    - Touch Bar daemon implements the client side
    - Apps publish items via the compositor
    - Pros: clean, standards-aligned, composable
    - Cons: requires compositor patches, app-side adoption, slow ecosystem

  Approach B: Out-of-band IPC (compositor events → daemon)
    - Touch Bar daemon subscribes to Hyprland's hyprctl events
      (or Sway's IPC socket) for window focus changes
    - On focus change, daemon looks up the app's Touch Bar config
      (from a config file or a per-app D-Bus interface)
    - Re-renders on focus change
    - Pros: no compositor patches needed, works today with hyprctl/Sway IPC
    - Cons: no per-app publishing (apps can't dynamically publish items),
      only per-app static configs keyed on app-id

  Approach C: D-Bus per-app publishing
    - Apps (or their toolkits) publish Touch Bar items via D-Bus
    - Touch Bar daemon listens on D-Bus, renders the frontmost app's items
    - Compositor tells the daemon which app is focused (via hyprctl/Sway IPC)
    - Pros: apps can dynamically publish items (like macOS)
    - Cons: requires app/toolkit adoption (GTK/Qt would need integration)

### 2.3 Dynamic image pipeline gap

macOS: apps can send any image (NSImageView, custom drawing).
Linux tiny-dfr: static SVG/PNG files only. No HTTP fetch, no dynamic images.

To close this gap:
  - Add async image fetcher (reqwest + image/librsvg) to the renderer
  - Cache decoded images
  - Render into cairo surface on update
  - The framebuffer side is fine; the image pipeline is greenfield

Example use case: "tabs with website images"
  - Renderer fetches favicon/screenshot for each browser tab
  - Decodes to a cairo surface
  - Renders as a scrubber/picker item
  - Updates when tabs change (via D-Bus from Firefox, or scraping)

---

## 3. Feature Parity Matrix

| Feature | macOS | Linux (current) | Gap size |
|---------|-------|-----------------|----------|
| Raw pixel display | TouchBarServer | appletbdrm | At parity |
| USB protocol | DFRDisplay | appletbdrm | At parity |
| Text buttons | NSTouchBar | tiny-dfr (Text) | At parity |
| SVG/PNG icons | NSTouchBar | tiny-dfr (Svg/Bitmap) | At parity |
| Clock | NSTouchBar | tiny-dfr (Time) | At parity |
| Battery indicator | NSTouchBar | tiny-dfr (Battery) | At parity |
| Sliders | NSSliderTouchBarItem | — | Missing (cairo can draw) |
| Color pickers | NSColorPickerTouchBarItem | — | Missing (cairo can draw) |
| Tabs/pickers | NSPickerTouchBarItem | — | Missing (cairo can draw) |
| Popovers | NSPopoverTouchBarItem | — | Missing (cairo can draw) |
| Steppers | NSStepperTouchBarItem | — | Missing (cairo can draw) |
| Scrubbers | NSScrubber | — | Missing (cairo can draw) |
| Candidate lists | NSCandidateListTouchBarItem | — | Missing |
| Sharing pickers | NSSharingServicePickerTouchBarItem | — | Missing |
| Custom views | NSCustomTouchBarItem | — | Missing (cairo can draw) |
| Per-app context | responder chain | — | Missing (no Wayland protocol) |
| Dynamic images | any NSImage | — | Missing (no fetch pipeline) |
| Gesture recognizers | click/pan/press/magnify | tap only (uinput) | Partial |
| Control Strip | system (always on right) | MediaLayer (static) | Partial |
| Touch ID | LocalAuthentication | — | N/A (SEP-locked) |
| User customization | drag in/out/rearrange | edit config.toml | Different approach |
| Template images | ~60+ system glyphs | freedesktop icon themes | Different approach |

---

## 4. What Does NOT Need Building (already at parity)

- USB protocol to T1 (appletbdrm handles it)
- Raw pixel rendering (cairo → DRM dumb buffer → appletbdrm → T1)
- Basic buttons + icons (tiny-dfr already does this)
- Touch input (libinput on seat-touchbar already works)
- Key event output (uinput already works)
- Backlight control (tiny-dfr handles it)
- Anti-burn-in (tiny-dfr pixel-shift handles it)

---

## 5. What DOES Need Building (the three gaps)

### Gap 1: Rich widget renderer (extend tiny-dfr or build new)
  - Sliders, color pickers, tabs, popovers, steppers, scrubbers
  - Continuous gesture handling (drag, pan, press-and-hold)
  - cairo can render all of these — implementation work, not research
  - Effort: medium (cairo drawing + libinput gesture handling)

### Gap 2: Per-app context protocol (the architectural gap)
  - Option A: Wayland protocol extension (clean, slow adoption)
  - Option B: hyprctl/Sway IPC focus events + per-app configs (works now, limited)
  - Option C: D-Bus per-app publishing (full macOS parity, needs toolkit adoption)
  - Effort: high (architectural decision needed — see brainstorming doc)

### Gap 3: Dynamic image pipeline
  - HTTP fetch + decode + cache + render
  - Effort: low-medium (standard async image pipeline)

---

## Sources

### Linux drivers
- appletbdrm (in-tree): https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/tiny/appletbdrm.c
- appletbdrm-t1 (DKMS): https://github.com/moerdowo/appletbdrm-t1
- appletbdrm-t1 (Surinder005): https://github.com/Surinder005/appletbdrm-t1
- apple-ib-drv: https://github.com/t2linux/apple-ib-drv (branch mbp15)
- LKML patch cover: https://lwn.net/Articles/1011636/

### Userspace renderer
- tiny-dfr (upstream): https://github.com/AsahiLinux/tiny-dfr
- tiny-dfr (AdityaGarg8 fork): https://github.com/AdityaGarg8/tiny-dfr (archived)
- tiny-dfr config template: share/tiny-dfr/config.toml (in repo)

### Compositor integration
- Hyprland: https://github.com/hyprwm/Hyprland (no Touch Bar issues found)
- Sway: https://github.com/swaywm/sway (no Touch Bar integration)
- Wayland protocols: https://gitlab.freedesktop.org/wlroots/wlroots
  (search for "touch bar" → 0 results)

### macOS reference (local evidence)
- 9.1.7-usb-interfaces-macos.txt — interface 3 display endpoint confirmation
- 9.4.1-daemons-summary.txt — TouchBarServer + ControlStrip split
- macOS-capture-checklist.md item 9.4.4 — responder chain gap acknowledged