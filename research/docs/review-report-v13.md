# QA Review Report v13 — re-verification of fix/visible-validation-adr-051

**Branch**: `fix/visible-validation-adr-051` off master `efb2cd5` (== v0.2.6).
**HEAD**: `e987f73` (docs: ADR-053 + self-assessment-16).
**Date**: 2026-09-27. **Role**: QA & reliability engineer (re-verification v13).
**Scope**: ADR-051 (+ ADR-052 deferral doc + ADR-053 + runbook ride-alongs).
**FREEZE**: no source changes, findings only. Working tree clean at start and end.
**Host safety**: oracle untouched and lit throughout; no service lifecycle actions; no `/etc` writes; `/dev/input` unchanged; debugfs — oracle sole master (name+uid) at start and end.

---

## Summary

**CLEARED FOR MERGE (v0.2.7) + binary reinstall + the Stage-4 completion interlock**, with **two findings** (F-13-1, F-13-2) logged as ADR proposals — neither blocks the merge; both are documentation/runbook corrections. The Stage-4 interlock must name the **SHAPE widget** as the visibility target (NOT the auto-esc), per W17.

---

## Per-claim verdicts

### Claim 1 — ADR-051 draw-path derivation — ✅ VERIFIED

**Adjudication**: the esc button draw path (`src/widgets/button.rs:52-102`) is exactly as derived.

- **SHAPE** (`button.rs:60-87`): rounded-rect via four `ctx.arc(...)` + `close_path()` + `set_source_rgb(color,color,color)` + `fill()`. The fill is `0.400` when active, `0.0` otherwise (`button.rs:53-59`). Skipped only when `self.label == "_spacer"` (`button.rs:61`). **Zero font dependency in this path** — confirmed by reading.
- **TEXT** (`button.rs:88-101`): `set_source_rgb(1.0,1.0,1.0)` (white) + `select_font_face("sans-serif",…)` + `set_font_size(24.0)` + `text_extents` + `show_text`. **This path depends on fontconfig/freetype.**

**Run-A glow was the TEXT, not the shape.** The esc's inactive shape fill is `0.0` = black (`button.rs:58-59`); the glow in Run A is the white `show_text("esc")` at `button.rs:89-101`. The ADR-051 doc states this correctly (`docs/adr/051-*.md:55-64`) — including the self-correcting "wait — inactive fill is 0.0 = black" aside. The esc button is **not** a safe visibility probe: its shape is black when inactive, and its visibility depends on text. ✅

**ShapeWidget is font-independent end-to-end** (`src/widgets/shape.rs:60-82`): `render` = `set_source_rgb(f,f,f)` + `rectangle(...)` + `fill()`. No `select_font_face`, no `show_text`, no `text_extents` anywhere in the file (verified by reading the full 269-line module). `tap_action() -> None` (zero key injection). ✅

**Config schema supports it** (`src/config/yaml.rs:148-153`): `WidgetDef::shape { fill, stretch }` with `#[serde(default = "default_shape_fill")]` = `0.5` and `#[serde(default = "default_stretch")]` = `1`. The test `test_adr051_shape_widget_parses_with_defaults` (`yaml.rs:385-413`) parses a minimal config and asserts the defaults (fill=0.5, stretch=1) + explicit values (fill=0.8, stretch=3). ✅

### Claim 2 (W16) — Shipped page visibility — ✅ VERIFIED (no finding)

**Adjudication**: the shipped validation page's shape fill values are **non-black**.

- `examples/render-only-validation-page.yaml` ships 4 shape widgets: `fill: 0.5` (×2), `fill: 0.8`, `fill: 0.2` — all non-black, all visible against the bar's black background. The first (leftmost) widget is `fill: 0.5` (the visibility probe). ✅
- The config default (`default_shape_fill()` = `0.5`, `yaml.rs:177-179`) is non-black. A config that omits `fill:` on a `shape` widget gets 0.5, NOT 0.0. ✅
- **Can the shipped page yield a black shape via config?** Only if an operator explicitly writes `fill: 0.0` (or a negative value, which clamps to 0.0 per `shape.rs:70`). That is an operator choice, not a shipped-page defect. The shipped example never does this. The pixel-probe test (`test_shape_widget_renders_non_black_pixels`) + the adversarial test (`test_shape_widget_adversarial_black_fill_produces_zero_non_black`) together guarantee that IF a shape were made black, the probe would FAIL — see Claim 4.
- **No finding.** The shipped page is non-black by construction + by default.

