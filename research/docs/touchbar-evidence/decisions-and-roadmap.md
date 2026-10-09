# Touch Bar Linux Project — Decisions and Roadmap
# Created: 2026-08-25
# Status: SCOPE A committed, SCOPE B deferred (collect info)

---

## 1. Decision: Scope A — Static per-app configs

### Committed
- **Scope A**: static per-app TOML configs, compositor focus detection, system
  keys + Control Strip, FN key gesture modes, static creative widgets
- **Timeline**: 3-4 weeks to first useful release
- **Limit accepted**: creative widgets (slider, color picker, tabs) are static
  — they control system things or emit key combos/scripts, NOT the focused
  app's actual state. A slider in a GIMP config controls system brightness
  or emits a key combo, not GIMP's exposure value.

### Future: Scope B — Rich widgets + D-Bus (deferred)
- **Phase 2**: add D-Bus publishing layer on top of the scope A foundation
- **Timeline**: ~2 months after scope A ships
- **Condition**: widget model in scope A must be designed to be reusable
  (widgets receive values from a "source" abstraction — initially static
  config, later D-Bus)

### Out of scope (both A and B for now)
- Scope C (Wayland protocol) — political, depends on upstream maintainers
- Touch ID / SEP — hard blocked (T1 SEP is encrypted)
- Predictive text / candidate lists — needs toolkit-level integration
- T1 firmware updates — not feasible from Linux

---

## 2. Scope A Roadmap (committed)

### Phase A1: Foundation (week 1-2)
- [ ] **A1.1** Renderer decision (extend tiny-dfr vs new daemon) — Round 2
- [ ] **A1.2** DRM display plumbing (open /dev/dri/cardN, cairo surface, dirty-rect push)
- [ ] **A1.3** Config parser (TOML schema for per-app configs)
- [ ] **A1.4** Widget model (minimal: button, spacer, slider-static, text, SVG/PNG icon)
- [ ] **A1.5** Touch input (libinput on seat-touchbar, tap → uinput, drag → slider)
- [ ] **A1.6** Backlight + pixel-shift (carry over from tiny-dfr)

### Phase A2: Per-app context (week 2-3)
- [ ] **A2.1** Compositor focus detection
  - Define `trait CompositorFocusProvider { fn current() -> FocusedWindow; fn focus_changes() -> impl Iterator<Item=FocusedWindow>; }`
  - Implement `SwayFocusProvider` (swayipc crate, MIT, WindowChange::Focus events)
  - Implement `HyprlandFocusProvider` (raw socket2 parsing, ~30 lines, avoids GPL crate)
  - Runtime detection: $SWAYSOCK → Sway, $HYPRLAND_INSTANCE_SIGNATURE → Hyprland
- [ ] **A2.2** App-id → config mapping (swap on focus change, re-render)
  - Map app-id to ~/.config/touchbar/apps/<app-id>.toml
  - Fallback: apps/default.toml → built-in defaults
  - inotify watch on apps/ directory for live config reload
- [ ] **A2.3** FN key gesture modes
  - Keep existing press-and-hold (layer peek) and double-press (layer swap)
  - Add `FnHoldTimeout` config key (ms, global in config.toml)
  - Keep existing `DoublePressSwitchLayers` and `LayerSwipe` config keys
- [ ] **A2.4** Control Strip
  - Default: Pinned buttons (existing mechanism, no new code)
  - Optional: `[ControlStrip]` TOML table (Enabled, Width, Buttons)
  - When enabled: split bar into left (app) + right (strip), strip renders independently
  - Use case: background music player / feeder always visible on the right

### Phase A3: Rich static widgets (week 3-4)
- [ ] **A3.1** Slider widget — already in not-quite-tiny-dfr (carry over)
- [ ] **A3.2** Tab/picker widget (new ButtonImage::TabPicker variant, segmented control, tap to select)
- [ ] **A3.3** Color picker widget (new ButtonImage::ColorPicker variant, collapsed swatch → expand to grid → select)
- [ ] **A3.4** Press-and-hold popover (new TouchState::PressHold state, distinct from tap-to-expand)
- [ ] **A3.5** Popover/expandable widget — already in not-quite-tiny-dfr (carry over)
- [ ] **A3.6** Clock + battery + CPU/GPU — already in not-quite-tiny-dfr (carry over)

