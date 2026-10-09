# Pre-Flight Review Report — touchbar-engine

**Reviewer**: QA / reliability engineer (read-only role)
**Date**: 2026-09-25
**Subject**: `touchbar-engine` first-build, preparing for FIRST hardware test session
**Baseline**: `docs/prior-art.md` (Seborider/mbp-t1-touchbar prior art, MBP14,2 digitizer naming issue)
**Hardware present on this bench**: MacBookPro14,2 (T1), kernel `7.2.6-arch2-1`,
`05ac:8600` iBridge, `/dev/dri/card0` = `appletbdrm` (mode 60×2170, ratio ≈36.2),
`/dev/dri/card1` = `i915` (eDP 2560×1600, ratio ≈0.625), digitizer
`input13 = "Apple Inc. iBridge Touchpad"`, backlight `appletb_backlight` + `acpi_video0`.
`appletbdrm` + `hid_multitouch` modules loaded; `apple_ibridge` NOT loaded.

> **FREEZE RULE reminder**: This review is read-only. No code was modified.
> `cargo fmt --check` / `clippy` / `test` were run for evidence only; their
> suggested rewrites were NOT applied. Findings below are observations, not fixes.

---

## 1. Build-tool evidence (verbatim)

### 1.1 `cargo fmt --check` — **FAIL (exit 1)**

The formatter reports many style deviations across `src/config/manager.rs`,
`src/config/mod.rs`, `src/config/yaml.rs`, `src/fonts.rs`, `src/ipc/mod.rs`,
`src/ipc/protocol.rs`, `src/ipc/server.rs`, `src/main.rs`, `src/pixel_shift.rs`,
`src/providers/backlight.rs`, `src/providers/drm_backend.rs`,
`src/providers/input.rs`, `src/providers/mock_backlight.rs`,
`src/providers/mock_display.rs`, `src/providers/mock_input.rs`,
`src/providers/mod.rs`, `src/widgets/button.rs`, `src/widgets/mod.rs`,
`src/widgets/page.rs`, `src/widgets/slider.rs`.

Representative samples (from `cargo fmt --check` stdout):

```
Diff in src/config/yaml.rs:51:
-fn default_true() -> bool { true }
+fn default_true() -> bool {
+    true
+}
...
Diff in src/main.rs:22:
-use providers::{
-    BacklightProvider, DamageRect, DisplayProvider, InputEvent, InputProvider,
-};
-use providers::drm_backend::DrmProvider;
+use input_linux::{uinput::UInputHandle, EventKind, Key, SynchronizeKind};
+use input_linux_sys::{input_event, input_id, uinput_setup};
+use libc::c_char;
+use pixel_shift::PixelShiftManager;
+use providers::backlight::SysfsBacklight;
+use providers::drm_backend::DrmProvider;
...
Diff in src/widgets/slider.rs:14:
-    pub on_mute: Option<String>,  // IPC command name
+    pub on_mute: Option<String>,   // IPC command name
```

Full diff was emitted to stdout (≈70 hunks). Exit code 1.

### 1.2 `cargo clippy --all-targets` — **PASS with warnings (exit 0)**

`cargo clippy` exits 0 (no errors). **128 warnings** reported across the bin
and test targets. Categorised summary (from `cargo clippy` stdout, deduplicated):

| Category | Count | Notes |
|---|---|---|
| `unnecessary_cast` (`f64 as f64`) | 4 | `src/providers/input.rs:117,125,126,127` — `x_transformed`/`y_transformed` already return `f64` |
| `match_single_binding` | 1 | `src/main.rs:55` — `match DrmProvider::new() { provider => ... }` is a single-binding match |
| `if_same_then_else` | 1 | `src/main.rs:420` — `if format == "24hr" { "⏰" } else { "⏰" }` identical branches (dead `format` check) |
| `upper_camel_case` on enum variants (`button`, `spacer`, `slider`, `dial`, `time`, `battery`, `tap`, `swipe`, `slider_value`, …) | many | Serde `rename_all = "snake_case"` keeps wire format; the lint is cosmetic |
| `unused_import` (`BoxedWidget`, `Widget`, `Surface`, `Rect`, `update_gesture`, `IpcMessage`, `IpcResponse`, `Read`, `Path`, `OwnedFd`, `KeyboardEvent`, `InotifyEvent`, `Gesture`, `SliderWidget`) | many | Dead imports |
| `field is never read` (`icon`, `on_change`, `on_mute`, `id`) | several | Phase-2 stubs; expected |
| `variant is never constructed` (`LidChanged`, `WaitingAtEnd`, `ShiftingSubpixel`) | 3 | Stubs / partially-wired state machine |
| `unused variable` (`x`, `value`, `mode`, `delta_x`) | 4 | |
| `&PathBuf` instead of `&Path` | 1 | `src/providers/backlight.rs:28` `read_attr(path: &PathBuf, ...)` |
| `write!()` ending in single newline | 1 | `src/providers/backlight.rs:61` |