### Claim 3 (W17) — Full-page font-freedom + auto-esc — ⚠️ VERIFIED with FINDING F-13-1

**Adjudication**: the complete shapes-only page draw is:

| Widget | Type | fill | stretch | Font dependency? |
|--------|------|------|---------|------------------|
| 1 | shape | 0.5 | 2 | NO |
| 2 | shape | 0.8 | 2 | NO |
| 3 | shape | 0.2 | 2 | NO |
| 4 | spacer | — | 1 | NO (renders nothing, `button.rs:131-133`) |
| 5 | shape | 0.5 | 2 | NO |

**Background**: the bar's framebuffer is cleared to black before the page draws (the cairo surface starts black; `Page::layout` + the render loop paint the page widgets onto it). **Separators**: there are NO separator widgets on this page — the shapes are adjacent (the spacer at position 4 provides the only gap). **Spacers**: one spacer (stretch 1) — `SpacerWidget::render` is a no-op (`button.rs:131-133`), font-free. ✅

**BUT — the auto-inserted esc STILL APPEARS on the validation page at production width.** This is the W17 crux.

- `build_pages` (`src/main.rs:1202-1206`) auto-inserts an `esc` `ButtonWidget` at position 0 when `width >= ESC_THRESHOLD` (2170) AND the page is non-empty.
- The MBP 14,2 Touch Bar logical width is 2170 (`logical_w` from `geometry.logical.width`, `main.rs:596`). The validation page is non-empty. **So at production width, an esc ButtonWidget IS auto-inserted at position 0.**
- The sim probe confirms: `W17 auto-esc gate at width=2170 (ESC_THRESHOLD=2170): auto_esc_inserted = true` (`docs/test-logs/048/fix-report/sim-render-evidence.txt`).
- The esc is a `ButtonWidget` whose visibility is TEXT-dependent (white `show_text("esc")`, `button.rs:89-101`); its inactive shape fill is black (`button.rs:58-59`).

**Therefore the page is NOT 100% font-free at production width** — the auto-esc is a text-dependent widget that appears at position 0. The shapes-only guarantee applies to the operator-defined widgets, NOT the auto-inserted esc.

**Implication for the runbook**: the Stage-4 HC question ("does the bar glow?") MUST name the **SHAPE widget** as the visibility target, NOT the esc. The esc's own visibility is text-dependent (it will be dark under the F-045-1 font failure, exactly as Run B of session 047 showed). The shape widget is the font-free visibility probe; the esc is not.

**FINDING F-13-1 (doc/runbook — NOT a blocker)**: the shipped example's comment at `examples/render-only-validation-page.yaml:87-88` claims "no auto-esc is added because the page is wide" — this is **backwards**. Wide bars (`width >= 2170`) TRIGGER auto-esc, not skip it. The comment should read "an auto-esc IS added at position 0 because the page is wide; it is text-dependent and NOT the visibility probe — the SHAPE widget is." The runbook (`docs/test-plan.md` Stage-4 section) must name the shape widget as the visibility target. → **ADR proposal F-13-1** (logged below, not implemented).

**Does this break the visibility-by-construction guarantee?** NO — the 4 shape widgets (covering 8/9 of the bar width) are font-free and visible by construction; the auto-esc at position 0 is an additional text-dependent widget that will be dark under a font failure, but the shapes still glow. The page is visible by construction; the esc is just not the probe. The guarantee holds for the shapes.

### Claim 4 — Pixel-probe non-vacuity — ✅ VERIFIED

**Adjudication**: both pixel-probe tests pass; the adversarial test is constructed inline, NOT on the shipped page; the shipped-page path would be caught if made black.

