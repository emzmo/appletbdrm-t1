# ADR 051: Visible-by-construction validation page (shape-drawn, zero-action widget)

## Status: Accepted

## Date: 2026-09-27

## Context

Session 047's A/B discrimination interlock
(`docs/test-logs/047-ab/REPORT.md`) CONFIRMED the content hypothesis
for F-045-1: Run A (tbard + default page) glows, Run B (tbard +
render-only validation page) is dark, with the DRM scanout state
IDENTICAL in both runs (plane-0 → fb 41 → crtc-0 active → USB-1;
`docs/test-logs/047-ab/runA-step4a-dri2-state.log` and
`runB-step4a-dri2-state.log`). The differential is the CONTENT. H1–H4
(backlight/DRM-side) are refuted.

The render-only validation page
(`examples/render-only-validation-page.yaml`) is the Stage-4/5
observation page. Its "no injection during render-only observation"
guarantee was verified by the s044 test
(`src/config/yaml.rs:279-335`,
`test_adr049_render_only_validation_page_has_zero_key_actions`) — but
that test verified PARSE + ZERO-ACTIONS, NEVER VISIBILITY. Every
visible widget on the page is text-dependent, so when text
rasterization fails (the confirmed root cause), the entire framebuffer
is all-black and the bar appears dark at any brightness —
indistinguishable from a backlight failure. This is the test gap that
let F-045-1's "NOT a render issue" claim go unchallenged.

### Draw-path derivation (from code)

The esc button (the SHAPE path that glowed in Run A) is a
`ButtonWidget` constructed at `src/main.rs:1196`
(`ButtonWidget::new("esc", vec![Key::Esc])`) and auto-inserted at
`src/main.rs:1195-1198` when `width >= ESC_THRESHOLD`. Its render path
lives in `src/widgets/button.rs:52-102`:

- **SHAPE** (`src/widgets/button.rs:60-87`): a rounded-rect background
  drawn via four `ctx.arc(...)` calls (`button.rs:67-83`) + a
  `ctx.close_path()` (`button.rs:84`) + `ctx.set_source_rgb(...)`
  (`button.rs:85`) + `ctx.fill().unwrap()` (`button.rs:86`). The fill
  color is `0.400` when active, `0.0` otherwise (`button.rs:53-59`).
  This path has ZERO font dependency — it is pure cairo path geometry.
  It is skipped only when `self.label == "_spacer"` (`button.rs:61`),
  the spacer sentinel.
- **TEXT** (`src/widgets/button.rs:88-101`): `ctx.select_font_face(...)`
  (`button.rs:90-94`) + `ctx.set_font_size(24.0)` (`button.rs:95`) +
  `ctx.text_extents(&self.label).unwrap()` (`button.rs:96`) +
  `ctx.show_text(&self.label).unwrap()` (`button.rs:101`). This path
  depends on fontconfig/freetype resolving "sans-serif"; on font
  failure cairo's toy text API silently renders nothing (no panic, no
  error — `.unwrap()` unwraps `Ok(())`).

So the esc button's SHAPE glowed in Run A because Run A used the
default page (esc button auto-inserted, label "esc" != "_spacer", so
the rounded-rect fill drew at color `0.0`... wait — inactive fill is
`0.0` = black). The glow in Run A is the TEXT ("esc" rendered white at
`button.rs:89`), NOT the shape. The shape's inactive fill is black
(`button.rs:58-59`). Run A glows because text rendered; Run B is dark
because text did not. Either way, the lesson holds: the page has NO
widget that is visible BY CONSTRUCTION (a non-black shape independent
of text). The esc button is not a safe visibility probe — its shape is
black when inactive, and its visibility depends on text.

The `SliderWidget` render path (`src/widgets/slider.rs:48-82`) DOES
draw a non-black shape independent of text: a background bar at
`slider.rs:52-54` (`set_source_rgb(0.15,0.15,0.15)` + `rectangle` +
`fill`) and a filled portion at `slider.rs:57-61` (color `0.4`/`0.6` +
`rectangle` + `fill`). But it ALSO draws a text label
(`slider.rs:63-81`), and `slider` is not on the render-only validation
page. It proves the codebase already has shape-drawn fill primitives
available; the gap is that no widget on the validation page uses one
without text.

### What the config schema supports today

`WidgetDef` (`src/config/yaml.rs:90-143`) supports `button`, `spacer`,
`slider`, `dial`, `time`, `battery`. There is NO pure-shape / rect /
icon-rect widget type. `button` has an `icon: Option<String>` field
(`yaml.rs:99`) that is parsed but NEVER read in `build_pages`
(`src/main.rs:1148-1158` — the `icon` is `..`-ignored) — so an icon
cannot make a button visible without text. `spacer`
(`yaml.rs:103-106`) renders nothing (`button.rs:131-133`). The
`Settings::show_button_outlines` flag (`yaml.rs:25`) is parsed and
defaulted `true` but NEVER read in the render path (grep: only
`yaml.rs:25,45` mention it) — the rounded-rect is drawn unconditionally
on non-spacer buttons.

