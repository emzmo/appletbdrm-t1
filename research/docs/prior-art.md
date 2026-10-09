# Prior Art: Apple Touch Bar Drivers on T1/T2 Macs

## 1. Executive Summary

The Apple Touch Bar has a fragmented driver landscape: the T2 generation (2018–2020 MacBook Pro) has full mainline support since Linux 6.15, while the T1 generation (2016–2017) remains entirely out-of-tree. The T1 and T2 Touch Bars use fundamentally different transports — the T1 exposes the Touch Bar as a multi-interface USB device (`05ac:8600`) behind an iBridge demux layer, while the T2 presents separate USB interfaces (`05ac:8102`, `05ac:8302`) on a virtual USB host controller. Multiple community projects have achieved keyboard-only (dark-panel) mode on T1, but full DRM rendering — where the host paints arbitrary pixels onto the Touch Bar — was first achieved on T1 hardware by the **Seborider/mbp-t1-touchbar** project (August 2026). That project patched the mainline `appletbdrm` driver to accept the T1's product ID and handle three protocol dialect differences. Our project, `seojoonlee-dev/not-quite-tiny-dfr`, is a fork of the AsahiLinux `tiny-dfr` userspace renderer targeting T2 Macs; it does not contain kernel driver patches for T1 hardware.

## 2. Architecture Primer: T1 vs T2 Touch Bar Transport

### T1 (2016–2017 MacBook Pro, MacBookPro13,x / 14,x)

The T1 Secure Enclave Processor exposes a single USB device (`05ac:8600`, "Apple Inc. iBridge") with multiple configurations:

| USB Config | Interfaces | Purpose |
|-----------|------------|---------|
| 1 | HID keyboard (83-byte descriptor), HID 0xff12 (ALS+backlight), UVC webcam | Firmware-rendered control strip (dark panel) |
| 2 | Multitouch digitizer, DFR display (class 0x10, 2 bulk EPs), UVC webcam, CDC-NCM, HID 0xff12, Secure Enclave | Host-rendered DRM mode |

The iBridge device boots into config 1. Switching to config 2 is required for DRM rendering but was never supported in mainline Linux. In config 2, the display interface uses a protocol nearly identical to the T2's — GINF/REDY/CLRD/frame-update/UDCL — but with three dialect deviations: a 16-byte short-transfer preamble, a one-behind ACK scheme, and stale bulk pipes that must be cleared at probe.

The `apple-ibridge` driver binds to ACPI `_HID = APP7777`, creates virtual sub-HID devices, and demuxes the shared USB HID interface into separate touch-bar and ALS sub-devices. This demux architecture was rejected by HID subsystem maintainers three times (2019–2021) and was never mainlined.

### T2 (2018–2020 MacBook Pro, MacBookPro15,x / 16,x)

The T2 Secure Enclave Processor exposes the Touch Bar as separate USB interfaces on a virtual USB host controller (VHCI) provided by the `apple-bce` or `t2bce` driver:

| USB VID:PID | Interface Class | Mainline Driver | Purpose |
|------------|----------------|-----------------|---------|
| `05ac:8102` | HID | `hid-appletb-bl` (6.15+) | Backlight (off/dim/on) |
| `05ac:8302` | HID | `hid-appletb-kbd` (6.15+) | Keyboard mode (Esc/Fn/Media/Off) |
| `05ac:8302` | USB Audio/Video (class 0x10) | `appletbdrm` (6.15+) | DRM display (full pixel rendering) |

No demux layer is needed — each function has its own USB interface. This simpler architecture is what enabled mainlining in Linux 6.15.

### Shared Userspace: `tiny-dfr`

The `tiny-dfr` daemon (AsahiLinux/tiny-dfr) renders the dynamic function row onto the DRM device created by `appletbdrm` or `apple_z2`. It is transport-agnostic — it finds the Touch Bar by aspect ratio (`height/width > 30`) among `/dev/dri/card*` devices. The `seojoonlee-dev/not-quite-tiny-dfr` fork adds T2-specific workarounds (display-stream stall avoidance, heartbeat flushes).