- `test_shape_widget_renders_non_black_pixels` (`shape.rs:115-150`): renders `fill=0.5` into an in-memory cairo surface (painted black first), asserts `non_black > 0`. ✅
- `test_shape_widget_adversarial_black_fill_produces_zero_non_black` (`shape.rs:159-194`): renders `fill=0.0` (black) into a black-painted surface, asserts `non_black == 0`. The adversarial widget is constructed **inline** (`ShapeWidget::new(0.0)`) — a throwaway copy, NOT the shipped page. ✅
- The two tests together prove: if the shipped page's shape were ever made black (`fill: 0.0`), the probe assertion (`non_black > 0`) would FAIL. The probe is non-vacuous.
- `test_shape_widget_clamps_fill` (`shape.rs:202-240`): negative fill → clamps to 0.0 (black, red channel 0); over-1.0 fill → clamps to 1.0 (white, red channel 255). ✅
- **Sim-render corroboration** (`docs/test-logs/048/fix-report/sim-render-evidence.txt`): the shipped page renders 115,800 non-black pixels / 130,200 total; the adversarial (all shapes forced `fill=0.0`) renders 0 non-black — the shipped-page probe semantics would FAIL if the page were made black. ✅
- **Throwaway copies deleted**: the sim probe at `/tmp/opencode/v13-sim` was removed after capture; no repo source touched. ✅

### Claim 5 — ADR-052 deferral — ✅ VERIFIED (no production render-path change)

**Adjudication**: ADR-052 (`docs/adr/052-*.md`) is a design doc, NOT an implementation.

- **Root cause recorded**: cairo's toy text API silently renders nothing on a fontconfig/freetype failure (`select_font_face`/`text_extents`/`show_text` all return `Ok(())` with zero-width glyphs — no panic, no error, no WARN). `src/fonts.rs` is DEAD CODE (declared `mod fonts;` at `main.rs:22` but never called from the render path — widgets use cairo's internal fontconfig). The sandbox (`packaging/systemd/tbard.service`) uses `ProtectSystem=strict`/`ProtectHome=true`/`PrivateTmp=true`; the fontconfig cache (`/var/cache/fontconfig/`) is read-only → cache writes fail silently → fontconfig falls back to in-memory resolution. The 043 counter-example shows text DID render under the same sandbox, so fontconfig resolves "sans-serif" today; the failure mode is SILENT if it ever fails. ✅
- **Binding WARN+ requirement recorded**: "The engine must log font/render failure at WARN+ — silence is the bug class. A font miss, a fontconfig init failure, or a zero-width glyph extent MUST produce a WARN (or higher) log line, NEVER silent all-black." (`docs/adr/052-*.md:166-169`). ✅
- **Candidate fixes scoped to Phase 2**: Option 1 (wire `fonts.rs`), Option 2 (bundle a font), Option 3 (font-failure detection + shape fallback). All marked "design — NOT implemented." ✅
- **NO production render-path change shipped**: `git diff efb2cd5..HEAD -- src/` touches only `src/widgets/shape.rs` (new file), `src/widgets/mod.rs` (`pub mod shape;` + the ADR-053 doc comment on `TAP_MAX_MS`), `src/config/yaml.rs` (the `shape` variant + tests), `src/main.rs` (the `WidgetDef::shape` match arm — 8 lines). **NONE of these touch the button/slider text render paths.** The `src/fonts.rs` dead module is untouched. ✅
- **No half-fix**: ADR-052 is explicitly deferred ("DEFER to Phase 2", `docs/adr/052-*.md:141`). ✅

### Claim 6 — Runbook ride-alongs — ✅ VERIFIED (with F-13-1 noted)

**F-045-3 Variant B canonical in test-plan**: ✅
- `docs/test-plan.md` STEP 1 (mask) + STEP 5 (restore) now carry both Variant A (`/usr/lib`-deployed, direct `systemctl mask`) and Variant B (`/etc`-deployed, move-aside + mask). The Variant B procedure records the pre-session sha256, moves the real file aside, symlinks `/dev/null`, daemon-reloads, stops; restore reverses + verifies byte-identical via sha256 + confirms the `.bak` is gone. The source amendment doc (`docs/test-logs/046-f045-1-analysis/f045-3-runbook-amendment.md`) matches the test-plan text. ✅

