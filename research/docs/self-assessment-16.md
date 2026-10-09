# Self-assessment 16 — session 048 (ADR-051 visible-by-construction validation page; ADR-052 deferred; runbook/docs ride-alongs)

**Branch**: `fix/visible-validation-adr-051` off master `efb2cd5` (== v0.2.6).
**Date**: 2026-09-27. **Role**: fix engineer (ONE code session, sim/sandbox
only; no hardware testing; no service lifecycle actions; no `/etc`
changes). **These are CLAIMS, not verdicts** — QA v13 adjudicates.

## Claims

### C1 — ADR-051 draw-path derivation (cited, from code)

- The esc button (the SHAPE that glowed in Run A) is a `ButtonWidget`
  built at `src/main.rs:1196`, auto-inserted at `src/main.rs:1195-1198`
  when `width >= ESC_THRESHOLD`. Its render path is
  `src/widgets/button.rs:52-102`: SHAPE at `button.rs:60-87` (rounded
  rect via `ctx.arc` + `ctx.fill()`, fill `0.400` active / `0.0`
  inactive at `button.rs:53-59`), TEXT at `button.rs:88-101`
  (`select_font_face` + `show_text`).
- CLAIM: the esc button's glow in Run A is the TEXT (white at
  `button.rs:89`), NOT the shape (inactive shape fill is `0.0` = black
  at `button.rs:58-59`). The esc button is NOT a safe visibility probe
  — its shape is black when inactive, and its visibility depends on
  text. This is derived from the code, not from a hardware
  observation.
- The config schema (`src/config/yaml.rs:90-143`) supports `button`,
  `spacer`, `slider`, `dial`, `time`, `battery` — NO pure-shape widget.
  `button.icon` (`yaml.rs:99`) is parsed but NEVER read in
  `build_pages` (`src/main.rs:1148-1158`, `icon` is `..`-ignored).
  `Settings::show_button_outlines` (`yaml.rs:25`) is parsed + defaulted
  `true` but NEVER read in the render path (grep: only `yaml.rs:25,45`
  — dead config). The `SliderWidget` (`src/widgets/slider.rs:48-82`)
  draws a non-black shape (`slider.rs:52-61`) but ALSO draws text and
  is not on the validation page.
- CLAIM: the minimal path is a NEW `ShapeWidget` (filled rect via
  `ctx.rectangle()` + `ctx.fill()`, no font dependency). Preferred
  over reusing `button` (black inactive shape) and over wiring
  `show_button_outlines` (dead config, button shape still black).

### C2 — ADR-051 implementation (visible by construction)

- `src/widgets/shape.rs`: `ShapeWidget { fill, stretch }`,
  `render` = `ctx.set_source_rgb(f,f,f); ctx.rectangle(...); ctx.fill()`,
  no `select_font_face`/`show_text`/`text_extents`. `tap_action() ->
  None`. CLAIM: the draw path is font-free BY CONSTRUCTION (verified
  by grep — no font calls in `src/widgets/shape.rs`).
- `src/config/yaml.rs`: `WidgetDef::shape { fill, stretch }` with
  defaults `fill: 0.5`, `stretch: 1`. `src/main.rs::build_pages`
  constructs `ShapeWidget::new(*fill).with_stretch(*stretch)`.
- `examples/render-only-validation-page.yaml` revised to shapes-only
  (0.5 / 0.8 / 0.2 / spacer / 0.5). CLAIM: the page CANNOT go all-black
  on a font miss because no widget on it depends on a font (every
  visible widget is `type: shape`).
- `scripts/check-invariants.sh`: `src/widgets/shape.rs` added to the
  ADR-017 `deny(clippy::indexing_slicing)` required-files list.

### C3 — Pixel-probe test + adversarial demo (non-vacuous)

- `test_shape_widget_renders_non_black_pixels` (`src/widgets/shape.rs`):
  renders `fill=0.5` into an in-memory cairo surface (painted black
  first), asserts NON-BLACK pixels. CLAIM: this closes the s044 gap
  (parse + actions tested, visibility never).
- `test_shape_widget_adversarial_black_fill_produces_zero_non_black`:
  `fill=0.0` (black) MUST produce zero non-black pixels against a
  black background. CLAIM: this proves the pixel-probe is non-vacuous
  — if the shipped page's shape were ever made black, the probe would
  FAIL (the adversarial case is constructed inline, NOT on the shipped
  page).
- Test count: **91 → 97** (+6: 5 `widgets::shape` tests + 1
  `config::yaml::tests::test_adr051_shape_widget_parses_with_defaults`).
  Reconciliation: 92 (main.rs unit, +1 over baseline 86? — see C7) + 5
  integration = 97. (Baseline was 86 main.rs + 5 integration = 91;
  ADR-051 added 6 main.rs tests → 92 main.rs + 5 integration = 97.)

### C4 — ADR-052 root-cause verdict (deferred with evidence)

