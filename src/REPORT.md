Unified Apple Touch Bar Solution — Technical Integration Report
0. Executive Summary
Six projects in ./src/ address overlapping slices of the Apple Touch Bar stack on Linux. Two are kernel-space drivers (DRM framebuffer + HID multitouch), four are userspace daemons/tooling of varying complexity. The goal is a single out-of-source unified project that supports both T1 (2016–2017) and T2 (2018–2020) MacBooks without modifying ./src/.
The analysis below identifies the strongest base for the unified daemon (not-quite-tiny-dfr — it is the most advanced feature-wise and already supports the T2/Apple-Silicon DRM path), and describes how the T1-specific resilience patches from tiny-dfr-mbp142, the unified kernel DRM driver from appletbdrm, the T1 HID multitouch patches from kernel-hid-t1-0.2, and the guided-setup/settings UX from omarchy-touchbar are carried in.
1. Component Breakdown & Extraction Plan
1.1 appletbdrm — Unified DRM Kernel Driver
Core Purpose: A single appletbdrm.ko out-of-tree kernel module that exposes the Touch Bar display as a DRM framebuffer for both T1 (05ac:8600, iBridge, USB Config 2, Interface 3) and T2 (05ac:8302). It implements the proprietary bulk protocol (GINF/REDY/CLRD/UDCL/WDSP/SBTN) and registers a drm_driver with DRIVER_MODESET | DRIVER_GEM | DRIVER_ATOMIC. On T1 it additionally claims USB Interface 6 (HID Usage Page 0xFF12) and registers a backlight_device (appletb_backlight, raw 0–255) driven by HID Feature Reports 3/4/5 (display state, absolute nits, auto-brightness). On T2 it does not register a backlight (T2 backlight is the separate in-tree hid_appletb_bl driver for PID 0x8102).
Key code-level facts:
- appletbdrm.c:1356 appletbdrm_probe — branches on id->idProduct into MAC_TYPE_T1 vs MAC_TYPE_T2; T1 uses async URB + deferred init_work_fn, T2 uses synchronous appletbdrm_probe_t2_sync (appletbdrm.c:883).
- T1 brightness: appletbdrm_t1_set_brightness_nits (appletbdrm.c:538), appletbdrm_t1_disable_autobrightness (appletbdrm.c:506), appletbdrm_t1_read_brightness_caps (appletbdrm.c:476).
- T2 brightness: appletbdrm_t2_set_brightness (appletbdrm.c:591) via SBTN bulk opcode with IEEE-754 float (brightness_to_ieee754, appletbdrm.c:218).
- XRGB8888→BGR888 blit: appletbdrm_xrgb8888_to_bgr888 (appletbdrm.c:295).
- ibridge_switcher.c — userspace libusb tool that flips the T1 iBridge from USB Configuration 1 (DFU) to Configuration 2 (operational); built as ibridge-switcher and run from a systemd oneshot (install.sh:91-137).
What to use (carry over to unified solution):
- appletbdrm.c — the unified DRM/backlight kernel module, used as-is. This is the single kernel display driver for both chip generations.
- ibridge_switcher.c — the T1 USB configuration switcher, needed at boot before the DRM card appears.
- dkms.conf, Makefile — DKMS packaging metadata (referenced/copied by the unified installer; see §2).
- install.sh — reference for the ibridge-switcher systemd unit generation and ordering after macbook-quirks.service; the unified installer will re-author this, but the ordering logic (After=macbook-quirks vs DefaultDependencies=no early-boot path) should be preserved.
What to discard / replace:
- The generated /etc/systemd/system/ibridge-switcher.service content is fine but will be re-emitted by the unified installer under a unified name/dependency graph (see §3).
- The udev rule cleanup (install.sh:164-166) is installer plumbing, not runtime.
1.2 kernel-hid-t1-0.2 — T1 HID Multitouch Driver
Core Purpose: A DKMS module that adds Apple T1 iBridge (05ac:8600) touch-digitizer support to the kernel's hid-multitouch driver by reusing the existing MT_CLS_APPLE_TOUCHBAR touch class (originally for T2's 0x8302). Because DKMS modules must ship their own .c source (kernel header packages don't include drivers/hid/*.c), it vendors hid-multitouch.c, hid-ids.h, hid-haptic.h and applies two tiny patches:
- patches/t1-ids.patch — adds #define USB_DEVICE_ID_APPLE_IBRIDGE 0x8600 to hid-ids.h.
- patches/t1-touch.patch — adds an mt_devices[] entry mapping 0x8600 → MT_CLS_APPLE_TOUCHBAR.
pre_build.sh enforces kernel ≥ 6.11 (needs on_hid_hw_open/on_hid_hw_close callbacks), prefers patching a full in-tree source tree if available (/usr/src/linux*, /usr/lib/modules/$ver/source), and falls back to the vendored 6.18-era copy. sync-from-kernel.sh is a developer tool to refresh the vendored copy.
What to use:
- dkms.conf, Makefile, pre_build.sh — the DKMS build hook with the kernel-version guard and in-tree-source detection. Used as-is (the unified installer registers this DKMS module unchanged).
- patches/t1-ids.patch, patches/t1-touch.patch — the actual T1 touch quirk; used as-is.
- src/{hid-multitouch.c,hid-ids.h,hid-haptic.h} — vendored fallback sources; used as-is (read-only fallback path in pre_build.sh).
- sync-from-kernel.sh — developer/maintenance tool for refreshing the vendored copy; documented in the unified project but not run at install time.
What to discard / replace:
- Nothing. This module is purely additive (a DKMS-built hid-multitouch.ko replacement that superset-adds the T1 ID). It coexists with appletbdrm.ko — they bind different USB interfaces of the same physical device.
1.3 tiny-dfr — Basic Userspace DFR Daemon (T2 / Apple Silicon)
Core Purpose: The original AsahiLinux tiny-dfr — a Rust daemon that opens the Touch Bar DRM card (/dev/dri/card*, aspect-ratio heuristic height/width >= 30), renders an Esc + F1–F12 / media-key layer with cairo + librsvg + freetype/fontconfig, reads touch input via libinput on seat-touchbar, emits virtual key events via uinput, and manages backlight (BacklightManager with adaptive brightness, lid switch, dim/off timeouts). Config is TOML, live-reloaded via inotify. Privileges are dropped to nobody:input,video.
Key files: src/main.rs (monolithic ~1058 lines: Button, FunctionLayer, input loop, uinput), src/display.rs (DrmBackend), src/config.rs, src/backlight.rs, src/pixel_shift.rs, src/fonts.rs (raw FFI to fontconfig), build.rs (pkg-config fontconfig).
What to use:
- As the conceptual baseline / reference for the minimal feature set. The unified daemon inherits tiny-dfr's architecture (DRM dumb-buffer + atomic commit, libinput seat split, uinput virtual keyboard, inotify live-reload) through not-quite-tiny-dfr, which is a strict superset fork of it.
- etc/udev/rules.d/99-touchbar-seat.rules — the seat-touchbar assignment rule (DRM + input device names). The unified rule set is derived from this (see §3).
- etc/systemd/system/systemd-backlight@*.service (empty drop-ins disabling systemd-backlight for appletb_backlight and 228200000.display-pipe.0) — carry over to prevent systemd-backlight fighting the daemon.
What to discard:
- src/* — entirely superseded by not-quite-tiny-dfr's refactored, feature-richer versions (see §1.5). Keeping tiny-dfr's monolithic main.rs would forfeit widgets, sliders, media, CPU/GPU, scrollable layers, layer swipe, Pango text, soft-dimming, T1 stall backoff, and user-config detection.
- etc/udev/rules.d/99-touchbar-tiny-dfr.rules — superseded by the unified rule (different SYSTEMD_WANTS target, plus T1 digitizer names added from the mbp142 fork).
- etc/systemd/system/tiny-dfr.service — superseded by the unified service unit.
Note: tiny-dfr/CLAUDE.md (symlinked as AGENTS.md) contains a notice asserting that automated agents are not authorized to modify/analyze that repository. This report is a read-only analysis performed at your request for your own out-of-source integration project; it does not modify, fork, or generate contributions into tiny-dfr. The unified solution will not vendor tiny-dfr's source — it uses not-quite-tiny-dfr as the daemon base instead (§2).
1.4 tiny-dfr-mbp142 — T1-Adapted Fork of tiny-dfr
Core Purpose: A fork of tiny-dfr specifically adapted for the MacBookPro14,2 (T1, 2017) running through appletbdrm. The delta vs upstream is small and precisely documented in its README:
1. Digitizer name match (src/main.rs:1041-1047): matches "iBridge Touchpad" in addition to " Touch Bar", because the T1's touch digitizer is named Apple Inc. iBridge Touchpad (upstream only matched the T2's Apple Inc. Touch Bar Display Touchpad).
2. Resilient open_card (src/main.rs:818-841): retries for up to 60s (30 × 2s) because the DRM card appears late — ibridge-switcher flips USB Config 1→2 at sysinit, and only then does appletbdrm probe.
3. Flush-stall backoff (src/main.rs:866-873, 1004-1020): the appletbdrm USB bulk stream goes cold after ~700ms idle; a drm.dirty() flush taking ≥200ms is a stall, backed off exponentially (2s → 32s, FLUSH_STALL_MAX_DOUBLINGS=4).
4. Path renames (src/config.rs:17, src/main.rs:166-169): /etc/tiny-dfr-mbp142, /usr/share/tiny-dfr-mbp142, binary tiny-dfr-mbp142.
5. Adapted systemd unit (etc/systemd/system/tiny-dfr-mbp142.service): no T2 device-unit binds, Restart=always, After=systemd-logind.service.
6. udev rule (etc/udev/rules.d/99-touchbar-tiny-dfr-mbp142.rules): adds Apple Inc. iBridge Touchpad to SYSTEMD_WANTS.
Everything else is byte-identical to upstream tiny-dfr.
What to use (the critical T1 resilience patches):
- Digitizer name match — the unified daemon's touch-device discovery must match both " Touch Bar" (T2) and "iBridge Touchpad" (T1). This is a ~2-line logic change to carry into the unified main.rs.
- Resilient open_card (60s retry loop) — the unified daemon must wait for the late-appearing T1 DRM card. This loop becomes the T1 path of a chip-detection branch (§2.3).
- Flush-stall backoff — the unified daemon needs this on T1. not-quite-tiny-dfr already has an equivalent (its FLUSH_STALL_MIN/FLUSH_COOLDOWN_BASE/FLUSH_STALL_MAX_DOUBLINGS constants and heartbeat logic in src/main.rs:199-216), so the mbp142 patch is subsumed by nqtd's more complete implementation. Verify nqtd's stall logic is enabled on the T1 path (it is currently T2-measured but protocol-identical).
- udev rule: T1 digitizer name — the Apple Inc. iBridge Touchpad SYSTEMD_WANTS line must appear in the unified udev rule set (§3).
What to discard:
- The standalone fork itself is not kept — its deltas are absorbed into the unified daemon and unified udev rules. The path renames (tiny-dfr-mbp142 → unified name) are not carried; the unified project has its own name.
- src/display.rs, src/backlight.rs, src/pixel_shift.rs, src/fonts.rs, src/config.rs (except the path constant) — identical to upstream tiny-dfr, and all superseded by not-quite-tiny-dfr's versions.
1.5 not-quite-tiny-dfr — Enhanced Userspace DFR Daemon (the unified daemon base)
Core Purpose: A heavily-extended fork of tiny-dfr — the most advanced daemon in the set. It is a Rust crate (Cargo.toml, edition = "2021") with a clean module split:
Module	Role
src/main.rs	Event loop, FunctionLayer, touch state machine (tap/hold/scroll/fling/layer-swipe/slider-drag), frame pacing (60Hz VRR-style), flush-stall backoff, keep-warm heartbeat, user login detection, privilege drop
src/display.rs	DrmBackend — identical DRM dumb-buffer + atomic commit path to tiny-dfr (aspect-ratio card discovery)
src/config.rs	TOML config with cascading layers (/usr/share → /etc → ~/.config), [Style] table, Layers freeform, live-reload via directory-watch inotify (survives atomic-rename saves), error banner layer
src/backlight.rs	BacklightManager with configurable dim_timeout/off_timeout, adaptive brightness, lid switch, software dimming (10 geometric levels, eased), TouchBarBrightnessUp/Down buttons with hold-to-repeat
src/button.rs	Button/ButtonImage variants: Text, Svg, Bitmap, Time, Battery, Cpu, Gpu, Slider, Media, Command (script widget), Spacer. CachedSvg rasterizes once per size. ExpandState tap-to-expand animation
src/render.rs	Cairo/Pango drawing primitives, rounded-rect, capsule, media panel (album cover, transport, synced lyrics), box blur
src/widget.rs	WidgetRuntime — worker threads polling shell commands (command widgets + slider get/set/mute), coalesced slider sets, wake-pipe to main loop
src/style.rs	Color (hex parser), Style (fonts, colors, spacing, background image), StyleProxy merge
src/sensors.rs	Battery/CPU-temp/CPU-power(GPU) sysfs pollers; RAPL energy_uj (root-only, opened pre-drop); cached in Mutex statics
src/gpu.rs	AMD/NVIDIA/Intel GPU detection via /sys/class/drm; hwmon or nvidia-smi
src/media.rs	MPRIS via playerctl; album art decode (image crate), synced lyrics
src/uinput.rs	Interface (libinput), create_uinput, toggle_keys (handles TouchBarBrightnessUp/Down internally)
src/user.rs	resolve_target_user — NOT_QUITE_TINY_DFR_USER env or logind seat0 active Class=user session
src/pixel_shift.rs	Same as tiny-dfr
Notable advanced features: scrollable layers with fling/snap/rubber-band, two-finger layer swipe with pinned-Esc, tap-to-expand sliders, command widgets (JSON {"text","color","icon"} protocol), CPU/GPU temp+watts widgets, media widget with album art + synced lyrics, background image with blur, per-button color overrides, Pango text (per-glyph fallback, emoji), 60Hz frame pacing, keep-warm heartbeat (150ms) to avoid the appletbdrm cold-stream wedge, flush-stall exponential backoff.
It already supports the T2/Apple-Silicon DRM path. Its display.rs is byte-identical to tiny-dfr's (same aspect-ratio card discovery, no T1 retry). Its udev rules and systemd unit target T2 only (no iBridge Touchpad name, device-unit binds).
What to use — this is the unified daemon's code base. All of src/*.rs is carried over, with the following T1 integration modifications applied as a thin adapter layer (see §2 for how, respecting read-only ./src/):
- T1 digitizer name match: merge the mbp142 "iBridge Touchpad" match into the touch-device-added handler (in nqtd this lives in main.rs where dev.name() is checked — the event loop's Event::Device(DeviceEvent::Added(...)) arm).
- T1 resilient card open: wrap DrmBackend::open_card() with the mbp142 60s retry loop on the T1 path (chip-detection gate, §2.3).
- T1 backlight device name: nqtd's backlight.rs find_backlight() already matches appletb_backlight (backlight.rs:70), so T1 brightness sysfs path works unchanged. The T1's appletbdrm-registered appletb_backlight (raw 0–255, via HID Feature Reports) is the same sysfs interface nqtd expects.
- T1 flush-stall + heartbeat: nqtd already implements both (main.rs:199-216); confirm the heartbeat is active on T1 (the stream-cold behavior is protocol-identical on T1 per the mbp142 README).
- T1 udev/systemd: the unified rule set and service unit must include the T1 digitizer name and not require T2-only device units (§3).
What to discard:
- etc/udev/rules.d/99-touchbar-not-quite-tiny-dfr.rules — superseded by the unified rule (adds T1 digitizer, unified service name).
- etc/systemd/system/not-quite-tiny-dfr.service — superseded by the unified service unit (T1-friendly ordering, no hard T2 device binds).
- nix/, flake.nix, flake.lock — Nix-specific packaging; carry only if the unified project ships Nix support.
- share/not-quite-tiny-dfr/widgets/*.sh (battery.sh, battery_eta.sh, weather.sh) — example widget scripts; ship as optional examples under the unified share dir.
1.6 omarchy-touchbar — Settings UI + Guided Setup (Python/GTK)
Core Purpose: An Omarchy desktop plugin (Python 3.11+, GTK4/libadwaita, QML bar widget) that provides:
1. Hardware routing (hardware.py): maps DMI product_name → t1 / t2 / unsupported via hardcoded model lists (T1_MODELS, T2_MODELS), and checks t2_transport_ready() (/sys/module/t2bce_vhci or apple_bce).
2. Guided setup (setup.py): T1 path installs t1bridge (a different, Standard Agents T1 driver stack — not appletbdrm+kernel-hid-t1), adds the signed standardagents pacman repo, verifies GPG key, adds user to t1bridge group, writes a usbmuxd override (/etc/udev/rules.d/39-usbmuxd.rules) to exclude the internal T1 (05ac:8600) from usbmuxd's iPhone classification. T2 path installs tiny-dfr from Arch repos.
3. T2 settings panel (app/t2_panel.py): GTK4/Adw window to toggle MediaLayerDefault in /etc/tiny-dfr/config.toml, preserving other settings (t2.py's set_media_default regex-based TOML editor).
4. T1 custom renderer (app/renderer.py, app/layout.py, app/drawing.py, app/protocol.py): a Python/Cairo renderer that talks to T1Bridge's IPC socket (/run/t1bridge/touchbar.sock, T1HW protocol v1) — not the DRM framebuffer. It renders sliders, workspaces, media, Omarchy menu, Fn keys, and runs as a user systemd service (t1-touchbar.service) via a renderer-selection symlink.
5. T1 settings panel (app/panel.py): GTK4/Adw window to show/hide/reorder shortcuts, toggle media + keyboard brightness, enable/disable the custom renderer.
6. Window rules (windows.py): installs a scoped Hyprland Lua window rule (float + center) for me.kerim.OmarchyTouchBar.
7. Desktop provider (app/desktop-provider.py, app/desktop.py): unprivileged Pactl/MPRIS/Hyprland/Wayland adapter for volume/media/brightness/workspace/OSD.
What to use:
- hardware.py — the DMI model → backend routing logic (T1_MODELS, T2_MODELS, backend_for(), model_name(), t2_transport_ready()). This is the canonical chip-detection table; the unified project's installer and the daemon's runtime chip-detection both consult it (or a Rust port of it — see §2.3).
- t2.py — the set_media_default TOML-preserving editor, if the unified settings UI exposes a MediaLayerDefault toggle. Reusable as-is (it edits /etc/tiny-dfr/config.toml; the unified project would retarget it to the unified config path).
- app/panel.py + app/t2_panel.py — the GTK4/Adw settings panels, as the reference UX for the unified settings app. The T1 panel's shortcut-show/hide/reorder + media/keyboard toggles + enable/disable-custom-renderer flow maps directly onto the unified daemon's config (which already supports per-button visibility via Layers). The T2 panel's MediaLayerDefault combo is a trivial subset.
- app/drawing.py — the hand-drawn Cairo vector icons (volume, brightness, keyboard, workspaces, camera, bell, previous/next/play, back) are a self-contained icon set usable as fallback SVGs in the unified share dir (they're currently drawn procedurally; converting to SVG or shipping as a Python-rendered preview is straightforward).
- app/preferences.py — the validated, atomic JSON preferences pattern (temp-file + fsync + rename) is a good model for the unified settings store if one is needed beyond TOML.
- windows.py — the Hyprland window-rule installer pattern (backup + reload + rollback on config error) is reusable if the unified project ships a floating settings window on Hyprland/Omarchy.
- setup.py's usbmuxd override logic (usbmux_override(), MARKER, the 39-usbmuxd.rules generation) — critical T1 coexistence fix: without it, usbmuxd classifies the internal T1 as an iPhone and clears its USB config at boot, breaking the Touch Bar. The unified installer must ship this override. The GPG key verification (verify_key) and standardagents repo logic is T1Bridge-specific and not carried if the unified project uses appletbdrm+kernel-hid-t1 instead of T1Bridge (see "What to discard" below).
What to discard:
- app/renderer.py, app/layout.py, app/drawing.py (as a runtime renderer), app/protocol.py, app/desktop.py, app/desktop-provider.py — the T1Bridge-IPC Python renderer. The unified project uses the DRM framebuffer path via the Rust daemon (not-quite-tiny-dfr), not T1Bridge's T1HW socket protocol. These files are a different rendering architecture (userspace IPC to a proprietary broker vs. direct DRM). They are useful as UX/icon reference only.
- setup.py's T1Bridge-specific installation (signed standardagents repo, t1bridge/t1bridge-dkms packages, t1bridge group, t1-touchbar-hw.service, t1-touchbar.service, fprintd-t1bridge). The unified project replaces this with appletbdrm DKMS + kernel-hid-t1 DKMS + ibridge-switcher (from appletbdrm/install.sh). The T1Bridge stack and the appletbdrm+kernel-hid-t1 stack are mutually exclusive (setup.py:148-150 explicitly refuses macbookpro-t1-touchbar-dkms / apple-ibridge-dkms-git).
- manifest.json, BarWidget.qml, Panel.qml — Omarchy plugin manifest and QML; specific to the Omarchy plugin shell. Not part of the unified daemon. (The unified project could optionally ship an Omarchy plugin wrapper, but that's a packaging concern, not a core component.)
- control.py — Omarchy plugin CLI glue (status/enable/disable/setup/diagnostics/media/function/restart); the unified project has its own CLI/installer. The status health-check pattern (checking DRM card, group membership, service active, config readable) is a good reference.
2. Integration Strategy (Read-Only ./src/)
./src/ remains strictly read-only. The unified project lives in a sibling directory (e.g. ../unified-touchbar/ or a separate repo root). The strategy differs for kernel-space vs. userspace components.
2.1 Kernel-Space Components (appletbdrm, kernel-hid-t1-0.2)
These are DKMS modules — they are built against the running kernel's headers and installed into /usr/src/<name>-<ver>/ by dkms add. They are not compiled into the unified project's binary. The integration is at the packaging/installer level, not the source level:
- The unified project's installer copies the DKMS source trees verbatim from ./src/appletbdrm/{appletbdrm.c,Makefile,dkms.conf,ibridge_switcher.c} and ./src/kernel-hid-t1-0.2/{dkms.conf,Makefile,pre_build.sh,patches/,src/} into /usr/src/appletbdrm-1.2/ and /usr/src/kernel-hid-t1-0.2/ respectively, then runs dkms add/build/install for each.
- Because this is a file copy at install time (not a compile-time dependency), the read-only constraint is respected: ./src/ is the source of truth, the installer reads from it, and the DKMS trees in /usr/src/ are the build copies.
- ibridge_switcher.c is compiled as a standalone userspace binary (gcc -o ibridge-switcher ibridge_switcher.c -lusb-1.0) by the unified installer, not linked into the daemon.
- No #include of kernel source from the unified project — the kernel modules are self-contained and built by DKMS independently.
Alternative (symlink-based): the installer could symlink /usr/src/appletbdrm-1.2/ → ./src/appletbdrm/ if ./src/ is guaranteed to persist on the build machine. This is fragile (a git clean in ./src/ breaks DKMS) and not recommended; the copy approach is standard for DKMS.
2.2 Userspace Daemon (not-quite-tiny-dfr as the base)
The unified daemon is a Rust crate that depends on not-quite-tiny-dfr's source. Since ./src/ is read-only and we must not vendor-and-modify the source in place, the options are:
Option A — Cargo path dependency (recommended):
The unified project's Cargo.toml declares not-quite-tiny-dfr as a path dependency pointing into ./src/:
[dependencies]
not-quite-tiny-dfr = { path = "../src/not-quite-tiny-dfr" }
However, not-quite-tiny-dfr is a binary crate (src/main.rs with fn main()), not a library. To use it as a dependency, the unified project would need nqtd to expose a library target (lib.rs). Since we cannot modify ./src/, this requires either:
- A thin wrapper crate in the unified project that include!()s or mod-references nqtd's source files via relative paths (e.g. #[path = "../../src/not-quite-tiny-dfr/src/display.rs"] mod display;). This works because Rust's #[path] attribute can point outside the crate root. The wrapper then adds the T1-specific patches (digitizer name, card-retry) in its own main.rs that calls into the referenced modules.
- Or a build-time source copy (build.rs copies ./src/not-quite-tiny-dfr/src/*.rs into OUT_DIR, applies a patch file with the T1 deltas, and the unified crate compiles the patched copy). This is cleaner and keeps ./src/ untouched.
Option B — Git submodule + patch (if ./src/ are git clones):
Each project in ./src/ has a .git/ directory. The unified project could submodule-reference not-quite-tiny-dfr at a pinned commit and apply a .patch file (the T1 deltas) at build time via build.rs. This is the cleanest for reproducibility and upstream tracking, but requires the upstream repos to be publicly available at those commits.
Option C — Fork (if modification is acceptable outside ./src/):
Copy ./src/not-quite-tiny-dfr/ into the unified project's directory (outside ./src/), rename to the unified name, and apply the T1 patches directly. This is the simplest and most pragmatic, but diverges from upstream and requires manual re-syncing. This is the approach used by tiny-dfr-mbp142 itself (it's a fork with a documented divergence checklist).
Recommended: Option B (submodule + patch) if git history matters, else Option C (fork-in-place). Option A's #[path] trick is clever but brittle across Rust editions and refactors. Given that the T1 deltas are small (~30 lines across 2-3 sites), a patch file is maintainable and reviewable.
2.3 T1/T2 Dynamic Routing in the Daemon
The unified daemon auto-detects the chip at startup and branches accordingly. Detection is via the DRM card's driver name or USB ID, not DMI (the daemon must work even when DMI is unavailable):
1. DRM card discovery (display.rs::DrmBackend::open_card): scan /dev/dri/card*, open each, find a connected connector with height/width >= 30 (Touch Bar aspect ratio). The matched card's driver name is read from /sys/class/drm/<card>/device/driver → appletbdrm (both T1 and T2) or adp (Apple Silicon). This distinguishes Touch Bar from Apple Silicon DFR.
2. T1 vs T2 discrimination: read the USB ID of the device behind the DRM card: /sys/class/drm/<card>/device/idProduct → 0x8600 (T1) or 0x8302 (T2). Alternatively, check for the existence of appletb_backlight registered by appletbdrm (T1 only — T2 backlight is hid_appletb_bl for PID 0x8102, a different USB interface).
3. T1 path: if T1, wrap open_card with the 60s retry loop (from tiny-dfr-mbp142); match "iBridge Touchpad" in the digitizer name; enable the flush-stall backoff and heartbeat (already in nqtd).
4. T2 path: if T2, use the existing nqtd behavior (immediate open_card, " Touch Bar" digitizer match). The T2 USB config switch (bConfigurationValue 1→2) is handled by the udev rule, not the daemon.
5. Apple Silicon path: if adp driver, use the existing nqtd behavior (the adp DRM driver is for Apple Silicon DFR, which nqtd already supports).
The routing is a runtime enum ChipType { T1, T2, AppleSilicon } resolved once at startup and stored in the daemon state; all chip-specific branches key off it. No recompilation is needed to switch chips.
2.4 Userspace Settings UI + Installer (from omarchy-touchbar)
The Python/GTK settings app and installer are independent scripts that run outside the daemon process. They are integrated by:
- Copying the relevant .py files into the unified project's directory (outside ./src/), retargeting paths (/etc/tiny-dfr/config.toml → /etc/<unified-name>/config.toml, t1bridge → appletbdrm+kernel-hid-t1 install steps, t1-touchbar.service → unified service).
- The hardware.py model table is reused verbatim (it's pure data + 3 functions).
- The setup.py T1 install path is rewritten to install appletbdrm DKMS + kernel-hid-t1 DKMS + ibridge-switcher (from ./src/appletbdrm/install.sh's logic) instead of T1Bridge. The usbmuxd override (usbmux_override()) is reused as-is. The GPG/repo logic for standardagents is dropped.
- The settings panels (panel.py, t2_panel.py) are retargeted to the unified config path and service name. The T1 panel's "enable custom renderer" flow (symlink-based renderer selection) is dropped — the unified daemon is always the renderer; the panel instead toggles config options (shortcut visibility, media, keyboard brightness) that the daemon live-reloads via inotify.
3. Dependency & Conflict Analysis
3.1 Shared Resources the Projects Fight Over
Resource	appletbdrm	kernel-hid-t1	tiny-dfr	tiny-dfr-mbp142	not-quite-tiny-dfr	omarchy-touchbar
DRM card /dev/dri/card*	Registers appletbdrm driver (T1+T2)	—	Opens first Touch-Bar-shaped card	Opens first Touch-Bar-shaped card	Opens first Touch-Bar-shaped card	Checks /dev/dri/touchbar (T1Bridge)
/sys/class/backlight/appletb_backlight	Registers (T1 only)	—	Writes brightness (adaptive dim)	Writes brightness	Writes brightness	—
/sys/class/backlight/{228200000.display-pipe.0, 228600000.dsi.0}	—	—	Writes (T2/AS)	Writes (T2/AS)	Writes (T2/AS)	—
seat-touchbar (udev)	—	—	Rule: DRM adp|appletbdrm + input names	Same + iBridge Touchpad	Same as tiny-dfr (no T1 name)	—
/dev/uinput	—	—	Opens (root, pre-drop)	Opens (root, pre-drop)	Opens (root, pre-drop)	—
libinput seat0	—	—	FN key (layer swap)	FN key	FN key + gestures	—
libinput seat-touchbar	—	—	Touch digitizer	Touch digitizer (T1 name)	Touch digitizer	—
Config path	—	—	/etc/tiny-dfr/config.toml	/etc/tiny-dfr-mbp142/config.toml	/etc/not-quite-tiny-dfr/config.toml + ~/.config/	/etc/tiny-dfr/config.toml (T2) + ~/.config/t1bridge/ (T1)
Share dir	—	—	/usr/share/tiny-dfr/	/usr/share/tiny-dfr-mbp142/	/usr/share/not-quite-tiny-dfr/	—
systemd service	ibridge-switcher.service (generated)	—	tiny-dfr.service (device-triggered)	tiny-dfr-mbp142.service (Restart=always)	not-quite-tiny-dfr.service (Restart=always)	t1-touchbar.service (user, T1Bridge)
udev SYSTEMD_WANTS	—	—	tiny-dfr.service	tiny-dfr-mbp142.service	not-quite-tiny-dfr.service	—
systemd-backlight drop-ins	—	—	Disables for appletb_backlight + display-pipe.0	Same	Same	—
USB Config switch (T2 0x8302)	—	—	udev: bConfigurationValue 1→2	udev: same	udev: same	—
USB Config switch (T1 0x8600)	ibridge-switcher.service (libusb)	—	—	(relies on switcher)	—	T1Bridge handles it
usbmuxd override	—	—	—	—	—	/etc/udev/rules.d/39-usbmuxd.rules (excludes 05ac:8600)
Conflicts if multiple are installed simultaneously:
- tiny-dfr + tiny-dfr-mbp142 + not-quite-tiny-dfr all fight over the same DRM card, /dev/uinput, seat-touchbar, and appletb_backlight. Only one can hold the DRM master lock (acquire_master_lock() in display.rs). Their udev rules have different SYSTEMD_WANTS targets, so installing two would cause both services to be triggered. The unified project installs exactly one daemon and one set of udev rules.
- appletbdrm + omarchy-touchbar's T1Bridge are mutually exclusive driver stacks for the T1. setup.py:148-150 refuses macbookpro-t1-touchbar-dkms / apple-ibridge-dkms-git. The unified project uses appletbdrm + kernel-hid-t1, not T1Bridge.
- ibridge-switcher (appletbdrm) vs usbmuxd: without the usbmuxd override (omarchy-touchbar's 39-usbmuxd.rules), usbmuxd reclassifies the T1 (05ac:8600) as an iPhone and resets its USB config, undoing ibridge-switcher's Config 2 switch. The unified installer must ship the usbmuxd override.
3.2 Kernel → Userspace Exposure
The kernel-space drivers expose themselves to userspace daemons through three channels:
1. DRM device (/dev/dri/card*): appletbdrm registers a drm_driver (appletbdrm.c:1269-1277) with DRIVER_MODESET | DRIVER_GEM | DRIVER_ATOMIC. The DRM card appears under /dev/dri/cardN and /sys/class/drm/cardN/. The udev rule matches SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DRIVERS=="adp|appletbdrm" to tag it for seat-touchbar and SYSTEMD_WANTS. The daemon opens it RW, acquires DRM master, creates a dumb buffer, and commits it atomically. The driver accepts XRGB8888 (emulated, converted to BGR888 in-kernel via appletbdrm_xrgb8888_to_bgr888) and BGR888 framebuffers.
2. Backlight sysfs (/sys/class/backlight/appletb_backlight/): T1 only — appletbdrm registers a backlight_device (appletbdrm.c:774-803) with BACKLIGHT_RAW, max_brightness=255. The daemon writes brightness and reads max_brightness/brightness. T2 backlight is the in-tree hid_appletb_bl driver (for PID 0x8102), exposing the same sysfs interface under a different name (appletb_backlight via hid-appletb-bl driver). The daemon's find_backlight() matches both.
3. HID input device (/dev/input/event*): kernel-hid-t1's patched hid-multitouch exposes the T1 touch digitizer as a multitouch input device named Apple Inc. iBridge Touchpad (T1) or Apple Inc. Touch Bar Display Touchpad (T2). The udev rule assigns it to seat-touchbar; the daemon's libinput context on seat-touchbar reads touch events. The FN key comes from seat0 (the laptop keyboard). The daemon creates a virtual keyboard via /dev/uinput to emit key events for button presses.
3.3 Unified Rule/Service Resolution
The unified project ships a single consolidated udev rule and single systemd service that subsume all three daemons' rules:
Unified udev rule (99-touchbar-unified.rules):
# T2 USB config switch (0x8302)
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="8302", \
  ATTR{bConfigurationValue}=="1", ATTR{bConfigurationValue}="0", ATTR{bConfigurationValue}="2"

# Touch digitizer → seat-touchbar + start daemon (T1 + T2 + Apple Silicon names)
SUBSYSTEM=="input", ATTR{name}=="Apple Inc. iBridge Touchpad", ENV{ID_SEAT}="seat-touchbar", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="unified-touchbar.service"
SUBSYSTEM=="input", ATTR{name}=="Apple Inc. Touch Bar Display Touchpad", ENV{ID_SEAT}="seat-touchbar", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="unified-touchbar.service"
SUBSYSTEM=="input", ATTR{name}=="MacBookPro17,1 Touch Bar", ENV{ID_SEAT}="seat-touchbar", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="unified-touchbar.service"
SUBSYSTEM=="input", ATTR{name}=="Mac14,7 Touch Bar", ENV{ID_SEAT}="seat-touchbar", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="unified-touchbar.service"

# DRM card → seat-touchbar (not master-of-seat)
SUBSYSTEM=="drm", KERNEL=="card*", DRIVERS=="adp|appletbdrm", \
  TAG-="master-of-seat", ENV{ID_SEAT}="seat-touchbar"

# Backlight aliases (T1 appletbdrm + T2 hid-appletb-bl + Apple Silicon)
SUBSYSTEM=="backlight", KERNEL=="appletb_backlight", TAG+="systemd", \
  ENV{SYSTEMD_ALIAS}="/dev/unified_touchbar_backlight"
SUBSYSTEM=="backlight", KERNEL=="228200000.display-pipe.0", DRIVERS=="panel-summit", \
  TAG+="systemd", ENV{SYSTEMD_ALIAS}="/dev/unified_touchbar_backlight"
SUBSYSTEM=="backlight", KERNELS=="228600000.dsi.0", DRIVERS=="panel-summit", \
  TAG+="systemd", ENV{SYSTEMD_ALIAS}="/dev/unified_touchbar_backlight"
# Display backlight (for adaptive brightness)
SUBSYSTEM=="backlight", KERNEL=="apple-panel-bl|gmux_backlight|intel_backlight|acpi_video0", \
  TAG+="systemd", ENV{SYSTEMD_ALIAS}="/dev/unified_touchbar_display_backlight"
Unified systemd service (unified-touchbar.service):
[Unit]
Description=Unified Apple Touch Bar daemon (T1/T2/Apple Silicon)
# No hard device-unit binds: daemon scans /dev/dri and retries (T1 card appears late).
After=systemd-logind.service systemd-user-sessions.service ibridge-switcher.service
Wants=ibridge-switcher.service

[Service]
ExecStart=/usr/bin/unified-touchbar
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
PrivateIPC=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=strict
RestrictAddressFamilies=AF_UNIX AF_NETLINK AF_INET AF_INET6
CacheDirectory=unified-touchbar
RestrictNamespaces=true
RestrictSUIDSGID=true

[Install]
WantedBy=graphical.target
T1-specific systemd service (ibridge-switcher.service) — carried from appletbdrm/install.sh:91-137, installed alongside the unified daemon service. Ordered Before=unified-touchbar.service so the DRM card is available before the daemon starts its 60s card-wait.
systemd-backlight disable drop-ins — carried from tiny-dfr/etc/systemd/system/systemd-backlight@backlight:appletb_backlight.service (empty file) to prevent systemd-backlight from restoring/fighting the daemon's brightness.
4. Proposed Unified Architecture (High-Level)
                         HARDWARE LAYER
 ┌─────────────────────────────────────────────────────────────────┐
 │                    Apple Touch Bar (T1/T2)                      │
 │   USB Device 05ac:8600 (T1 iBridge)  /  05ac:8302 (T2 iBridge) │
 └──────────────┬───────────────────────────────┬──────────────────┘
                │ USB Config 2 (T1: switched     │ USB Config 2 (T2: udev
                │ by ibridge-switcher at boot)   │  rule forces 1→2 at hotplug)
                ▼                                ▼
 ╔════════════════════════════════════════════════════════════════════╗
 ║                    KERNEL SPACE (DKMS modules)                     ║
 ║                                                                    ║
 ║  ┌─────────────────────────────┐   ┌────────────────────────────┐  ║
 ║  │    appletbdrm.ko            │   │  hid-multitouch.ko         │  ║
 ║  │  (from ./src/appletbdrm)    │   │  (from ./src/kernel-hid-   │  ║
 ║  │                             │   │   t1-0.2, patched)         │  ║
 ║  │  • DRM framebuffer driver   │   │  • MT_CLS_APPLE_TOUCHBAR   │  ║
 ║  │    (T1 if3 + T2 if-class)   │   │  • T1: 0x8600 added        │  ║
 ║  │  • Bulk protocol:           │   │  • T2: 0x8302 (in-tree)    │  ║
 ║  │    GINF/REDY/CLRD/UDCL/     │   │                            │  ║
 ║  │    WDSP/SBTN                │   │  Exposes:                  │  ║
 ║  │  • XRGB8888→BGR888 blit     │   │  /dev/input/eventN         │  ║
 ║  │                             │   │  (multitouch digitizer)    │  ║
 ║  │  T1 only:                   │   │  Name: "Apple Inc.         │  ║
 ║  │  • Claims USB if6 (HID)     │   │   iBridge Touchpad" (T1) / │  ║
 ║  │  • backlight_device:        │   │   "Touch Bar Display       │  ║
 ║  │    appletb_backlight        │   │   Touchpad" (T2)           │  ║
 ║  │    (Feature Reports 3/4/5,  │   │  → seat-touchbar (udev)    │  ║
 ║  │     nits, auto-brightness)  │   │                            │  ║
 ║  │                             │   │                            │  ║
 ║  │  T2: no backlight (left to │   │                            │  ║
 ║  │      in-tree hid_appletb_bl)│   │                            │  ║
 ║  │                             │   │                            │  ║
 ║  │  Exposes:                   │   │                            │  ║
 ║  │  /dev/dri/cardN             │   │                            │  ║
 ║  │  /sys/class/backlight/      │   │                            │  ║
 ║  │   appletb_backlight (T1)    │   │                            │  ║
 ║  │  /sys/class/backlight/      │   │                            │  ║
 ║  │   appletb_backlight (T2,    │   │                            │  ║
 ║  │    via hid_appletb_bl)      │   │                            │  ║
 ║  └──────────────┬──────────────┘   └─────────────┬──────────────┘  ║
 ╚═════════════════╪═══════════════════════════════╪═════════════════╝
                   │ DRM + sysfs                     │ evdev/libinput
                   ▼                                 ▼
 ╔════════════════════════════════════════════════════════════════════╗
 ║                  USERSPACE: UNIFIED DAEMON (Rust)                  ║
 ║           (based on not-quite-tiny-dfr + T1 patches from           ║
 ║            tiny-dfr-mbp142, all sourced read-only from ./src/)     ║
 ║                                                                    ║
 ║  ┌──────────────────────────────────────────────────────────────┐  ║
 ║  │  STARTUP: Chip Detection                                     │  ║
 ║  │  1. Scan /dev/dri/card* for aspect-ratio >= 30 (Touch Bar)   │  ║
 ║  │  2. Read /sys/class/drm/<card>/device/idProduct              │  ║
 ║  │     → 0x8600 = T1, 0x8302 = T2, adp = Apple Silicon          │  ║
 ║  │  3. T1: wrap open_card with 60s retry (from mbp142)          │  ║
 ║  │     T2/AS: open immediately (nqtd behavior)                  │  ║
 ║  └──────────────────────────────────────────────────────────────┘  ║
 ║                                │                                   ║
 ║         ┌──────────────────────┼──────────────────────┐            ║
 ║         ▼                      ▼                      ▼            ║
 ║  ┌──────────────┐    ┌──────────────────┐    ┌──────────────┐      ║
 ║  │ DRM Backend  │    │ Input (libinput) │    │  Backlight   │      ║
 ║  │ display.rs   │    │ seat-touchbar:   │    │  backlight.rs│      ║
 ║  │              │    │  touch digitizer │    │              │      ║
 ║  │ Dumb buffer  │    │ seat0:           │    │ T1:          │      ║
 ║  │ Atomic commit│    │  FN key (layer   │    │  appletb_    │      ║
 ║  │ dirty rects  │    │   swap/gesture)  │    │  backlight   │      ║
 ║  │              │    │                  │    │  (HID nits,  │      ║
 ║  │ T1: retry    │    │ T1 name match:   │    │  via DRM     │      ║
 ║  │  open_card   │    │  "iBridge        │    │  driver)     │      ║
 ║  │ T1: flush    │    │   Touchpad"      │    │ T2:          │      ║
 ║  │  stall       │    │ T2 name match:   │    │  appletb_    │      ║
 ║  │  backoff +   │    │  "Touch Bar      │    │  backlight   │      ║
 ║  │  heartbeat   │    │   Display        │    │  (hid_appletb │      ║
 ║  │              │    │   Touchpad"      │    │  _bl)        │      ║
 ║  └──────┬───────┘    └────────┬─────────┘    └──────┬───────┘      ║
 ║         │                     │                     │              ║
 ║         ▼                     ▼                     ▼              ║
 ║  ┌──────────────────────────────────────────────────────────────┐  ║
 ║  │  RENDERING + EVENT LOOP (main.rs)                           │  ║
 ║  │                                                              │  ║
 ║  │  • FunctionLayer (N layers, scrollable, swipeable)          │  ║
 ║  │  • Button types: Text/Svg/Time/Battery/Cpu/Gpu/             │  ║
 ║  │    Slider/Media/Command/Spacer                              │  ║
 ║  │  • Cairo + Pango + librsvg rendering                        │  ║
 ║  │  • Pixel shift (burn-in mitigation)                         │  ║
 ║  │  • 60Hz frame pacing, keep-warm heartbeat                   │  ║
 ║  │  • Touch state machine: tap/hold/scroll/fling/swipe/slider  │  ║
 ║  │  • uinput virtual keyboard → key events                     │  ║
 ║  │  • Soft dimming (10 levels, eased) + adaptive brightness    │  ║
 ║  │  • Config: TOML cascade (/usr/share → /etc → ~/.config)     │  ║
 ║  │    live-reloaded via directory-watch inotify                │  ║
 ║  │  • Widget runtime: shell-command pollers (battery/CPU/GPU/  │  ║
 ║  │    media/sliders) in worker threads                         │  ║
 ║  │  • Privilege drop to logged-in user (logind seat0)          │  ║
 ║  └──────────────────────────────────────────────────────────────┘  ║
 ╚════════════════════════════════════════════════════════════════════╝
                   │
                   ▼
 ╔════════════════════════════════════════════════════════════════════╗
 ║               USERSPACE: SETTINGS + INSTALLER (Python/GTK)        ║
 ║           (adapted from omarchy-touchbar, outside ./src/)         ║
 ║                                                                    ║
 ║  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  ║
 ║  │  hardware.py     │  │  setup.py        │  │  panel.py        │  ║
 ║  │  (model routing) │  │  (guided install)│  │  (GTK4 settings) │  ║
 ║  │                  │  │                  │  │                  │  ║
 ║  │ T1_MODELS        │  │ T1: DKMS install │  │ T1: shortcut     │  ║
 ║  │ T2_MODELS        │  │  appletbdrm +    │  │  show/hide/      │  ║
 ║  │ backend_for()    │  │  kernel-hid-t1 + │  │  reorder, media, │  ║
 ║  │                  │  │  ibridge-switcher│  │  keyboard toggle │  ║
 ║  │ (from omarchy-   │  │  + usbmuxd override│ T2: MediaLayer    │  ║
 ║  │  touchbar, used  │  │ T2: install tiny-│  │  Default toggle  │  ║
 ║  │  verbatim)       │  │  dfr / unified   │  │  (subset)        │  ║
 ║  │                  │  │  from repos      │  │                  │  ║
 ║  └──────────────────┘  └──────────────────┘  └──────────────────┘  ║
 ╚════════════════════════════════════════════════════════════════════╝
4.1 Flow: Hardware Detection → Daemon → T1/T2 Logic
BOOT
  │
  ├─ udev: T2 USB 0x8302 detected → force bConfigurationValue 1→2
  │
  ├─ ibridge-switcher.service (T1 only):
  │    libusb opens 05ac:8600, set USB Config 1→2
  │    → kernel re-enumerates iBridge interfaces
  │
  ├─ appletbdrm.ko probes USB interface 3 (T1) or interface-class 0x10 (T2):
  │    T1: async URB → wait for STATS → GINF → setup DRM mode config
  │         claim if6 → register appletb_backlight (HID Feature Reports)
  │         → /dev/dri/cardN + /sys/class/backlight/appletb_backlight
  │    T2: sync GINF → REDY → setup DRM mode config → CLRD
  │         → /dev/dri/cardN (backlight via separate hid_appletb_bl)
  │
  ├─ hid-multitouch.ko probes touch digitizer interface:
  │    T1: 0x8600 → MT_CLS_APPLE_TOUCHBAR → /dev/input/eventM
  │         name: "Apple Inc. iBridge Touchpad"
  │    T2: 0x8302 → MT_CLS_APPLE_TOUCHBAR → /dev/input/eventM
  │         name: "Apple Inc. Touch Bar Display Touchpad"
  │    udev: → ID_SEAT=seat-touchbar, SYSTEMD_WANTS=unified-touchbar.service
  │
  └─ unified-touchbar.service starts:
       │
       ├─ Chip detection: scan /dev/dri/card*, read idProduct
       │   → ChipType::T1 (0x8600) | T2 (0x8302) | AppleSilicon (adp)
       │
       ├─ T1 path:
       │    DrmBackend::open_card() with 60s retry (card appears late)
       │    → acquire DRM master, dumb buffer, atomic commit
       │    BacklightManager: find_backlight() → appletb_backlight (T1)
       │    libinput seat-touchbar: match "iBridge Touchpad"
       │    Flush-stall backoff + 150ms heartbeat (keep USB stream warm)
       │
       ├─ T2 path:
       │    DrmBackend::open_card() immediate
       │    BacklightManager: find_backlight() → appletb_backlight (T2)
       │    libinput seat-touchbar: match "Touch Bar Display Touchpad"
       │    Flush-stall backoff + heartbeat (same protocol behavior)
       │
       └─ Common:
            Config: load /usr/share/<unified>/config.toml
                    + /etc/<unified>/config.toml
                    + ~/.config/<unified>/config.toml (live-reload)
            Render: Cairo + Pango → dumb buffer → DRM dirty rects
            Input: touch → hit-test → uinput key events
            FN key (seat0): layer swap / double-press / swipe
            Backlight: adaptive (follow display) or static + soft dim
            Widgets: battery/CPU/GPU/media/slider command pollers
            Privilege drop → logged-in user (logind seat0 Class=user)
4.2 Out-of-Source Directory Layout (Proposed)
touchbar/                          ← workspace root
├── src/                           ← READ-ONLY source components (as given)
│   ├── appletbdrm/
│   ├── kernel-hid-t1-0.2/
│   ├── tiny-dfr/
│   ├── tiny-dfr-mbp142/
│   ├── not-quite-tiny-dfr/
│   └── omarchy-touchbar/
│
└── unified-touchbar/              ← NEW: the unified project (outside src/)
    ├── Cargo.toml                 ← crate manifest (name = "unified-touchbar")
    ├── build.rs                   ← build-time: copy nqtd src, apply T1 patch
    ├── patches/
    │   └── t1-deltas.patch        ← T1 digitizer match + card retry (vs nqtd)
    ├── src/
    │   └── main.rs                ← thin wrapper / entry point (or patched nqtd)
    ├── etc/
    │   ├── udev/rules.d/
    │   │   ├── 99-touchbar-seat.rules        ← unified seat rule
    │   │   ├── 99-touchbar-unified.rules     ← unified SYSTEMD_WANTS + backlight
    │   │   └── 39-usbmuxd.rules              ← T1 usbmuxd override (from omarchy)
    │   └── systemd/system/
    │       ├── unified-touchbar.service      ← unified daemon unit
    │       ├── ibridge-switcher.service      ← T1 USB config switcher
    │       └── systemd-backlight@backlight:appletb_backlight.service  ← empty
    ├── share/unified-touchbar/
    │   ├── config.toml            ← default config
    │   ├── *.svg                  ← icons (from nqtd/tiny-dfr share)
    │   └── widgets/               ← example widget scripts
    ├── installer/
    │   ├── install.sh             ← unified installer (DKMS + binary + rules)
    │   ├── hardware.py            ← model routing (from omarchy, verbatim)
    │   ├── setup.py               ← guided setup (adapted from omarchy)
    │   ├── t2.py                  ← TOML-preserving editor (from omarchy)
    │   └── panel.py               ← GTK4 settings (adapted from omarchy)
    └── README.md
Summary of what each project contributes:
Project	Contribution to Unified Solution
appletbdrm	Kernel DRM driver (T1+T2 framebuffer + T1 HID brightness). ibridge_switcher.c (T1 USB config switcher). DKMS packaging.
kernel-hid-t1-0.2	Kernel HID multitouch for T1 (0x8600 → MT_CLS_APPLE_TOUCHBAR). DKMS + patches + pre_build hook.
tiny-dfr	Architecture reference (DRM/libinput/uinput/inotify). systemd-backlight disable drop-ins. Superseded as source by nqtd.
tiny-dfr-mbp142	T1 resilience patches: digitizer name match ("iBridge Touchpad"), 60s card-open retry, flush-stall backoff. (Stall backoff subsumed by nqtd's richer implementation.)
not-quite-tiny-dfr	The daemon code base: all Rust modules, rendering, widgets, config cascade, media, sensors, soft dimming, user detection, scrollable layers, layer swipe. T2/AS support already present.
omarchy-touchbar	Settings UX + installer logic: hardware.py model routing, t2.py TOML editor, GTK4 panel patterns, usbmux_override() (critical T1 coexistence fix), windows.py Hyprland rule pattern. T1Bridge-IPC renderer discarded.
