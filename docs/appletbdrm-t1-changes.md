# From `appletbdrm` to `appletbdrm-t1` — Change Report

This document describes every change made to the mainline Linux
`appletbdrm` driver to produce our `appletbdrm-t1` fork.

The mainline driver (in the Linux kernel since 6.15, at
`drivers/gpu/drm/tiny/appletbdrm.c`) supports only the **T2** chip
(2018–2020 MacBook Pros). Our fork adds support for the **T1** chip
(2016–2017 MacBook Pros, USB device `05ac:8600`, "iBridge").

---

## Background: T1 vs T2

| | T1 (2016–2017) | T2 (2018–2020) |
|---|---|---|
| USB device | `05ac:8600` (iBridge) | `05ac:8302` |
| USB configs | 2 (must switch from 1→2) | 1 (ready out of box) |
| Display interface | Shared behind iBridge demux | Separate interface |
| Brightness control | HID Feature Reports (Interface 6) | SBTN bulk message |
| Backlight driver | Self-registered in appletbdrm | External `hid_appletb_bl` |
| Touch input | `hid_multitouch` + `apple_ibridge` | `hid_multitouch` |

The display protocol (GINF/REDY/CLRD/UDCL) is nearly identical between
T1 and T2, but the T1 has four dialect differences that cause the
mainline driver to fail silently on T1 hardware.

---

## Summary of Changes

| Category | Changes |
|---|---|
| New files | `ibridge_switcher.c`, `ibridge-config-switch.service`, `ibridge-switch.sh`, `99-touchbar-seat.rules`, `PKGBUILD`, `install.sh` |
| Modified file | `appletbdrm.c` (1517 lines — extended from T2-only to T1+T2) |
| T1 dialect fixes | 4 protocol fixes (preamble drain, one-behind ACK, stale pipe clearing, sync probe) |
| T1 brightness | HID Feature Reports on Interface 6 (Reports 3, 4, 5) |
| Kernel compat | `drm_atomic_state` → `drm_atomic_commit` rename |
| Infrastructure | USB config switcher + systemd service + udev seat rule |

---

## Change 1: Dual-chip detection (`mac_type` enum)

**Original:** The driver matched only PID `0x8302` (T2). No concept of
chip type — everything was T2.

**Ours:** Added an enum to distinguish chips:

```c
enum appletbdrm_mac_type {
    MAC_TYPE_T1,
    MAC_TYPE_T2,
};
```

The USB ID table now matches both `0x8600` (T1) and `0x8302` (T2). At
probe time, the driver checks `id->idProduct` and sets `mac_type`
accordingly. All chip-specific behavior branches on this field.

---

## Change 2: T1 HID brightness control (Interface 6)

