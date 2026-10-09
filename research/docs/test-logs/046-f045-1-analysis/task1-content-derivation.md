# Task 1 — Content derivation (what does the render-only page rasterize?)

**Session**: 046 (read-only root-cause research)
**Subject**: F-045-1 — the content side the s047 report never checked
**Date**: 2026-09-27
**Method**: source audit of the draw path. Cite `file:line` throughout. FREEZE on `src/`.

## Executive finding

The render-only page's widgets are **ALL text-dependent** — there is NO shape-only widget on the page. If cairo's text rasterization fails under the sandbox, the page rasterizes to **all-black** (silent, no error). The 043 default page, by contrast, also relied on text — and text DID render (the human saw "a single bright widget mark"). **The font-failure hypothesis is WEAKENED by 043 but NOT exonerated**: the test-gap is that the s044 Stage-4 test verified parse + zero-actions, NEVER visibility. The content side was never checked.

---

## The render-only page's widgets (from `examples/render-only-validation-page.yaml`)

| # | YAML `type` | Built as (main.rs:1140-1202) | Draw path | TEXT vs SHAPE |
|---|-------------|------------------------------|-----------|---------------|
| 0 | `button` label="STAGE 4" action=[] stretch=2 | `ButtonWidget::new("STAGE 4", [])` (main.rs:1154-1157) | button.rs:52-102 | **TEXT** (white text on black rounded-rect) |
| 1 | `button` label="render-only" action=[] stretch=2 | `ButtonWidget::new("render-only", [])` | button.rs:52-102 | **TEXT** |
| 2 | `time` format="%H:%M" stretch=3 | `ButtonWidget::new("⏰", [])` with stretch=3 (main.rs:1179-1185) | button.rs:52-102 | **TEXT** (the "⏰" emoji is a TEXT label, NOT a shape — cairo `show_text`) |
| 3 | `spacer` stretch=1 | `SpacerWidget { stretch: 1 }` (main.rs:1159-1162) | button.rs:131-133 (`render` is a no-op) | **NOTHING** (renders nothing) |
| 4 | `button` label="no-op" action=[] stretch=2 | `ButtonWidget::new("no-op", [])` | button.rs:52-102 | **TEXT** |

**Plus the auto-added esc button** (main.rs:1194-1198): `width >= ESC_THRESHOLD (2170)` → `ButtonWidget::new("esc", vec![Key::Esc])` inserted at index 0. The render-only page's logical width is 2170 (main.rs:693, `geometry.logical_width()`), so **esc IS auto-added** to the render-only page. The esc button is a `ButtonWidget` with label "esc" — **TEXT**.

**Final widget row (left→right): [esc, "STAGE 4", "render-only", "⏰"(time), spacer, "no-op"]**

Every visible widget is a `ButtonWidget` that renders TEXT. The spacer renders nothing. **There is NO shape-only (SHAPE-drawn, no-text) widget on the page.**

---

## The ButtonWidget draw path (button.rs:52-102)

```rust
fn render(&self, ctx: &cairo::Context, rect: Rect, active: bool) {
    let color = if active { 0.400 } else if false { 0.200 } else { 0.0 };  // line 53-59
    // Background (rounded rect) — ONLY if label != "_spacer"
    if self.label != "_spacer" {                                            // line 61
        // ... rounded-rect path (lines 62-84) ...
        ctx.set_source_rgb(color, color, color);                            // line 85
        ctx.fill().unwrap();                                                // line 86
    }
    // Text                                                                  // line 88-101
    ctx.set_source_rgb(1.0, 1.0, 1.0);                                      // line 89  (WHITE)
    ctx.select_font_face("sans-serif", FontSlant::Normal, FontWeight::Bold);// line 90-94
    ctx.set_font_size(24.0);                                                // line 95
    let extents = ctx.text_extents(&self.label).unwrap();                   // line 96
    ctx.move_to(...);                                                       // line 97-100
    ctx.show_text(&self.label).unwrap();                                    // line 101
}
```

### Colors

