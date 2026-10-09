# ADR 047: Wire touch → backlight wake (port the oracle's `process_event` semantics)

## Status: Accepted

## Date: 2026-09-27

## Context

Session 043 STAGE 3 PASS rendered end-to-end (tbard ran 54min44s stable as
sole master, first pixels observed) but isolated a localized INPUT defect
with two cooperating symptoms, both derived read-only in
`docs/test-logs/043/findings-abc-code-derived.txt` (Fact 2):

1. **`backlight.notify_activity()` has ZERO call sites in `src/`.** The
   `InputEvent::Touch` arm (`src/main.rs:761-833`) routes touches to the
   gesture classifier + key emission but NEVER resets the backlight's idle
   timer. The only `notify_activity` call (`src/main.rs:839`) targets the
   INPUT provider, whose impl is an intentional no-op
   (`src/providers/input.rs:522-524`). A touch does NOT re-brighten the bar
   through tbard's adaptive path.
2. **A `current_bl == 0` gate drops touches when the bar is dark.**
   `src/providers/input.rs:471`:
   ```rust
   if Some(te.device()) != self.digitizer || self.current_bl == 0 { continue; }
   ```
   `LibinputProvider::current_bl` is initialized to `0` at
   `src/providers/input.rs:89` and is NEVER updated (no setter; only read
   via `current_backlight()` at `:518-520`). Once the bar is dark, digitizer
   events are dropped BEFORE they reach the gesture handler — so no tap log
   AND no wake. Both HC2 symptoms ("touching the bar: NO tap log, NO
   wake/brighten") from ONE root cause.

The HC2 "touch-to-wake" protocol in ADR-046
(`docs/adr/046-runbook-value-only-probe.md:93-96`) describes the intended
behavior aspirationally ("a touch event wakes the bar via tbard's adaptive
`notify_activity` path, resetting `last_active` and re-brightening") but
the wiring was never implemented. ADR-044's audit
(`docs/adr/044-backlight-provider-dispatch-audit.md:206`) claimed
`notify_activity` is "(called via input event path)" and "NO DEFECT" —
this is INCORRECT about the call site (it calls the input provider's no-op,
not the backlight). This ADR corrects that claim and lands the wiring.

## Task 0 — Derivation D1 (wake semantics, from the oracle) — CONFIRMED

The oracle is `backup_old/tiny-dfr-mbp142/` (read-only reference). Its wake
semantics, derived from `backup_old/tiny-dfr-mbp142/src/main.rs` and
`backup_old/tiny-dfr-mbp142/src/backlight.rs`:

### D1a — What calls `notify_activity` in the oracle, and does a TOUCHBAR touch wake a dark bar?

The oracle does NOT have a method literally named `notify_activity`. The
wake path is `BacklightManager::process_event(&event)`
(`backup_old/tiny-dfr-mbp142/src/backlight.rs:102-118`):

```rust
pub fn process_event(&mut self, event: &Event) {
    match event {
        Event::Keyboard(_) | Event::Pointer(_) | Event::Gesture(_) | Event::Touch(_) => {
            self.last_active = Instant::now();   // ← the wake
        }
        Event::Switch(SwitchEvent::Toggle(toggle)) => {
            if let Some(Switch::Lid) = toggle.switch() {
                self.lid_state = toggle.switch_state();
                if toggle.switch_state() == SwitchState::Off {
                    self.last_active = Instant::now();   // lid-open also wakes
                }
            }
        }
        _ => {}
    }
}
```

The SOLE call site is the top of the per-event loop, BEFORE the touch gate:
`backup_old/tiny-dfr-mbp142/src/main.rs:1037`:
```rust
for event in &mut input_tb.clone().chain(input_main.clone()) {
    backlight.process_event(&event);        // ← wakes on EVERY event, first
    match event {
        ...
        Event::Touch(te) => {
            if Some(te.device()) != digitizer || backlight.current_bl() == 0 {
                continue;                    // ← gate runs AFTER process_event
            }
            ...
```

**Verdict (D1a): a TOUCHBAR touch DOES wake a dark bar in the oracle.**
`process_event` runs UNCONDITIONALLY on every event (including
`Event::Touch`) and resets `last_active = Instant::now()` BEFORE the
`current_bl == 0` gate at `:1068` is evaluated. A touch on a dark bar
resets `last_active`; the subsequent `update_backlight` at `:1108` then
computes `since < BRIGHTNESS_DIM_TIMEOUT` → `display_to_touchbar(...)` (a
non-zero level) and writes it, lighting the bar. The touch itself is
DROPPED by the gate (no button hit processed on the waking touch), but the
WAKE succeeds. The next touch (bar now lit, `current_bl != 0`) passes the
gate and is processed normally.

This is the macOS Touch Bar UX: **touch wakes the bar; subsequent touches
process.** The waking touch is consumed by the wake; it does not also
trigger a button.

### D1b — Does the oracle carry the same `current_bl == 0` dark-gate?

**YES — the gate is a designed behavior, NOT a port distortion.** The
oracle has the identical gate at
`backup_old/tiny-dfr-mbp142/src/main.rs:1068`:
```rust
if Some(te.device()) != digitizer || backlight.current_bl() == 0 {
    continue;
}
```
The gate's purpose: when the bar is intentionally dark (idle > 60s →
`update_backlight` wrote 0), a touch should WAKE (reset `last_active`) but
NOT trigger a button (the user did not see the button they were touching on
a dark bar). This is deliberate: the wake happens via `process_event` (pre-
gate); the button-processing is gated by `current_bl != 0` (post-wake).

### D1c — Where the port distorted the design (the actual defect).

The port preserved the gate (`src/providers/input.rs:471`) but DROPPED the
pre-gate wake (`process_event` has no equivalent in the port's render loop).
It ALSO broke the gate's premise: the oracle's `current_bl` is initialized
from the ACTUAL sysfs brightness at construction
(`backup_old/tiny-dfr-mbp142/src/backlight.rs:91`:
`current_bl: read_attr(&bl_path, "brightness")`) and is updated on every
`update_backlight` write (`:143`). The port's `LibinputProvider::current_bl`
is initialized to `0` (`src/providers/input.rs:89`) and NEVER updated — so
the gate is stuck-closed once the bar is dark, which the oracle never
experiences (the oracle's `current_bl` tracks the real level).

So the port has TWO cooperating bugs:
- (i) the pre-gate wake (`process_event`) is absent → a touch never resets
  `last_active`;
- (ii) the gate's `current_bl` is stuck at 0 → the gate is closed even when
  the bar is lit by the adaptive loop (the `SysfsBacklight` writes 54, but
  `LibinputProvider::current_bl` is never told).

### D1d — Intended UX verdict.

**Touch wakes the bar (macOS behavior); subsequent touches process.** The
gate STAYS — it is designed. The wake must happen BEFORE the gate, on EVERY
touch event, by resetting the backlight's `last_active` (not the input
provider's no-op). The gate's `current_bl` must track the real backlight
level (so the gate opens once the wake lights the bar).

## Task 0 — Derivation D2 (libinput open timing + log handler) — CONFIRMED (post-drop-open REFUTED for the digitizer fd; log-handler REFUTED-for-FFI)

### D2a — When does the LibinputProvider context first dispatch relative to privdrop?

`LibinputProvider::new` creates the two `Libinput::new_with_udev(Interface)`
contexts and assigns the seats at `src/providers/input.rs:79-83`. The
contexts are created PRE-drop (the `LibinputProvider` is constructed at
`src/main.rs:334` in the service arm, BEFORE the privdrop at
`src/main.rs:459`). `init()` (`src/providers/input.rs:429-444`) calls
`self.tb_input.dispatch()` + `self.main_input.dispatch()` and then
`identify_digitizer()` — ALL pre-drop (init is called at `src/main.rs:335`,
before the drop at `:459`).

`identify_digitizer` (`src/providers/input.rs:155-217`) opens the digitizer's
evdev node read-only PRE-drop (`:175-182`, root can open it) and HOLDS the
fd in `digitizer_evdev_fd` (`:203`) for the daemon's lifetime. The
libinput context's OWN fd (the seat-touchbar epoll fd) is opened by
libinput during `udev_assign_seat` / `dispatch` — also pre-drop (the
context exists before the drop). The post-drop self-check at
`src/main.rs:471` verifies the seat-touchbar libinput fd is held
(`required_fds.digitizer = Some(input.seat_touchbar_raw_fd())` at `:426`).

**Verdict (D2a): the first dispatch AND the digitizer evdev open both
happen PRE-drop.** The "silent-post-drop-open" hypothesis (that the
digitizer evdev node is re-opened post-drop and EACCESes under nobody) is
**REFUTED for the digitizer fd** — ADR-036 already fixed this by holding
the evdev fd. The libinput context's own fd is also opened pre-drop.

### D2b — Is a libinput log handler installed?

**NO — and the `input` 0.9 crate does NOT expose the libinput log-handler
FFI.** `grep -rn "log_handler\|LogHandler\|libinput_log"
input-0.9.1/src/` returns zero matches; the crate's `Libinput` API
(`input-0.9.1/src/context.rs`) exposes `new_with_udev` / `new_from_fd` /
`dispatch` / `udev_assign_seat` but NOT `libinput_log_set_handler`. The
oracle (`backup_old/tiny-dfr-mbp142/src/main.rs`) also installs no log
handler. Installing one would require reaching past the safe wrapper into
raw `input-linux-sys` FFI (`libinput_log_set_handler` +
`libinput_log_set_priority`) — out of scope for this ADR and not what the
brief's "errors visible" intent requires.

**The spirit of the requirement (errors visible) is already met by a
different mechanism:** `env_logger::init()` is called at `src/main.rs:133`,
and ADR-045 set `RUST_LOG=info` in the installed unit. The `input` crate
maps libinput's internal errors to `Err` on `dispatch()` / `udev_assign_seat`,
which our code already propagates: `init()` (`src/providers/input.rs:429-
444`) returns `Err` on dispatch failure (propagated to exit 1 in service
mode at `src/main.rs:343-345`); `poll()` (`:449-450`) uses
`unwrap_or(())` on dispatch (a dropped event-batch, not a silent-dark
path). To close the "item-11 blind spot" (dispatch errors visible) WITHOUT
raw FFI, this ADR changes `poll()`'s dispatch from `unwrap_or(())` to a
`warn!` on `Err` — so a post-drop dispatch failure (the rare case the
held-fd pattern does not cover) is visible in the journal at INFO+.

### D2c — Is there a SECOND input defect once the gate/wake are fixed?

**No.** Once D1's wake is wired (touch → `backlight.notify_activity()` pre-
gate) and the gate's `current_bl` tracks the real backlight level, the
input path is complete: a touch wakes (resets `last_active` → next
`update()` lights the bar → `current_bl` advances → gate opens) and the
next touch passes the gate to the gesture handler. The post-drop-open
hypothesis (D2a) is refuted for the digitizer fd (ADR-036 holds it); the
libinput context fd is also pre-drop. The only residual is the
`unwrap_or(())` on `poll()`'s dispatch (D2b) — this ADR makes it a `warn!`.

## Decision

### 1. Wire touch → `backlight.notify_activity()` BEFORE the gate-equivalent.

The port splits the oracle's single event loop into `input.poll()` (which
emits `InputEvent`s) and the render loop's match on those events. The
oracle's `process_event` runs on the RAW libinput `Event` before any gate;
the port's equivalent must run on the `InputEvent::Touch` BEFORE the
gesture classifier (so a waking touch resets `last_active` even though it
will not produce a gesture). Concretely, in `real_main`
(`src/main.rs:761`), the `InputEvent::Touch` arm calls
`backlight.notify_activity()` FIRST, then processes contacts:

```rust
InputEvent::Touch(contacts) => {
    // ADR 047: wake the bar on ANY touch (ports the oracle's
    // process_event pre-gate wake; D1). A touch on a dark bar resets
    // last_active; the loop-bottom update() lights the bar; the
    // NEXT touch (current_bl != 0) passes the gate and processes.
    // The waking touch itself is consumed by the wake (macOS UX).
    backlight.notify_activity();
    for contact in contacts { ... }   // existing gesture path
}
```

The `InputEvent::Activity` arm (`src/main.rs:838-840`) currently calls
`input.notify_activity()` (the input provider's no-op). It is repurposed
to ALSO call `backlight.notify_activity()` (keyboard/switch/catch-all
activity wakes the bar too, matching the oracle's `process_event` which
wakes on `Keyboard`/`Pointer`/`Gesture`/`Touch` and lid-open).

### 2. Make the gate's `current_bl` track the real backlight level.

The gate at `src/providers/input.rs:471` reads `self.current_bl`. The port
must update this from the backlight's actual level each poll, so the gate
opens once the wake lights the bar. Add a `set_current_backlight(u32)`
setter on `InputProvider` and call it from the render loop AFTER
`backlight.update()` (the loop-bottom write that sets the real level):
`input.set_current_backlight(backlight.brightness())`. The trait gains a
default no-op `set_current_backlight` so mocks/sim are unaffected;
`LibinputProvider` overrides it to store the value the gate reads.

This keeps the gate's designed semantics (a touch on a dark bar wakes but
does not trigger a button) while fixing the stuck-at-0 defect: after the
wake's `update()` writes 54, `set_current_backlight(54)` opens the gate
for the next touch.

### 3. `poll()` dispatch errors visible (D2b).

Change `self.tb_input.dispatch().unwrap_or(())` /
`self.main_input.dispatch().unwrap_or(())` at
`src/providers/input.rs:449-450` to `warn!` on `Err`:
```rust
if let Err(e) = self.tb_input.dispatch() {
    log::warn!("tbard: seat-touchbar libinput dispatch failed: {}", e);
}
```
This closes the item-11 blind spot (a post-drop dispatch failure is now
visible at INFO+ in the journal) without raw libinput-FFI log-handler
work the `input` crate does not expose.

### 4. Self-check extended: assert the context holds a live touch device.

The post-drop self-check (`src/main.rs:468-475`) currently verifies the
seat-touchbar libinput FD is held (`required_fds.digitizer`), which proves
the CONTEXT is usable post-drop but NOT that a touch DEVICE was
identified. Extend `identify_digitizer`'s success to be asserted in the
self-check: in service mode, after `init()` succeeds, assert
`input.digitizer_is_identified()` (new accessor) is `true`. If
`identify_digitizer` returned `Ok(())` (service arm — `init`'s `Err`
already exits 1 at `src/main.rs:343-345`), the digitizer IS identified;
the self-check re-asserts it so a future regression that decouples `init`'s
return from the digitizer state is caught. Fail loudly (exit 1) otherwise.

### 5. Tap/processing log lines at INFO.

The tap log (`src/main.rs:786-794`) and swipe log (`:804-817`) are already
`info!` (Fact 1). This ADR adds an INFO line on the wake path
(`tbard: touch wake → backlight.notify_activity()`) so the wake is visible
in the journal — the HC2 touch-to-wake protocol's reliable witness.

### 6. Sim path stays hermetic.

`SimInputProvider` and `MockInput` get the default no-op
`set_current_backlight`; the sim's `poll()` does not gate on
`current_bl` (it has no dark-bar concept). The render-loop call to
`input.set_current_backlight(backlight.brightness())` is a no-op for the
sim/mock. No sim test changes.

## Alternatives considered

- **Remove the `current_bl == 0` gate entirely.** Rejected: the gate is
  DESIGNED (D1b — the oracle has the identical gate). Removing it would
  let a touch on a dark bar trigger a button the user could not see,
  diverging from the macOS UX and the oracle. The defect is the stuck
  `current_bl`, not the gate.
- **Wire the wake inside `LibinputProvider::poll` (before emitting
  `InputEvent::Touch`).** Rejected: `poll()` does not have a reference to
  the backlight provider (it is `&mut self` on the input provider only).
  Routing the wake through the render loop's `InputEvent::Touch` arm keeps
  the provider traits decoupled (ADR-005 — the engine loop is
  provider-agnostic) and matches the oracle's "wake on the event, then
  gate" ordering.
- **Make `LibinputProvider::current_bl` read the sysfs brightness directly
  each poll.** Rejected: the input provider must not open sysfs post-drop
  (NF-020-A — nobody cannot open the backlight brightness file; ADR-019
  holds the fd in the backlight provider, not the input provider). The
  setter pattern keeps the backlight as the single owner of the brightness
  value (coordinates with ADR-048's "one owner" contract) and the input
  provider as a consumer.
- **Install a raw-FFI libinput log handler.** Rejected: the `input` 0.9
  crate does not expose `libinput_log_set_handler`; reaching into
  `input-linux-sys` for the FFI is out of scope and would bypass the safe
  wrapper's invariants. The `warn!`-on-dispatch-Err change (D2b) closes
  the "errors visible" intent without raw FFI.

## Impact list

- `src/providers/mod.rs` — `InputProvider` trait gains
  `fn set_current_backlight(&mut self, _bl: u32) {}` (default no-op).
- `src/providers/input.rs` — `LibinputProvider` overrides
  `set_current_backlight` to store the value the gate reads; `poll()`'s
  dispatch `unwrap_or(())` → `warn!` on `Err`; new
  `digitizer_is_identified()` accessor for the self-check.
- `src/main.rs` — `InputEvent::Touch` arm calls
  `backlight.notify_activity()` first; `InputEvent::Activity` arm calls
  `backlight.notify_activity()` (in addition to the input no-op); loop-
  bottom calls `input.set_current_backlight(backlight.brightness())` after
  `backlight.update()`; service-arm post-drop self-check asserts
  `input.digitizer_is_identified()`.
- `src/providers/mock_input.rs` — inherits the default no-op
  `set_current_backlight` (no change).
- `src/providers/sim_input.rs` — inherits the default no-op
  `set_current_backlight` (no change; verify).
- `docs/adr/047-wire-touch-to-backlight-wake.md` — this file (new).
- `docs/adr/044-backlight-provider-dispatch-audit.md` — correction note:
  the "notify_activity (called via input event path) — NO DEFECT" claim
  at `:206` is incorrect about the call site; ADR-047 lands the wiring.
- `docs/test-plan.md` — ADR-047 note on the wake path + the new INFO
  witness line.
- `CHANGELOG.md` — `[Unreleased — ADR-047 input wake wiring]` subsection.
- `devlog.md` — session 044 entry (ADR-047 section).
- `docs/self-assessment-15.md` — claims C-047.

Tests (one commit, gates green):
- Wiring test: `InputEvent::Touch` → `backlight.notify_activity()` called
  → `backlight.update()` writes (mock chain).
- Gate test: touch while dark wakes (notify_activity resets last_active →
  update lights → set_current_backlight opens gate).
- Log-handler test: `poll()` dispatch `Err` → `warn!` emitted (not
  silent). [Covered by the `warn!` path; a unit test asserting the warn
  fires is not feasible without a libinput context that errors on demand,
  so the test is the `warn!` line's presence + the existing dispatch
  coverage. The self-check extension is unit-tested.]
- Self-check test: service arm asserts `digitizer_is_identified()`.
- Sim path hermetic: existing sim tests unchanged (verify count).

## References

- `backup_old/tiny-dfr-mbp142/src/backlight.rs:102-118` — the oracle's
  `process_event` (the wake; resets `last_active` on Keyboard/Pointer/
  Gesture/Touch + lid-open).
- `backup_old/tiny-dfr-mbp142/src/main.rs:1037` — the SOLE call site,
  BEFORE the gate at `:1068`.
- `backup_old/tiny-dfr-mbp142/src/backlight.rs:91` — the oracle's
  `current_bl` initialized from the REAL sysfs brightness (the port's
  stuck-at-0 distortion).
- `src/providers/input.rs:471` — the gate (designed; preserved).
- `src/providers/input.rs:89` — `current_bl: 0` (the stuck-at-0 defect).
- `src/main.rs:761-833` — `InputEvent::Touch` arm (no wake call today).
- `src/main.rs:838-840` — `InputEvent::Activity` → `input.notify_activity()`
  (no-op).
- `src/providers/backlight.rs:202-204` — `SysfsBacklight::notify_activity`
  (the override; DEAD today — this ADR wires it).
- `docs/test-logs/043/findings-abc-code-derived.txt` Fact 2 — the read-only
  audit that established the defect.
- `docs/adr/044-backlight-provider-dispatch-audit.md:206` — the incorrect
  "NO DEFECT" claim (corrected by this ADR).
- `docs/adr/036-digitizer-fd-pre-drop.md` — the held-fd pattern (D2a).
- `docs/adr/046-runbook-value-only-probe.md:93-96` — the aspirational
  wake-to-bright description this ADR implements.