**Original (T2):** Brightness is set by sending an SBTN ("Set
Brightness") bulk message to the display interface. A separate kernel
driver (`hid_appletb_bl`) handles the backlight sysfs device.

**Ours (T1):** The T1 controls brightness through **HID Feature
Reports** on a separate USB interface (Interface 6, Usage Page
`0xFF12`). This interface is not used by the T2. We added:

1. **Interface claiming** — `appletbdrm_claim_hid_interface()` claims
   Interface 6 at probe time so we can send HID reports to it. If it
   fails, the driver continues without brightness control (display
   still works, just can't dim).

2. **Report 3 — Display ON/OFF** (`appletbdrm_t1_set_display_state`):
   Turns the OLED panel on or off. Called when brightness goes to 0
   (off) or above 0 (on), and on DRM atomic enable/disable.

3. **Report 4 — Absolute brightness in nits** (
   `appletbdrm_t1_set_brightness_nits`): Sets the brightness to an
   absolute value in "nits" (raw units, ~12 nits minimum to ~357 nits
   maximum). The backlight sysfs 0–255 range is mapped linearly to
   this nit range.

4. **Report 5 — Auto-brightness disable** (
   `appletbdrm_t1_disable_autobright`): Sends a report to disable the
   T1's built-in auto-brightness (ambient light sensor driven). This
   is called before every manual brightness set, so the ALS doesn't
   fight our settings.

5. **Backlight device registration** — On T1, the driver registers
   its own `backlight_device` (unlike T2 which delegates to
   `hid_appletb_bl`). The `BL_CORE_SUSPENDRESUME` flag ensures
   brightness is saved/restored across suspend.

6. **Auto-brightness preservation** — The first call to
   `update_status` is skipped (via `backlight_initialized` flag) so
   the T1's boot-time auto-brightness setting isn't overwritten until
   the daemon explicitly sets a value.

---

## Change 3: Fix 1 — Preamble drain (16-byte short transfer)

**Problem:** The T1 prefixes every bulk reply with a 16-byte "short
transfer" that the T2 never sends. The mainline driver reads the bulk
response, checks that `actual_size == expected_size`, and fails with
`-EIO` because the short transfer is smaller than expected. This
happens on the very first GINF (Get Information) request, so the DRM
card never appears.

**Fix:** In `appletbdrm_read_response()`, added a retry loop (up to 8
attempts). When `mac_type == T1` and `actual_size != expected_size`,
the short transfer is drained (discarded) and the loop retries — the
real payload follows on the next bulk read.

```c
if (adev->mac_type == MAC_TYPE_T1 && (size_t)actual_size != size) {
    dev_dbg(adev->dmadev, "Draining %d byte transfer\n", actual_size);
    continue;
}
```

---

## Change 4: Fix 2 — One-behind ACK (timestamp gating)

**Problem:** The T1 acknowledges commands with a one-behind scheme —
the response to command N arrives when you send command N+1. The
mainline driver checks a timestamp to validate responses, but this
check rejects valid T1 responses because they arrive late.

**Fix:** The timestamp validation is gated to only run for T2. On T1,
the response is accepted based on message type matching, not
timestamp. The readiness signal (`MSG_SIGNAL_READINESS`) is also
discarded and retried, since the T1 sends it spontaneously during
operation.

---

## Change 5: Fix 3 — Stale pipe clearing (`usb_clear_halt`)

**Problem:** When the T1 switches from USB config 1 to config 2, the
bulk endpoints can be in a "halted" state or hold a stale transfer
from config 1. The first bulk transfer fails with `-EAGAIN` or
`-EIO`, and the DRM card never appears.

**Fix:** At probe time, when `mac_type == T1`, the driver calls
`usb_clear_halt()` on both the input and output bulk endpoints. This
sends a `CLEAR_FEATURE(ENDPOINT)` control transfer to reset the halt
condition:

```c
if (adev->mac_type == MAC_TYPE_T1) {
    usb_clear_halt(adev->udev, usb_rcvbulkpipe(..., adev->in_ep));
    usb_clear_halt(adev->udev, usb_sndbulkpipe(..., adev->out_ep));
}
```

---

## Change 6: Fix 4 — Sync probe (not async URB)

**Problem:** The mainline driver submits an async URB (USB Request
Block) to read the GINF response. On the T1, this fails with
`-EAGAIN` on every boot because the USB host controller hasn't yet
allocated bandwidth for the bulk endpoint at submit time.

**Fix:** Both T1 and T2 now use a **synchronous probe**
(`appletbdrm_probe_t2_sync`). Instead of submitting an async URB and
waiting for a completion callback, the driver calls `usb_bulk_msg()`
which blocks until the transfer completes and handles retries
internally. This is the approach used by Seborider's
`mbp-t1-touchbar` project and works reliably on both chips.

The async URB code path (`appletbdrm_submit_async_urb`,
`appletbdrm_async_urb_complete`) is retained for potential future use
but is not called during probe.

---

## Change 7: `drm_atomic_commit` rename (kernel 7.x compat)

**Problem:** The mainline driver uses `struct drm_atomic_state`, which
was renamed to `struct drm_atomic_commit` in kernel 7.x. Without this
rename, the driver doesn't compile on modern kernels.

**Fix:** All references to `drm_atomic_state` were changed to
`drm_atomic_commit` in function signatures, helper calls, and
structures. This is a mechanical rename with no logic change.

---

## Change 8: USB config switcher (`ibridge_switcher`)

**New file:** `ibridge_switcher.c` (118 lines)

The T1 boots in USB config 1 (keyboard mode). The display and touch
sensor only appear in config 2. This program uses libusb to switch the
iBridge device from config 1 to config 2.

It is a standalone userspace tool (not part of the kernel module)
because the config switch must happen before the driver probes the
device.

**Installed as:** `/usr/local/sbin/ibridge-config-switch.sh`

---

## Change 9: Systemd service (`ibridge-config-switch.service`)

**New file:** Runs the config switcher at boot, right after the udev
daemon is ready (`After=systemd-udevd.service`). Uses
`RemainAfterExit=yes` so the service stays "active" after the one-shot
switch completes.

The service script waits for the DRM card to appear (checks the driver
symlink on `/sys/class/drm/card0`), with a 25-second timeout. This
handles the case where the T1 takes a few seconds to re-enumerate
after the config switch.

---

## Change 10: Udev seat rule (`99-touchbar-seat.rules`)

**New file:** Isolates the Touch Bar from the compositor (Hyprprland)
so the daemon can take DRM master without competition.

- The **digitizer** (input device) is assigned to `seat1` — a
  separate seat that Hyprland doesn't monitor. The daemon reads touch
  events from this seat exclusively.
- The **DRM card** uses a `GOTO="seat_end"` that is a no-op across
  files (the `seat_end` label lives in `71-seat.rules`). This is
  intentionally fragile — assigning the DRM card to `seat1` crashes
  the SDDM login greeter on systemd 262.1 due to a
  `CreateSession InvalidParameter` bug. The no-op approach means the
  card stays on `seat0` (default) and the daemon wins the race by
  opening it first at boot.

---

## Change 11: PKGBUILD and install.sh

**New files:** Packaging for Arch Linux / AUR.

- `PKGBUILD` — Builds the DKMS module and installs the udev rules,
  systemd service, and config switcher.
- `install.sh` — Manual install alternative (for non-Arch distros or
  development). Supports `install`, `uninstall`, and `status` commands.

---

## Change 12: DKMS config

**Modified:** `dkms.conf` — the `MAKE` command builds only the kernel
module (`make modules`), skipping the `ibridge-switcher` userspace
tool (which needs libusb and is built/installed separately by the
PKGBUILD or install.sh).

---

## Commit History

| Commit | Description |
|---|---|
| `7373b06` | baseline: state before T1 dialect fixes |
| `ef655a4` | fix: drm_atomic_state → drm_atomic_commit (kernel 7.x) |
| `adec78a` | fix: clear stale bulk pipes before T1 probe |
| `9da3516` | fix: sync probe for T1 (avoid EAGAIN on URB submit) |
| `e0ddfc1` | fix: drain 16-byte preamble on T1 bulk reads |
| `a88f740` | fix: gate timestamp check for T1 one-behind ACK |
| `f5244a7` | fix: DKMS builds only kernel module, skip ibridge-switcher |
| `02a57b5` | feat: auto-switch iBridge to DRM config on boot |
| `22af2cb` | fix: increase config switch wait to 25s |
| `530f42b` | fix: use readlink for DRM driver symlink check |
| `7998179` | feat: assign Touch Bar to its own seat |
| `babe187` | chore: clean up repo, ignore external repos |
| `a55496a` | fix: use seat1 (no hyphen, D-Bus safe) |
| `3c2141f` | feat: add PKGBUILD for AUR |
| `48bacff` | fix: shadow 71-seat.rules (later reverted) |
| `acfa66c` | Revert shadow 71-seat.rules |
| `67086c7` | docs: add MIT license |
| `68470eb` | refactor: move research docs out |

Tag `v1.0.0-phase0-complete` marks the point where the driver was
fully working on the MacBookPro14,2 (T1) with display rendering and
touch input verified.

---

## What Was NOT Changed

- The display protocol (GINF/REDY/CLRD/UDCL opcodes) — identical
  between T1 and T2, no modification needed.
- The framebuffer format (24-bit RGB, damage tracking) — unchanged.
- The DRM connector/plane/CRTC setup — unchanged.
- The T2 brightness path (SBTN bulk message) — unchanged, still works
  for T2.
- The USB ID table still matches T2 (`0x8302`) — T2 users are
  unaffected.

---

## Credits

The mainline `appletbdrm` driver was written by Kerem Karabay
(`kekrby@gmail.com`) and sunplex07, and mainlined in Linux 6.15.

The T1 dialect fixes are based on the work of **Seborider**
(`mbp-t1-touchbar` project), who first achieved DRM rendering on T1
hardware. Our fork integrates Seborider's protocol fixes into the
mainline driver structure, adds HID-based brightness control, and
packages everything for DKMS + systemd + Arch Linux.