# ADR-057: Wake-Before-Gate — Fix the Dark-Bar Touch Death

## Status
Proposed (session 055, derived from oracle source comparison)

## Context

### The symptom
Session 055 (Stage-4 completion interlock): touching a dark bar does not wake
it. Keyboard activity does. The journal shows wake lines for touches that
*passed* the gate (while the bar was still lit from startup), but once the bar
decays to 0, no further wake lines appear — touches are silently dropped.

### Root cause (derived from oracle source comparison)

The oracle (`backup_old/tiny-dfr-mbp142/src/main.rs:1037-1068`) calls
`backlight.process_event(&event)` on **every** event **BEFORE** the
current_bl==0 gate at :1068. The wake (resetting `last_active`) fires
unconditionally; the gate then drops the *button-hit* for the waking touch.

Our engine's gate lives inside `LibinputProvider::poll()` (input.rs:516):
```rust
if Some(te.device()) != self.digitizer || self.current_bl == 0 {
    continue;  // touch DROPPED — never becomes an InputEvent
}
```
Touches on a dark bar are dropped in `poll()`, before they become
`InputEvent::Touch` events. The `notify_activity()` call in main.rs:800
only fires for events that *survive* `poll()` — so a touch on a dark bar
never wakes the backlight.

A second issue compounds this: `self.current_bl` in the input provider is
pushed via `set_current_backlight()` at main.rs:901, one loop iteration
*after* `backlight.update()` writes the new value. This creates a one-
iteration lag where the gate reads a stale value.

### The two defects

1. **Gate-before-wake** (structural): the gate in `poll()` drops touches
   before the wake can fire. The oracle's ordering is wake-then-gate.

2. **Stale push** (ADR-047's design): `set_current_backlight` pushes the
   backlight's level into the input provider one iteration late. The oracle
   reads `current_bl` directly from the backlight manager (no push).

## Decision

### Fix: move the gate to main.rs, after notify_activity; read backlight directly

1. **Remove the gate from `poll()`**: `LibinputProvider::poll()` returns ALL
   digitizer touches as `InputEvent::Touch`, regardless of `current_bl`.
   Non-digitizer touches are still filtered (device != digitizer → `Activity`).

2. **Move the gate to main.rs**: in the `InputEvent::Touch` arm, call
   `backlight.notify_activity()` FIRST (the wake), then check
   `backlight.brightness() == 0` (the gate). If the bar is dark, the touch
   is consumed by the wake (no gesture processing, no hit_test, no
   injection) — matching the oracle's macOS semantics.

3. **Read `backlight.brightness()` directly** (option "b"): the input
   provider no longer stores `current_bl` or implements
   `set_current_backlight`. The gate reads the real value from the
   backlight provider at the point of decision — no stale push, no
   one-iteration lag.

4. **Remove `set_current_backlight`** from the `InputProvider` trait, all
   impls, and the call site. The push mechanism (ADR-047) is superseded
   by the direct read.

### What changes

- `InputProvider::poll()` no longer gates on backlight — it returns all
  digitizer touches.
- `InputEvent::Touch` arm in main.rs: `notify_activity()` fires
  unconditionally; the gate (`backlight.brightness() == 0`) decides
  whether to process the touch or consume it as a wake-only event.
- `InputProvider::set_current_backlight` removed from trait + impls.
- `InputProvider::current_bl` field removed from `LibinputProvider`.
- `MockInput::current_bl` unchanged (it returns its own value for tests).
- The `RecordingInput` test wrapper loses `set_bl_calls` (no longer
  needed); tests assert `notify_calls` (the wake) + the gate's effect
  via mock backlight's `brightness()`.

### Faithful to the oracle

The oracle's flow per loop iteration:
1. dispatch → for each event: `process_event(wake)` → gate → process
2. `update_backlight()` at loop-bottom

Our flow after the fix:
1. `poll()` → dispatch → return all digitizer touches as `InputEvent::Touch`
2. main.rs: `notify_activity(wake)` → gate (`brightness() == 0?`) → process
3. `backlight.update()` at loop-bottom

The wake fires before the gate in both designs. The gate reads the real
backlight level in both designs. The only difference is our gate is in
main.rs (after poll) vs the oracle's inline (before hit_test) — functionally
identical.

## Consequences

- A touch on a dark bar fires `notify_activity()` → the loop-bottom
  `update()` writes the curve value (~54) → the bar lights → the NEXT
  iteration's touch passes the gate and processes. Same as the oracle.
- The waking touch is consumed (no gesture, no hit_test, no injection) —
  macOS semantics, as designed.
- The `set_current_backlight` push mechanism (ADR-047) is removed;
  ADR-047's wake wiring (`notify_activity` in the Touch arm) is preserved
  and now actually fires for dark-bar touches.
- Tests: the ADR-047 gate/wake tests are updated to assert
  `notify_activity` fires + the gate (via mock backlight `brightness() == 0`)
  consumes the touch; the `set_current_backlight` assertions are removed.

## Alternatives considered

- **Option (a)**: push `set_current_backlight` after `backlight.update()`
  (fixing the one-iteration lag). Rejected: doesn't fix the structural
  gate-before-wake bug — the gate in `poll()` still drops the touch before
  `notify_activity` can fire.

- **Option (c)**: force an immediate `update()` tick on `notify_activity`.
  Rejected: couples the input handler to the backlight's update schedule;
  the oracle doesn't do this (it relies on the loop-bottom update).

## Test plan

- Unit: mock backlight starts at 0; touch event → assert `notify_activity`
  fired (wake); assert no hit_test/injection (gate consumed it); then mock
  backlight at 54 → touch → assert hit_test ran (gate passed).
- Integration: the ADR-047 wake test (`test_adr047_touch_fires_backlight_
  notify_activity_and_wakes`) is updated: the touch fires `notify_activity`
  even when `current_bl == 0` (the fix); the gate consumes it.
- Regression guard: a test asserting `poll()` returns digitizer touches
  regardless of backlight level (the gate is NOT in poll anymore).
- Stage-4 hardware: touch a dark bar → bar lights (the acceptance).
