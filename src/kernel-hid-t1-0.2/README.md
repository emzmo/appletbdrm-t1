# kernel-hid-t1 — Patched hid-multitouch for T1 iBridge touch input

Provides a DKMS module that adds Apple T1 iBridge (`05ac:8600`) touch
support to the kernel's `hid-multitouch` driver, using the existing
`MT_CLS_APPLE_TOUCHBAR` class (originally for T2's `0x8302`).

## Why vendored source?

DKMS modules must ship their own `.c` source — kernel header packages
(`linux-headers`, `linux-lts-headers`) only include Kconfig and public
headers, not the private `drivers/hid/*.c` files. So we vendor:

- `hid-multitouch.c` — the full driver, with T1 ID added
- `hid-ids.h` — private header with USB device ID defines
- `hid-haptic.h` — private header for haptic touchpad support

## How it works

```
pre_build.sh (DKMS PRE_BUILD hook)
  ├─ 1. Enforces kernel >= 6.11 (needs on_hid_hw_open/close callbacks)
  ├─ 2. Searches for a full kernel source tree (e.g. /usr/src/linux)
  │    ├─ If found: copies in-tree hid-multitouch.c + applies patches/t1-*.patch
  │    │            (always compatible with the running kernel)
  │    └─ If not found: falls back to vendored copies in src/
  └─ 3. DKMS builds the module from the resulting source
```

### Patches

- `patches/t1-ids.patch` — adds `USB_DEVICE_ID_APPLE_IBRIDGE 0x8600` to `hid-ids.h`
- `patches/t1-touch.patch` — adds `mt_devices[]` entry for `0x8600` → `MT_CLS_APPLE_TOUCHBAR`

Both patches are small (4-5 lines each) and use stable context lines.

## Minimum kernel version

**6.11+** — the `on_hid_hw_open`/`on_hid_hw_close` HID driver callbacks
were added in 6.11 and are used by the vendored `hid-multitouch.c`.

## Updating the vendored copy

When a new kernel version is released, sync the vendored source:

```bash
# From a full kernel source tree:
./sync-from-kernel.sh /path/to/linux-source

# From a kernel.org tarball:
./sync-from-kernel.sh --tarball linux-6.19.tar.xz
```

This copies the in-tree files, applies the T1 patches, and writes a
`.vendored_from` stamp file tracking the kernel version.

## Files

```
kernel-hid-t1/
├── dkms.conf              # DKMS config (PRE_BUILD=pre_build.sh)
├── pre_build.sh           # Pre-build hook: version guard + in-tree source detection
├── sync-from-kernel.sh    # Developer tool: regenerate vendored copies
├── Makefile               # Top-level Makefile with kernel version guard
├── patches/
│   ├── t1-ids.patch        # Add USB_DEVICE_ID_APPLE_IBRIDGE to hid-ids.h
│   └── t1-touch.patch      # Add mt_devices[] entry for 0x8600
└── src/
    ├── Makefile            # Kbuild Makefile
    ├── hid-multitouch.c    # Vendored (6.18-era) + T1 patch
    ├── hid-ids.h           # Vendored (6.18-era) + T1 ID
    └── hid-haptic.h        # Vendored (6.18-era)
```

## Further reading

The `docs/` directory at the project root has the full architecture and
research material. For this component specifically see:

- `docs/01-hardware.md` §1.3 (touch digitizer, MT_CLS_APPLE_TOUCHBAR quirk)
- `docs/03-macos-driver-stack.md` §3.3 (HID descriptors, why Config 2 needs no fixup)
- `docs/08-current-codebase-map.md` §8.2 (this module's `file:line` map)
- `docs/09-gaps-and-research-questions.md` §9.6.7 (vendored copy age — open issue)