So the minimal path is a NEW widget type: a `ShapeWidget` that draws a
filled rectangle via `ctx.rectangle()` + `ctx.fill()` with an explicit
fill value, no text. This is preferred over (a) reusing `button` (its
shape is black when inactive — not a visibility guarantee) and (b)
wiring up `show_button_outlines` (it is dead config and the button
shape is still black). A dedicated `shape` widget makes the
visibility-by-construction guarantee explicit and testable at the
config level.

## Decision

Add a `WidgetDef::shape` variant + a `ShapeWidget` that renders a
filled rectangle via pure cairo path geometry (NO `select_font_face`,
NO `show_text` — zero font dependency anywhere in its draw path). The
validation page gains at least one `shape` widget as its FIRST
(leftmost) widget so the page is visible under the sandbox BY
CONSTRUCTION. Labels/time stay on the page ONLY if ADR-052 lands a
reliable text path; until then the shipped validation page is
shapes-only (text widgets removed so the page cannot go all-black on a
font miss).

### Schema

```yaml
- type: shape
  fill: 0.5        # gray value 0.0–1.0 (default 0.5 — a clearly visible mid-gray)
  stretch: 1       # default 1
```

`fill` is an `f64` clamped to `0.0..=1.0`; values outside the range are
clamped (not rejected — the page must still parse + render). The
default `0.5` is a non-black, non-white mid-gray chosen so the
adversarial test (make the shape black → `fill: 0.0` → test FAILs) is
meaningful and so the widget is visible against the bar's black
background and the button's black/inactive shape.

### Implementation

1. `src/widgets/shape.rs` — a new `ShapeWidget { fill: f64, stretch:
   usize }` implementing `Widget::render` as:
   ```rust
   let f = self.fill.clamp(0.0, 1.0);
   ctx.set_source_rgb(f, f, f);
   ctx.rectangle(rect.x, rect.y, rect.w, rect.h);
   ctx.fill().unwrap();
   ```
   `tap_action() -> None` (zero key injection — the render-only safety
   property holds). No `select_font_face`, no `show_text`, no
   `text_extents` — the draw path is font-free by construction.
2. `src/widgets/mod.rs` — `pub mod shape;` + re-export `ShapeWidget`.
3. `src/config/yaml.rs` — add `WidgetDef::shape { fill, stretch }`
   with `#[serde(default = "default_shape_fill")]` = `0.5` and
   `#[serde(default = "default_stretch")]`.
4. `src/main.rs::build_pages` — construct `ShapeWidget` for the
   `WidgetDef::shape` variant (reuses the existing match arm pattern).
5. `examples/render-only-validation-page.yaml` — replace the text
   widgets (3 buttons + time + spacer + no-op) with shape widgets so
   the shipped page is shapes-only and visible by construction. Keep
   `action: []` semantics implicit (shapes have no action field —
   `tap_action()` returns `None`).
6. Amend the s044 test
   (`src/config/yaml.rs:279-335`) to ALSO assert the validation page
   has at least one `WidgetDef::shape` widget (the visibility
   guarantee, not just the safety guarantee).
7. NEW pixel-probe test: render the validation page's `ShapeWidget`
   into an in-memory cairo surface and assert the surface produces
   NON-BLACK pixels. This closes the s044 gap (parse + actions tested,
   visibility never). Non-vacuous: an adversarial copy with `fill: 0.0`
   (black) MUST FAIL the probe (demonstrated on a throwaway copy in the
   test, not on the shipped page).

### The shape widget as a render-only probe

The shape widget serves a dual purpose:
- **Visibility guarantee**: the page is visible even if text fails.
- **Diagnostic probe**: if the shape is visible but text isn't → text
  rasterization is the problem (ADR-052 territory). If neither is
  visible → scanout/backlight is the problem (H1–H4 territory). One
  observation discriminates the two failure classes.

## Consequences

- The validation page is visible under the sandbox BY CONSTRUCTION —
  no font dependency anywhere in its draw path.
- The s044 test gains a visibility assertion (the page must have at
  least one shape-drawn widget).
- A pixel-probe test asserts the shape widget produces non-black
  pixels, with an adversarial black-fill demo proving non-vacuity.
- No production behavior change — `ShapeWidget::tap_action()` returns
  `None` (no key injection); the render-only safety property holds.
- `show_button_outlines` remains dead config (out of scope — a future
  ADR can either wire it or remove it; ADR-051 does not touch it).

## Relation to ADR-052

ADR-051 is the MINIMAL fix (make the validation page visible without
text). ADR-052 is the BROADER fix (make text rasterization reliable +
observable under the sandbox). ADR-051 is sufficient for the
validation page; ADR-052's scope is the production text widgets
(labels/time/battery/dial), which are Phase-2 placeholders today
(`src/main.rs:1182-1191`). If ADR-052 lands a reliable text path,
labels/time may return to the validation page; until then the shipped
page is shapes-only.