# ADR 002: Widget Engine and Gesture Recognition

## Status: Accepted

## Date: 2026-09-24

## Context

The original `tiny-dfr` renders a flat row of buttons in two fixed layers
(F-keys and media keys). Touch input is handled as simple tap/click on a
button with drag-to-stay-pressed. There is no gesture recognition, no
slider/dial support, and no way to add widgets at runtime.

The new engine must support:
- **Taps** (instant press-release within 300ms and 20px)
- **Horizontal swipes** (for sliders and pagers)
- **Sliders** (drag to set a 0-1 value)
- **Dials** (circular gesture, future)
- **Custom pages** pushed via IPC

## Decision

### Widget trait (`src/widgets/mod.rs`)

Every widget implements:
```rust
pub trait Widget {
    fn stretch(&self) -> usize;           // width multiplier
    fn render(&self, ctx, rect, active);   // cairo drawing
    fn needs_periodic_redraw(&self) -> bool; // for clocks/battery
    fn handle_gesture(&mut self, g: &Gesture); // swipe/tap
    fn tap_action(&self) -> Option<Vec<Key>>; // key emission
}
```

Widgets are type-erased as `Box<dyn Widget + Send + Sync>` (`BoxedWidget`).

### Gesture state machine (`src/widgets/mod.rs`)

Touch contacts are tracked per-slot through a `GestureState` enum:
- `Down` → finger just touched (record position + timestamp)
- `Moving` → finger moved beyond threshold (may become a swipe)
- `Up` → finger lifted

The `update_gesture()` function transitions between states and emits:
- `Gesture::Tap` if duration ≤ 300ms and displacement < 20px
- `Gesture::HorizontalSwipe` if horizontal delta > 20px and vertical < 30px

### Page layout (`src/widgets/page.rs`)

A `Page` is a horizontal row of widgets. Layout is computed by distributing
available width in proportion to each widget's `stretch()` factor, with 16px
spacing between widgets. Hit-testing checks whether touch coordinates fall
within a widget's allocated `Rect`.

### Unit tests

Three hit-test tests verify layout geometry:
- `test_hit_test_basic` — 3 equal-width buttons, verify each is hit correctly
- `test_hit_test_stretch` — stretch=3 + stretch=1, verify hit regions
- `test_hit_test_y_bounds` — y outside [0, height] misses

## Consequences

- **Positive**: Sliders and pagers are first-class widgets. Any widget can
  receive gesture events. The page layout is fully deterministic and testable.
- **Negative**: The current render pipeline is still monolithic in `main.rs`
  (Phase 2 will extract a proper `Engine` struct). Dial gestures are stubbed
  for future implementation.
- **Trade-off**: `Box<dyn Widget + Send + Sync>` avoids generic monomorphization
  bloat but requires dynamic dispatch on every render frame. For a 60Hz
  display with ≤20 widgets, this is negligible.

## References

- `src/widgets/mod.rs` — Widget trait, Gesture, GestureState, update_gesture
- `src/widgets/button.rs` — ButtonWidget, SpacerWidget
- `src/widgets/slider.rs` — SliderWidget
- `src/widgets/page.rs` — Page layout + hit tests