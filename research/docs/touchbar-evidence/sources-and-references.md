# Sources and References
# Research document for the touchbar-evidence project
# Date: 2026-08-25

## 1. macOS Documentation (Apple developer.apple.com)

Fetched 2026-08-25 via WebFetch (Markdown versions):

- NSTouchBar overview:
  https://developer.apple.com/documentation/appkit/nstouchbar
- NSTouchBarItem reference:
  https://developer.apple.com/documentation/appkit/nstouchbaritem
- NSTouchBarItem.Identifier struct:
  https://developer.apple.com/documentation/appkit/nstouchbaritem/identifier-swift.struct
- NSCustomTouchBarItem:
  https://developer.apple.com/documentation/appkit/nscustomtouchbaritem
- NSButtonTouchBarItem:
  https://developer.apple.com/documentation/appkit/nsbuttontouchbaritem
- NSSliderTouchBarItem:
  https://developer.apple.com/documentation/appkit/nsslidertouchbaritem
- NSColorPickerTouchBarItem:
  https://developer.apple.com/documentation/appkit/nscolorpickertouchbaritem
- NSCandidateListTouchBarItem:
  https://developer.apple.com/documentation/appkit/nscandidatelisttouchbaritem
- NSSharingServicePickerTouchBarItem:
  https://developer.apple.com/documentation/appkit/nssharingservicepickertouchbaritem
- NSPopoverTouchBarItem:
  https://developer.apple.com/documentation/appkit/nspopovertouchbaritem
- NSGroupTouchBarItem:
  https://developer.apple.com/documentation/appkit/nsgrouptouchbaritem
- NSPickerTouchBarItem:
  https://developer.apple.com/documentation/appkit/nspickertouchbaritem
- NSStepperTouchBarItem:
  https://developer.apple.com/documentation/appkit/nssteppertouchbaritem
- NSScrubber:
  https://developer.apple.com/documentation/appkit/nsscrubber

## 2. Apple Support Articles

- Change Touch Bar settings on Mac:
  https://support.apple.com/guide/mac-help/change-touch-bar-settings-mchlc050704e/mac
  (article ID: mchlc050704e)
- Customize the Touch Bar on Mac:
  https://support.apple.com/guide/mac-help/customize-the-touch-bar-mchl5a63b060/mac
- Use the Touch Bar on Mac:
  https://support.apple.com/guide/mac-help/use-the-touch-bar-mchlbfd5b039/mac
- Use the function keys on MacBook Pro with Touch Bar:
  https://support.apple.com/en-us/108316
  (confirms press-and-hold Fn behavior; no timing slider documented)

## 3. Linux Kernel Driver (appletbdrm)

- In-tree source (Linux 6.15+):
  https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/tiny/appletbdrm.c
  Author: Kerem Karabay (kekrby@gmail.com)
  Driver features: DRIVER_MODESET | DRIVER_GEM | DRIVER_ATOMIC
  Connector: DRM_MODE_CONNECTOR_USB
  Pixel format: DRM_FORMAT_BGR888

- T1 fork (DKMS package, adds PID 0x8600):
  https://github.com/moerdowo/appletbdrm-t1
  Key patch: handles T1's 16-byte request-header echo on IN endpoint

- T1 fork (alternative):
  https://github.com/Surinder005/appletbdrm-t1

- LKML patch cover letter:
  https://lwn.net/Articles/1011636/
  Quote: "DRM mode enables the Touch Bar to act as a second display,
  just like macOS"

## 4. Linux HID Driver (apple-ib-drv, alternative path)

- Repository: https://github.com/t2linux/apple-ib-drv (branch mbp15)
  Forked from: roadrunner2/macbook12-spi-driver
  Modules: apple-ibridge, apple-ib-tb, apple-ib-als
  Note: HID driver, NOT framebuffer. Only 3 hardcoded layouts.
  Explicitly states macOS "fancy mode" is not supported.

## 5. Linux Userspace Renderer (tiny-dfr)

- Upstream: https://github.com/AsahiLinux/tiny-dfr
  Active, 117 stars (as of 2026-08-25)
  Dependencies: cairo, libinput, freetype, fontconfig, librsvg >=2.59, uinput
  Source files: main.rs, display.rs, backlight.rs, config.rs, fonts.rs,
    pixel_shift.rs (6 files, Rust)
  Config: /etc/tiny-dfr/config.toml (static TOML)

- Fork (archived): https://github.com/AdityaGarg8/tiny-dfr (branch app5)

## 6. Compositor / Wayland Integration

- Hyprland: https://github.com/hyprwm/Hyprland
  Issue search for "touchbar"/"touch bar": no relevant results
- Sway: https://github.com/swaywm/sway
  No Touch Bar integration
- Wayland protocols registry: https://gitlab.freedesktop.org/wlroots/wlroots
  Search for "touch bar": 0 results
- GitHub-wide search for '"touch bar" wayland protocol': 0 results

## 7. T1 Firmware

- combined.memboot structure (from tigercosmos gist):
  https://gist.github.com/tigercosmos/ecbfe1fc20b7303c1808d3ab74af1f5b
  Format: osrd (OSRamdisk) + krnl (KernelCache) + dtre (DeviceTree) +
    sepi (SEP firmware) — bare concatenation of Image4 objects
  Size: ~30.6 MB (full EmbeddedOS, NOT an asset/icon bundle)
  Build: 14Y901