## 3. Project Landscape

| Project | Target | Touch Bar Capability | Maintenance | Last Activity | Link |
|---------|--------|---------------------|-------------|---------------|------|
| `roadrunner2/macbook12-spi-driver` | T1 | Keyboard mode (dark panel) via `apple-ib-tb` | Abandoned | Aug 2019 (commit); Feb 2020 (push) | [GitHub](https://github.com/roadrunner2/macbook12-spi-driver) |
| `t2linux/apple-ib-drv` | T2 | Keyboard mode + backlight via `apple-touchbar` | Active | Jan 2025 | [GitHub](https://github.com/t2linux/apple-ib-drv) |
| `F13-Kr1pt0n/macbook-pro-touchbar-driver` | T1 | Keyboard mode; `tb_mode=display` switches to USB config 2 for external `appletbdrm` | Active | Sep 2025 | [GitHub](https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver) |
| `Phennova/apple-touchbar-driver` | T1 | Keyboard mode (Level 1); DRM planned (Level 2, not yet implemented) | Active | Sep 2026 | [GitHub](https://github.com/Phennova/apple-touchbar-driver) |
| `AJ-dev-i60/t1-touchbar` | T1 | Keyboard mode (firmware-rendered control strip); DRM planned in separate `t1-touchbar-studio` (private) | Active | Jul 2026 | [GitHub](https://github.com/AJ-dev-i60/t1-touchbar) |
| `Seborider/mbp-t1-touchbar` | T1 | **Full DRM rendering** (lit, touch-responsive, host-rendered) | Active | Sep 2026 | [GitHub](https://github.com/Seborider/mbp-t1-touchbar) |
| `seojoonlee-dev/not-quite-tiny-dfr` | T2 | Userspace renderer (fork of tiny-dfr); T2 display-stream stall workarounds | Active | Aug 2026 | [GitHub](https://github.com/seojoonlee-dev/not-quite-tiny-dfr) |
| `AsahiLinux/tiny-dfr` | ARM + T2 | Userspace renderer for `appletbdrm`/`apple_z2` | Active | Ongoing | [GitHub](https://github.com/AsahiLinux/tiny-dfr) |
| `t2linux/apple-bce-drv` | T2 | VHCI transport (no direct Touch Bar) | Maintained | 2025+ | [GitHub](https://github.com/t2linux/apple-bce-drv) |
| `deqrocks/t2bce` | T2 | VHCI transport replacement (archived) | Archived | 2026 | [GitHub](https://github.com/deqrocks/t2bce) |
| Mainline `applespi` | T1/T2 | SPI keyboard/trackpad | Mainlined | Linux 5.3+ | [Kernel](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/input/keyboard/applespi.c) |
| Mainline `hid-appletb-kbd` | T2 | Touch Bar keyboard mode | Mainlined | Linux 6.15+ | [Kernel](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-appletb-kbd.c) |
| Mainline `hid-appletb-bl` | T2 | Touch Bar backlight | Mainlined | Linux 6.15+ | [Kernel](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-appletb-bl.c) |
| Mainline `appletbdrm` | T2 | Touch Bar DRM display | Mainlined | Linux 6.15+ | [Kernel](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/tiny/appletbdrm.c) |
| Mainline `apple_z2` | ARM | Touch Bar/touchscreen (Apple Silicon) | Mainlined | Linux 6.15+ | Kernel |
| Mainline `hid-multitouch` (Touch Bar quirk) | T2 + ARM | Touch input on Touch Bar | Queued | Linux 6.17+ | [LKML](https://lkml.iu.edu/hypermail/linux/kernel/2506.1/04426.html) |

## 4. Mainline Kernel Status

### Merged

| Driver | Kernel | Scope | Author(s) |
|--------|--------|-------|-----------|
| `applespi` | 5.3 (Jul 2019) | SPI keyboard/trackpad (T1/T2) | Ronald Tschalär |
| `hid-appletb-bl` | 6.15 (Jun 2025) | Touch Bar backlight (T2 only) | Kerem Karabay, Aditya Garg; original: Ronald Tschalär |
| `hid-appletb-kbd` | 6.15 (Jun 2025) | Touch Bar keyboard mode (T2 only) | Kerem Karabay, Aditya Garg; original: Ronald Tschalär |
| `appletbdrm` | 6.15 (Jun 2025) | Touch Bar DRM display (T2 only) | Kerem Karabay, Aditya Garg |
| `apple_z2` | 6.15 (Jun 2025) | Touch Bar/touchscreen (Apple Silicon) | Asahi Linux developers |
| `hid-multitouch` Touch Bar quirk | 6.17 (queued) | Touch input on Touch Bar (T2 + ARM) | Kerem Karabay, Aditya Garg |

### Rejected / Never Merged

| Driver | Attempts | Scope | Reason for Rejection |
|--------|----------|-------|---------------------|
| `apple-ibridge` (iBridge demux) | v1 (Apr 2019), v2 (Jun 2019), v3 (Feb 2021) | T1 iBridge core + Touch Bar + ALS | HID maintainer Benjamin Tissoires objected to the MFD-based architecture (v1) and the virtual-HID demux approach (v2/v3). No maintainer championed the series after v3. |

**Key objection** (Benjamin Tissoires, Apr 2019): The original MFD approach was "far too complex." Tschalär rewrote it as a HID-only demux for v2, but the approach was still seen as architecturally unusual. After v3, no further revisions were posted, and the series stalled. [VERIFIED — [LKML v1](https://lwn.net/Articles/786475/), [v2](https://lwn.net/Articles/790946/), [v3](https://lkml.rescloud.iu.edu/2102.3/03558.html), [Tissoires review](https://lkml.indiana.edu/hypermail/linux/kernel/1904.3/03501.html)]

**Why T2 succeeded but T1 did not:** The T2 chip exposes the Touch Bar as separate USB interfaces (backlight, keyboard, display), each handled by a simple standalone driver. The T1 chip shares a single USB HID interface between the Touch Bar and ALS, requiring a demux layer that the HID subsystem maintainers found objectionable. [VERIFIED]

### Current Gap

As of Linux 6.19/7.x, **no mainline driver supports the T1 Touch Bar in any mode** — not keyboard mode, not DRM rendering. T1 users must rely on out-of-tree DKMS modules.

## 5. Device Identification: T1 vs T2 ID Tables

### T1 iBridge Device IDs

| ID Type | Value | Purpose | Source |
|---------|-------|---------|--------|
| ACPI `_HID` | `APP7777` | iBridge core driver binding | `apple-ibridge.c` [VERIFIED] |
| ACPI `_HID` | `APP000D` | SPI keyboard/trackpad driver binding | `applespi.c` [VERIFIED] |
| USB VID:PID | `05ac:8600` | iBridge USB device (physical) | `apple-ibridge.c` [VERIFIED] |
| USB VID:PID | `1d6b:0301` | Virtual Touch Bar sub-HID device | `apple-ibridge.c` in t2linux fork [VERIFIED] |
| USB VID:PID | `1d6b:0302` | Virtual ALS sub-HID device | `apple-ibridge.c` in t2linux fork [VERIFIED] |
| USB VID:PID | `05ac:1281` | iBridge Recovery Mode device | [REPORTED] tigercosmos gist |

### T2 Touch Bar Device IDs

| ID Type | Value | Purpose | Source |
|---------|-------|---------|--------|
| USB VID:PID | `05ac:8102` | Touch Bar Backlight interface | `hid-appletb-bl.c` [VERIFIED] |
| USB VID:PID | `05ac:8302` (HID) | Touch Bar Keyboard Mode interface | `hid-appletb-kbd.c` [VERIFIED] |
| USB VID:PID | `05ac:8302` (USB class 0x10) | Touch Bar DRM Display interface | `appletbdrm.c` [VERIFIED] |

### Where the Name Check Lives

The critical gate that prevents T2 drivers from probing on T1 hardware is the **USB product ID match** in each driver's device ID table:

1. **`appletbdrm`** (mainline, `drivers/gpu/drm/tiny/appletbdrm.c`):
   ```c
   static const struct usb_device_id appletbdrm_usb_id_table[] = {
       { USB_DEVICE_INTERFACE_CLASS(0x05ac, 0x8302, USB_CLASS_AUDIO_VIDEO) },
       {}
   };
   ```
   Matches only `05ac:8302`. The T1 device `05ac:8600` is **not listed**. This is a **cosmetic software gate** — the T1 device uses the same DRM protocol (with dialect differences), and adding `05ac:8600` to this table is one of the four one-line additions needed for T1 support. [VERIFIED]

2. **`hid-appletb-kbd`** (mainline, `drivers/hid/hid-appletb-kbd.c`):
   ```c
   static const struct hid_device_id appletb_kbd_hid_ids[] = {
       { HID_USB_DEVICE(USB_VENDOR_ID_APPLE, USB_DEVICE_ID_APPLE_TOUCHBAR_DISPLAY) },
       {}
   };
   ```
   Where `USB_DEVICE_ID_APPLE_TOUCHBAR_DISPLAY = 0x8302`. T1 device `05ac:8600` is not listed. [VERIFIED]

3. **`hid-appletb-bl`** (mainline, `drivers/hid/hid-appletb-bl.c`):
   ```c
   static const struct hid_device_id appletb_bl_hid_ids[] = {
       { HID_USB_DEVICE(USB_VENDOR_ID_APPLE, USB_DEVICE_ID_APPLE_TOUCHBAR_BACKLIGHT) },
       {}
   };
   ```
   Where `USB_DEVICE_ID_APPLE_TOUCHBAR_BACKLIGHT = 0x8102`. T1 device `05ac:8600` is not listed. [VERIFIED]

4. **`apple-ibridge`** (out-of-tree, T1):
   ```c
   static const struct acpi_device_id appleib_acpi_match[] = {
       { "APP7777", 0 },
       { },
   };
   static const struct hid_device_id appleib_hid_ids[] = {
       { HID_USB_DEVICE(USB_ID_VENDOR_APPLE, USB_ID_PRODUCT_IBRIDGE) },
       { },
   };
   ```
   Where `USB_ID_PRODUCT_IBRIDGE = 0x8600`. This is the reverse — the T1 demux driver only matches the T1 device. [VERIFIED]

5. **`APPLETB_FEATURE_IS_T1`** flag (out-of-tree, `apple-touchbar.c` in t2linux fork):
   ```c
   #define APPLETB_FEATURE_IS_T1  BIT(0)

   static const struct hid_device_id appletb_hid_ids[] = {
       { HID_USB_DEVICE(USB_VENDOR_ID_LINUX_FOUNDATION, USB_DEVICE_ID_IBRIDGE_TB),
         .driver_data = APPLETB_FEATURE_IS_T1 },
       { HID_USB_DEVICE(USB_VENDOR_ID_APPLE, USB_DEVICE_ID_APPLE_TOUCHBAR_BACKLIGHT) },
       { HID_USB_DEVICE(USB_VENDOR_ID_APPLE, USB_DEVICE_ID_APPLE_TOUCHBAR_DISPLAY) },
       { },
   };
   ```
   When the virtual Touch Bar sub-device (`1d6b:0301`) matches, the `APPLETB_FEATURE_IS_T1` flag is set, and mode switching uses raw USB vendor control messages instead of standard HID reports. [VERIFIED]

### Conclusion: Cosmetic Software Gate vs. Real Protocol Boundary

The USB product ID mismatch (`8302` vs `8600`) is a **cosmetic software gate** — it prevents the T2 driver from binding to the T1 device, but it is not a hard protocol boundary. The T1 and T2 Touch Bars use the same DRM rendering protocol (GINF/REDY/CLRD/frame/UDCL) with three dialect deviations:

1. **16-byte preamble**: T1 prefixes each bulk reply with a short transfer that must be drained; T2 does not.
2. **One-behind ACK**: T1 acknowledges frame N by echoing frame N−1's timestamp; T2 echoes frame N's timestamp.
3. **Stale bulk pipes**: T1 can enumerate with halted or stale bulk pipes; T2 does not.

All three deviations are gated on a product-ID check (`appletbdrm_is_t1()`) in the Seborider patches, so T2 code paths are completely unaffected. The underlying hardware is similar enough that the same driver, with these targeted patches, can drive both.

However, there is also a **structural difference**: T1 requires USB configuration switching (from config 1 to config 2) and a macOS-wake-sequence replay before the DRM display becomes available. This is handled by userspace scripts (`touchbar-t1-setup`, `touchbar-activate`) and cannot be done by the driver alone.

## 6. Prior Art on T1↔T2 Cross-Compatibility

### Seborider/mbp-t1-touchbar (August 2026) — The Primary Prior Art

**URL:** https://github.com/Seborider/mbp-t1-touchbar
**First commit:** 2026-08-30
**Most recent commit:** 2026-09-11

This project is the first known demonstration of full DRM rendering on T1 hardware. It achieves a lit, touch-responsive, host-rendered Touch Bar on MacBookPro13,x / 14,x models.

**Changes required (4 one-line ID additions + 3 dialect fixes + infrastructure):**

| Component | Change | Nature |
|-----------|-------|--------|
| `appletbdrm.c` USB ID table | Add `USB_DEVICE_INTERFACE_CLASS(0x05ac, 0x8600, USB_CLASS_AUDIO_VIDEO)` | One-line ID addition |
| `hid-multitouch.c` + `hid-ids.h` | Add `USB_DEVICE_ID_APPLE_IBRIDGE 0x8600` + `MT_CLS_APPLE_TOUCHBAR` match | One-line ID addition |
| `hid-appletb-bl.c` | Add `HID_DEVICE(BUS_USB, HID_GROUP_SENSOR_HUB, USB_VENDOR_ID_APPLE, USB_DEVICE_ID_APPLE_IBRIDGE)` | One-line ID addition (group-scoped to avoid claiming the digitizer) |
| `tiny-dfr` (userspace) | Add `\|\| dev.name().contains("iBridge Touchpad")` to digitizer matching | One-line name addition |
| `appletbdrm.c` `appletbdrm_read_response()` | Add retry loop with T1 short-transfer drain, gated on `appletbdrm_is_t1()` | Dialect fix |
| `appletbdrm.c` `appletbdrm_flush_damage()` | Gate timestamp-verification check on `appletbdrm_is_t1()`; also fixes latent T2 bug where mismatch was logged but not propagated | Dialect fix |
| `appletbdrm.c` `appletbdrm_probe()` | Clear both bulk pipes before first transfer on T1, gated on `appletbdrm_is_t1()` | Dialect fix |
| System infrastructure | `touchbar-t1-setup` (module loading, dynamic ID registration, USB config switch, driver binding), `touchbar-activate` (macOS wake sequence replay), `touchbar-t1.service`, seat rules, udev rules | Infrastructure |

**Known issue on MacBookPro14,2:** Open PR #1 reports that the digitizer on MBP14,2 models reports as `"Apple Inc. Apple T1 Controller Touchpad"` rather than `"Apple Inc. iBridge Touchpad"`, breaking touch in four places (tiny-dfr matching, udev seat rules, doctor.sh, watch-endtoend.py). This PR is unmerged as of 2026-09-24. [REPORTED]

### AJ-dev-i60/t1-touchbar (June 2026) — Keyboard-Only T1 Driver

**URL:** https://github.com/AJ-dev-i60/t1-touchbar
**Last commit:** 2026-07-01

Fork of `t2linux/apple-ib-drv` with T1-specific fixes for kernel 7.x. Provides keyboard-only (dark panel) mode — the firmware-rendered control strip. DRM rendering is planned for a separate private project (`t1-touchbar-studio`). Key contribution: DMI-gated `skip_acpi_power` parameter that avoids hard-freezing T1 machines on the `ASOC.SOCW(1)` ACPI call. [VERIFIED]

### F13-Kr1pt0n/macbook-pro-touchbar-driver (2025) — Keyboard + Config-Switching T1 Driver

**URL:** https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver
**Last commit:** 2025-09-03

Fork of `marc-git/macbook12-spi-driver`. Adds `tb_mode=auto|keyboard|display` module parameter and USB configuration switching via `usb_set_configuration()` on kernel 6.15+. In display mode, it switches to USB config 2 and expects an external `appletbdrm` to bind to the display interface. Does not include its own DRM driver patches. [VERIFIED]

### Phennova/apple-touchbar-driver (2026) — Keyboard-Only T1 Driver (DRM Planned)

**URL:** https://github.com/Phennova/apple-touchbar-driver
**Last commit:** 2026-09-08

Manual adaptation from roadrunner2 + Heratiki + t2linux sources. Provides keyboard-only mode (Level 1). DRM mode (Level 2) is planned but not yet implemented — the README describes vendoring `appletbdrm.c` and patching in the T1 product ID as Increment 2. [VERIFIED]

### roadrunner2/macbook12-spi-driver (2019) — Original T1 Driver

**URL:** https://github.com/roadrunner2/macbook12-spi-driver
**Last commit:** 2019-08-27

The original T1 Touch Bar driver. Provides keyboard-only mode via `apple-ib-tb`. Abandoned after `applespi` was mainlined in 5.3. The Touch Bar and ALS portions were never mainlined. [VERIFIED]

### Negative Result: No Reports of Unmodified T2 Drivers on T1

No reports were found of the stock T2 Touch Bar drivers (`appletbdrm`, `hid-appletb-kbd`, `hid-appletb-bl`) working on T1 hardware without patches. The T1 and T2 devices differ in USB product ID, USB configuration layout, ACPI power management, and DRM protocol dialect. Every successful T1 Touch Bar setup uses a fork or patch set. [VERIFIED across GitHub, Reddit, Arch/Fedora/Ubuntu forums, t2linux wiki, and LKML]

## 7. Gap Statement

### What Our Repo (`seojoonlee-dev/not-quite-tiny-dfr`) Adds

Our project is a fork of AsahiLinux/tiny-dfr (a Rust userspace daemon) with T2-specific reliability patches:

- **Display-stream stall workaround** (commit `2d46524`): Full-bar redraws instead of partial clips, heartbeat flushes, and exponential backoff on stalled flushes to avoid `appletbdrm` desync on T2 Macs.
- **Additional widgets**: Battery calibration, CPU/GPU widgets, media widget, lyrics sync, volume slider, SVG caching.
- **NixOS module**: Distribution packaging for NixOS.

**Our project does not contain kernel driver patches for T1 hardware.** It is a T2-focused userspace renderer.

### Relationship to Existing Work

| Capability | Seborider/mbp-t1-touchbar | AJ-dev/t1-touchbar | F13-Kr1pt0n | Phennova | not-quite-tiny-dfr (ours) |
|-----------|--------------------------|-------------------|-------------|----------|--------------------------|
| T1 DRM rendering | ✅ Full (lit + touch) | ❌ Keyboard only | ⚠️ Config switch only | ❌ Planned | ❌ N/A (T2 only) |
| T1 keyboard mode | ✅ Via blacklist of `apple-ibridge` | ✅ With `skip_acpi_power` | ✅ With `tb_mode` param | ✅ Level 1 | ❌ N/A |
| T2 DRM rendering | ✅ (unmodified upstream) | ❌ (T2 not targeted) | ⚠️ Depends on external `appletbdrm` | ❌ | ✅ With stall fixes |
| Userspace renderer | tiny-dfr (patched) | N/A (firmware-rendered) | N/A (expects external) | N/A (planned) | tiny-dfr (forked + enhanced) |
| Kernel patches | appletbdrm + hid-multitouch + hid-appletb-bl | apple-ibridge + apple-touchbar (DKMS) | apple-ibridge + apple-ib-tb + apple-ib-als (DKMS) | apple-ibridge + apple-ib-tb + apple-ib-als (DKMS) | None |

### Honest Assessment

1. **T1 DRM rendering is not novel to our project.** Seborider/mbp-t1-touchbar (first commit 2026-08-30) demonstrated full DRM rendering on T1 hardware before our project. Our project does not contain kernel patches for T1 support.

2. **T2 display-stream stall workarounds are a genuine contribution.** The `appletbdrm` DRM driver on T2 Macs has a known desync/stall issue that our fork addresses with full-bar redraws, heartbeat flushes, and exponential backoff. As of this writing, no other project has published an equivalent workaround for this specific T2 reliability problem in the userspace renderer.

3. **The MacBookPro14,2 digitizer naming issue** (reported in Seborider PR #1) is an open problem. If our project or any downstream project targets this specific model, the digitizer name `"Apple Inc. Apple T1 Controller Touchpad"` must be added to the matching logic in addition to `"Apple Inc. iBridge Touchpad"`.

4. **No mainline path exists for T1 Touch Bar DRM.** The three rejected `apple-ibridge` patch series (2019–2021) and the T2-only `appletbdrm` (6.15+) leave T1 users reliant on out-of-tree patches indefinitely. Seborider's approach — patching the mainline `appletbdrm` driver to accept the T1 product ID with dialect-gated fixes — is the most upstream-compatible strategy, as it modifies the existing mainline driver rather than replacing it.

## 8. Sources

### Foundation Projects

- roadrunner2/macbook12-spi-driver: https://github.com/roadrunner2/macbook12-spi-driver [VERIFIED, accessed 2026-09-24]
- t2linux/apple-ib-drv: https://github.com/t2linux/apple-ib-drv [VERIFIED, accessed 2026-09-24]
- marc-git/macbook12-spi-driver: https://github.com/marc-git/macbook12-spi-driver [VERIFIED, accessed 2026-09-24]
- AsahiLinux/tiny-dfr: https://github.com/AsahiLinux/tiny-dfr [VERIFIED, accessed 2026-09-24]
- seojoonlee-dev/not-quite-tiny-dfr: https://github.com/seojoonlee-dev/not-quite-tiny-dfr [VERIFIED, accessed 2026-09-24]

### T1 Touch Bar Drivers

- Seborider/mbp-t1-touchbar: https://github.com/Seborider/mbp-t1-touchbar [VERIFIED, accessed 2026-09-24]
- AJ-dev-i60/t1-touchbar: https://github.com/AJ-dev-i60/t1-touchbar [VERIFIED, accessed 2026-09-24]
- F13-Kr1pt0n/macbook-pro-touchbar-driver: https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver [VERIFIED, accessed 2026-09-24]
- Phennova/apple-touchbar-driver: https://github.com/Phennova/apple-touchbar-driver [VERIFIED, accessed 2026-09-24]

### T2 Ecosystem

- t2linux kernel patches: https://github.com/t2linux/linux-t2-patches [VERIFIED, accessed 2026-09-24]
- t2linux wiki: https://wiki.t2linux.org/ [VERIFIED, accessed 2026-09-24]
- t2linux apple-bce: https://github.com/t2linux/apple-bce-drv [VERIFIED, accessed 2026-09-24]
- deqrocks/t2bce: https://github.com/deqrocks/t2bce [VERIFIED, accessed 2026-09-24]

### Mainline Kernel

- applespi merge (5.3): https://cateee.net/lkddb/web-lkddb/KEYBOARD_APPLESPI.html [VERIFIED]
- hid-appletb-bl source: https://github.com/torvalds/linux/blob/master/drivers/hid/hid-appletb-bl.c [VERIFIED, accessed 2026-09-24]
- hid-appletb-kbd source: https://github.com/torvalds/linux/blob/master/drivers/hid/hid-appletb-kbd.c [VERIFIED, accessed 2026-09-24]
- appletbdrm source: https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/tiny/appletbdrm.c [VERIFIED, accessed 2026-09-24]

### Kernel Mailing Lists

- Ronald Tschalär v1 (Apr 2019): https://lwn.net/Articles/786475/ [VERIFIED]
- Ronald Tschalär v2 (Jun 2019): https://lwn.net/Articles/790946/ [VERIFIED]
- Ronald Tschalär v3 (Feb 2021): https://lkml.rescloud.iu.edu/2102.3/03558.html [VERIFIED]
- Benjamin Tissoires review: https://lkml.indiana.edu/hypermail/linux/kernel/1904.3/03501.html [VERIFIED]
- Aditya Garg appletbdrm v6 (Feb 2025): https://lkml.org/lkml/2025/2/25/1524 [VERIFIED]
- Multitouch quirks queued for 6.17: https://lkml.iu.edu/hypermail/linux/kernel/2506.1/04426.html [VERIFIED]
- LWN: Touch Bar driver for T2 Macs: https://lwn.net/Articles/1007701/ [VERIFIED]
- LWN: Touch Bar DRM driver: https://lwn.net/Articles/1011636/ [VERIFIED]
- Phoronix: Apple Touch Bar in Linux 6.15: https://www.phoronix.com/news/Apple-Touch-Bar-Display-Linux [VERIFIED]

### Community Resources

- Dunedan/mbp-2016-linux: https://github.com/Dunedan/mbp-2016-linux [VERIFIED, accessed 2026-09-24]
- ArchWiki MacBookPro14,2: https://wiki.archlinux.org/title/MacBookPro14,2 [VERIFIED, accessed 2026-09-24]
- ArchWiki Laptop/Apple: https://wiki.archlinux.org/title/Laptop/Apple [VERIFIED, accessed 2026-09-24]
- Arch BBS Touch Bar help: https://bbs.archlinux.org/viewtopic.php?id=309376 [VERIFIED]
- Reddit r/linux_on_mac T1: https://www.reddit.com/r/linux_on_mac/comments/1q69gj3/ [REPORTED]
- Reddit r/omarchy T1 Touch Bar: https://www.reddit.com/r/omarchy/comments/1w3hy2q/ [REPORTED]

### Packaging

- AUR apple-ib-drv-dkms-git: https://aur.archlinux.org/packages/apple-ib-drv-dkms-git [VERIFIED, accessed 2026-09-24]
- AUR macbook12-spi-driver-dkms: https://aur.archlinux.org/packages/macbook12-spi-driver-dkms [VERIFIED, accessed 2026-09-24]
- COPR sharpenedblade/t2linux: https://copr.fedorainfracloud.org/coprs/sharpenedblade/t2linux [VERIFIED, accessed 2026-09-24]

### Related Context

- Asahi Linux `apple_z2` (Apple Silicon Touch Bar): Merged in Linux 6.15. Uses ADP (Apple Display Protocol) over Device Tree, not USB. No cross-compatibility with Intel Mac Touch Bar drivers. [VERIFIED — Phoronix](https://www.phoronix.com/news/Linux-6.15-Input)
- Touch ID on T1: Andrew Boyd (0xBOYD) demonstrated working T1 Touch ID via `t1bridge` (https://github.com/standardagents/t1bridge), communicating with the T1 Secure Enclave over CDC-NCM. Requires machine-specific `EFI/APPLE/EMBEDDEDOS/FDRData`. Early-stage as of 2026-09. [REPORTED]
- Touch ID on T2: `jmurth1234/t2-touchid-linux` provides experimental `fprintd`-compatible fingerprint authentication. Only works with fingers enrolled in macOS. [REPORTED — t2linux wiki]

---

*Document generated 2026-09-24. All claims labeled as [VERIFIED] were confirmed by direct examination of source code or official documentation. Claims labeled [REPORTED] come from community sources that could not be independently verified at the time of writing. Claims labeled [UNVERIFIED] could not be confirmed.*