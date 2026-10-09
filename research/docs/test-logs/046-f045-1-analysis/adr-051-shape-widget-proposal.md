# ADR-051 (proposed): shape-drawn no-action widget for the validation page

**Status**: Proposed (not accepted — root-cause research output, session 046)
**Date**: 2026-09-27
**Origin**: F-045-1 adjudication (docs/test-logs/046-f045-1-analysis/task1-content-derivation.md, task3-ab-discrimination-plan.md)

## Context

The render-only validation page (`examples/render-only-validation-page.yaml`) is the Stage-4/5 observation page. Its "no injection during render-only observation" guarantee was verified by the s044 Stage-4 test (`src/config/yaml.rs:268-335`, `test_adr049_render_only_validation_page_has_zero_key_actions`) — but that test verified PARSE + ZERO-ACTIONS, NEVER VISIBILITY.

Every visible widget on the render-only page is a `ButtonWidget` that renders TEXT (white text on a black rounded-rect background — `src/widgets/button.rs:52-102`). The `time` widget is built as `ButtonWidget::new("⏰", [])` (`src/main.rs:1179-1185`) — also text. The `spacer` renders nothing (`button.rs:131-133`).

**If cairo's text rasterization fails** (font miss, fontconfig init failure, sandbox restriction), `ctx.show_text()` silently renders nothing — no panic, no error, no WARN. The entire page rasterizes to all-black. The Touch Bar is an LCD panel: an all-black framebuffer blocks the backlight at any brightness. The bar appears DARK — indistinguishable from a backlight failure.

This is the test gap that allowed F-045-1's "NOT a render issue" claim to go unchallenged: the content side was never checked, and the page has no shape-only widget that would be visible even if text fails.

## Decision

Add at least one **SHAPE-drawn, no-action widget** to the validation page — a widget that renders a visible shape (e.g. a filled rectangle or circle) via cairo path operations (`ctx.rectangle()` + `ctx.fill()`), WITHOUT depending on `ctx.show_text()`. This makes the page visible even if text rasterization fails.

### Implementation (design only — no `src/` changes in session 046)

1. Add a `WidgetDef::shape` variant to `src/config/yaml.rs`:
   ```yaml
   - type: shape
     fill: 0.5  # gray value 0.0–1.0
     stretch: 1
   ```
2. Add a `ShapeWidget` to `src/widgets/` (or extend `SpacerWidget` with an optional fill):
   ```rust
   impl Widget for ShapeWidget {
       fn render(&self, ctx: &cairo::Context, rect: Rect, _active: bool) {
           ctx.set_source_rgb(self.fill, self.fill, self.fill);
           ctx.rectangle(rect.x, rect.y, rect.w, rect.h);
           ctx.fill().unwrap();
       }
       fn tap_action(&self) -> Option<Vec<input_linux::Key>> { None }
   }
   ```
3. Add the shape widget to `examples/render-only-validation-page.yaml` as the FIRST widget (leftmost — the first thing the human sees).
4. Amend the s044 test (`src/config/yaml.rs:268-335`) to ALSO assert the page has at least one shape-drawn widget (a visibility guarantee, not just a safety guarantee).

### The shape widget as a render-only probe

The shape widget serves a dual purpose:
- **Visibility guarantee**: the page is visible even if text fails.
- **Diagnostic probe**: if the shape is visible but the text isn't → text rasterization is the problem. If neither is visible → the scanout/backlight is the problem. This discriminates the content hypothesis (HC) from H1–H4 in one observation.

## Consequences

- The validation page gains a visible element that does not depend on fontconfig/freetype.
- The s044 test gains a visibility assertion (the page must have at least one shape-drawn widget).
- The F-045-1 "NOT a render issue" claim becomes testable: if the shape widget glows on the next run, the content hypothesis is confirmed and H1–H4 are refuted.
- No production behavior change — the shape widget has `tap_action() -> None` (no key injection).

## Relation to ADR-052

ADR-051 is the MINIMAL fix (make the validation page visible without text). ADR-052 (candidate) is the BROADER fix (make text rasterization reliable under the sandbox for production-intended labels/time/battery). ADR-051 is sufficient for the validation page; ADR-052's scope depends on whether text widgets are production-intended or Phase-2 placeholders.