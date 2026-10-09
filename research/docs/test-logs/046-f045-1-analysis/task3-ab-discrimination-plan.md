# Task 3 — A/B discrimination plan (design only; the next short interlock)

**Session**: 046 (read-only root-cause research)
**Subject**: F-045-1 — the experiment that separates the content hypothesis from H1–H4
**Date**: 2026-09-27
**Method**: experimental design, no execution. FREEZE on `src/`.

## Goal

One short interlock that discriminates between:
- **HC (content hypothesis)**: the 045 bar is dark because the framebuffer is all-black (content failure), not because the backlight isn't emitting.
- **H1–H4 (backlight/DRM-side hypotheses)**: the 045 bar is dark because the backlight isn't emitting or the scanout isn't armed (backlight/DRM failure).

The 043 counter-example already weakens H1–H4 (same DRM code glowed in 043). The A/B test is the decisive experiment: if the default page (043 condition) glows under the CURRENT binary (cd7aa6c3) and the render-only page doesn't, the differential is the CONTENT, not the backlight.

---

## Pre-conditions

1. **Oracle masked** (ADR-049 move-aside mask for /etc-deployed units — see F-045-3 runbook amendment below). Verify no auto-restart within +60s.
2. **Binary**: `/usr/bin/tbard` sha256 `cd7aa6c3...` (v0.2.6, current). Verify with `sha256sum /usr/bin/tbard` + `strings /usr/bin/tbard | grep -- --service | wc -l` (≥1).
3. **No `/etc/touchbar/config.yaml`** at the start (remove any installed config from prior runs). Verify `ls /etc/touchbar/` shows only `config.yaml.example` (or nothing).
4. **Display backlight** at 90 (acpi_video0) — the curve input. Verify `cat /sys/class/backlight/acpi_video0/brightness`.
5. **P1 baseline**: debugfs dri/2 clients (oracle sole master), /dev/input count, sysfs touchbar brightness. Archive.

---

## Run A — tbard, NO config (built-in default page — exact 043 condition)

### Setup

- Remove `/etc/touchbar/config.yaml` if it exists (so the service falls back to `default_config()` — main.rs:1042-1047).
- The default page: 12 F-key buttons + auto-added esc (main.rs:1057-1092, :1194-1198). All `ButtonWidget`s with text labels. **This is the exact 043 condition.**

### Captures

| Capture | Command | What it shows |
|---------|---------|---------------|
| debugfs dri/2 state (THE CHECK 047 MISSED) | `sudo cat /sys/kernel/debug/dri/2/framebuffers` + `sudo cat /sys/kernel/debug/dri/2/planes` + `sudo cat /sys/kernel/debug/dri/2/crtcs` | Whether a fb is bound, whether a plane is scanning out, whether the crtc is active. **This is the scanout-state check 045 omitted.** |
| Manual brightness 100 | `sudo brightnessctl -d appletb_backlight set 100` | External brightness write (bypasses tbard's adaptive — tests whether the backlight emits at all when the framebuffer has content). |
| HC: "do you see the esc mark?" | Human checkpoint — describe what you see in one sentence. | Whether the default page's white "esc" text is visible. **NO TOUCHING** — the default page injects by design (esc + F1..F12 are key-emitting); touching would inject keys. |
| Journal | `sudo journalctl -u tbard.service --no-pager` | Boot sequence, enable-tick, any errors. |
| sysfs state | `cat /sys/class/backlight/appletb_backlight/brightness` + `bl_power` + `cat /sys/class/drm/card2-*/status` + `enabled` + `dpms` | Backlight + connector state. |

### Protocol

1. `sudo systemctl start tbard.service`
2. Wait ~5s (let the render loop flush a few frames).
3. Capture debugfs dri/2 framebuffers + planes + crtcs.
4. `sudo brightnessctl -d appletb_backlight set 100` (external write to 100).
5. HC: "Do you see the esc mark on the left side of the Touch Bar? Describe what you see in one sentence. DO NOT TOUCH THE BAR."
6. Capture journal + sysfs state.
7. `sudo systemctl stop tbard.service` (expect exit 0 + debugfs release).

### NO TOUCHING

The default page's widgets have `action: vec![Key::Esc]` / `vec![Key::F1]` etc. — touching the bar injects keys. The A/B test is RENDER-ONLY observation. The human must NOT touch the bar during Run A. The brightness is set EXTERNALLY via `brightnessctl` (bypassing tbard's adaptive path), exactly as in 043 (where the human wrote brightness 50 via brightnessctl).