No `error:` lines. Full warning list was emitted to stdout.

### 1.3 `cargo test` — **PASS (exit 0)**

```
running 11 tests
test config::yaml::tests::test_parse_settings ... ok
test config::yaml::tests::test_parse_slider ... ok
test config::yaml::tests::test_parse_time_and_battery ... ok
test config::yaml::tests::test_parse_minimal_config ... ok
test config::yaml::tests::test_reject_invalid_yaml ... ok
test ipc::protocol::tests::test_roundtrip_error_response ... ok
test widgets::page::tests::test_hit_test_stretch ... ok
test widgets::page::tests::test_hit_test_basic ... ok
test widgets::page::tests::test_hit_test_y_bounds ... ok
test ipc::protocol::tests::test_roundtrip_update_widget ... ok
test ipc::protocol::tests::test_roundtrip_set_pages ... ok

test result: ok. 11 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

11/11 unit tests pass. Note: all passing tests are **hardware-free**
(config parsing, IPC serde round-trips, hit-test geometry). No test exercises
`DrmProvider`, `LibinputProvider`, `SysfsBacklight`, the render loop, or the
IPC server's socket path. `MockDisplay`/`MockInput`/`MockBacklight` exist but
are not used by any test.

---

## 2. Pre-flight checklist

Each item is marked **PASS** or **FAIL** with a code/log pointer. Any FAIL
blocks the hardware session per the FREEZE RULE.

### 2.1 Discovery is by geometry; ZERO name-string dependencies (code, udev, seat rules); MBP14,2 "Apple T1 Controller Touchpad" immunity — **FAIL**

The DRM discovery (`discover_touchbar_drm`, `src/providers/mod.rs:105-123`,
`probe_drm_device` `src/providers/mod.rs:125-171`) is genuinely geometry-based:
it scans `/dev/dri/card*` and accepts the first connector whose mode satisfies
`(h*100)/w >= 3000` (i.e. height/width ≥ 30). On this bench `card0` mode is
60×2170 → ratio 36.2 ✓; `card1` eDP is 2560×1600 → ratio 0.625, rejected ✓.
No DRM name strings are used. **This part is PASS.**

However the **digitizer** discovery is NOT geometry-based. It is purely
name-string based:

```rust
// src/providers/input.rs:69-72
fn is_digitizer(dev: &InputDevice) -> bool {
    let name = dev.name();
    name.contains("Touch Bar") || name.contains("iBridge Touchpad") || name.contains("T1 Controller Touchpad")
}
```

`LibinputProvider::poll` only emits `InputEvent::Touch` for the device that
passes `is_digitizer` (`src/providers/input.rs:106-139`, gated at line 107
`if Some(te.device()) != self.digitizer`). The `seat-touchbar` udev assignment
is relied upon to *narrow the candidate set* but the **final gate is the name
string**. The architecture doc and ADR 001 (`docs/adr/001-architecture.md:43-45`)
claim name-matching is "a supplementary heuristic, not the primary gate" — the
code contradicts the documentation: there is no ABS_MT resolution / geometry
check in `is_digitizer`; the header comment at `src/providers/input.rs:5`
("ABS_MT_POSITION_X resolution matching the Touch Bar width") describes a
check that is **not implemented**.

**MBP14,2 immunity specifically**: The Seborider PR #1 issue names the
digitizer `"Apple Inc. Apple T1 Controller Touchpad"`. The code at
`src/providers/input.rs:71` **does** include `"T1 Controller Touchpad"` as a
substring, so a device literally named `"Apple Inc. Apple T1 Controller
Touchpad"` **would** match (`contains` substring). On THIS bench the device is
`"Apple Inc. iBridge Touchpad"` (also matched). So the substring list covers
both known names — **the daemon itself is immune to the PR #1 name variant**.

