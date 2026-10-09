# Brainstorming — Architecture Approach for Linux Touch Bar Rich UI
# Pre-brainstorm preparation document
# Date: 2026-08-25

## Purpose

This document frames the three architectural gaps identified in the research,
so we can brainstorm which approach is best for each. The brainstorming session
should determine:

1. Which renderer approach to use (extend tiny-dfr vs new daemon)
2. Which per-app context approach to use (Wayland protocol vs IPC vs D-Bus)
3. Which image pipeline approach to use (if needed)
4. Project scope and phasing

---

## Gap 1: Rich Widget Renderer

### The problem
tiny-dfr only renders static buttons (text, SVG, PNG, clock, battery).
macOS has 10 widget classes (sliders, color pickers, tabs, popovers, steppers,
scrubbers, candidate lists, sharing pickers, custom views). cairo can draw
all of them — the substrate is not the limit.

### Option 1A: Extend tiny-dfr (Rust)
- Add new widget types to the ButtonImage enum (or a new Widget enum)
- Implement cairo drawing for each widget type
- Add libinput gesture handling (drag for sliders, pan for scrubbers)
- Keep the existing DRM + cairo + uinput architecture
- Pros: builds on existing working code, Rust safety, active upstream
- Cons: Rust (steeper learning curve if team is C/Python), upstream may
  not accept rich-widget patches (tiny-dfr's scope is deliberately minimal)

### Option 1B: New daemon (C/C++ or Rust)
- Build a new Touch Bar daemon from scratch
- Use cairo + libinput + DRM directly (same libraries as tiny-dfr)
- Design widget system from the start (sliders, pickers, tabs, popovers)
- Pros: clean design, no upstream constraints, can choose language
- Cons: reinvents the DRM/cairo/libinput plumbing that tiny-dfr already has

### Option 1C: Python/JS daemon on top of tiny-dfr's DRM layer
- Use tiny-dfr as the display backend (or extract its display.rs)
- Build the rich widget layer in Python (pycairo) or JavaScript (node-cairo)
- Pros: faster prototyping, easier to add D-Bus/HTTP integrations
- Cons: slower rendering (Python), more dependencies, harder to deploy

### Key question: Should we extend tiny-dfr or build new?
Considerations:
- tiny-dfr's scope is deliberately minimal (AsahiLinux project)
- Rich widgets need a widget model (state, layout, event handling) that
  tiny-dfr's static-config model doesn't support
- The DRM + cairo plumbing is ~30% of the work; the widget model is ~70%
- If we extend tiny-dfr, we fork it (upstream won't merge rich widgets)
- If we build new, we reuse tiny-dfr's display.rs as a reference

---

## Gap 2: Per-App Context Protocol (the architectural decision)

### The problem
macOS: the responder chain lets the frontmost app publish its own Touch Bar
items dynamically. The Touch Bar changes when you switch apps.
Linux: no equivalent. tiny-dfr shows the same static config regardless of
what's focused. No Wayland protocol, no compositor integration.

### Option 2A: New Wayland protocol extension (wlr-touchbar)
- Define a new protocol: wlr-touchbar-unstable-v1
- Compositor (Hyprland/Sway) implements the server side
  - Tracks the focused window's app-id
  - Notifies the Touch Bar daemon of focus changes
  - Relays item publishing from apps to the daemon
- Touch Bar daemon implements the client side
  - Receives focus-change events
  - Receives item-publish events from apps
  - Renders the frontmost app's items
- Apps (or their toolkits) implement the publisher side
  - GTK/Qt would need Touch Bar item publishing support
- Pros: clean, standards-aligned, composable, full macOS parity
- Cons: requires compositor patches, toolkit adoption, slow ecosystem growth,
  high upfront effort, political (getting wlroots/Hyprland to merge)

### Option 2B: Compositor IPC focus events + per-app static configs
- Touch Bar daemon subscribes to compositor focus events:
  - Hyprland: hyprctl activewindow (poll) or hyprctl IPC (if available)
  - Sway: swaymsg -t subscribe -e '["window"]' (IPC socket)
- On focus change, daemon looks up the app's Touch Bar config:
  - From a config directory: ~/.config/touchbar/<app-id>.toml
  - Fallback to default.toml if no app-specific config
- Re-renders on focus change
- Pros: works TODAY with no compositor patches, simple, pragmatic
- Cons: apps can't DYNAMICALLY publish items (only static configs keyed on
  app-id), no real per-app interaction (just per-app static layouts)

### Option 2C: D-Bus per-app publishing (macOS parity without Wayland)
- Define a D-Bus interface: org.linux.TouchBar.Publisher
- Apps (or their toolkits) publish items via D-Bus:
  - Register as a publisher with their app-id
  - Send item updates (button/slider/tab definitions) via D-Bus signals
- Touch Bar daemon listens on D-Bus:
  - Tracks which app is focused (via compositor IPC, Option 2B style)
  - Renders the focused app's published items
  - Falls back to static config if app doesn't publish
- Pros: full macOS parity (apps dynamically publish), no compositor patches,
  D-Bus is already standard on Linux desktops
- Cons: requires app/toolkit adoption (GTK/Qt integration), but can start
  with a few hand-coded apps + fallback to static configs

### Option 2D: Hybrid (2B now → 2C later → 2A eventually)
- Phase 1: implement Option 2B (IPC focus events + static configs)
  - Works immediately, no dependencies on apps or compositors
  - Prove the concept, ship something useful
- Phase 2: add Option 2C (D-Bus publishing) for apps that want dynamic items
  - Backwards compatible (static config is the fallback)
  - Start with a reference implementation for one app (e.g. Firefox tab bar)
- Phase 3: if ecosystem adopts it, propose Option 2A (Wayland protocol)
  - Standardize what works
  - Get compositor maintainers to merge

### Key question: How much macOS parity do we need upfront?
- If "just per-app static layouts" is enough → Option 2B (ship in days)
- If "apps dynamically publish items" is needed → Option 2C (weeks)
- If "standards-aligned Wayland protocol" is the goal → Option 2A (months)

---

## Gap 3: Dynamic Image Pipeline

### The problem
macOS: apps can send any image (NSImageView, custom drawing, remote URLs).
Linux tiny-dfr: static SVG/PNG files only. No HTTP fetch, no dynamic images.
Use case: "tabs with website images" (favicons/screenshots in a scrubber).

### Option 3A: Async HTTP fetcher in the renderer
- Add reqwest (Rust) or requests (Python) or fetch (Node) to the daemon
- Fetch images by URL, decode with image/librsvg, cache, render
- Update on a timer or on-demand (D-Bus signal from app)
- Pros: simple, self-contained
- Cons: renderer becomes networked (security, latency, caching complexity)

### Option 3B: D-Bus image publishing (apps send images, not URLs)
- Apps publish pre-decoded image buffers via D-Bus (as raw pixels or PNG)
- Renderer just displays what it receives
- Pros: no network code in renderer, apps control their own image pipeline
- Cons: large D-Bus messages (images are big), needs shared-memory for perf

### Option 3C: Shared-memory image buffer (fastest)
- Renderer exposes a shared-memory region (memfd or dma-buf)
- Apps write pixels directly into the shared buffer
- Renderer reads from the buffer and composites into the Touch Bar surface
- Pros: zero-copy, fastest possible, works with GPU rendering
- Cons: complex, needs careful synchronization, Linux-specific

### Key question: Do images come from URLs (renderer fetches) or from
apps (renderer receives)? This depends on the per-app context approach
chosen in Gap 2.

---

## Cross-cutting decisions

### Language choice
- Rust: matches tiny-dfr, memory-safe, good cairo/libinput bindings, steeper
- C/C++: closest to DRM/cairo native, most examples, no memory safety
- Python: fastest prototyping, pycairo works, too slow for production?
- Node.js: good for D-Bus/HTTP, node-cairo exists, unusual for system daemons

### Widget model
- Immediate-mode (like ImGui): simple, no state management, redraw every frame
- Retained-mode (like DOM/NSTouchBar): widget tree, state, event delegation
- Hybrid: retained widget tree with immediate-mode rendering (like Flutter)

### Touch input model
- Current: tap → uinput key event (binary, no continuous gestures)
- Needed: drag (sliders), pan (scrubbers), press-and-hold (popovers),
  multi-touch (magnification)
- libinput already provides touch-motion events — just need to handle them

### Testing strategy
- Unit test the widget model (state transitions, layout math)
- Integration test with a virtual DRM device (vkms or mock)
- Visual test with the real T1 (capture photos of the OLED?)
- Protocol conformance test (compare USB traffic against macOS DTrace captures)

---

## Open questions for the brainstorming session

1. Scope: do we want full macOS parity (all 10 widget types + per-app
   dynamic publishing) or a useful subset (per-app static configs with
   sliders/pickers/tabs)?

2. Renderer: extend tiny-dfr (fork) or build new daemon?

3. Per-app context: Option 2B (pragmatic, ships now), 2C (D-Bus, macOS
   parity), or 2D (phased hybrid)?

4. Language: Rust (match tiny-dfr), C/C++ (native), or Python (prototype)?

5. Widget model: immediate-mode, retained-mode, or hybrid?

6. Image pipeline: URL fetching (3A), D-Bus publishing (3B), or
   shared-memory (3C)?

7. Compositor: Hyprland-first, Sway-first, or compositor-agnostic?

8. Timeline: proof-of-concept (days), useful tool (weeks), or
   production-ready (months)?

9. Community: do we want this to be upstreamed (tiny-dfr PR, Hyprland
   protocol) or maintained as a separate project?

10. Priority features: which widgets matter most? (sliders for brightness,
    scrubbers for tab switching, color pickers for GIMP, all of them?)