- **Background (inactive, `active=false`)**: `color = 0.0` → `set_source_rgb(0.0, 0.0, 0.0)` → **BLACK** rounded-rect. The `else if false` branch (line 55) is dead code — `0.200` is never used.
- **Background (active, `active=true`)**: `color = 0.400` → dark gray. But `active` is `false` for all widgets — `page.render(&ctx, None)` (main.rs:703) passes `active_widget = None`, so `is_active = (None == Some(i)) = false` for all i (page.rs:76).
- **Text**: `set_source_rgb(1.0, 1.0, 1.0)` → **WHITE**.

### What is visible

For an inactive button on a black-painted surface (main.rs:700-701: `ctx.set_source_rgb(0.0,0.0,0.0); ctx.paint()` — the whole framebuffer is painted black first):
- The rounded-rect background is BLACK on BLACK → **invisible**.
- The white TEXT is the ONLY visible element.

**If `ctx.show_text()` renders nothing (font failure), the entire widget is INVISIBLE (black on black). The page rasterizes to all-black.**

### The `show_text().unwrap()` — silent failure mode

`ctx.show_text(&self.label).unwrap()` (button.rs:101) and `ctx.text_extents(&self.label).unwrap()` (button.rs:96) use `.unwrap()`. If cairo's text rendering fails, these would **panic** (not silently render nothing). BUT: cairo's toy text API does NOT error on a missing font — it silently renders nothing (or renders empty/tofu boxes depending on the cairo build). The `.unwrap()` would only panic on a surface error, not on a font-miss. **A font failure produces silent all-black, not a panic.**

---

## The 043 default page's esc button draw path (shape reference)

The 043 run used `default_config()` (main.rs:1057-1092) because `/etc/touchbar/config.yaml` did NOT exist (only `config.yaml.example` was present — 045 p1-baseline.txt:52-56 shows the pre-session state). The default page:
- 12 `ButtonWidget`s: "F1".."F12", each `action: vec!["F{n}"]`, stretch=1.
- Plus auto-added `ButtonWidget::new("esc", vec![Key::Esc])` at index 0 (main.rs:1195-1198, width 2170 >= ESC_THRESHOLD 2170).

**The 043 esc button is the SAME `ButtonWidget::render` path** (button.rs:52-102). It draws:
1. BLACK rounded-rect background (inactive, `color=0.0`).
2. WHITE text "esc" via `ctx.show_text("esc")`.

The human saw "a single bright widget mark on the left side of the strip" (043 hc2-first-pixels.txt:21-22). This is the esc button's white "esc" text — the leftmost widget. **The 043 text DID render.** This means:
- cairo's `select_font_face("sans-serif", ...)` DID resolve a font.
- `show_text("esc")` DID produce white pixels.
- The sandbox (`ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, user nobody) did NOT prevent font loading in 043.

**The font-failure hypothesis is WEAKENED by 043**: the same cairo, same sandbox, same font path produced visible text in 043. The systemd unit is UNCHANGED between v0.2.5 and v0.2.6 (verified: `git diff d66f3ef..cc374b3 -- packaging/systemd/tbard.service` is empty). The widget render code is UNCHANGED (`git diff d66f3ef..cc374b3 -- src/widgets/` is empty).

---

## Text rasterization dependency: cairo toy text / fontconfig

### What the code uses

The widgets call `ctx.select_font_face("sans-serif", FontSlant::Normal, FontWeight::Bold)` (button.rs:90-94) and `ctx.show_text(...)` (button.rs:101). This is cairo's **toy text API**. Cairo's toy text API internally uses fontconfig (via the `freetype` feature) to resolve "sans-serif" to a font file, then freetype to rasterize glyphs.

### The `cairo-rs` crate configuration

`Cargo.toml`:
```toml
cairo-rs = { version = "0.22", default-features = false, features = ["freetype", "png"] }
```
The `freetype` feature enables cairo's freetype + fontconfig backend. **This is the backend that `select_font_face` uses.**

### The `src/fonts.rs` FFI module — DEAD CODE

`src/fonts.rs` declares fontconfig FFI bindings (`FontConfig::new`, `Pattern::new`, `match_pattern`, `perform_substitutions`, `get_file_name`). It is declared as `mod fonts;` at `main.rs:22`. **But it is NEVER called from the render path.** `grep -rn "fonts::FontConfig\|FontConfig::new\|fonts::Pattern" src/` → only the `mod fonts;` declaration. The widgets use cairo's toy text API, NOT the `fonts.rs` FFI. **`fonts.rs` is dead code** (a port stub from tiny-dfr that was never wired into the render path).

This means: **font resolution goes through cairo's internal fontconfig calls, NOT through `src/fonts.rs`.** The `src/fonts.rs` typed-error handling (`HwError::Ffi`) is NEVER exercised at runtime. A fontconfig failure would manifest inside cairo, not as a typed `HwError`.

### Behavior under the sandbox (`ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, user nobody)