### Phase A4: Polish (week 4+)
- [ ] **A4.1** Config hot-reload (inotify watch on config dir)
- [ ] **A4.2** Default config library (Terminal, Firefox, GIMP, VLC, etc.)
- [ ] **A4.3** Documentation (config schema, widget reference, per-app guide)
- [ ] **A4.4** Packaging (AUR, Nix flake, systemd service)

---

## 3. Scope B Roadmap (deferred — collect info now)

### Phase B1: Foundation (week 1-2) — same as A1
- Reuse A1 output entirely (DRM plumbing, config parser, widget model)

### Phase B2: D-Bus publishing infrastructure (week 3-5)
- [ ] **B2.1** D-Bus server (org.linux.TouchBar on session bus)
- [ ] **B2.2** Publisher interface (Register, UpdateItems, SetItemValue, Unregister)
- [ ] **B2.3** Focus integration (compositor IPC + D-Bus publisher arbitration)
- [ ] **B2.4** Item serialization format (D-Bus-friendly item definitions)

### Phase B3: Full widget vocabulary (week 5-8)
- [ ] **B3.1** Slider (app-bound: value from D-Bus, drag sends value back)
- [ ] **B3.2** Scrubber (horizontal picker, items from app)
- [ ] **B3.3** Color picker (app-bound: color list from app)
- [ ] **B3.4** Tabs/picker (app-bound: tab defs from app)
- [ ] **B3.5** Popover (app-bound: sub-items from app)
- [ ] **B3.6** Stepper (increment/decrement, value to app)
- [ ] **B3.7** Candidate list (text suggestions from text-input helper)
- [ ] **B3.8** Custom view (raw pixel buffer or SVG from app)

### Phase B4: Image pipeline (week 8-10)
- [ ] **B4.1** Image fetch (HTTP, decode PNG/JPEG/SVG, cache)
- [ ] **B4.2** Image publishing (D-Bus for small, memfd/dma-buf for large)
- [ ] **B4.3** Favicon/screenshot support (for browser tab scrubbers)

### Phase B5: Reference integrations (week 10-12)
- [ ] **B5.1** Firefox integration (extension + Native Messaging + D-Bus bridge)
- [ ] **B5.2** GIMP integration (helper script, color picker + sliders)
- [ ] **B5.3** VLC integration (play/pause + timeline scrubber)
- [ ] **B5.4** Terminal integration (function keys + paste snippets)

### Phase B6: Polish (week 12+)
- [ ] **B6.1** Hot-reload + config library + docs + packaging
- [ ] **B6.2** D-Bus API documentation + publisher SDK
- [ ] **B6.3** Shared-memory image path for large images

---

## 4. Blocked / Infeasible Tasks

### Hard blocked (cannot be done on either scope)
| Task | Why | Notes |
|------|-----|-------|
| Touch ID / fingerprint | T1 SEP is encrypted; interface 7 carries encrypted SEP traffic | No Linux driver can decrypt it |
| T1 firmware updates | Requires Apple IMG4 tooling + SEP co-processing | T1 firmware stays at whatever macOS last installed |
| True Tone color matching | Apple-proprietary color mapping from ALS data | Can read ALS (interface 6), can't replicate the mapping |
| Predictive text / candidate list | Needs deep toolkit integration (IBus/Fcitx) | Soft block — possible but high effort, not in scope A or B |
| Per-window (not per-app) context | macOS responder chain is per-window; our model is per-app | Soft block — one Touch Bar layout per app, not per window |
| Exact macOS refresh rate | T1 firmware controls OLED refresh; host can only push pixels | We get whatever the T1 gives us (~20-55 Hz measured) |

