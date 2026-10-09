# Touch Bar Engine — Architecture

## Layer Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                       IPC Clients                               │
│  (volume sliders, media players, IDEs, dev-tools, Waybar, ...)  │
└─────────────────────────┬───────────────────────────────────────┘
                          │ Unix socket (JSON) / WebSocket (JSON)
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      IPC Server                                 │
│  ┌──────────────┐  ┌────────────────┐  ┌───────────────────┐   │
│  │  Unix Socket  │  │  JSON Parser   │  │  Event Broadcaster│   │
│  │  Listener     │  │  (serde_json)  │  │  (Phase 3: WS)   │   │
│  └──────────────┘  └────────────────┘  └───────────────────┘   │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Engine (single writer)                      │
│                                                                 │
│  ┌───────────┐  ┌───────────┐  ┌────────────┐  ┌───────────┐  │
│  │  Config    │  │  Page      │  │  Gesture   │  │  Render   │  │
│  │  Manager   │  │  Layout    │  │  Recogniser│  │  Pipeline │  │
│  │  (YAML)   │  │  (widgets) │  │            │  │  (cairo)  │  │
│  └─────┬─────┘  └─────┬─────┘  └─────┬──────┘  └─────┬─────┘  │
│        │              │              │                │         │
│        ▼              ▼              ▼                ▼         │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                  Provider Traits                          │  │
│  │  ┌─────────────┐ ┌──────────────┐ ┌──────────────────┐   │  │
│  │  │ DisplayProv │ │ InputProvider│ │ BacklightProvider│   │  │
│  │  │   ider      │ │              │ │                  │   │  │
│  │  └──────┬──────┘ └──────┬───────┘ └───────┬──────────┘   │  │
│  └─────────┼───────────────┼──────────────────┼──────────────┘  │
└────────────┼───────────────┼──────────────────┼────────────────┘
             │               │                  │
             ▼               ▼                  ▼
┌──────────────┐  ┌──────────────────┐  ┌────────────────────────┐
│  DRM Device  │  │  libinput        │  │  /sys/class/backlight  │
│  (appletbdrm)│  │  (seat-touchbar  │  │  (appletb_backlight    │
│  2170×60     │  │   + seat0)       │  │   or hid-appletb-bl)   │
└──────────────┘  └──────────────────┘  └────────────────────────┘
```

## Provider Traits

### `DisplayProvider`

```rust
pub trait DisplayProvider {
    fn acquire(&mut self) -> Result<()>;           // Open DRM device
    fn release(&mut self) -> Result<()>;            // Release before S3
    fn display_info(&self) -> Result<DisplayInfo>;  // Width, height
    fn flush(&mut self, src: &[u8], clips: &[DamageRect]) -> Result<()>;
    fn is_connected(&self) -> bool;
}
```

Real: `DrmProvider` (owns `/dev/dri/card*`, handles T1 stall backoff)  
Test: `MockDisplay` (in-memory buffer, records flush calls)

### `InputProvider`

```rust
pub trait InputProvider {
    fn init(&mut self) -> Result<()>;
    fn poll(&mut self) -> Vec<InputEvent>;
    fn current_backlight(&self) -> u32;
    fn notify_activity(&mut self);
}
```

Real: `LibinputProvider` (reads `seat-touchbar` + `seat0`)  
Test: `MockInput` (queue-based event injection)

### `BacklightProvider`

```rust
pub trait BacklightProvider {
    fn set_brightness(&mut self, value: u32) -> Result<()>;
    fn brightness(&self) -> u32;
    fn max_brightness(&self) -> u32;
}
```

Real: `SysfsBacklight` (`/sys/class/backlight/appletb_backlight`)  
Test: `MockBacklight` (in-memory)

### `PowerProvider` (stub)

```rust
pub trait PowerProvider {
    fn is_lid_closed(&self) -> bool;
    fn ms_since_activity(&self) -> u64;
}
```

## Lifecycle

```
   ┌───────┐
   │ Start │
   └───┬───┘
       ▼
  DisplayProvider::acquire()  ─── retry 30×2s for T1 late card
       ▼
  InputProvider::init()       ─── libinput on seat-touchbar + seat0
       ▼
  BacklightProvider::new()    ─── discover sysfs path
       ▼
  ConfigManager::new()        ─── inotify on /etc/touchbar-engine/config.yaml
       ▼
  ┌──────────────────────────────────────────────┐
  │  Main Loop (10ms cadence, epoll-driven)      │
  │                                               │
  │  1. Check config reload (inotify)             │
  │  2. Check IPC messages                       │
  │  3. Poll input events                         │
  │  4. Update gesture state machines             │
  │  5. Emit key events on tap                    │
  │  6. Handle widget gestures                    │
  │  7. Redraw dirty pages → cairo surface        │
  │  8. Flush to DRM (with stall backoff)         │
  │  9. Update backlight (adaptive dim)            │
  │ 10. Sleep until next event / timeout           │
  └──────────────────────────────────────────────┘
       ▼
  (on SIGTERM) → DisplayProvider::release() → exit
