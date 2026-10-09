# ADR-052 (candidate): fix text rasterization under the sandbox

**Status**: Candidate (not proposed for acceptance — depends on whether text widgets are production-intended)
**Date**: 2026-09-27
**Origin**: F-045-1 adjudication (docs/test-logs/046-f045-1-analysis/task1-content-derivation.md)

## Context

The render path uses cairo's toy text API: `ctx.select_font_face("sans-serif", FontSlant::Normal, FontWeight::Bold)` (`src/widgets/button.rs:90-94`) + `ctx.show_text(&self.label)` (`button.rs:101`). Cairo's toy text API uses fontconfig (via the `freetype` feature in `Cargo.toml`: `cairo-rs = { version = "0.22", features = ["freetype", "png"] }`) to resolve "sans-serif" to a font file, then freetype to rasterize glyphs.

**The `src/fonts.rs` fontconfig FFI module is DEAD CODE** — it is declared (`mod fonts;` at `main.rs:22`) but NEVER called from the render path. The widgets use cairo's internal fontconfig calls, not the `fonts.rs` FFI. A fontconfig failure manifests inside cairo, not as a typed `HwError::Ffi`.

### The sandbox

The systemd unit (`packaging/systemd/tbard.service:80-91`):
```ini
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
```

- `ProtectSystem=strict`: filesystem read-only (except whitelisted paths). Font files (`/usr/share/fonts/`) are READABLE. Fontconfig config (`/etc/fonts/fonts.conf`) is READABLE.
- `ProtectHome=true`: user font configs (`~/.config/fontconfig/`) NOT accessible. System fonts ARE accessible.
- `PrivateTmp=true`: private `/tmp` + `/var/tmp`. Fontconfig cache (`/var/cache/fontconfig/`) is under `/var` (read-only under strict). **Cache writes fail silently.** Fontconfig falls back to in-memory resolution — it does NOT fail to render.

### The silent failure mode

If fontconfig cannot find ANY font (no "sans-serif" match), cairo's toy text API:
- `select_font_face("sans-serif", ...)` → sets an invalid/NULL face. Does NOT error.
- `text_extents("label")` → returns zero-width extents. Does NOT error.
- `show_text("label")` → renders nothing. Does NOT error.

**Result: silent all-black. No panic (the `.unwrap()` in `button.rs:96,101` unwraps `Ok(())`). No error log. No WARN.**

The 043 counter-example (043 hc2-first-pixels.txt:18-23) shows text DID render under the same sandbox — so fontconfig DOES resolve "sans-serif" in the current sandbox. But the failure mode is SILENT if it ever fails. The s044 test never checked visibility.

## Decision (candidate — not for acceptance this session)

IF text widgets (labels, time, battery, dial) are production-intended (not just Phase-2 placeholders), text rasterization must be RELIABLE and OBSERVABLE under the sandbox. Three candidate approaches:

### Option 1: wire `src/fonts.rs` into the render path

Use the fontconfig FFI to resolve the font file, verify it exists, log a `WARN` if fontconfig cannot resolve "sans-serif", then use `cairo::FontFace::new_from_ft_face` (or the toy API with a verified font path). This makes font failure OBSERVABLE instead of silent.

**Cost**: medium. The `fonts.rs` FFI exists but is unwired. Wiring it requires a font-resolution step before the render loop + a fallback path.

### Option 2: bundle a font in the package

Bundle a small public-domain TTF in `/usr/share/touchbar/fonts/` (readable under `ProtectSystem=strict`) and load it explicitly via `cairo::FontFace::new_from_file`. This removes the fontconfig dependency entirely.

**Cost**: low-medium. Adds a font file to the package + a load step in the render init. The sandbox allows reading `/usr/share/touchbar/fonts/` (read-only).

### Option 3: font-failure detection + shape fallback

After `select_font_face`, call `text_extents` on a known string (e.g. "X") and assert non-zero width. If zero, log a `WARN` and fall back to a SHAPE-drawn placeholder (a filled rect). This makes font failure non-silent AND visible.

**Cost**: low. A check after `select_font_face` + a fallback path. Does not require bundling a font.

## Scope dependency

The `time` widget is built as `ButtonWidget::new("⏰", [])` with a TODO: `// TODO(Phase 2): render real 12hr/24hr time labels.` (`src/main.rs:1182-1183`). The `battery` widget is `ButtonWidget::new("🔋", [])` (`main.rs:1186-1191`). The `dial` widget is `ButtonWidget::new(label, [])` (`main.rs:1174-1178`). These are ALL placeholders.

**If these widgets are Phase-2 placeholders** (to be replaced with real rendering), ADR-052 is NOT needed now — ADR-051 (add a shape widget to the validation page) is sufficient. ADR-052's scope is the Phase-2 implementation: when real time/battery/dial rendering lands, it must not silently fail.

**If these widgets are production-intended as-is** (emoji labels are the final rendering), ADR-052 IS needed — the emoji glyphs may not be in the system font, and the failure would be silent.

## Recommendation

**Defer ADR-052 until the Phase-2 time/battery/dial rendering is designed.** ADR-051 (shape widget) is the immediate fix for the validation page. ADR-052 is a candidate for the Phase-2 scope. Log it as a candidate now so the Phase-2 design includes a font-failure detection requirement.