The systemd unit (`packaging/systemd/tbard.service:80-91`):
```ini
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateIPC=true
...
```

- **`ProtectSystem=strict`**: the entire filesystem is mounted read-only for the service, EXCEPT `/dev`, `/proc`, `/sys`, and anything explicitly whitelisted by `ReadWritePaths`. Font FILES (e.g. `/usr/share/fonts/`, `/usr/share/fontconfig/`) are READ-ONLY — **reading fonts is NOT blocked** (strict makes the FS read-only, not unreadable).
- **`ProtectHome=true`**: `/home`, `/root`, `/run/user` are not accessible. User font configs (`~/.config/fontconfig/fonts.conf`, `~/.fonts.conf`) are NOT accessible. **System fonts and system fontconfig configs ARE accessible.**
- **`PrivateTmp=true`**: the service gets a private `/tmp` and `/var/tmp`. **fontconfig's cache** (`/var/cache/fontconfig/`) is NOT under `/tmp` — it's under `/var`, which is read-only under `ProtectSystem=strict`. **If fontconfig tries to WRITE a cache entry (first-run cache miss), the write fails.** But fontconfig can still READ an existing cache. If the cache is stale or absent, fontconfig re-scans the font dirs (read-only) and tries to write the cache (fails silently) — it still resolves fonts in-memory.
- **user nobody (uid 65534)**: post-privdrop. `nobody` has read access to `/usr/share/fonts/` and `/usr/share/fontconfig/` (world-readable). **Font loading is NOT blocked by the user drop.**

### Can fonts load? Where does the cache write fail?

**Fonts CAN load** under the sandbox, as long as:
1. The system fontconfig config (`/etc/fonts/fonts.conf`) is world-readable (it is, by default on Arch).
2. The font files (`/usr/share/fonts/`) are world-readable (they are).
3. The fontconfig cache (`/var/cache/fontconfig/`) is either present-and-readable OR fontconfig can re-scan without writing.

**The cache write fails silently** under `ProtectSystem=strict` + `PrivateTmp` (fontconfig cannot write to `/var/cache/fontconfig/`). But fontconfig falls back to in-memory resolution — it does NOT fail to render. **This is NOT a silent-all-black failure mode.**

### Does cairo render NOTHING on font failure?

If fontconfig genuinely cannot find ANY font (no `sans-serif` match), cairo's toy text API:
- `select_font_face("sans-serif", ...)` — sets the font face to a NULL/invalid face. Does NOT error.
- `text_extents("label")` — returns zero-width extents (no glyph). Does NOT error.
- `show_text("label")` — renders nothing (no glyphs to draw). Does NOT error.

**The result is silent all-black. No panic (the `.unwrap()` in button.rs:96,101 unwraps a `Result` that is `Ok` — cairo returns `Ok(())` even when it renders nothing). No error log. No WARN.** The bar appears dark even though the backlight is on and the framebuffer is being scanned out.

**THIS IS THE CONTENT HYPOTHESIS**: if the render-only page's text fails to rasterize (for any reason — font miss, fontconfig init failure, cairo toy-text resolution failure), the page is all-black. The human sees "no glow" because the pixels are black, not because the backlight is off. The 045 human's "no glow at brightness 255" is consistent with this: the backlight IS emitting at 255, but the framebuffer content is all-black, so no light passes through the LCD layer (the Touch Bar is an LCD panel with a backlight — a black framebuffer blocks the backlight).