```

## Device Discovery

**Never by device-name strings.** Always by geometry:

- **DRM display**: Scan `/dev/dri/card*` read-only (`O_RDONLY|O_CLOEXEC`),
  check for a connected connector whose mode has `height / width > 30`
  (ADR 004). The Touch Bar is 2170×60 (ratio ≈ 36). The laptop's eDP panel
  has ratio ≈ 0.56. DRM master is taken **only** on the matched card.
- **Digitizer**: Assigned to `seat-touchbar` by a udev rule matching USB
  VID:PID `05ac:8600` (ADR 009 — not by product name). The input provider
  matches the digitizer by **ABS_MT geometry vs the DRM mode** (axis
  maxima ≈ 2170×60, allowing rotation) — **zero product-name strings** in
  the matching path.
- **Backlight**: Scan `/sys/class/backlight/` for names containing
  `appletb_backlight`, `display-pipe`, or `228600000.dsi.0`.

## Coordinate Spaces (ADR 020)

The Touch Bar has **three coordinate spaces**:

1. **Framebuffer space (portrait)**: the DRM dumb buffer / `appletbdrm`
   mode, 60×2170 (width=60, height=2170). `DisplayInfo` reports this.
2. **Logical bar space (landscape)**: the bar as the user sees it,
   2170×60 (width=2170, height=60). This is the ONLY space for
   `Page::layout()`, `hit_test()`, gestures, config rect validation, and
   the future web mirror.
3. **Digitizer space (raw → landscape)**: the digitizer reports raw HID
   ranges (ABS_MT_POSITION_X max=32767, Y max=127); libinput's
   `x_transformed(logical.width)` / `y_transformed(logical.height)`
   scales raw → logical-landscape.

Rotation is **confined to the paint path**: the cairo CTM
`translate(logical.height, 0) ∘ rotate(90°)` maps a logical drawing
point (x,y) → device (logical.height − y, x). `Geometry`
(`src/geometry.rs`) carries both dims and exposes `apply_paint_matrix`.
Layout, hit_test, and gestures NEVER see the rotation. This matches the
proven oracle convention (`backup_old/tiny-dfr-mbp142/src/main.rs:842`
swaps DRM dims to `(height=60, width=2170)`; `:599-600` translates by
`height=60`).

## Security Model

- **No root required**: The daemon drops privileges to `nobody` with
  `input` + `video` groups after opening DRM/input/backlight fds.
- **Socket isolation**: `$XDG_RUNTIME_DIR/touchbar/engine.sock` mode 0600.
- **WebSocket localhost-only**: Binds `127.0.0.1:9170` by default.
- **Input sanitization**: Widget labels are rendered as-is (cairo text).
  Icon paths are validated against XDG data dirs or `/usr/share/touchbar-engine/`.
  Exec commands are Phase 2 (will use D-Bus activation, not shell exec).

## File Layout

```
touchbar-engine/
├── src/
│   ├── main.rs                    # Daemon entry point
│   ├── config/
│   │   ├── mod.rs                 # ConfigManager (inotify hot-reload)
│   │   └── yaml.rs                # YAML config parser + schema
│   ├── providers/
│   │   ├── mod.rs                 # Traits + geometry discovery
│   │   ├── drm_backend.rs         # Real DRM provider
│   │   ├── input.rs               # Real libinput provider
│   │   ├── backlight.rs           # Real sysfs backlight
│   │   ├── mock_display.rs        # Test mock
│   │   ├── mock_input.rs          # Test mock
│   │   └── mock_backlight.rs      # Test mock
│   ├── widgets/
│   │   ├── mod.rs                 # Widget trait + gesture FSM
│   │   ├── button.rs              # ButtonWidget + SpacerWidget
│   │   ├── slider.rs              # SliderWidget
│   │   └── page.rs                # Page layout + hit-testing
│   ├── ipc/
│   │   ├── mod.rs                 # IPC module root
│   │   ├── protocol.rs           # JSON protocol types + serde
│   │   └── server.rs              # Unix socket server
│   ├── fonts.rs                   # Fontconfig FFI
│   └── pixel_shift.rs             # OLED burn-in prevention
├── proto/
│   └── protocol.md                # Human-readable protocol spec
├── docs/
│   ├── prior-art.md                # Research baseline
│   ├── architecture.md             # This file
│   └── adr/                        # Architecture Decision Records
│       ├── 001-architecture.md
│       ├── 002-widget-engine.md
│       └── 003-ipc-protocol.md
├── examples/
│   ├── volume-slider.yaml
│   ├── media-page.yaml
│   └── dev-tools-page.yaml
├── Cargo.toml
└── README.md
```