## 8. Local Evidence Files (this project)

All in ~/touchbar-evidence/:

- macos-version.txt — macOS 13.7.8 (22H730)
- hardware.txt — MacBookPro14,2, i7, 16GB, FW 529.140.2, SMC 2.44f6
- esp-firmware-paths.txt — ESP mount status (needs manual mount)
- 9.1.2-refresh-rate.txt — deferred to Linux usbmon (DTrace option available)
- 9.1.7-usb-interfaces-macos.txt — [CONFIRMED] interface 7 = SEP, full T1 map
- 9.2.3-protocol-headers.txt — deferred (DTrace buffer-capture option available)
- 9.2.5-framebuffer-batching.txt — deferred (DTrace option available)
- 9.3.1-kextstat.txt — [CONFIRMED] kext names (refuted checklist's guesses)
- 9.3.1-kextstat-full.txt — full kextstat output
- 9.3.2-iodt.txt — [CONFIRMED] ASOC/APP7777 device tree
- 9.3.2-iodt-full.txt — full IOPlatformDevice dump
- 9.3.3-ioreg-asoc.txt — ASOC device properties
- 9.3.3-acpi-ioreg.txt — ACPI plane dump
- 9.3.3-socw-log.txt — SOCW log query (no events in window)
- 9.3.4-hid-descriptor.txt — HID report descriptors (partial)
- 9.4.1-daemons-summary.txt — [CONFIRMED] TouchBarServer + ControlStrip
- 9.4.1-ps.txt — process list
- 9.4.1-launchctl.txt — launchd service labels
- 9.4.1-launchd-details.txt — launchd service details
- 9.4.2-fn-timing-notes.txt — FN key defaults + manual observation pending
- 9.4.2-touchbar-defaults.txt — com.apple.touchbar.agent defaults
- 9.4.2-keyboard-defaults.txt — com.apple.keyboard (does not exist)
- 9.4.2-controlstrip-defaults.txt — com.apple.controlstrip defaults
- 9.4.3-touchbar-agent-defaults.txt — touchbar.agent defaults (2 keys)
- 9.4.3-all-defaults.txt — full defaults dump
- 9.4.3-touchbar-related-defaults.txt — grep for touchbar/controlstrip/dfr
- 9.5.1-support-url.txt — [CONFIRMED] canonical Apple Support URLs
- 9.5.2-restart-cmd.txt — [CONFIRMED] launchctl kickstart command
- raw-ioreg-ioservice.txt — full ioreg IOService plane dump (3 MB)
- raw-ioreg-iusb.txt — full ioreg IOUSB plane dump
- tb-monitor.sh — DTrace monitoring script (Phase 5)

## 9. DTrace Probe Discovery (local verification)

- DFRDisplay313 custom provider (TouchBarServer, PID 313):
  Probe 1: DFRDisplay313:DFRDisplay:_DFRDisplayDrawRectsRequest:draw_request
    (framebuffer OUT to T1 — fires on each draw-rects request)
  Probe 2: DFRDisplay313:DFRDisplay:_DFRDisplayUsbRecvComplete:draw_completion
    (T1 completion ACK — fires when T1 acknowledges a pixel transfer)

- These are custom USDT-style probes registered by TouchBarServer,
  not standard fbt/pid provider probes. They confirm the macOS host
  sends "draw rectangles" requests (dirty-rect framebuffer updates),
  not high-level "draw icon" commands.

- Refresh rate measurement (from DTrace capture, idle):
  median inter-draw_req interval: 45-52ms (~20-22 Hz idle)
  active (after redraw trigger): ~18ms (~55 Hz)
  batching: avg 1.5-3.0 draw_comp per draw_req

## 10. Research Methodology

This research was conducted on 2026-08-25 on a MacBookPro14,2 (T1)
running macOS 13.7.8 with SIP disabled and amfi_get_out_of_my_way=1
(to allow DTrace kernel probing).

Methods:
- ioreg dumps (IOUSB + IOService + IOACPI planes) for hardware/driver mapping
- kextstat for loaded kernel extensions
- launchctl + ps for daemon/service identification
- defaults read for user preferences
- DTrace (DFRDisplay313 provider) for USB transfer timing analysis
- WebFetch of Apple developer documentation for NSTouchBar API
- WebFetch of Apple Support articles for canonical URLs
- Web research of Linux driver source code (appletbdrm, apple-ib-drv, tiny-dfr)
- GitHub issue/protocol searches for Wayland/compositor integration
- Cross-referencing Linux driver structs against local protocol evidence

Limitations:
- USB byte-level capture (9.2.3/9.2.5) was not possible from macOS
  (no USB extcap in Wireshark, T1 entitlement-locked). Deferred to
  Linux usbmon or DTrace tracemem (future work).
- ESP firmware path check was not completed (EFI mount failed without
  sudo tty). Needs manual mount.
- FN key timing (9.4.2) requires manual System Settings GUI observation.
- 782-byte HID descriptor (9.3.4) needs Linux usbhid-dump for confirmation.