**IMPORTANT PHYSICAL MODEL**: the Touch Bar is an LCD panel (not an OLED). The backlight emits light; the LCD layer modulates it. A BLACK framebuffer means the LCD blocks the backlight → the bar appears DARK even with the backlight at full brightness. **"No glow at brightness 255" is EXACTLY what you'd see if the framebuffer is all-black.** This is NOT evidence that the backlight isn't emitting — it's evidence that the CONTENT is black.

---

## The test-gap finding (s044 Stage-4 test)

The s044 Stage-4 test (`src/config/yaml.rs:268-335`, `test_adr049_render_only_validation_page_has_zero_key_actions`) verified:
1. **PARSE**: the render-only page YAML parses to a valid `TouchbarConfig` (yaml.rs:283).
2. **ZERO ACTIONS**: every button widget has `action: []` (yaml.rs:291-301), every time widget has no action (yaml.rs:303-316), every battery widget has no action (yaml.rs:318-325). This is the "no injection during render-only observation" guarantee.

**The test NEVER verified VISIBILITY** — it does not render the page to a cairo surface and assert that non-black pixels are produced. It does not check that `show_text` produces glyphs. It does not check that fontconfig resolves "sans-serif". **The content side was never tested.** The s044 gates-verbatim.txt:60-67 shows the test ran and passed (1 test, ok) — but it only checked the config schema, not the render output.

**This is the test gap**: the Stage-4 prep verified the page is SAFE (no key injection) but not VISIBLE (does it actually render anything?). The 045 run was the first time the render-only page was scanned out to hardware — and the human saw no glow.

---

## Draw-path table (summary)

| Widget (render-only page) | Type | Draw path | Background (inactive) | Foreground | Visible if text fails? |
|---------------------------|------|-----------|----------------------|------------|------------------------|
| esc (auto-added) | ButtonWidget "esc" | button.rs:52-102 | black rounded-rect | white text "esc" | **NO** (all-black) |
| "STAGE 4" | ButtonWidget | button.rs:52-102 | black rounded-rect | white text | **NO** |
| "render-only" | ButtonWidget | button.rs:52-102 | black rounded-rect | white text | **NO** |
| "⏰" (time) | ButtonWidget (main.rs:1183) | button.rs:52-102 | black rounded-rect | white text "⏰" | **NO** |
| spacer | SpacerWidget | button.rs:131-133 (no-op) | — | — | N/A (renders nothing by design) |
| "no-op" | ButtonWidget | button.rs:52-102 | black rounded-rect | white text | **NO** |

**The entire visible content of the render-only page is TEXT. There is no SHAPE-only widget. If text fails, the page is all-black.**

## Contrast: 043 default page

| Widget (043 default) | Type | Visible if text fails? |
|----------------------|------|------------------------|
| esc (auto-added) | ButtonWidget "esc" | **NO** (all-black) |
| F1..F12 | ButtonWidget "F1".."F12" | **NO** (all-black) |

**The 043 default page is ALSO entirely text-dependent.** The 043 human saw "a single bright widget mark" (the esc text) — so text DID render in 043. **The font-failure hypothesis is NOT the differential between 043 and 045** (same render path, same sandbox, same cairo). The differential is the CONFIG (default page → render-only page), but BOTH configs are text-only. **If fonts work in 043, they work in 045.**

**This weakens the content hypothesis as the DIFFERENTIAL cause but does NOT exonerate it as a CONTRIBUTING factor**: if the 045 bar is dark because the framebuffer is all-black (for ANY reason — render failure, flush failure, scanout not armed), the human would see "no glow at brightness 255." The s047 report's claim that "no glow at 255 proves it's not a render issue" (findings-045.txt:41-43) is **physically wrong** for an LCD panel: a black framebuffer blocks the backlight at any brightness. The report conflated "backlight emitting" with "bar appears lit" — for an LCD, these are NOT the same.