---

## Run B — tbard, render-only page; same captures, same HC

### Setup

- Install `/etc/touchbar/config.yaml` from `examples/render-only-validation-page.yaml`:
  `sudo cp examples/render-only-validation-page.yaml /etc/touchbar/config.yaml`
- The render-only page: 3 text buttons + time widget (built as "⏰" button) + spacer + auto-added esc. All visible widgets are `ButtonWidget`s with text labels. **This is the exact 045 condition.**

### Captures (SAME as Run A)

| Capture | Command | What it shows |
|---------|---------|---------------|
| debugfs dri/2 state | `sudo cat /sys/kernel/debug/dri/2/framebuffers` + `planes` + `crtcs` | Same scanout-state check. |
| Manual brightness 100 | `sudo brightnessctl -d appletb_backlight set 100` | Same external brightness. |
| HC: "any content visible?" | Human checkpoint — describe what you see in one sentence. | Whether the render-only page's text is visible. Touching is SAFE here (all actions are `[]` — no injection), but NOT REQUIRED for the observation. |
| Journal | `sudo journalctl -u tbard.service --no-pager` | Same. |
| sysfs state | Same as Run A. | Same. |

### Protocol

1. `sudo cp examples/render-only-validation-page.yaml /etc/touchbar/config.yaml`
2. `sudo systemctl start tbard.service`
3. Wait ~5s.
4. Capture debugfs dri/2 framebuffers + planes + crtcs.
5. `sudo brightnessctl -d appletb_backlight set 100`
6. HC: "Do you see any content on the Touch Bar? Describe what you see in one sentence."
7. Capture journal + sysfs state.
8. `sudo systemctl stop tbard.service`
9. Remove `/etc/touchbar/config.yaml` (restore to no-config state).

---

## Prediction table