**ADR-053 tap caveat in mod.rs doc + test-plan**: ✅
- `src/widgets/mod.rs:88-97`: the `TAP_MAX_MS` doc comment records the corpus observation (~750ms normal taps), the crisp-tap requirement (<300ms), and the "re-touch crisply before filing" guidance. **No code change** — the threshold stays 300ms (the doc comment is the change). ✅
- `docs/test-plan.md` Stage-4 section: the ADR-053 caveat block is present ("if a touch exceeds 300ms, NO tap line appears and item 3 stays blocked on a CRISP re-touch, NOT on an input defect"). ✅
- `docs/adr/053-*.md`: the ADR is present, documentation-only, status Accepted. ✅

**Idle-decay testability note**: ✅
- `docs/test-plan.md` Stage-4 section: the idle-decay caveat block is present (active-session seat0 pointer activity keeps the bar awake via the `InputEvent::Activity` catch-all → `backlight.notify_activity()` resetting `last_active`; idle-decay verification requires no seat0 input for the full decay window or a headless condition). Marked "a testability gap, NOT a defect." ✅

**F-13-1 (above) applies to the runbook's HC question** — the Stage-4 visibility target must be named as the shape widget, not the auto-esc.

### Claim 7 — Tests + reconciliation + gates + commit hygiene — ✅ VERIFIED

**Tests: 91 → 97**:
- Baseline (`efb2cd5`, measured in a clean git worktree at `/tmp/opencode/v13-baseline`): **86 main.rs unit + 5 integration = 91**. ✅
- Branch: **92 main.rs unit + 5 integration = 97**. The +6: 5 tests in `widgets::shape::tests` (`test_shape_widget_defaults`, `test_shape_widget_with_stretch`, `test_shape_widget_renders_non_black_pixels`, `test_shape_widget_adversarial_black_fill_produces_zero_non_black`, `test_shape_widget_clamps_fill`) + 1 test in `config::yaml::tests` (`test_adr051_shape_widget_parses_with_defaults`). ✅
- The self-assessment C7 reconciliation ("91 + 6 = 97") is arithmetically correct. The wording "92 main.rs unit" is slightly imprecise (the 5 shape tests live in `src/widgets/shape.rs`, not `src/main.rs` directly), but they compile into the same bin test binary and count as unit tests — the count is right. ✅
- The existing s044 test (`test_adr049_render_only_validation_page_has_zero_key_actions`) was AMENDED to also assert `shape_count > 0` (the visibility guarantee, not just the safety guarantee). ✅

**Gates verbatim** (`docs/test-logs/048/fix-report/gates-verbatim.txt`):
- `cargo fmt --check` → EXIT 0 (no diff). ✅
- `cargo build --bin tbard` → Finished, EXIT 0. ✅
- `cargo clippy --all-targets -- -D warnings` → Finished, EXIT 0. ✅
- `cargo test` → 92 + 5 = 97 passed; 0 failed. ✅
- `scripts/check-invariants.sh` → PASS, EXIT 0 (the ADR-017 `deny(clippy::indexing_slicing)` required-files list now includes `src/widgets/shape.rs`). ✅
- `scripts/ci-gate.sh` → CI gate: PASS, EXIT 0. ✅
- `bash -n packaging/PKGBUILD` → OK, EXIT 0. ✅

**Commit hygiene**: ✅
- Order: `42a14b2` (session 047 A/B evidence — content hypothesis CONFIRMED) → `08ef2dc` (ADR-051: the ADR doc + the code in ONE commit) → `a5c98d2` (ADR-052: deferred design doc, 1 file, no code) → `e987f73` (ADR-053 + self-assessment-16).
- **ADR-before-code**: the ADR-051 doc ships in the same commit as the code (`08ef2dc`) — the ADR is the first thing in that commit's diff (the `docs/adr/051-*.md` file). ADR-052 and ADR-053 are docs-only commits with no code. The session-047 evidence (`42a14b2`) precedes the ADR-051 commit (the evidence motivates the ADR). ✅
- ADR-052 is a clean docs-only commit (`a5c98d2` — 1 file, 197 insertions, no code). ✅
- ADR-053 is a clean docs-only commit (`e987f73` — 2 files: the ADR + self-assessment; the `mod.rs` doc comment is in `08ef2dc`). ✅

---

## W16 adjudication

