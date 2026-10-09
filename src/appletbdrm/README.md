## appletbdrm

Unified DRM driver for Apple Touch Bar on MacBook Pro 2016-2020.

T1 (2016-2017) and T2 (2018-2020) MacBooks supported.

| Model | Year | Chip | USB ID | Brightness |
|-------|------|------|--------|------------|
| MacBook Pro 13" (A1706) | 2016-2017 | T1 | 05ac:8600 | HID |
| MacBook Pro 15" (A1707) | 2016-2017 | T1 | 05ac:8600 | HID |
| MacBook Pro 13/15/16" | 2018-2020 | T2 | 05ac:8302 | hid_appletb_bl |

Tested on MacbookPro14,2 ; MacbookPro16,1

- DRM framebuffer display
- Backlight control (T1: HID, T2: handled by hid_appletb_bl)
- T1: Auto-brightness preserved on boot
- T1: Automatic USB configuration switching

### Kernel Patches (Touch Input)

Required for touch input. Use t2linux patches or a patched kernel.

- `hid-appleib.c` - T1 descriptor fixup (64-bit field split)
- `hid-multitouch.c` - `MT_CLS_APPLE_TOUCHBAR` touch class

### T1 Notes

T1 iBridge boots in USB Configuration 1. The `ibridge-switcher` tool switches to Configuration 2 via systemd.

### Brightness Protocols

T1 (HID Feature Reports on Interface 6):
- Report 5: AutoBrightness control
- Report 4: Absolute brightness in nits
- Report 3: Display ON/OFF state

T2: Backlight handled by separate `hid_appletb_bl` kernel driver.

## Installation

Dependencies:
```bash
# Arch/Manjaro
sudo pacman -S dkms gcc libusb

# Debian/Ubuntu
sudo apt install dkms build-essential libusb-1.0-0-dev
```

Install:
```bash
sudo ./install.sh
sudo reboot
```

Status/Uninstall:
```bash
./install.sh status
sudo ./install.sh uninstall
```

## Usage

Display appears as a DRM device, use with tiny-dfr or similar:
```bash
ls /dev/dri/card*
```

Brightness (auto-brightness enabled by default):
```bash
echo 128 | sudo tee /sys/class/backlight/appletb_backlight/brightness
```

## License

GPL-2.0

## Credits

- Kerem Karabay - Original appletbdrm protocol
- t2linux project - Kernel patches
- sunplex07 - T1 support, unified driver, rework.
