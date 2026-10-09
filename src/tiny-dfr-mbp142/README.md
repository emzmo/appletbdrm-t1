# tiny-dfr-mbp142

Touch Bar daemon for the **MacBookPro14,2** (T1 chip, 2017). Fork of
[AsahiLinux/tiny-dfr](https://github.com/AsahiLinux/tiny-dfr) — the
most basic dynamic function row daemon — adapted for the T1's
appletbdrm framebuffer path.

## What changed vs upstream

| Change | Why |
|---|---|
| Digitizer name match: `+ "iBridge Touchpad"` | The T1's touch digitizer is named `Apple Inc. iBridge Touchpad` — upstream matches `" Touch Bar"` only, so touches were never bound |
| Resilient `open_card` (60s wait/retry) | The DRM card (`card0-USB-1`) appears LATE: the iBridge starts in USB Config 1 and `ibridge-switcher` flips it to Config 2 during sysinit. Upstream panics instantly if no card exists |
| Flush-stall backoff | The appletbdrm stream goes cold after ~700ms idle; a stalled flush needs an exponential cooldown, not a wedge |
| Renamed paths | `/etc/tiny-dfr-mbp142`, `/usr/share/tiny-dfr-mbp142`, binary `tiny-dfr-mbp142` |
| Adapted systemd unit | No T2 device binds; `Restart=always`; after logind (T1 needs no device units) |
| udev rule: T1 digitizer added | same name-match fix at the rules level |

## Requirements (T1 stack)

The Touch Bar must be exposed as a DRM device first. This requires
(see `../config2/`):

1. `appletbdrm` DKMS driver (kernel 7.2.3 needs the
   `drm_atomic_commit` signature fix — `../config2/appletbdrm-1.2/`)
2. `kernel-hid-t1` DKMS (touch digitizer via hid-multitouch)
3. `ibridge-switcher.service` (flips the iBridge USB Config 1 → 2 at
   sysinit)
4. `tiny-dfr-mbp142.service` + udev rules (this folder's `etc/`)

## Build

```bash
CARGO_TARGET_DIR=/path/on/ext4 cargo build --release
# (do NOT build on the vfat USB drive — noexec)
```

Dependencies: cairo, librsvg, freetype, fontconfig, libinput, udev,
libdrm (all via pacman); rust.

## Config

`/usr/share/tiny-dfr-mbp142/config.toml` (system default) →
`/etc/tiny-dfr-mbp142/config.toml` →
`~/.config/tiny-dfr-mbp142/config.toml` (live-reloaded).

## Dev notes (T1 specifics)

- **Display discovery**: the daemon scans `/dev/dri/card*` and picks
  the first card with a connected connector whose mode has
  `height/width >= 30` (2170x60 → 36). This is how it avoids the
  laptop's eDP panel.
- **Touch input**: libinput on `seat-touchbar` (the udev rules assign
  the digitizer there). The daemon also opens a second libinput
  context on `seat0` for the FN key (layer swap).
- **Stream warmth**: the T1's USB bulk stream stalls if idle >~700ms.
  The daemon's continuous redraw cadence keeps it warm; stalls are
  detected (flush >= 200ms) and backed off exponentially (2s..32s).
- **Sleep**: on S3 the kernel RESETS the iBridge USB device — the
  appletbdrm DRM card disappears and comes back after re-enumeration.
  The daemon must survive the card vanishing (Restart=always +
  resilient open_card). See `../test-results/` for the recovery hook.
- **Camera conflict**: Config 2 has no UVC streaming interface — the
  webcam only works in Config 1. Mutually exclusive with the bar.
- **Brightness**: T1 = HID feature reports on Interface 6 (nits),
  exposed by appletbdrm as `appletb_backlight` (raw, 0-255).

## Upstream divergence checklist

Run `diff -ru` against a pristine AsahiLinux/tiny-dfr clone; our
divergence is exactly:
1. `src/main.rs` — digitizer name match, open_card retry, stall
   backoff, path renames
2. `src/config.rs` — path renames
3. `Cargo.toml` — name/description
4. `etc/` — renamed service + udev rules with T1 digitizer
5. `share/` — renamed config dir

Everything else is upstream verbatim.

## Feature comparison vs macOS TouchBarServer (2026-09-09)

| Feature | macOS (TouchBarServer + DFRDisplay) | tiny-dfr-mbp142 |
|---|---|---|
| DFR bulk protocol | GINF/REDY/CLRD/UDCL/WDSP + DRND/NTBG/CMBK/DMBK/OSUR | GINF/REDY/CLRD/UDCL/WDSP + DRND trigger (NTBG/CMBK/DMBK/OSUR ignored) |
| Init trigger | userspace: proactive GINF on wake (pipes never close) | burst (cold boot) + proactive GINF after 8s silence (re-enum) |
| Rendering | SkyLight compositing, iOSurface, per-app contexts | cairo layers, per-layer config, live-reload |
| Brightness | DFRBrightness dimming-steps (framework) | software dimming + `appletb_backlight` (nits via if6) |
| Sleep/wake | pipes never close; owner just resumes cadence | kernel resets the device; daemon Restart=always + resilient open_card |
| Stream warmth | continuous ~1.5 flushes/s | redraw cadence + stall backoff (2s..32s) |
| Touch ID | SEP channel (if7, KernelRelayHost) | not exposed |
| ALS | if2 sensor-hub (Config 1 only) | not exposed in Config 2 |

### The protocol reference
`../protocol/` documents the bulk protocol; `../macos-evidence/DFR-binaries/`
has Apple's DFRDisplay disassembly (the opcodes + packet switch).

### Linux-specific additions (macOS never needed these)
- proactive GINF after re-enumeration (Linux xhci-hcd resets the device;
  macOS's AppleUSBXHCI preserves endpoint contexts)
- flush-stall backoff (Linux xhci loses endpoint warmth across idle)
- the S3 recovery hook (`../config2/etc/systemd/system-sleep/`)

### Known non-goals
- Touch ID (SEP channel is macOS-private, protocol undocumented)
- ALS auto-brightness in Config 2 (the T1 doesn't expose the sensor
  there; Config 1 exposes it but has no framebuffer)