**W16 — shipped page visibility**: ✅ **CLEARED**. The shipped `examples/render-only-validation-page.yaml` has 4 shape widgets with fills 0.5 / 0.8 / 0.2 / 0.5 — all non-black. The config default (`default_shape_fill()` = 0.5) is non-black. A config that omits `fill:` gets 0.5, not 0.0. The shipped page CANNOT yield a black shape via config defaults. An operator could explicitly write `fill: 0.0`, but that is an operator choice, not a shipped-page defect — and the pixel-probe + adversarial test would catch it (Claim 4). **No finding.**

## W17 adjudication

**W17 — full-page font-freedom + auto-esc**: ⚠️ **VERIFIED with FINDING F-13-1**. The operator-defined page widgets (4 shapes + 1 spacer) are 100% font-free. **BUT the auto-inserted esc (`main.rs:1202-1206`) STILL APPEARS at production width (2170)** — the sim probe confirms `auto_esc_inserted = true`. The esc is a `ButtonWidget` whose visibility is text-dependent (white `show_text`); its inactive shape fill is black. **The page is NOT 100% font-free at production width** — the auto-esc is a text-dependent widget at position 0. The visibility-by-construction guarantee holds for the SHAPE widgets (8/9 of the bar width); the esc is NOT the visibility probe. **The runbook's HC question must name the SHAPE widget as the visibility target, NOT the esc.** F-13-1 logs this as a doc/runbook correction (the shipped example's comment at line 87-88 is backwards). **Not a blocker** — the shapes still glow; the esc just doesn't.

---

## Sim-render evidence

See `docs/test-logs/048/fix-report/sim-render-evidence.txt` for the full capture. Summary:

- The shipped validation page **parses** (1 page, id `render-only-validation`, 4 shape widgets + 1 spacer, total stretch 9).
- The page **draws non-black pixels**: 115,800 / 130,200 (the 14,400 black = the spacer's stretch-1 slot = 2170×60/9).
- Per-shape centroid RGB matches the fill values: 0.5→(128,128,128), 0.8→(204,204,204), 0.2→(51,51,51), 0.5→(128,128,128).
- **Adversarial** (all shapes forced `fill=0.0`): 0 non-black pixels — the probe would FAIL. Non-vacuous.
- **W17 auto-esc gate**: at width=2170, `auto_esc_inserted = true`.

The probe was a throwaway binary at `/tmp/opencode/v13-sim` (replicated `ShapeWidget::render` + the serde schema; did NOT touch repo source). Deleted after capture. The repo `--dry-run` path uses `demo_config()` (not the validation page), so a `--dry-run` run would not exercise the validation page; the throwaway probe was the cleanest way to render the shipped page in sim without a source change.

---

## Live audits

- **Build**: `cargo build --bin tbard` → Finished, EXIT 0.
- **Suite**: `cargo test` → 97 passed (92 unit + 5 integration); 0 failed.
- **Two shape tests alone** (`--bin tbard -- --nocapture`): all 5 `widgets::shape::tests` pass (defaults, with_stretch, renders_non_black_pixels, adversarial_black_fill, clamps_fill).
- **Sim render**: the validation page parses + draws shapes (115,800 non-black pixels); adversarial fill=0.0 → 0 non-black (non-vacuous). See above.
- **`/usr/bin/tbard`**: sha256 `cd7aa6c33f49ec0d43e51aa69d81fe1cc7b11172c3ce0476befe2fe817f230ad` — matches the expected v0.2.6 binary (`cd7aa6c3…`). The v0.2.7 reinstall is the merge session's job; NOT performed this session. Recorded.
- **Host state** (`docs/test-logs/048/fix-report/host-state.txt`):
  - START: oracle (tiny-dfr-mbp142, PID 568, uid 65534/nobody) sole DRM master of card2 (appletbdrm); tbard not running; /dev/input 25 entries; /etc oracle unit mtime 2026-09-14.
  - END: oracle STILL sole master (PID 568, nobody); tbard never started; /dev/input 25 (UNCHANGED); /etc mtime 2026-09-14 (UNCHANGED); debugfs — oracle sole master (name+uid) at start and end, no tbard row appeared.
  - No service lifecycle actions. No `/etc` writes. No interlock. The oracle stayed untouched and lit throughout.

---

## Findings (new → ADR proposals, logged not implemented)

### F-13-1 — shipped example auto-esc comment is backwards (doc/runbook)

**Severity**: low (documentation). **Blocker?** NO.
**Where**: `examples/render-only-validation-page.yaml:87-88` ("A spacer to keep the layout symmetric with the default page's esc-margin (no auto-esc is added because the page is wide).").
**Issue**: the comment claims "no auto-esc is added because the page is wide." This is BACKWARDS — wide bars (`width >= ESC_THRESHOLD` = 2170) TRIGGER auto-esc (`src/main.rs:1202-1206`), not skip it. The sim probe confirms `auto_esc_inserted = true` at width=2170. An esc `ButtonWidget` IS auto-inserted at position 0 on the validation page at production width.
**Impact**: the comment misleads a future reader into thinking the page is 100% font-free; it is NOT (the auto-esc is text-dependent). The visibility-by-construction guarantee holds for the shape widgets; the esc is not the probe.
**Fix (proposed, NOT implemented)**: correct the comment to "an auto-esc IS added at position 0 because the page is wide (width >= 2170); the esc is text-dependent and NOT the visibility probe — the SHAPE widget is." Amend the Stage-4 runbook (`docs/test-plan.md`) HC question to name the SHAPE widget as the visibility target.
**ADR proposal**: F-13-1 → ADR-054 candidate (doc/runbook correction; no code change).

### F-13-2 — self-assessment C7 test-count wording imprecise (doc)

**Severity**: trivial (documentation). **Blocker?** NO.
**Where**: `docs/self-assessment-16.md:70-72` ("92 (main.rs unit, +1 over baseline 86? — see C7) + 5 integration = 97").
**Issue**: the reconciliation is arithmetically correct (91 → 97) but the wording "92 main.rs unit" is imprecise — the 5 shape tests live in `src/widgets/shape.rs` (not `src/main.rs` literally), though they compile into the same bin test binary and count as unit tests. The "? — see C7" hedge is also untidy.
**Impact**: none on the merge; the count is right.
**Fix (proposed, NOT implemented)**: reword to "92 unit tests in the bin test binary (86 baseline + 5 in `widgets::shape::tests` + 1 in `config::yaml::tests`) + 5 integration = 97."
**ADR proposal**: F-13-2 → doc tidy (no ADR needed; fold into the next self-assessment).

---

## Stage-4 completion interlock (shapes-only page)

The Stage-4 completion interlock (the merge session's hardware run) must verify, with the shapes-only validation page installed as `/etc/touchbar/config.yaml`:

1. **Visible wake on safe page** — the bar glows with the shapes-only page (the SHAPE widget is the visibility target; NOT the auto-esc, which is text-dependent and will be dark under the F-045-1 font failure). The 4 shapes (fills 0.5/0.8/0.2/0.5) cover 8/9 of the bar width; if they glow, scanout + backlight work (H1–H4 refuted). If they don't, scanout/backlight is the problem (NOT a content failure).
3. **Reconfirm** — the ADR-049 interlock (move-aside + mask for the `/etc`-deployed oracle unit, Variant B), the ADR-047 wake (touch → `backlight.notify_activity()`), the zero-injection check (`/dev/input` unchanged), and the lifecycle contract (SIGTERM → exit 0, debugfs release) — all proven on hardware in session 047; reconfirm.
5. **Config hot-reload** — live (the remaining Stage-4 functional acceptance; NOT tested this session — no hardware). The hot-reload path (`main.rs:651` `build_pages(&new_cfg, logical_w)` on config change) must be exercised on hardware with the shapes-only page.

Item 3 (tap log) is NOT blocked by the page — re-touch crisply (<300ms, ADR-053) for a `tap page=...` line. Idle-decay verification (DIM/OFF) requires no seat0 input for the full decay window or a headless condition (testability caveat, NOT a defect).

---

## Final

**CLEARED FOR MERGE (v0.2.7) + binary reinstall + the Stage-4 completion interlock (shapes-only page; items 1 (visible wake on safe page) + 3 (reconfirm) + 5 (config hot-reload, live)).**

Two findings (F-13-1, F-13-2) are logged as ADR proposals — neither blocks the merge; both are documentation/runbook corrections. F-13-1 (the auto-esc comment + the runbook HC target) is the important one: the Stage-4 interlock MUST name the SHAPE widget as the visibility target, not the auto-esc. The shapes-only page is visible by construction; the auto-esc is not.