| Run A (default page) | Run B (render-only page) | Verdict | Interpretation |
|-----------------------|--------------------------|---------|----------------|
| **glows** (esc text visible) | **dark** (no content visible) | **HC CONFIRMED** | The content hypothesis is CONFIRMED. The backlight emits in both runs (same DRM, same sysfs); the differential is the CONTENT. The render-only page's content is all-black for a reason to investigate (likely the scanout-state check in Run B will show the fb is not bound or the plane is not scanning out — OR the text fails to rasterize for a config-specific reason). H1–H4 are REFUTED (Run A glows with the same binary + DRM code). |
| **glows** | **glows** | H1–H4 REFUTED; 045 was a transient | Both pages glow → the 045 no-glow was a transient (e.g. the appletbdrm driver was in a bad state that has since cleared). Re-run 045's exact condition to reproduce. |
| **dark** | **dark** | H1–H4 REVIVED | Both pages dark → the backlight/scanout is the problem (not the content). The 043 glow was specific to the v0.2.5 binary or a since-changed state. Investigate the binary diff (ADR-047/048 changes to the enable-tick path) or a hardware state change. |
| **dark** | **glows** | (unlikely — inverts the 043 observation) | The default page is dark but the render-only page glows. Would suggest the default page's specific content (12 F-keys + esc) triggers a failure the render-only page doesn't. Investigate the layout math (stretch=1 × 13 widgets vs the render-only page's stretch distribution). |

**The decisive case is Row 1 (A glows + B dark)**: it confirms the content hypothesis and refutes H1–H4 in one experiment. This is the EXPECTED outcome given the 043 counter-example (043 glowed with the default page under the v0.2.5 binary; the v0.2.6 binary's DRM code is unchanged).

---

## Post-experiment: if HC is confirmed, investigate WHY the render-only page is dark

If Run A glows and Run B is dark, the scanout-state check (debugfs dri/2 framebuffers + planes + crtcs) in Run B is the next data:

- **If the fb is NOT bound to a plane** (Run B's `framebuffers` shows no fb, or `planes` shows no fb_id): the flush succeeded but the scanout was not armed. This would be a DRM-side issue specific to the render-only page's flush — investigate whether the render-only page's flush path differs (it shouldn't — same `display.flush` at main.rs:716).
- **If the fb IS bound but the content is all-black**: the text failed to rasterize. Investigate cairo's fontconfig resolution under the sandbox (run `FC_DEBUG=1` in the unit's environment, or add a `WARN` on zero-glyph `text_extents`). The `fonts.rs` FFI module is dead code — the render path uses cairo's toy text API, which silently renders nothing on font failure.
- **If the fb is bound and the content is non-black but the bar is still dark**: the LCD panel is not modulating (a hardware/driver state outside tbard's control). This would revive a hardware-side hypothesis.

---

## Fix candidates (ADR proposals — NOT fixes this session)

### ADR-051: add at least one SHAPE-drawn, no-action widget to the validation page (the minimal fix)

**Problem**: the render-only validation page (`examples/render-only-validation-page.yaml`) has NO shape-only widget. Every visible widget is a `ButtonWidget` that renders TEXT (white on black). If cairo's text rasterization fails (font miss, fontconfig init failure, sandbox restriction), the entire page is all-black — indistinguishable from a backlight failure. The s044 Stage-4 test verified parse + zero-actions, NEVER visibility.

**Fix**: add at least one SHAPE-drawn, no-action widget to the validation page — a widget that renders a visible shape (e.g. a filled rectangle or circle) WITHOUT depending on `show_text`. This makes the page visible even if text rasterization fails.

**Implementation options** (design only — no `src/` changes this session):
1. **Add a `shape` widget type** (new `WidgetDef::shape` variant in `config/yaml.rs`, a `ShapeWidget` in `src/widgets/` that draws a filled rect/circle with `ctx.rectangle()` + `ctx.fill()`, no `show_text`). Add it to the render-only page as the first widget (leftmost, so it's the first thing the human sees).
2. **OR: make the `SpacerWidget` draw a faint background** (e.g. `set_source_rgb(0.2, 0.2, 0.2)` + `ctx.paint()`) when a `show_spacer_outline` setting is true. This gives a visible shape without text.
3. **OR: add an `icon` widget type** that draws a simple geometric icon (e.g. a circle, a triangle) via cairo path operations, no text.

**The minimal fix is option 1** (a `shape` widget that draws a filled rect). It is the smallest change that makes the validation page visible without text. It also serves as a RENDER-ONLY probe: if the shape is visible but the text isn't, the text rasterization is the problem; if neither is visible, the scanout/backlight is the problem.

**ADR-051 also amends the s044 test**: the `test_adr049_render_only_validation_page_has_zero_key_actions` test (config/yaml.rs:268-335) should ALSO assert that the page has at least one shape-drawn widget (a visibility guarantee, not just a safety guarantee).

### ADR-052 (candidate): fix text rasterization under the sandbox if labels/time are production-intended

**Problem**: the `time` widget is built as `ButtonWidget::new("⏰", [])` (main.rs:1179-1185) — a TEXT label (the "⏰" emoji). The `battery` widget is built as `ButtonWidget::new("🔋", [])` (main.rs:1186-1191). These are TEXT-dependent. If the font lacks the emoji glyph, the widget renders nothing. The `dial` widget is built as `ButtonWidget::new(label, [])` (main.rs:1174-1178) — also text.

**If labels/time/battery are production-intended** (not just validation placeholders), text rasterization must be reliable under the sandbox. The current path uses cairo's toy text API (`select_font_face("sans-serif", ...)`) which silently renders nothing on font failure.

**Fix candidates** (design only):
1. **Wire `src/fonts.rs` into the render path**: use the fontconfig FFI to resolve the font file, then `cairo::FontFace::new_from_ft_face` (or the toy API with a verified font path). Log a `WARN` if fontconfig cannot resolve "sans-serif". This makes font failure OBSERVABLE instead of silent.
2. **Bundle a font** in the package (e.g. a small public-domain TTF in `/usr/share/touchbar/fonts/`) and load it explicitly via `cairo::FontFace::new_from_file`. This removes the fontconfig dependency entirely. The sandbox's `ProtectSystem=strict` allows reading `/usr/share/touchbar/fonts/` (read-only).
3. **Add a font-failure detection**: after `select_font_face`, call `text_extents` on a known string and assert non-zero width. If zero, log a `WARN` and fall back to a SHAPE-drawn placeholder (e.g. a filled rect). This makes font failure non-silent.

**ADR-052 is a CANDIDATE** — it is only needed if text widgets are production-intended. If the validation page is the only use of text widgets, ADR-051 (add a shape widget) is sufficient. ADR-052's scope depends on whether the time/battery/dial widgets are placeholders (to be implemented in Phase 2 with real rendering) or production-intended.

**NOTE on the `time` widget's TODO**: main.rs:1182 says `// TODO(Phase 2): render real 12hr/24hr time labels.` The current "⏰" emoji is a PLACEHOLDER — the real time rendering is Phase 2. ADR-052 would be scoped to the Phase 2 implementation, not the placeholder.

### F-045-3 runbook amendment: /etc-deployed unit move-aside + mask

**Problem** (F-045-3, findings-045.txt:138-153): the oracle's deployed unit is a REAL FILE at `/etc/systemd/system/tiny-dfr-mbp142.service` (not a symlink, not at `/usr/lib/systemd/system/`). `systemctl mask` fails with "File already exists" — it cannot overwrite a real file. The ADR-049 runbook commands fail on this deployment shape.

**Runbook amendment** (for the `/etc-deployed` unit shape):
1. **Move-aside**: back up the real file, replace it with a `/dev/null` symlink (the mask), daemon-reload, stop.
   ```bash
   sudo cp /etc/systemd/system/tiny-dfr-mbp142.service /etc/systemd/system/tiny-dfr-mbp142.service.bak
   sudo rm /etc/systemd/system/tiny-dfr-mbp142.service
   sudo ln -s /dev/null /etc/systemd/system/tiny-dfr-mbp142.service
   sudo systemctl daemon-reload
   sudo systemctl stop tiny-dfr-mbp142.service 2>/dev/null || true
   ```
2. **Verify**: `systemctl is-enabled tiny-dfr-mbp142.service` → `masked`. `systemctl is-active` → `inactive`. Wait +60s, verify no auto-restart.
3. **Restore** (reverse the move-aside):
   ```bash
   sudo rm /etc/systemd/system/tiny-dfr-mbp142.service
   sudo mv /etc/systemd/system/tiny-dfr-mbp142.service.bak /etc/systemd/system/tiny-dfr-mbp142.service
   sudo systemctl daemon-reload
   sudo systemctl start tiny-dfr-mbp142.service
   ```
4. **Verify restore**: `sha256sum /etc/systemd/system/tiny-dfr-mbp142.service` matches the pre-session backup (byte-identical). `systemctl is-active` → `active`.

**This amendment should be added to ADR-049's runbook** (`docs/adr/049-interlock-hardening-mask-oracle.md`) as a "/etc-deployed unit" section. The existing runbook assumes `/usr/lib/systemd/system/` (the package-installed location); the amendment covers the `/etc/systemd/system/` (operator-installed) location.

---

## What this session's output enables

- **Task 0**: Stage-4 items 2 (gate semantics) and 3 (tap log) are adjudicated from the archived journal. Item 2 is VERIFIED (gate was open). Item 3 is BLOCKED on a re-run with a crisp <300ms tap — the 045 touch exceeded `TAP_MAX_MS`.
- **Task 1**: the content side is derived — the render-only page is ALL text, no shape. The test gap (s044 verified parse + zero-actions, never visibility) is logged.
- **Task 2**: H1–H4 are weakened or refuted by the 043 counter-example. The content hypothesis (HC) is the omitted hypothesis the 043 evidence favors. The s047 report's "NOT a render issue" claim is unsubstantiated (content side never checked; physical model wrong for LCD).
- **Task 3**: the A/B plan is the decisive experiment. Run A (default page, no touching) + Run B (render-only page) with debugfs dri/2 scanout-state checks. A glows + B dark → HC confirmed. Fix candidates: ADR-051 (shape widget), ADR-052 (text rasterization, candidate), F-045-3 runbook amendment (/etc move-aside mask).

**FREEZE on `src/` — no fixes this session. All output is DATA.**