### Blocked for Scope A (unblocked by moving to B)
| Task | Why | Unblocked by |
|------|-----|-------------|
| Browser tab scrubber with live favicons | Browsers don't expose tab list externally; needs D-Bus publishing | Scope B (B4.3 + B5.1) |
| App-state widgets (GIMP exposure, VLC timeline) | Static configs can't read app state | Scope B (B3.1-B3.6) |
| Dynamic content (live updates without focus change) | Static configs are files, not live data | Scope B (D-Bus signals) |

### High-risk (not blocked, but could fail)
| Task | Risk | Mitigation |
|------|------|-----------|
| appletbdrm-t1 patch maintenance | Kernel updates may break the T1 echo-bug patch | DKMS, pin to tested kernels |
| hyprctl API stability | Hyprland IPC may change between versions | Abstract compositor interface; Sway IPC as fallback |
| libinput seat-touchbar | Seat may not auto-create on all distros | Ship udev rules + docs |
| cairo rendering performance | Complex widgets could cause frame drops | Use damage-clips, benchmark early |
| T1 USB enumeration race | T1 may not be ready at daemon start | Wait for /dev/dri/cardN via udev |

---

## 5. Info to Collect Now (for Scope B preparation)

These are things to research/gather during Scope A development that will
make Scope B faster when we start it:

### 5.1 D-Bus research
- [ ] Study D-Bus session bus patterns for desktop services (e.g. how
      xdg-desktop-portal, mpris, StatusNotifierItem work)
- [ ] Evaluate D-Bus message size limits for image transfer (what's practical?)
- [ ] Investigate memfd/dma-buf as shared-memory image transport
- [ ] Draft the org.linux.TouchBar D-Bus interface (Introspection XML)
- [ ] Study gdbus / zbus (Rust) / dbus-python for the publisher SDK

### 5.2 Compositor integration research
- [ ] Document Hyprland's IPC API for window focus events (hyprctl activewindow,
      hyprctl dispatch, event socket if available)
- [ ] Document Sway's IPC API (swaymsg -t subscribe -e '["window"]')
- [ ] Evaluate wlroots protocols for possible future scope C (wlr-foreign-toplevel
      could give us focus events without a custom protocol)
- [ ] Check if xdg-desktop-portal could be a publishing channel (it already has
      per-app sandboxing + D-Bus)

### 5.3 Browser integration research
- [ ] Study Firefox WebExtension Native Messaging (how to bridge to D-Bus)
- [ ] Study Chrome/Chromium extension Native Messaging
- [ ] Evaluate whether MPRIS (D-Bus media interface) already gives us enough
      for media-player widgets (VLC, Spotify, etc. use MPRIS)
- [ ] Check if Firefox has a D-Bus interface or tab-list API already

### 5.4 Widget model design (for reusability)
- [ ] Design the widget trait/interface so values can come from either:
      - Static config (Scope A) — value is a literal in TOML
      - D-Bus (Scope B) — value is a D-Bus property of the publisher
      - Script output (Scope A+) — value is the stdout of a command
- [ ] Design the action model so actions can be:
      - Key event (uinput) — Scope A
      - Script execution — Scope A
      - D-Bus method call to publisher — Scope B
- [ ] Design the image source model so images can come from:
      - File path (SVG/PNG) — Scope A
      - HTTP URL — Scope B
      - D-Bus image buffer — Scope B
      - Shared memory (memfd) — Scope B+

### 5.5 T1 hardware research (continue evidence collection)
- [ ] Run tb-monitor.sh across scenarios (app-switch, brightness, idle, FN modes)
      to build a refresh-rate profile per behavior
- [ ] Capture DTrace tracemem of transfer buffers (for 9.2.3 protocol unk_XX
      comparison — needs the commented-out tracemem line enabled)
- [ ] Mount the ESP and check firmware/ vs EMBEDDEDOS/ paths (needs sudo in a tty)
- [ ] On Linux side: run usbhid-dump to confirm the 782-byte HID descriptor (9.3.4)

---

## 6. Decisions Made

### Round 1: Scope (2026-08-25)

