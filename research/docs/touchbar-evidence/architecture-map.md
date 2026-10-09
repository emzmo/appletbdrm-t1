# Touch Bar Architecture — macOS vs Linux
# Research document for the touchbar-evidence project
# Date: 2026-08-25
# Machine: MacBookPro14,2 (T1), macOS 13.7.8 (22H730)

## 1. Executive Summary

The Apple T1 Touch Bar is a **dumb USB-attached OLED display**. It receives raw
BGR888 pixel rectangles from the host over USB interface 3. All UI rendering
(icons, text, sliders, color pickers, tabs, images) happens on the host CPU.

- macOS: TouchBarServer renders with CoreAnimation, ships pixels via USB
- Linux: appletbdrm (DRM driver) + tiny-dfr (cairo renderer) do the same

The display substrate is at parity between macOS and Linux. The gap is in the
**intelligence layer** — what decides what to show, and the widget vocabulary
available to render.

---

## 2. Architecture Map — macOS

```
┌─────────────────────────────────────────────────────────────────┐
│                        macOS HOST (x86 CPU)                     │
│                                                                 │
│  ┌──────────────┐   ┌──────────────┐   ┌────────────────────┐  │
│  │  Your App    │   │  Finder,     │   │  System Settings   │  │
│  │  (Safari,    │   │  Terminal,   │   │  / ControlStrip    │  │
│  │  Mail, etc.) │   │  Mail, etc.  │   │  .app              │  │
│  └──────┬───────┘   └──────┬───────┘   └─────────┬──────────┘  │
│         │                  │                     │              │
│         │ NSTouchBar       │ NSTouchBar          │              │
│         │ provider         │ provider            │              │
│         v                  v                     v              │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              RESPONDER CHAIN (AppKit)                   │   │
│  │                                                         │   │
│  │  Frontmost app's NSTouchBar delegate is asked for:      │   │
│  │    - defaultItemIdentifiers                            │   │
│  │    - principalItemIdentifier                           │   │
│  │    - escapeKeyReplacementItemIdentifier                 │   │
│  │  Items are instantiated (10 NSTouchBarItem subclasses)  │   │
│  │  ┌──────────────────────────────────────────────────┐   │   │
│  │  │ WIDGET VOCABULARY (AppKit, system-provided):     │   │   │
│  │  │  - NSButtonTouchBarItem      (buttons)           │   │   │
│  │  │  - NSSliderTouchBarItem      (sliders)           │   │   │
│  │  │  - NSColorPickerTouchBarItem (color pickers)     │   │   │
│  │  │  - NSPickerTouchBarItem      (tabs/pickers)      │   │   │
│  │  │  - NSPopoverTouchBarItem     (popovers)          │   │   │
│  │  │  - NSGroupTouchBarItem       (groups/tabs)       │   │   │
│  │  │  - NSStepperTouchBarItem     (steppers)          │   │   │
│  │  │  - NSScrubber                (horizontal picker) │   │   │
│  │  │  - NSCandidateListTouchBarItem (predictive text) │   │   │
│  │  │  - NSSharingServicePickerTouchBarItem (share)    │   │   │
│  │  │  - NSCustomTouchBarItem      (any NSView)        │   │   │
│  │  └──────────────────────────────────────────────────┘   │   │
│  │  Icons/assets from: DFRFoundation.framework,            │   │
│  │    /System/Library/PrivateFrameworks/, ~60+ template     │   │
│  │    images (touchBarPlayTemplate, touchBarVolumeUp, etc.) │   │
│  └────────────────────────┬────────────────────────────────┘   │
│                           │                                     │
│                           │ CoreAnimation renders to framebuffer│
│                           v                                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │          TouchBarServer (pid 313, /usr/libexec/)        │   │
│  │                                                         │   │
│  │  Owns USB interface 3 (entitlement: com.apple.appledfr  │   │
│  │  .client). Calls DFRDisplayDrawRectsRequest to send     │   │
│  │  dirty rectangles of BGR888 pixels via USB bulk OUT.    │   │
│  │  Receives DFRDisplayUsbRecvComplete ACKs via bulk IN.   │   │
│  └────────────────────────┬────────────────────────────────┘   │
│                           │                                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │          ControlStrip (pid 468, CoreServices/.app)      │   │
│  │                                                         │   │
│  │  High-level agent: decides WHAT to show. Reads          │   │
│  │  PresentationModeGlobal from com.apple.touchbar.agent   │   │
│  │  defaults. Restarted via:                                │   │
│  │    launchctl kickstart -k gui/501/com.apple.controlstrip │   │
│  └─────────────────────────────────────────────────────────┘   │
│                           │                                     │
└───────────────────────────┼─────────────────────────────────────┘
                            │
                            │ USB interface 3 (class 0x10)
                            │ bulk OUT: pixel rectangles (BGR888)
                            │ bulk IN: completion ACKs
                            v
┌─────────────────────────────────────────────────────────────────┐
│                    T1 CONTROLLER (05ac:8600)                    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  EmbeddedOS (from combined.memboot, ~30.6 MB)           │   │
│  │                                                         │   │
│  │  Runs a full iOS-derived OS (kernel + ramdisk +         │   │
│  │  devicetree + SEP firmware).                            │   │
│  │                                                         │   │
│  │  Display role: USB display SERVER on interface 3.       │   │
│  │  Receives bulk pixel rectangles → blits to OLED panel.  │   │
│  │                                                         │   │
│  │  Does NOT contain: icons, glyphs, UI assets, fonts.     │   │
│  │  All content is rendered on the host.                   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  OLED PANEL (2170×60 px, BGR888)                        │   │
│  │  ~50-60 Hz refresh during activity, idle ~22 Hz         │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. Architecture Map — Linux (current state)

```
┌─────────────────────────────────────────────────────────────────┐
│                        Linux HOST (x86 CPU)                     │
│                                                                 │
│  ┌──────────────┐   ┌──────────────┐   ┌────────────────────┐  │
│  │  Hyprland /  │   │  Terminal,   │   │  No per-app        │  │
│  │  Sway        │   │  Firefox,    │   │  Touch Bar         │  │
│  │  (compositor)│   │  etc.        │   │  integration       │  │
│  └──────┬───────┘   └──────────────┘   └────────────────────┘  │
│         │                       │                     │          │
│         │ No Wayland protocol   │                     │          │
│         │ for Touch Bar items   │                     │          │
│         v                       v                     v          │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  NO RESPONDER CHAIN EQUIVALENT                          │   │
│  │                                                         │   │
│  │  There is no Wayland protocol for Touch Bar items.      │   │
│  │  GitHub search for "touch bar" wayland protocol: 0.     │   │
│  │  Hyprland/Sway have no Touch Bar integration.          │   │
│  │  No IPC bridge to compositor focus events.              │   │
│  │                                                         │   │
│  │  GAP: This is the biggest missing piece.                │   │
│  └─────────────────────────────────────────────────────────┘   │
│                           │                                     │
│                           │ (no per-app context flows down)     │
│                           v                                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  tiny-dfr (userspace daemon, AsahiLinux)                │   │
│  │                                                         │   │
│  │  Reads /etc/tiny-dfr/config.toml (STATIC config)        │   │
│  │  Renders with cairo + librsvg + freetype                │   │
│  │                                                         │   │
│  │  WIDGET VOCABULARY (current):                           │   │
│  │  ┌──────────────────────────────────────────────────┐   │   │
│  │  │  - Text labels (F1, F2, etc.)                    │   │   │
│  │  │  - SVG icons (via librsvg)                       │   │   │
│  │  │  - PNG bitmaps (via cairo)                       │   │   │
│  │  │  - Live clock (chrono)                           │   │   │
│  │  │  - Battery indicator (from /sys/class/power)     │   │   │
│  │  │  - Spacer                                        │   │   │
│  │  └──────────────────────────────────────────────────┘   │   │
│  │  MISSING: sliders, color pickers, tabs, popovers,      │   │
│  │    steppers, scrubbers, per-app items, dynamic images  │   │
│  │                                                         │   │
│  │  Two static layers: PrimaryLayer (F-keys) +            │   │
│  │    MediaLayer (media keys), swapped on double-FN       │   │
│  │                                                         │   │
│  │  Touch input: libinput on seat-touchbar                │   │
│  │  Output: uinput keyboard events (key combos)           │   │
│  └────────────────────────┬────────────────────────────────┘   │
│                           │                                     │
│                           │ cairo renders to DRM dumb buffer    │
│                           │ drm.dirty(&clips) pushes rects      │
│                           v                                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  appletbdrm (kernel DRM driver, Linux 6.15+)            │   │
│  │                                                         │   │
│  │  For T1: needs moerdowo/appletbdrm-t1 patch             │   │
│  │    (adds PID 0x8600, handles T1's 16-byte echo bug)     │   │
│  │                                                         │   │
│  │  Registers as /dev/dri/cardN (DRM device)               │   │
│  │  Connector type: DRM_MODE_CONNECTOR_USB                 │   │
│  │  Pixel format: DRM_FORMAT_BGR888 (24-bit)               │   │
│  │  XRGB8888 emulated via drm_fb_xrgb8888_to_bgr888        │   │
│  │                                                         │   │
│  │  USB protocol (interface 3, class 0x10, 2 bulk EPs):    │   │
│  │  ┌──────────────────────────────────────────────────┐   │   │
│  │  │  Opcodes (4-char codes):                         │   │   │
│  │  │    CLRD = clear display                          │   │   │
│  │  │    GINF = get info (width/height/bpp/format)     │   │   │
│  │  │    REDY = signal readiness                       │   │   │
│  │  │    UDCL = update complete (T1) / UPDC (T2)       │   │   │
│  │  │                                                  │   │   │
│  │  │  Framebuffer update:                              │   │   │
│  │  │    struct appletbdrm_frame {                     │   │   │
│  │  │      begin_x, begin_y, width, height,            │   │   │
│  │  │      buf_size, u8 buf[]  // raw BGR888 pixels    │   │   │
│  │  │    }                                              │   │   │
│  │  │    + footer with magic: 0xfffe, 0x80001,         │   │   │
│  │  │      0x80002, 0xffff, 64-bit timestamp           │   │   │
│  │  └──────────────────────────────────────────────────┘   │   │
│  │                                                         │   │
│  │  Uses drm_atomic_helper_damage_iter for dirty rects    │   │
│  │  Same wire protocol as macOS TouchBarServer            │   │
│  └────────────────────────┬────────────────────────────────┘   │
│                           │                                     │
└───────────────────────────┼─────────────────────────────────────┘
                            │
                            │ USB interface 3 (class 0x10)
                            │ bulk OUT: pixel rectangles (BGR888)
                            │ bulk IN: completion ACKs (UDCL)
                            v
┌─────────────────────────────────────────────────────────────────┐
│                    T1 CONTROLLER (05ac:8600)                    │
│                                                                 │
│  Same T1 as macOS — dumb pixel sink. See macOS map for details. │
│  The T1 firmware is identical regardless of host OS.            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. USB Interface Map — T1 Controller (05ac:8600)

Confirmed from ioreg on macOS 13.7.8 (see 9.1.7-usb-interfaces-macos.txt):

```
Apple T1 Controller (idVendor=0x05ac, idProduct=0x8600)
  Config 2 (active), 3 configs total, USB High Speed (480 Mb/s)
  USB Address: 4, locationID: 0x14100000

  Interface 0: Video (class 0x0e, subclass 1)     — FaceTime HD Camera
    bNumEndpoints: 0 (uses isochronous on alt setting)
    Owner: VDCAssistant (pid 234)

  Interface 1: Video (class 0x0e, subclass 2)     — FaceTime HD Camera (isoc)
    bNumEndpoints: 1
    Owner: VDCAssistant (pid 234)

  Interface 2: HID (class 0x03)                   — Touch Bar digitizer/touch
    bNumEndpoints: 1
    Owner: AppleUserUSBHostHIDDevice
    PrimaryUsage: Digitizer (0x0d), Touch Pad (0x05)
    MaxInputReportSize: 52 bytes

  Interface 3: Application Spec (class 0x10)      — DFR DISPLAY (appletbdrm)
    bNumEndpoints: 2 (bulk IN + bulk OUT)
    Owner: TouchBarServer (pid 313)
    Entitlement: com.apple.appledfr.client
    Protocol: raw BGR888 pixel rectangles (see above)

  Interface 4: CDC (class 0x02, subclass 0x0d)    — NCM Control (iBridge ethernet)
    bNumEndpoints: 0
    Owner: AppleUSBNCMControl
    USB Interface Name: "NCM Control"

  Interface 5: CDC-Data (class 0x0a)              — NCM Data (iBridge ethernet)
    bNumEndpoints: 2
    Owner: AppleUSBNCMData
    USB Interface Name: "NCM Data"
    BSD interface: en5

  Interface 6: HID (class 0x03)                   — ALS + other sensors
    bNumEndpoints: 1
    Owner: AppleUserUSBHostHIDDevice
    PrimaryUsage: Sensor (0x20), Ambient Light (0x41)
    MaxInputReportSize: 10, MaxFeatureReportSize: 116
    Child: AppleUSBALSService

  Interface 7: Vendor (class 0xff, subclass 0xf9, protocol 0x11) — SEP / Touch ID
    bNumEndpoints: 2 (bulk IN + bulk OUT)
    Owner: KernelRelayHost (com.apple.driver.KernelRelayHost)
    USB Interface Name: "Apple USB SEP Interface"
    [CONFIRMED] = Touch ID / SEP control channel
```

---

## 5. Display Protocol Detail (interface 3)

The wire protocol between host and T1 for display updates, confirmed from
both the Linux appletbdrm driver source and the macOS DFRDisplay probes:

### Message types (4-char opcodes)
| Opcode | Hex | Direction | Purpose |
|--------|-----|-----------|---------|
| `CLRD` | 0x434c5244 | OUT | Clear display |
| `GINF` | 0x47494e46 | OUT→IN | Get info (returns width/height/bpp/format/orientation) |
| `REDY` | 0x52454459 | OUT | Signal readiness |
| `UDCL` | 0x5544434c | IN | Update complete (T1 ACK after pixel transfer) |
| `UPDC` | 0x55504443 | IN | Update complete (T2 variant — same meaning) |

### Framebuffer update structure
```
Request header:
  unk_00, unk_02, unk_04, unk_08    (magic constants — see 9.2.3)

Frame records (array):
  struct appletbdrm_frame {
    le16 begin_x;       // rectangle start X
    le16 begin_y;       // rectangle start Y
    le16 width;         // rectangle width
    le16 height;        // rectangle height
    le32 buf_size;      // pixel buffer size
    u8  buf[];          // raw BGR888 pixels (width * height * 3)
  }

Footer:
  unk_00[12], unk_0c, unk_10[12], unk_1c,
  unk_28[12], unk_34, unk_38[20], unk_4c
  Magic: 0xfffe, 0x80001, 0x80002, 0xffff
  64-bit timestamp
```

### T1-specific quirk (appletbdrm-t1 patch)
The T1 echoes a 16-byte copy of the request header on the IN endpoint before
the real response. The T2 does not. Without the patch, the stream gets one
message behind forever, capping the panel at ~3 fps with 1-second stalls.
The three-line fix (skip too-short messages, drain one stale frame at probe,
add 0x8600 to the ID table) brings it to ~19 fps sustained at 20 Hz requested.

### Refresh rate (from DTrace capture)
- Active (app switching): ~18ms inter-draw_req interval (~55 Hz)
- Idle: ~45ms median (~22 Hz), with periodic bursts
- Batching: avg 1.5-3.0 draw_comp per draw_req (multiple ACKs per update)

---

## 6. Rendering Pipeline Comparison

```
macOS rendering pipeline:
  App → NSTouchBar delegate → responder chain → ControlStrip agent
    → TouchBarServer (CoreAnimation render)
    → DFRDisplayDrawRectsRequest (dirty rects)
    → USB bulk OUT (BGR888 pixels)
    → T1 → OLED

Linux rendering pipeline (current):
  /etc/tiny-dfr/config.toml (static)
    → tiny-dfr (cairo + librsvg render)
    → drm.dirty(&clips) (dirty rects)
    → appletbdrm kernel driver
    → USB bulk OUT (BGR888 pixels, same protocol)
    → T1 → OLED

Linux rendering pipeline (proposed for rich UI):
  Compositor (Hyprland/Sway) → IPC/protocol
    → Touch Bar daemon (per-app context + rich widgets)
      → cairo render (sliders, pickers, tabs, images)
      → drm.dirty(&clips)
      → appletbdrm
      → USB bulk OUT (same protocol — unchanged)
      → T1 → OLED
```

The key insight: **the USB protocol and T1 firmware are the same in all three
pipelines.** The difference is entirely in what happens on the host before
pixels reach the USB bus. The display substrate (appletbdrm + T1) is a dumb
pipe that will display anything you render.