# F-045-1 analysis — root-cause research (session 046, read-only)

**Session**: 046 — one session, read-only, no interlock, no lifecycle, no `/etc`. Oracle stays lit.
**Goal**: adjudicate F-045-1 — the s047 report's "NOT a render issue" claim is unsubstantiated (backlight side verified; content side never checked) and its H1–H4 space omits the content hypothesis that the 043 evidence favors.
**Date**: 2026-09-27
**FREEZE**: no `src/` changes this session. All output is DATA.

## Documents

| File | Task | Content |
|------|------|---------|
| `task0-tap-line-verdict.md` | Task 0 | Tap-line verdict from the archived journal. Stage-4 items 2 (gate semantics) and 3 (tap log). |
| `task1-content-derivation.md` | Task 1 | The render-only page's draw path — all TEXT, no SHAPE. Font/sandbox derivation. The test gap (s044 verified parse + zero-actions, never visibility). |
| `task2-adjudication.md` | Task 2 | The 043-vs-047 differential. H1–H4 adjudicated against the 043 counter-example (weakened/refuted). The content hypothesis (HC) the report omits. |
| `task3-ab-discrimination-plan.md` | Task 3 | The A/B experiment design. Prediction table. Fix candidates. |
| `adr-051-shape-widget-proposal.md` | ADR-051 | Proposed: add a SHAPE-drawn, no-action widget to the validation page (the minimal fix). |
| `adr-052-text-rasterization-candidate.md` | ADR-052 | Candidate: fix text rasterization under the sandbox if labels/time are production-intended. |
| `f045-3-runbook-amendment.md` | F-045-3 | Proposed amendment to ADR-049: /etc-deployed unit move-aside + mask. |

## Headline findings

### 1. The s047 report's "NOT a render issue" claim is UNSUBSTANTIATED

The report (findings-045.txt:41-43) argues: "no glow at brightness 255 (a pure backlight value, no rendering involved)" proves it's not a render issue. **This is physically wrong for an LCD panel.** The Touch Bar is an LCD: a BLACK framebuffer blocks the backlight at any brightness. "No glow at 255" is consistent with an all-black framebuffer — the content side was never checked.

### 2. H1–H4 are weakened or refuted by the 043 counter-example

043 (same DRM code, same master, same sandbox, same cairo): bar glowed at external brightness 50 with the default page. No special panel-enable. The oracle was NOT involved (it was restart-looping on the busy card). The DRM code is byte-identical between v0.2.5 (043) and v0.2.6 (045) — `git diff d66f3ef..cc374b3 -- src/providers/drm_backend.rs` is empty.

- **H1** (DRM scanout leaves backlight undrivable): WEAKENED/REFUTED — 043 glowed with the same DRM code.
- **H2** (oracle does a DRM op tbard doesn't): REFUTED — 043 glowed without the oracle.
- **H3** (oracle startup clears T1/USB state): REFUTED — 043 glowed without oracle startup.
- **H4** (timing/race: flush before enable): WEAKENED/REFUTED — 043 had worse timing (128→54 clobber) and glowed.

### 3. The content hypothesis (HC) is the omitted hypothesis the 043 evidence favors

The 043-vs-045 differential is the CONFIG (default page → render-only page) — a CONTENT variable. Both pages are text-only (`ButtonWidget::render` — white text on black). If the render-only page's text fails to rasterize, the framebuffer is all-black → the bar appears dark at any brightness. The report's H1–H4 are all backlight/DRM-side and do not consider the content.

### 4. The render-only page has NO shape-only widget

Every visible widget on the render-only page is a `ButtonWidget` that renders TEXT (`src/widgets/button.rs:52-102`). The `time` widget is `ButtonWidget::new("⏰", [])` (`src/main.rs:1183`) — text. The `spacer` renders nothing. **If cairo's `show_text()` silently renders nothing (font failure), the page is all-black.** There is no shape-drawn fallback.

### 5. The s044 Stage-4 test verified parse + zero-actions, NEVER visibility

`test_adr049_render_only_validation_page_has_zero_key_actions` (`src/config/yaml.rs:268-335`) asserts the page parses and has no key actions. It does NOT assert the page renders non-black pixels. The content side was never tested.

### 6. The tap lines are absent because the touch exceeded TAP_MAX_MS (300ms), not because of a gate failure

The gate was OPEN (current_bl=54, pushed by `set_current_backlight` at `main.rs:898`). The 14 wake lines confirm touches reached `main.rs:785`. The tap `info!` line (`main.rs:825`) fires only if `update_gesture` returns `Some(Gesture::Tap)` — which requires a Down→Up within 300ms. The 043 evtest capture showed a 758ms tap duration; the 045 touch likely exceeded 300ms too. **Stage-4 item 2 (gate semantics) is VERIFIED (gate was open). Item 3 (tap log) is BLOCKED on a re-run with a crisp <300ms tap.**

### 7. The capture gap: neither 043 nor 045 checked debugfs dri/2 scanout state

Both sessions checked `debugfs dri/2/clients` (master holder) but NEITHER checked `dri/2/framebuffers`, `dri/2/planes`, or `dri/2/crtcs` (the actual scanout state — whether a fb is bound to a plane, whether the crtc is active). 043 didn't need to (visible pixels confirmed the scanout). 045 DID need to (the absence of pixels is the symptom the scanout-state check would explain).

## The decisive experiment (Task 3)

Run A (tbard, no config, default page — exact 043 condition) + Run B (tbard, render-only page). Same captures: debugfs dri/2 framebuffers + planes + crtcs (the check 047 missed), manual brightness 100, human checkpoint. NO TOUCHING in Run A (the default page injects).

**Prediction**: A glows + B dark → HC CONFIRMED, H1–H4 refuted. A dark → H1–H4 revived.

## Fix candidates

- **ADR-051** (proposed): add a SHAPE-drawn, no-action widget to the validation page — visible without text, the minimal fix.
- **ADR-052** (candidate): fix text rasterization under the sandbox if labels/time are production-intended — deferred to Phase 2 scope.
- **F-045-3 runbook amendment** (proposed): ADR-049 amendment for /etc-deployed units — move-aside + mask.

## FREEZE

No `src/` changes this session. All output is DATA. The ADR proposals are for the next session's acceptance; the A/B plan is for the next short interlock.