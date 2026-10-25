# appletbdrm-t1

Apple Touch Bar driver suite for T1 (2016–2017) and T2 (2018–2020) MacBook Pros on Linux. Provides DRM display rendering and multitouch input via two DKMS kernel modules, plus a USB config switcher and udev seat rule.

For a detailed list of changes from the mainline `appletbdrm` driver, see [docs/appletbdrm-t1-changes.md](docs/appletbdrm-t1-changes.md).

## What's included

| Component | Description |
|-----------|-------------|
| `appletbdrm` | DRM display driver — makes the Touch Bar appear as `/dev/dri/card*` |
| `kernel-hid-t1` | Patched `hid-multitouch` — adds T1 iBridge touch support |
| `ibridge-config-switch` | Boot service that switches the T1 from keyboard mode to display+touch mode |
| `99-touchbar-seat.rules` | Udev rule that isolates the Touch Bar from the compositor |

## Installation

### Option 1 — Install script (any distro)

```bash
git clone https://github.com/emzmo/appletbdrm-t1.git
cd appletbdrm-t1
sudo ./install.sh install
sudo reboot
```

Check status or uninstall:

```bash
./install.sh status
sudo ./install.sh uninstall
```

### Option 2 — Manual

```bash
# Install appletbdrm DKMS module
sudo cp -r src/appletbdrm /usr/src/appletbdrm-1.2
sudo dkms add -m appletbdrm -v 1.2
sudo dkms build -m appletbdrm -v 1.2
sudo dkms install -m appletbdrm -v 1.2

# Install kernel-hid-t1 DKMS module
sudo cp -r src/kernel-hid-t1 /usr/src/kernel-hid-t1-0.2
sudo chmod +x /usr/src/kernel-hid-t1-0.2/pre_build.sh
sudo dkms add -m kernel-hid-t1 -v 0.2
sudo dkms build -m kernel-hid-t1 -v 0.2
sudo dkms install -m kernel-hid-t1 -v 0.2

# Install USB config switcher
sudo install -Dm755 src/appletbdrm/etc/systemd/system/ibridge-config-switch.sh \
    /usr/local/sbin/ibridge-config-switch.sh
sudo install -Dm644 src/appletbdrm/etc/systemd/system/ibridge-config-switch.service \
    /etc/systemd/system/ibridge-config-switch.service
sudo systemctl enable ibridge-config-switch.service

# Install udev seat rule
sudo install -Dm644 etc/udev/rules.d/99-touchbar-seat.rules \
    /etc/udev/rules.d/99-touchbar-seat.rules
sudo udevadm control --reload-rules

sudo reboot
```

### Option 3 — PKGBUILD (Arch Linux, not yet published on AUR)

```bash
git clone https://github.com/emzmo/appletbdrm-t1.git
cd appletbdrm-t1
makepkg -si
sudo systemctl enable ibridge-config-switch.service
sudo reboot
```

## Requirements

- `dkms`, `gcc`, `make`
- Kernel headers for your running kernel (`linux-headers`, `linux-lts-headers`, `linux-omarchy-headers`, etc.)
- Kernel 6.11+ (the `hid-multitouch` driver needs `on_hid_hw_open/close` callbacks added in 6.11)

## Supported hardware

| Model | Year | Chip | USB ID |
|-------|------|------|--------|
| MacBook Pro 13" (A1706) | 2016–2017 | T1 | 05ac:8600 |
| MacBook Pro 15" (A1707) | 2016–2017 | T1 | 05ac:8600 |
| MacBook Pro 13/15/16" | 2018–2020 | T2 | 05ac:8302 |

Tested on MacBookPro14,2 (T1) and MacBookPro16,1 (T2).

## Usage

The Touch Bar appears as a DRM device — use it with [tiny-dfr](https://github.com/AsahiLinux/tiny-dfr), [reactive-dfr](https://github.com/emzmo/reactive-dfr), or any DRM client:

```bash
ls /dev/dri/card*
```

Brightness control:

```bash
echo 128 | sudo tee /sys/class/backlight/appletb_backlight/brightness
```

## Credits

- **Kerem Karabay** (`kekrby@gmail.com`) — original `appletbdrm` DRM driver, mainlined in Linux 6.15
- **sunplex07** — T1 support and unified driver rework
- **Seborider** ([mbp-t1-touchbar](https://github.com/Seborider/mbp-t1-touchbar)) — first achieved DRM rendering on T1 hardware; the protocol dialect fixes in this fork are based on their work
- **t2linux project** — kernel patches and community resources for T2 Macs
- **cevatkerim** ([omarchy-touchbar](https://github.com/cevatkerim/omarchy-touchbar)) — Omarchy integration work

## License

GPL-2.0 (kernel modules)
