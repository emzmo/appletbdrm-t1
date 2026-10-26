# Changelog — appletbdrm-t1

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

---

## [v2.0.0] — 2026-10-26

### Added
- **mac_type sysfs attribute**: the kernel driver now exposes the chip type
  (`t1` or `t2`) at `/sys/class/drm/cardN/device/mac_type`. The reactive-dfr
  daemon reads this to gate T2-specific workarounds on T1 hardware.
- **known-issues.md**: post-v1 audit documenting 8 known issues with
  severity, impact, and v2 strategies.
- **Universal install.sh**: standalone installer for non-PKGBUILD distros
  (`sudo ./install.sh install/uninstall/status`).
- **Project README** with 3 installation methods (script, manual, PKGBUILD),
  supported hardware table, and credits.
- **kernel-hid-t1 tracked in git**: the touch input DKMS module is now a
  first-class citizen in the repo (was previously gitignored).

### Changed
- **PKGBUILD rewritten**: now installs both DKMS modules (appletbdrm +
  kernel-hid-t1), config switcher, and udev rule in one package. No more
  `sed`-patching dkms.conf — each module keeps its own version.
- **Install hooks** (`appletbdrm-t1-dkms.install`): post-install/upgrade/remove
  hooks with user instructions.

### Removed
- **ibridge_switcher.c**: unused C binary alternative to the shell script
  (the actual install uses `ibridge-config-switch.sh` which writes to
  sysfs directly, no libusb dependency).
- **install.sh (old)**: replaced by the new universal install.sh.
- **External reference repos** (Seborider, AsahiLinux, seojoonlee-dev, etc.):
  moved to `~/Projects/touchbar-research` for archival.
- **Research docs** (55 ADRs, 431 test logs, 44 macOS evidence files):
  moved to `~/Projects/touchbar-research`.

### Fixed
- **install.sh robustness**: empty array check with `set -u` (bash <4.4
  compatibility), source directory existence check, stale build artifact
  cleanup after copy.

---

## [v1.1.0] — 2026-10-25

### Added
- **MIT license** at repo root.
- **Change report** (`docs/appletbdrm-t1-changes.md`): detailed analysis of
  all changes from mainline `appletbdrm` to this fork.
- **PKGBUILD** for AUR/makepkg installation.

### Changed
- **Repo cleanup**: gitignore updated, external repos and tooling excluded.

### Removed
- **Research docs** (586 files) moved to `~/Projects/touchbar-research`.

---

## [v1.0.0-phase0-complete] — 2026-10-10

### Added
- **T1 DRM driver** (`appletbdrm.c`): unified driver supporting both T1
  (05ac:8600) and T2 (05ac:8302) MacBook Pros.
- **T1 HID brightness control**: backlight via HID Feature Reports on
  Interface 6 (Reports 3/4/5) — display on/off, absolute brightness in
  nits, auto-brightness disable.
- **4 T1 protocol dialect fixes**:
  1. Preamble drain: 16-byte short transfer prefixed to T1 bulk replies
     is drained and retried.
  2. One-behind ACK: timestamp validation gated to T2 only; T1 responses
     accepted by message type.
  3. Stale pipe clearing: `usb_clear_halt()` on both bulk endpoints at
     probe time to reset config-1 residue.
  4. Sync probe: `usb_bulk_msg()` replaces async URB submission (which
     failed with `-EAGAIN` on every T1 boot).
- **USB config switcher** (`ibridge-config-switch.sh` + `.service`):
  systemd service that switches the T1 iBridge from USB config 1
  (keyboard) to config 2 (display + touch) at boot.
- **Udev seat rule** (`99-touchbar-seat.rules`): digitizer assigned to
  `seat1` to isolate from the compositor.
- **DKMS config**: `dkms.conf` with `AUTOINSTALL=yes`.

### Changed
- **`drm_atomic_state` → `drm_atomic_commit`**: rename for kernel 7.x
  compatibility.
- **DKMS build**: only builds the kernel module, skips the userspace
  ibridge-switcher binary.

### Fixed
- **Config switch wait**: increased to 25s for slow cold boots.
- **DRM driver symlink check**: uses `readlink` instead of `ls` for
  reliability.
- **Seat name**: `seat-touchbar` → `seat1` (no hyphen, D-Bus safe).

### Reverted
- **71-seat.rules shadow**: attempted to shadow `71-seat.rules` to prevent
  Hyprland from grabbing the DRM card. Reverted due to S3 resume issues.

---

## [baseline-pre-t1-fixes] — 2026-10-09

Initial baseline: mainline `appletbdrm` driver before T1 dialect fixes.
T2-only, no T1 support, no USB config switcher, no udev seat rule.

[v2.0.0]: https://github.com/emzmo/appletbdrm-t1/releases/tag/v2.0.0
[v1.1.0]: https://github.com/emzmo/appletbdrm-t1/releases/tag/v1.1.0
[v1.0.0-phase0-complete]: https://github.com/emzmo/appletbdrm-t1/releases/tag/v1.0.0-phase0-complete
[baseline-pre-t1-fixes]: https://github.com/emzmo/appletbdrm-t1/releases/tag/baseline-pre-t1-fixes