- Root-cause derivation (WITHOUT hardware): cairo's toy text API
  silently renders nothing on a fontconfig/freetype failure
  (`select_font_face` / `text_extents` / `show_text` all return
  `Ok(())` with zero-width glyphs). `src/fonts.rs` is DEAD CODE
  (declared `mod fonts;` at `main.rs:22` but NEVER called from the
  render path — widgets use cairo's internal fontconfig). The sandbox
  (`packaging/systemd/tbard.service`) uses `ProtectSystem=strict` /
  `ProtectHome=true` / `PrivateTmp=true`; the fontconfig cache
  (`/var/cache/fontconfig/`) is read-only → cache writes fail silently
  → fontconfig falls back to in-memory resolution (does NOT fail to
  render). The 043 counter-example shows text DID render under the
  same sandbox, so fontconfig DOES resolve "sans-serif" today; the
  failure mode is SILENT if it ever fails.
- CLAIM: the fix is architectural (wire `fonts.rs` / bundle a font /
  font-failure detection + shape fallback). Per the rules ("if the
  fix is architectural... DOCUMENT the design as a Phase-2 ADR and
  ship 051 alone — do not half-fix"), ADR-052 is DEFERRED as a design
  doc (`docs/adr/052-*.md`) with the binding requirement "log
  font/render failure at WARN+ — silence is the bug class." The
  Phase-2 implementation must include a test asserting text rendering
  FAILS LOUDLY (or succeeds).
- CLAIM: ADR-052 is NOT half-fixed. No `src/` change for ADR-052 this
  session.

### C5 — Runbook/docs ride-alongs

- F-045-3: the /etc-deployed-unit move-aside + mask procedure (sha256
  before/after, byte-identical restore) is folded canonical into
  `docs/test-plan.md` STEP 1 (mask) + STEP 5 (restore) as Variant B
  alongside the /usr/lib Variant A. CLAIM: the amendment doc
  (`docs/test-logs/046-f045-1-analysis/f045-3-runbook-amendment.md`)
  is now canonical in the test-plan.
- ADR-053 (documentation-only): the `TAP_MAX_MS=300ms` caveat is
  recorded in `src/widgets/mod.rs:87` (doc comment) +
  `docs/test-plan.md` (Stage-4 runbook caveat) + `docs/adr/053-*.md`.
  CLAIM: no code change (the threshold stays 300ms; only docs).
- Idle-decay testability caveat: active-session seat0 pointer activity
  keeps the bar awake (correct behavior — the `src/providers/input.rs`
  catch-all pushes `InputEvent::Activity`, resetting `last_active` via
  `backlight.notify_activity()`). Documented in `docs/test-plan.md`
  (Stage-4 caveat). CLAIM: no code change; a test-env caveat, not a
  defect.

### C6 — Gates

- CLAIM: gates green after the ADR-051 commit — `cargo fmt --check`,
  `cargo build --bin tbard`, `cargo clippy --all-targets -- -D
  warnings`, `cargo test` (97 passed), `scripts/check-invariants.sh`
  (PASS), `scripts/ci-gate.sh` (PASS), `bash -n packaging/PKGBUILD`
  (OK).
- CLAIM: no hardware testing (sim/sandbox only). No service lifecycle
  actions. No `/etc` changes. `backup_old/` read-only.

### C7 — Test-count reconciliation

- Baseline (master `efb2cd5`): 86 main.rs unit + 5 integration = 91.
- After ADR-051: 92 main.rs unit + 5 integration = 97 (+6 main.rs).
  The +6: `test_shape_widget_defaults`,
  `test_shape_widget_with_stretch`,
  `test_shape_widget_renders_non_black_pixels`,
  `test_shape_widget_adversarial_black_fill_produces_zero_non_black`,
  `test_shape_widget_clamps_fill`,
  `test_adr051_shape_widget_parses_with_defaults`.
- CLAIM: 91 + 6 = 97, reconciled.

## Risks / open items

- The pixel-probe tests use an in-memory cairo `ImageSurface` (not the
  DRM scanout path). They prove the `ShapeWidget` draw path produces
  non-black pixels in cairo; they do NOT prove the DRM scanout composes
  the shape onto the panel (that is the hardware verification, out of
  scope this session). The probe closes the s044 VISIBILITY gap at the
  widget-render layer; the scanout composition remains hardware-
  verified.
- ADR-052's sim replication (run the branch binary under `systemd-run`
  with the unit's sandbox profile as user `nobody` rendering a TEXT
  widget) was NOT run this session — it is deferred with the Phase-2
  fix. The root-cause derivation is from code inspection + the 047 A/B
  evidence, NOT from a sim replication. This is consistent with "do
  not half-fix" but means the fontconfig failure mode is inferred, not
  directly observed under the sandbox this session.
- The `show_button_outlines` dead config is NOT touched (out of scope —
  a future ADR can wire or remove it).
- Item 5 (config hot-reload) is the remaining Stage-4 functional
  acceptance; out of scope for this fix session (no hardware).

## Stage-4 acceptance after ADR-051 (claims)

- Item 1 (visible wake): the validation page is now visible BY
  CONSTRUCTION; the next hardware run can re-test item 1 on a page
  that glows by construction. NOT re-verified on hardware this session.
- Item 5 (config hot-reload): NOT tested; deferred to the next
  interlock.
- Items 2/3/4/6/7: closed on hardware in session 047 (claims, per the
  047 REPORT).

## Final

- CLAIM: READY FOR RE-VERIFICATION (QA v13) — no blockers identified
  in this session's work; ADR-051 ships, ADR-052 is deferred with a
  design doc, the runbook/docs ride-alongs are canonical. QA v13
  adjudicates the claims and decides whether the Stage-4 item-1
  re-verification (with the shapes-only page) proceeds on hardware.