| Decision | Choice | Date | Rationale |
|----------|--------|------|----------|
| Overall scope | A (static per-app configs) | 2026-08-25 | Ship fast, prove concept, accept limits |
| Future scope | B (D-Bus), deferred | 2026-08-25 | Unblocks dynamic content; phase 2 |
| Use cases (priority) | System keys, Per-app layouts, FN gestures, Creative widgets | 2026-08-25 | User's stated needs |
| Creative widget binding | Static (emit key/script, not app state) | 2026-08-25 | Scope A limit accepted |
| Touch ID | Out of scope | 2026-08-25 | Hard blocked (SEP encrypted) |
| Predictive text | Out of scope | 2026-08-25 | Needs toolkit integration, too high effort |
| Scope C (Wayland) | Out of scope, future | 2026-08-25 | Political, depends on upstream |

### Round 2: Renderer + Language (2026-08-25)

| Decision | Choice | Date | Rationale |
|----------|--------|------|----------|
| Renderer base | Fork `seojoonlee-dev/not-quite-tiny-dfr` | 2026-08-25 | Already has sliders + popovers + T2 dirty-rect fix + DRM/cairo plumbing from tiny-dfr. Adding tabs/color pickers follows the slider pattern. Upstream tiny-dfr is hostile to rich-widget patches. |
| Language | Rust | 2026-08-25 | Matches tiny-dfr/not-quite-tiny-dfr. All bindings active (drm-rs, cairo-rs, input, zbus). Single binary, nixpkgs-ready. Python DRM binding is archived. C offers no advantage over Rust here. |
| Upstream relationship | Permanent fork, no upstream PRs planned | 2026-08-25 | tiny-dfr maintainer is hostile to contributions (PR #38 unmerged 2yr, anti-agent directives, "get lost" commit). not-quite-tiny-dfr is a community fork with 3 stars. We diverge permanently. |
| License | MIT (inherited) | 2026-08-25 | tiny-dfr is MIT, not-quite-tiny-dfr inherits it. Fork-friendly, no copyleft. |

### Round 2 analysis: not-quite-tiny-dfr codebase audit (2026-08-25)

- 15 source files, 10,183 lines (vs tiny-dfr's 6 files, 1,882 lines)
- ButtonImage enum: 11 variants (Text, Svg, Bitmap, Time, Battery, Cpu, Gpu, Slider, Media, Command, Spacer)
- WidgetRuntime: async command execution with JSON protocol — already the "value source" abstraction for scope B
- Already has: sliders (spring animation, drag, mute), popovers (crossfade, auto-collapse), command widgets (JSON, async, retry), scrollable layers (momentum, rubber-band, fling), full theming, T2 dirty-rect fix, NixOS module
- Missing (we add): tabs/picker, color picker, per-app config swapping, FN gesture modes
- Code quality: well-documented, sophisticated physics, performant (SVG cache, frame-locked 60 Hz)
- Concern: main.rs is 3,968 lines (monolithic); ButtonImage is a God enum (no trait abstraction)
- Reusability: ~1,016 lines verbatim, ~1,480 with edits, ~2,276 with significant edits, ~5,311 needs rework

### Round 2 kernel research (2026-08-25)

- appletbdrm is in mainline Linux (merged 6.15, March 2025) but ONLY supports T2 (PID 0x8302)
- T1 (PID 0x8600) needs the appletbdrm-t1 DKMS patch (echo-skip + stale-response drain + ID table)
- Patch is NOT in mainline and has NOT been submitted upstream yet (Aug 2026)
- Patch is prepared for submission ("meant to be sendable as-is")
- Kernel version requirement: 7.1+ (uses recent DRM API names); older LTS (6.6/6.1/5.15) won't compile without backporting
- DKMS coexists with mainline: installs to /updates/dkms/, shadows the in-tree module
- Recommendation: run kernel 7.1.10 stable or 7.2 mainline + DKMS patch; submit patch to dri-devel

### Round 3: Widget Model + Config Format (2026-08-25)

| Decision | Choice | Date | Rationale |
|----------|--------|------|----------|
| Widget model (scope A) | 3C: Hybrid — keep enum, add variants | 2026-08-25 | Add ColorPicker + TabPicker as new ButtonImage variants following the slider pattern. ~400-600 lines. No refactor of working code. Ship fast. |
| Widget model (scope B) | Plan trait refactor (Box<dyn Widget>) | 2026-08-25 | When adding D-Bus + more widgets, refactor to trait objects. Only affects the view layer; WidgetRuntime (model) stays. |
| Config format | TOML (keep) | 2026-08-25 | Already there, working, serde-parsed, well-documented. Zero migration cost. D-Bus items (scope B) use the D-Bus wire format, not the config file. |
| Per-app config structure | 3E: Subdirectory-per-app | 2026-08-25 | ~/.config/touchbar/config.toml for global, ~/.config/touchbar/apps/<app-id>.toml for per-app layouts. Clean separation, easy to share configs. |

### Fork details: not-quite-tiny-dfr
- Repo: https://github.com/seojoonlee-dev/not-quite-tiny-dfr
- Stars: 3, commits: 198, updated Aug 2026
- Already implements: sliders (tap-to-expand, drag, spring animation, mute), popovers (expandable widgets, crossfade), command widgets (JSON protocol, async polling), CPU/GPU widgets, scrollable layers, two-finger swipes, full theming, T2 dirty-rect fix, NixOS module
- Missing (we add): tabs/picker, color picker, per-app config swapping, FN gesture modes
- Tested on: 2019 15" MacBook Pro (T2). We need to verify T1 compatibility.
- License: MIT (inherited from tiny-dfr)

### What we inherit (reusable from not-quite-tiny-dfr)
- display.rs (DRM card open, dumb buffer, dirty-rect push) — ~213 lines
- fonts.rs (fontconfig FFI) — ~138 lines
- pixel_shift.rs (anti-burn-in) — ~107 lines
- backlight.rs (sysfs backlight, dimming) — ~150 lines
- config.rs (TOML parsing, inotify hot-reload) — ~217 lines, extend for per-app
- Slider widget (tap-to-expand, drag, spring animation) — reuse directly
- Popover/expandable widget (crossfade, auto-collapse) — reuse directly
- Command widget (JSON protocol, async polling) — reuse for script-backed widgets
- T2 dirty-rect bug fix — critical for stable display updates
- Theming system (colors, background image, corner radius, font size)

### What we add (new work)
- Per-app config swapping (compositor focus detection → swap active config)
  - Config structure: ~/.config/touchbar/config.toml (global) + ~/.config/touchbar/apps/<app-id>.toml (per-app)
  - Matching: Hyprland hyprctl / Sway IPC → app-id → apps/<app-id>.toml → fallback to apps/default.toml
- FN key gesture modes (press-and-hold, double-press, configurable timeout)
- Tab/picker widget (segmented control, tap to select) — new ButtonImage variant
- Color picker widget (collapsed swatch → expand to grid → select) — new ButtonImage variant
- Compositor integration (Hyprland hyprctl, Sway IPC)
- T1 compatibility verification (the fork was tested on T2, not T1)
- Kernel: document DKMS patch requirement; consider submitting T1 patch upstream

---

## 7. Future Decisions (pending — to resolve in later rounds)

| Decision | Options | Status | Round |
|----------|---------|--------|-------|
| Renderer base | Fork tiny-dfr / new daemon | **DECIDED: Fork not-quite-tiny-dfr** | Round 2 ✓ |
| Language | Rust / C/C++ / Python | **DECIDED: Rust** | Round 2 ✓ |
| Widget model (scope A) | Enum / trait / hybrid | **DECIDED: Hybrid (keep enum, add variants)** | Round 3 ✓ |
| Widget model (scope B) | Trait refactor | **DECIDED: Plan Box<dyn Widget> refactor for scope B** | Round 3 ✓ |
| Config format | TOML / JSON / YAML | **DECIDED: TOML (keep)** | Round 3 ✓ |
| Per-app config structure | Flat / subdirectory / single file | **DECIDED: Subdirectory (apps/)** | Round 3 ✓ |
| Compositor priority | Hyprland-first / Sway-first / agnostic | **DECIDED: Sway + Hyprland now, wlr later (4C)** | Round 4 ✓ |
| Touch input model | tap-only / full gestures | **DECIDED: Keep existing + add press-and-hold (4E)** | Round 4 ✓ |
| Control Strip design | Always-on / toggleable / app-configurable | **DECIDED: Pinned default + optional always-on strip (4H+4G)** | Round 4 ✓ |
| FN gesture timing | Hardcoded / configurable / per-app | **DECIDED: Keep existing + add config keys (4I)** | Round 4 ✓ |
| Image pipeline (for B) | URL fetch / D-Bus / shared-memory | Pending | Phase B |
| D-Bus interface design | Flat / nested / introspection-heavy | Pending | Phase B |
| Browser integration path | Extension + Native Messaging / D-Bus / MPRIS | Pending | Phase B |
| T1 patch upstream submission | When to send to dri-devel | Pending | Post-scope-A |

### Round 4: Compositor, Touch, Control Strip, FN Gestures (2026-08-25)

| Decision | Choice | Date | Rationale |
|----------|--------|------|----------|
| Compositor priority | 4C: Sway + Hyprland now, wlr-foreign-toplevel later | 2026-08-25 | Two compositor-specific providers (Sway via swayipc crate MIT, Hyprland via raw socket2 parsing to avoid GPL crate) behind a shared trait. wlr-foreign-toplevel added as a third unified provider in phase B. Runtime detection via env vars ($SWAYSOCK, $HYPRLAND_INSTANCE_SIGNATURE). |
| Touch input model | 4E: Extend with press-and-hold for popovers | 2026-08-25 | Keep the existing 5-state TouchState machine (Held, Pending, Scroll, LayerSwipe, SliderDrag). Add a PressHold state for press-and-hold to show popovers — different from tap-to-expand. The existing HOLD_ACTIVATE_MS (150ms) already distinguishes tap from hold; add a new transition. ~150-200 lines. |
| Control Strip | 4H + 4G: Pinned by default, optional always-on strip | 2026-08-25 | Default: use existing Pinned button mechanism (system buttons pinned on the right, no special layout code). Optional: configurable always-on Control Strip via TOML (ControlStrip = true, ControlStripWidth = 400) for background services like a music player feeder. The always-on strip reserves right-side pixels and renders independently of the app layout. ~250-350 lines. |
| FN gesture timing | 4I: Keep existing + add config keys | 2026-08-25 | Press-and-hold FN (layer peek) and double-press FN (layer swap) already implemented. Add FnHoldTimeout (ms) and keep DoublePressSwitchLayers (already exists). Timing is global in config.toml, not per-app. ~50 lines. |

### Compositor integration details

Trait abstraction:
```rust
pub struct FocusedWindow { pub app_id: String, pub title: String }

pub trait CompositorFocusProvider {
    fn current(&self) -> Result<FocusedWindow>;
    fn focus_changes(&mut self) -> Result<impl Iterator<Item = FocusedWindow>>;
}
```

Three providers (in priority order):
1. SwayFocusProvider — swayipc crate (MIT, 4.0.0), EventStream with WindowChange::Focus
2. HyprlandFocusProvider — raw socket2 parsing (~30 lines, avoids GPL hyprland crate)
   - Parse `activewindow>>CLASS,TITLE\n` lines from $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock
   - current() via `hyprctl -j activewindow` one-shot
3. WlrForeignToplevelFocusProvider — wayland-protocols-wlr crate (MIT), phase B
   - Binds zwlr_foreign_toplevel_manager_v1, tracks app_id + activated state per handle

Runtime detection:
- $SWAYSOCK or $I3SOCK present → SwayFocusProvider
- $HYPRLAND_INSTANCE_SIGNATURE present → HyprlandFocusProvider
- Fallback → try wlr-foreign-toplevel (phase B) or default.toml

### Touch model extension

New TouchState variant:
```rust
PressHold { layer: usize, btn: usize, started: Instant }
```
- Transition from Pending when hold duration > HOLD_ACTIVATE_MS and the widget supports press-and-hold
- Shows a popover (expanded view) while held; collapses on release
- Distinct from tap-to-expand (which stays open after release and auto-collapses after idle)

### Control Strip config schema

```toml
# config.toml (global)
[ControlStrip]
Enabled = false              # default: false (use Pinned buttons instead)
Width = 400                  # pixels reserved on the right
Buttons = [
    { Icon = "brightness_up", Action = "BrightnessUp" },
    { Icon = "volume_up", Action = "VolumeUp" },
    { Icon = "play_pause", Action = "PlayPause" },
]
```

When Enabled = true:
- The bar is split: left region = app layout, right region = Control Strip
- Control Strip renders independently (not affected by app config swap)
- Use case: a background music player feeder always shows transport controls on the right, while the left side swaps per-app

When Enabled = false (default):
- No special strip; system buttons are Pinned in the per-app config
- Simpler, matches not-quite-tiny-dfr's existing model

### FN gesture config schema

```toml
# config.toml (global)
FnHoldTimeout = 0            # ms to hold FN before peeking at FN layer (0 = instant, matches current behavior)
DoublePressSwitchLayers = 300 # ms window for double-press FN to swap layers (already exists in not-quite-tiny-dfr)
LayerSwipe = true            # two-finger horizontal swipe to switch layers (already exists)
```

---

## 8. Key Principles for Phase 1

**Principle 1: Widget model is hybrid.**
Scope A keeps the ButtonImage enum and adds variants (ColorPicker, TabPicker)
following the slider pattern. Scope B refactors to Box<dyn Widget> — but only
the view layer. The WidgetRuntime (model) is already abstracted: values come
from shell commands in scope A, from D-Bus in scope B. The rendering layer
doesn't care where values come from.

**Principle 2: Config is subdirectory-per-app.**
~/.config/touchbar/config.toml holds global settings (style, backlight, dim).
~/.config/touchbar/apps/<app-id>.toml holds per-app button layouts. The daemon
watches compositor focus, maps app-id to a config file, and swaps on focus
change. Fallback: apps/default.toml → built-in defaults.

**Principle 3: Preserve the WidgetRuntime abstraction.**
The WidgetRuntime (widget.rs) is the "value source" abstraction. In scope A,
values come from shell commands. In scope B, we add a D-Bus value source
that implements the same interface. The rendering layer stays unchanged.

**Principle 4: Keep TOML.**
The config format stays TOML (serde-parsed, inotify hot-reloaded). D-Bus
items (scope B) use the D-Bus wire format, not the config file format.

**Principle 5: New widgets follow the slider pattern.**
ColorPicker and TabPicker are new ButtonImage variants with:
- A state struct (like SliderState)
- A render arm in Button::render() (like the slider's track+handle)
- A touch-handling arm in main.rs (like TouchState::SliderDrag)
- Config keys (like SliderGet/SliderSet)
This is the established pattern in not-quite-tiny-dfr — follow it, don't
invent a new architecture for scope A.

**Principle 6: Compositor abstraction via trait.**
Define a CompositorFocusProvider trait. Implement Sway + Hyprland providers
now (behind the trait), add wlr-foreign-toplevel later. Runtime detection
via env vars. The daemon's config-swap logic depends only on the trait,
never on compositor-specific APIs.

**Principle 7: Touch model extends, doesn't replace.**
The existing 5-state TouchState machine handles tap, hold, drag, fling,
rubber-band, layer-swipe, slider-drag. Add a PressHold state for
press-and-hold popovers. New widgets add arms to existing states, not
new state machines.

**Principle 8: Control Strip is dual-mode.**
Default: Pinned buttons (no special layout code, uses existing mechanism).
Optional: always-on strip via TOML config (ControlStrip.Enabled = true),
reserving right-side pixels for a background service (music player, feeder).
The always-on strip renders independently of the app layout swap.

**Principle 9: FN timing is global, not per-app.**
FN hold timeout and double-press window are in the global config.toml.
The per-app configs define what the FN layer shows (button layouts), but
the timing is the same across all apps.