The FAIL is for the **invariant**: "ZERO name-string dependencies anywhere
(code, udev, seat rules)". The code has a name-string dependency in
`is_digitizer`. Additionally, the **deployed udev rules** in `backup_old/udev-rules/`
have name-string dependencies and do NOT cover the MBP14,2 name:

```
# backup_old/udev-rules/99-touchbar-seat.rules:3-5
SUBSYSTEM=="input", ATTR{name}=="Apple Inc. Touch Bar Display Touchpad", ENV{ID_SEAT}="seat-touchbar"
SUBSYSTEM=="input", ATTR{name}=="MacBookPro17,1 Touch Bar", ENV{ID_SEAT}="seat-touchbar"
SUBSYSTEM=="input", ATTR{name}=="Mac14,7 Touch Bar", ENV{ID_SEAT}="seat-touchbar"
```

These seat rules do **not** list `"Apple Inc. iBridge Touchpad"` (the name on
this bench) nor `"Apple Inc. Apple T1 Controller Touchpad"` (the PR #1 name).
If the daemon relies on the `seat-touchbar` assignment to narrow candidates
and the udev rule never assigns the seat, the digitizer will sit on `seat0`
and the `tb_input` libinput context (`src/providers/input.rs:56`,
`udev_assign_seat("seat-touchbar")`) will never see it. **This is a real
name-string dependency in the seat rules and it does not cover this bench's
device name nor the PR #1 device name.**

**Affected surface**:
- `src/providers/input.rs:69-72` (`is_digitizer`) — sole digitizer gate
- `src/providers/input.rs:107` — touch events dropped if `digitizer` is `None`
- `backup_old/udev-rules/99-touchbar-seat.rules:3-5` — seat assignment (deploy path)
- `backup_old/udev-rules/99-touchbar-tiny-dfr-mbp142.rules:3-6` — service activation by name
- `docs/architecture.md:140-143` and `docs/adr/001-architecture.md:43-45` — docs claim geometry-only; code disagrees
- `docs/prior-art.md:200,262` — the PR #1 issue is acknowledged but not resolved in udev

### 2.2 Single-writer guard; only the Touch Bar card is ever opened, never card0 — **FAIL (two defects)**

**Defect A — discovery opens every card and grabs master on each.**
`discover_touchbar_drm` (`src/providers/mod.rs:107-118`) iterates **all**
`/dev/dri/card*` entries and calls `probe_drm_device` on each.
`probe_drm_device` (`src/providers/mod.rs:141-146`) opens the card read+write
and calls `card.acquire_master_lock()` (line 146, `let _ =
card.acquire_master_lock();`). On this bench that means the daemon **opens
`card0` (appletbdrm) AND `card1` (i915 eDP)** and attempts to acquire DRM
master on **both** during the scan. The master lock on `card1` (the Intel
display) is taken and then released when the probe `Card` is dropped at the
end of `probe_drm_device`, but:

  1. It momentarily takes master on the **main display**, which can race with
     a running compositor (i915 KMS master contention). On a headless TTY this
     is harmless; under a live Weston/GNOME/X session it can steal the scanout
     and black-blink the laptop panel.
  2. The Touch Bar card (`card0`) is opened **twice** during startup: once
     inside `probe_drm_device` (discovery, master taken and dropped), then
     again inside `try_open_card` (`src/providers/drm_backend.rs:61-66`,
     `open_with_retry` → `discover_touchbar_drm` returns the path, then
     `try_open_card` opens the same path and takes master again). Between the
     two opens the fd is closed, so there is a brief window where no process
     holds master on `card0`. Not a correctness bug, but it is not "open the
     Touch Bar card once and hold it."

**Defect B — the task says "never card0". On this bench the Touch Bar IS
card0.** `/dev/dri/card0` is the `appletbdrm` node (`DEVTYPE=usb_interface`,
`DRIVER=appletbdrm`, `PRODUCT=5ac/8600`). The rule "only the Touch Bar card,
never card0" only holds on machines where the GPU enumerates first. The
geometry scan does correctly identify `card0` as the Touch Bar here, so the
daemon **will** open `card0` — which is correct for this bench but contradicts
a literal reading of "never card0". I am flagging this as a documentation /
expectation mismatch, not a code defect: the real invariant should be "only
the geometry-matched card, never the eDP/GPU card." The code does satisfy
*that* invariant for the final keeper, but violates it during probing (Defect
A).

**Affected surface**:
- `src/providers/mod.rs:105-171` — discovery opens all cards, takes master on each
- `src/providers/drm_backend.rs:189-236` — `open_with_retry` re-opens the matched path
- `docs/architecture.md:136-140` — claims "Scan `/dev/dri/card*`, open each"; the doc admits the scan opens each, so the invariant "only the Touch Bar card" is not actually enforced by the code

### 2.3 All I/O bounded: timeouts, max retries, backoff; no infinite loops; no unwrap() on hardware paths — **FAIL**

Findings:

- **DRM acquire is bounded**: `open_with_retry(30, Duration::from_secs(2))`
  (`src/providers/drm_backend.rs:189-236`, called from `acquire` line 278).
  30 attempts × 2 s = 60 s max. **PASS** for the retry bound.
- **Flush stall backoff is bounded**: `record_flush_duration`
  (`src/providers/drm_backend.rs:263-273`) caps doublings at
  `FLUSH_STALL_MAX_DOUBLINGS = 4` → max cooldown 2·(1<<4) = 32 s
  (`src/providers/drm_backend.rs:42-44`). It does **not** cap the **number**
  of stalls: `stall_count` is `u32` and saturates, but the cooldown is
  recomputed every flush and the loop never gives up or escalates beyond the
  32 s sleep. An indefinitely misbehaving device → indefinite 32 s sleeps.
  This is "bounded per-iteration, unbounded in total." Marginal.
- **The main render loop is an infinite `loop {}` with no exit condition**
  (`src/main.rs:165-323`). There is no `SIGTERM`/`SIGINT` handler, no message
  that breaks the loop, and `real_main` never returns. The only "shutdown" is
  `panic::catch_unwind` (`src/main.rs:81`) which **swallows panics silently**
  and then the process falls off the end of `main` and exits — without calling
  `DisplayProvider::release()`, without destroying the framebuffer, without
  removing the IPC socket, and without dropping the DRM master lock cleanly
  (the `DrmProvider` `Drop` is not `impl Drop`, so master is released only
  when the `Card`'s `File` is dropped by the OS). **This is an unbounded
  loop with no clean shutdown.**
- **`unwrap()` / `expect()` on hardware paths** (from `grep`):

  | Location | Call | Hardware path? |
  |---|---|---|
  | `src/main.rs:77` | `panic!("Touch Bar card never appeared: {}")` | Yes — but this is the *bounded* retry exhaustion; a panic is acceptable as "fail fast," except it bypasses `release()`. |
  | `src/main.rs:85` | `drm.display_info().expect("Failed to get display info")` | **Yes** — panics if the card vanished between acquire and info. |
  | `src/main.rs:95` | `.expect("Failed to open /dev/uinput …")` | **Yes** — hardware `/dev/uinput`. |
  | `src/main.rs:97,99,117,118` | `uinput.set_evbit(…).unwrap()`, `set_keybit(k).unwrap()`, `dev_setup(…).unwrap()`, `dev_create().unwrap()` | **Yes** — uinput ioctls. |
  | `src/main.rs:121` | `SysfsBacklight::new(true, 128).expect("Failed to init backlight")` | **Yes** — sysfs backlight probe. |
  | `src/main.rs:124` | `ConfigManager::new().expect("Failed to init config manager")` | Partially — inotify init, can fail on a restricted system. |
  | `src/main.rs:136,142` | `drm.display_info().unwrap()`, `ImageSurface::create(…).unwrap()` | **Yes** (display_info) / cairo allocation (not hardware but can OOM). |
  | `src/main.rs:191,199,205` | `Context::new(&surface).unwrap()`, `ctx.paint().unwrap()`, `surface.data().unwrap()` | Render path; panics on a damaged surface. |
  | `src/main.rs:338,350` | `uinput.write(…).unwrap()` (×2 in `emit_keys`) | **Yes** — uinput write on every key emission. A single `write` failure kills the daemon. |
  | `src/providers/backlight.rs:30-33` | `read_attr` does `fs::read_to_string(…).unwrap_or_else(|_| panic!("Failed to read {}", attr))` | **Yes** — panics if `brightness`/`max_brightness` sysfs file is unreadable (e.g. device removed at runtime). |
  | `src/widgets/button.rs:65,71,76`, `src/widgets/slider.rs:51,58,69,74` | `ctx.fill().unwrap()`, `text_extents(…).unwrap()`, `show_text(…).unwrap()` | Render path. |
  | `src/fonts.rs:81,86,91,95` | `CString::new(…).unwrap()`, `CStr::to_str().unwrap()` | FFI; `to_str().unwrap()` panics on non-UTF8 font path. |

  The task says "no `unwrap()` on hardware paths." The table above lists
  multiple `unwrap()`/`expect()`/`panic!()` calls directly on DRM, uinput,
  sysfs-backlight, and uinput-write paths. **This is a FAIL.**

- **`map()` dead-end** (`src/providers/drm_backend.rs:239-248`): the public
  `map()` method always returns `Err` ("use flush() instead"). Not a bound
  problem, but it is dead/misleading code.

**Affected surface**:
- `src/main.rs:45-82` (entry), `84-323` (real_main loop), `326-351` (emit_keys)
- `src/providers/drm_backend.rs:239-248` (dead `map`)
- `src/providers/backlight.rs:28-34` (panic on sysfs read)
- `src/widgets/button.rs`, `src/widgets/slider.rs` (render-path unwraps)
- `src/fonts.rs:81-95` (FFI unwraps)

### 2.4 No ACPI calls anywhere, including scripts (T1 hard-freeze risk, ASOC.SOCW(1)) — **PASS (with caveat)**

`grep` for `ACPI|acpi|ASOC|SOCW|_SB\.|acpi_eval` across the whole repo:

- **No ACPI calls in `src/`** (the Rust daemon). Zero matches in any `.rs`
  file. The daemon talks to DRM, libinput, sysfs, uinput, fontconfig — no
  `/proc/acpi`, no `/sys/firmware/acpi`, no `acpi_call`, no `SOCW`.
- Matches are only in **documentation** (`docs/prior-art.md`,
  `lineage-research.md`) describing the prior art, and in
  `src/providers/mod.rs:193` and `backup_old/.../backlight.rs:53` and the old
  udev rule — all three are the **string `"acpi_video0"`** used as a backlight
  sysfs path name to **read** `/sys/class/backlight/acpi_video0/brightness`.
  That is a sysfs read of the kernel's ACPI-video backlight class, **not** an
  ACPI method call. It does not invoke `ASOC.SOCW(1)` or any ACPI method. It
  is safe.
- The `backup_old/systemd/touchbar-suspend-hook` does **not** issue ACPI calls
  either; it does sysfs `unbind`, `bConfigurationValue` writes, `modprobe`,
  PCI remove/rescan. No `acpi_call`.
- `backup_old/ibridge_switcher.c` uses libusb `set_configuration` — no ACPI.

**Caveat (not a FAIL)**: `discover_display_backlight_path`
(`src/providers/mod.rs:189-201`) reads `acpi_video0` brightness as a fallback
for adaptive Touch Bar brightness following. On this bench `acpi_video0`
exists. Reading its `brightness` file is a normal sysfs read, not an ACPI
eval. Safe.

**Verdict: PASS.** No ACPI method calls anywhere in code or scripts.

### 2.5 unsafe blocks justified; error paths release resources (DRM master, sockets, evdev) — **FAIL**

- **`unsafe` blocks** exist only in `src/fonts.rs` (lines 37, 42, 49, 60, 82,
  87, 96, 107) — all FFI to fontconfig. The blocks are **not annotated with a
  SAFETY comment** explaining the invariant (e.g. that `FcInitLoadConfigAndFonts`
  returns a valid pointer or NULL, and that NULL is checked before use). In
  `FontConfig::new` (`src/fonts.rs:36-39`) the returned pointer is stored
  without a NULL check; a NULL `config` would crash on the next FFI call.
  `Pattern::new` (`src/fonts.rs:80-83`) likewise does not check
  `FcNameParse`'s return. The `Drop` impls call `FcConfigDestroy` /
  `FcPatternDestroy` unconditionally. **No SAFETY justification.** Minor
  because fontconfig rarely fails, but the task requires justification.
- `src/providers/drm_backend.rs:243-247` contains a `// SAFETY:` comment inside
  `map()` but that method is dead code (always returns Err) — the comment is
  misleading.

- **Error paths release resources — FAIL.** Specifically:

  1. **`DrmProvider` has no `impl Drop`.** If `real_main` panics (and it can,
     at many `unwrap()`/`expect()` sites listed in 2.3), the `DrmProvider` is
     dropped via `catch_unwind`'s unwind, but `DrmProvider`'s fields (`Card`,
     `DumbBuffer`, `framebuffer::Handle`) are dropped in unspecified order by
     Rust's default drop glue. The `release()` method
     (`src/providers/drm_backend.rs:281-297`) which destroys the framebuffer
     and dumb buffer **in the correct order** is **never called** on the panic
     path or on normal exit (there is no normal exit — the loop never
     returns). The DRM master lock is released only when the `Card`'s `File`
     fd is closed by the kernel on process exit. A framebuffer/dumb-buffer
     leak on the device is possible across restarts until the kernel reclaims
     them. **Resource leak on error path.**
  2. **`IpcServer` is never instantiated by `main`** (see 2.8), so its `Drop`
     (`src/ipc/server.rs:146-149`) that removes the socket is never reached.
     If a future caller binds the socket and then panics, the `Drop` does
     clean up — good — but today the IPC server is dead code.
  3. **`LibinputProvider` has no `Drop`**; libinput handles are leaked on
     exit (acceptable — process death reclaims them).
  4. **`UInputHandle`** in `main.rs:91-118`: on a panic between `dev_create()`
     and the unwind, the uinput device persists until the fd is closed by the
     OS. Acceptable but untidy.

**Affected surface**:
- `src/fonts.rs:36-39, 80-83, 58-62, 105-108` — unchecked FFI pointers, no SAFETY comments
- `src/providers/drm_backend.rs:32-40` (no `impl Drop`), `:281-297` (`release` never called on exit)
- `src/main.rs:81-82` — `catch_unwind` swallows panics, no cleanup

### 2.6 Backlight failure fail-safe = ON (visible), never dark — **FAIL**

`SysfsBacklight::update` (`src/providers/backlight.rs:85-113`):

```rust
let new_bl = self.max_bl.min(if self.lid_closed {
    0
} else if since < BRIGHTNESS_DIM_TIMEOUT_MS {
    if self.adaptive { … Self::display_to_touchbar(…) } else { self.active_brightness }
} else if since < BRIGHTNESS_OFF_TIMEOUT_MS {
    DIMMED_BRIGHTNESS   // = 1
} else {
    0
});
…
self.set_backlight_file(new_bl);
```

`set_backlight_file` (`src/providers/backlight.rs:55-63`) does:

```rust
if let Ok(mut file) = std::fs::OpenOptions::new().write(true).open(self.bl_path.join("brightness")) {
    let _ = write!(file, "{}\n", value);
}
```

**Fail-safe analysis**:

1. **If the sysfs write fails** (`OpenOptions::open` returns Err, or `write!`
   fails), the error is silently discarded (`if let Ok`, `let _ =`). The
   daemon's `current_bl` is still updated to `new_bl` in memory
   (line 107 `self.current_bl = new_bl;` happens before the write at line
   108). So the daemon *thinks* it set the backlight but the hardware may be
   in any state. This is not fail-safe-ON; it is fail-silent.
2. **`display_to_touchbar`** (`src/providers/backlight.rs:65-69`) returns
   `(normalized.powf(0.5) * active_brightness) as u32 + 1` clamped to
   `MAX_TOUCH_BAR_BRIGHTNESS`. The `+ 1` guarantees a minimum of 1 (visible)
   when adaptive and the display brightness is ≥ 0. Good — but only on the
   adaptive path.
3. **Idle path**: after 30 s → `DIMMED_BRIGHTNESS = 1` (visible), after 60 s
   → `0` (dark). The task says "backlight failure fail-safe = ON (visible),
   never dark." The **idle timeout intentionally drives the bar to 0** (dark)
   after 60 s. This is by design (power saving), but it directly contradicts
   "never dark." If "never dark" means "on any *failure* the bar stays lit,"
   then the idle-off is not a failure and is fine — but the **silent write
   failure** in point 1 IS a failure and the bar could stay dark with the
   daemon unaware.
4. **`SysfsBacklight::new`** (`src/providers/backlight.rs:37-53`) calls
   `read_attr` which **panics** (`src/providers/backlight.rs:30`) if the
   brightness sysfs file is missing. So a backlight-device failure at startup
   → panic → daemon dies → bar stays in whatever state the kernel left it
   (could be dark). Not fail-safe-ON.

**Verdict: FAIL.** Silent write failures + startup panic + idle-to-0. The
fail-safe is not enforced; the daemon can leave the bar dark with no alarm.

**Affected surface**:
- `src/providers/backlight.rs:28-34` (panic on read), `:55-63` (silent write), `:85-113` (idle-to-0)
- `src/main.rs:121` (`expect` on backlight init)

### 2.7 `--dry-run` simulated provider exists; IPC security (socket 0600, WS localhost) — **FAIL (dry-run missing); PASS (IPC socket perms); N/A (WS not implemented)**

- **`--dry-run`**: There is **no CLI argument parsing** in `main.rs`. `main`
  (`src/main.rs:45-82`) calls `env_logger::init()` then immediately
  `DrmProvider::new()` + `acquire()`. There is no `clap`, no `std::env::args`
  parsing, no `--dry-run` flag, and no simulated-provider selection. The mock
  providers (`mock_display.rs`, `mock_input.rs`, `mock_backlight.rs`) exist
  but are **only referenced from their module declarations**; `main` never
  uses them. `grep` for `dry` in `src/` returns nothing. **FAIL — no dry-run
  path.** The staged test plan's Stage 1 (dry-run) therefore cannot be run
  against this binary as built.

- **IPC socket permissions — PASS (code), but the server is not wired in.**
  `IpcServer::bind` (`src/ipc/server.rs:34-60`) creates the socket, then
  `std::fs::set_permissions(&path, Permissions::from_mode(0o600))` (lines
  45-50). The 0600 enforcement is correct. **However `IpcServer` is never
  instantiated by `main`** — `grep` for `IpcServer` in `src/main.rs` returns
  zero matches. The entire `src/ipc/` module is compiled but unused at
  runtime. So the 0600 permission is correct *in the dead code*; the live
  daemon does not open any IPC socket at all. The IPC security invariant is
  vacuously satisfied (no socket = no leak) but the **promised IPC API is not
  delivered** in this build.

- **WebSocket localhost-only**: `cargo.toml` has no `tungstenite`/`axum`/WS
  dependency; `grep` for `WebSocket|9170|bind.*127` in `src/` returns nothing.
  WebSocket is not implemented (README and ADR 003 say Phase 3). **N/A** for
  this build.

**Affected surface**:
- `src/main.rs:45-82` — no arg parsing, no dry-run
- `src/ipc/server.rs:34-60` — correct 0600 but never called
- `src/ipc/mod.rs`, `src/ipc/protocol.rs` — compiled, unused at runtime
- `README.md:76-89`, `proto/protocol.md` — document an IPC API the binary does not expose

---

## 3. Summary of findings

| # | Item | Verdict | Blocking? |
|---|---|---|---|
| 1 | `cargo fmt --check` | **FAIL** (exit 1) | No (style only) |
| 2 | `cargo clippy` | PASS (exit 0, 128 warnings) | No |
| 3 | `cargo test` | PASS (11/11) | No |
| 2.1 | Geometry-only discovery, zero name-string deps, MBP14,2 immunity | **FAIL** (digitizer is name-gated; udev seat rules are name-gated and miss both this bench's name and the PR #1 name) | **YES** |
| 2.2 | Single-writer, only Touch Bar card, never card0 | **FAIL** (discovery opens all cards + takes master on the eDP card; Touch Bar is card0 on this bench) | **YES** |
| 2.3 | All I/O bounded, no infinite loops, no unwrap() on hw paths | **FAIL** (infinite loop, no shutdown, many hw-path unwraps/panics) | **YES** |
| 2.4 | No ACPI calls anywhere | PASS | No |
| 2.5 | unsafe justified; error paths release resources | **FAIL** (no SAFETY comments; no `impl Drop` for DrmProvider; `release()` never called) | **YES** |
| 2.6 | Backlight fail-safe ON, never dark | **FAIL** (silent write failure; startup panic; idle-to-0) | **YES** |
| 2.7 | `--dry-run` exists; IPC 0600; WS localhost | **FAIL** (no dry-run; IPC server not wired in; WS N/A) | **YES** |

---

## 4. Go / No-Go recommendation

**NO-GO for hardware contact beyond Stage 0 environment capture.**

Six of the seven substantive invariants are FAIL. Three of them
(name-string digitizer gate + udev seat rules that miss the actual device
name; single-writer/master contention on the eDP card; no dry-run path) mean
that the **Stage 1 (dry-run) and Stage 4 (touch-logging) steps of the test
plan cannot be executed meaningfully** against this binary as built:

- Stage 1 dry-run is impossible — there is no `--dry-run` flag and no
  simulated provider selection in `main`.
- Stage 4 touch-logging will likely see **zero touch events** because the
  udev seat rules in the deploy stack (`backup_old/udev-rules/`) do not list
  `"Apple Inc. iBridge Touchpad"` (the name on this bench), so the digitizer
  will not be assigned to `seat-touchbar`, so `tb_input` will never enumerate
  it, so `is_digitizer` will never even be called on it. (If the seat rules
  are fixed but `is_digitizer` is not, the name substring still happens to
  match `"iBridge Touchpad"` on this bench — but the invariant is still
  violated and the PR #1 name remains a latent break.)
- Running the daemon at all on a live compositor risks a master-contention
  black-blink on the laptop eDP panel during discovery (Defect 2.2.A).

**Per the FREEZE RULE, these findings are logged, not fixed.** Fixes belong
on a branch, after a written root-cause + impact analysis for each FAIL, as
ADRs. The recommended next step is to **stop**, write the ADRs, implement
fixes on a branch, re-run this review, and only then proceed to Stage 0 →
Stage 1.

Stage 0 (environment capture: `dmesg`, `lsusb`, `evtest`, DRM node, module
versions) is **non-destructive and read-only** and may be performed now; it
does not require the daemon to be correct. See `docs/test-plan.md` Stage 0.

---

## 5. Evidence index

- `cargo fmt --check` stdout (Section 1.1)
- `cargo clippy --all-targets` stdout (Section 1.2)
- `cargo test` stdout (Section 1.3)
- `src/providers/mod.rs:105-171` (discovery), `:189-201` (display backlight)
- `src/providers/drm_backend.rs:42-44, 61-66, 189-236, 239-248, 263-273, 277-297`
- `src/providers/input.rs:5, 53-72, 82-150`
- `src/providers/backlight.rs:28-34, 55-63, 65-69, 85-113`
- `src/main.rs:45-82, 84-323, 326-351`
- `src/ipc/server.rs:34-60, 146-149`
- `src/fonts.rs:36-39, 80-83, 58-62, 105-108`
- `src/widgets/button.rs:49-77`, `src/widgets/slider.rs:45-75`
- `backup_old/udev-rules/99-touchbar-seat.rules:3-5`
- `backup_old/udev-rules/99-touchbar-tiny-dfr-mbp142.rules:3-6`
- `docs/architecture.md:136-145`, `docs/adr/001-architecture.md:43-45`
- `docs/prior-art.md:200,262` (Seborider PR #1)
- Bench evidence: `/dev/dri/card0` = appletbdrm 60×2170; `/dev/dri/card1` = i915;
  `input13` = "Apple Inc. iBridge Touchpad"; `lsusb` 05ac:8600; kernel 7.2.6-arch2-1