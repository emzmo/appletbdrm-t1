# Task 2 — The 043-vs-047 differential

**Session**: 046 (read-only root-cause research)
**Subject**: F-045-1 — adjudicate the s047 report's H1–H4 against the 043 counter-example
**Date**: 2026-09-27
**Method**: binary diff, config diff, procedure diff, DRM code diff. Cite `file:line`. FREEZE on `src/`.

## Executive verdict

The s047 report's headline claim — "a backlight-activation differential (NOT a render issue)" — is **UNSUBSTANTIATED on two grounds**:

1. **The content side was never checked.** The report verified the backlight side (sysfs writes stick, value reads back 54, bl_power=0, dpms=On, connector enabled) but NEVER verified that the framebuffer content is non-black. For an LCD panel, "no glow at brightness 255" is consistent with an all-black framebuffer — the report's argument that "no glow at 255 proves it's not a render issue" (findings-045.txt:41-43) is **physically wrong**.

2. **The H1–H4 space omits the content hypothesis that the 043 evidence favors.** The 043 counter-example (tbard content lit at external brightness 50 with no special panel-enable) refutes or weakens H1–H4, and the 043-vs-045 differential points at the CONFIG (default page → render-only page) as the variable — but the report's H1–H4 are all DRM/backlight-side hypotheses that do not consider the content.

---

## Every delta (043 → 047)

### Binary diff (90daf3d6 → cd7aa6c3)

- **043 binary**: `/usr/bin/tbard` sha256 `90daf3d622faf90404b459a428661e42a32de6a9970be05856fdd24195c4a082` (v0.2.5, 043 p1-preflight-state.txt:25).
- **047/045 binary**: `/usr/bin/tbard` sha256 `cd7aa6c33f49ec0d43e51aa69d81fe1cc7b11172c3ce0476befe2fe817f230ad` (v0.2.6, 046 reinstall-and-behavioral-verbatim.log:7,15,21).
- **Source diff** (`git diff d66f3ef..cc374b3 -- src/`):
  - `src/main.rs`: +376 lines (ADR-047 wake wiring at main.rs:785-799, ADR-048 enable-tick changes, `set_current_backlight` push at main.rs:898, tests).
  - `src/providers/backlight.rs`: +379 lines (ADR-048 `compute_target()`, `enable()` rewrite to use curve output not raw 128, `notify_activity` at :253-255).
  - `src/providers/input.rs`: +63 lines (ADR-047 `set_current_backlight` at :581-583, gate comment update at :502-518).
  - `src/config/yaml.rs`: +75 lines (ADR-049 render-only page zero-actions test at :268-335).
  - `src/providers/mod.rs`: +9 lines (trait additions).
  - **UNCHANGED**: `src/providers/drm_backend.rs` (0 lines diff), `src/widgets/` (0 lines diff), `src/geometry.rs` (0 lines diff), `src/pixel_shift.rs` (0 lines diff), `src/fonts.rs` (0 lines diff).

**DRM code UNCHANGED — CITED**: `git diff d66f3ef..cc374b3 -- src/providers/drm_backend.rs` → empty. The atomic-commit setup (drm_backend.rs:129-197), the flush path (drm_backend.rs:441-470, `map_dumb_buffer` + `copy_from_slice` + `dirty_framebuffer`), and the master acquire/release (drm_backend.rs:87, :420-426) are byte-identical between 043 and 047.

### Config diff (default page → render-only page)

- **043**: NO `/etc/touchbar/config.yaml` existed (045 p1-baseline.txt:52-56 shows only `config.yaml.example`). The service fell back to `default_config()` (main.rs:1042-1047, :1057-1092) — 12 F-key buttons + auto-added esc. **All widgets are `ButtonWidget`s with text labels.**
- **047/045**: `/etc/touchbar/config.yaml` installed from `examples/render-only-validation-page.yaml` (045 step3-deploy-and-start.txt). The page has 3 text-label buttons + 1 time widget (built as `ButtonWidget::new("⏰", [])`) + 1 spacer + auto-added esc. **All visible widgets are `ButtonWidget`s with text labels.**

**Both configs are text-only.** The render path is identical (same `ButtonWidget::render`). The ONLY content difference is the LABELS ("esc"+"F1".."F12" vs "esc"+"STAGE 4"+"render-only"+"⏰"+"no-op") and the STRETCH distribution.

### Procedure diff (same)

- **043 procedure**: STEP 1 stop oracle → STEP 2 preflight → STEP 3 start tbard → STEP 5 HC2 (first pixels) → STEP 6 stop tbard → STEP 8 restore oracle → STEP 9 final state.
- **045 procedure**: STEP 1 mask oracle (ADR-049) → STEP 2 preflight → STEP 3 deploy render-only config + start tbard → STEP 4 +1s probe + master check → STEP 5 (no glow → investigate) → ABORT → STEP 7 rerun → STEP 8 restore.

**Key procedural difference**: 045 MASKED the oracle (ADR-049), 043 only STOPPED it. In 043, the oracle self-restarted and was restart-looping during the tbard run (043 step6-stop-tbard.txt:32-55) — but tbard held master throughout. In 045, the oracle was masked (inactive) throughout. **This difference is NOT a content-side variable** — it affects only whether the oracle is competing for the card, not what tbard renders.

**Another procedural difference**: 043 had NO config installed (fallback to default); 045 installed the render-only page. **This IS a content-side variable.**

### Capture gap: debugfs dri/2 state

- **043**: checked `debugfs dri/2/clients` (master holder) at P1, STEP 1, STEP 6, STEP 8 (043 p1-preflight-state.txt:25, step1-stop-oracle.txt:12, step6-stop-tbard.txt:22, step8-hc3-restore.txt:16). Did NOT check `dri/2/framebuffers`, `dri/2/planes`, or `dri/2/crtcs`.
- **045**: checked `debugfs dri/2/clients` (master holder) at P1, STEP 4a, STEP 4f, STEP 5, STEP 7 (045 p1-baseline.txt:8-11, step4-ab-master-and-probe.txt:14-16, step4-cdef-journal-input-dmesg-oracle.txt:41-42, step5-current-state.txt:8-9, abort-final-capture.txt:5-6). Did NOT check `dri/2/framebuffers`, `dri/2/planes`, or `dri/2/crtcs`.

**NEITHER session verified the DRM scanout state** (fb binding, plane state, crtc active state) on the touchbar card. The `debugfs dri/<N>/` directory contains `framebuffers`, `planes`, `crtcs` subdirectories that show the actual kernel-side scanout state — whether a framebuffer is bound to a plane, whether the plane is on a crtc, whether the crtc is active. **This is the check 045 missed** (and 043 missed it too, but 043 had a glowing bar so the scanout was implicitly confirmed by the visible pixels).

---

## Adjudication of H1–H4 against the 043 counter-example

### The 043 counter-example (the refutation baseline)

043 facts (hc2-first-pixels.txt:18-23, :58-70):
- tbard sole master of dri/2 (uid 65534).
- Bar lit at **manual brightnessctl 50** (external write, NOT tbard's adaptive path — tbard's adaptive had decayed to 0).
- Rendering observed: "a single bright widget mark on the left side" (the esc button's white text).
- NO special panel-enable: tbard's DRM setup was the SAME atomic-commit (drm_backend.rs:129-197) with the SAME properties (CRTC_ID, MODE_ID, ACTIVE=true, FB_ID, SRC_*, CRTC_*). No DPMS-on, no backlight property, no page-flip flag beyond the initial ALLOW_MODESET commit.
- DRM code UNCHANGED between 043 and 045 (cited above).

**The 043 counter-example establishes**: tbard's DRM scanout/atomic-commit path DOES turn the panel's backlight on (the bar glowed at external brightness 50 with no special panel-enable). The appletbdrm driver's backlight IS drivable by sysfs when tbard holds master. The oracle is NOT required for the backlight to emit.

### H1 — "tbard's DRM scanout/atomic-commit path leaves the panel's backlight enable in a state the sysfs cannot drive"

**WEAKENED, likely REFUTED.**

- 043 used the SAME `try_open_card` atomic-commit (drm_backend.rs:80-199) and the bar glowed. If the atomic-commit left the backlight in an undrivable state, 043 would also have been dark.
- The DRM code is byte-identical between 043 and 045. If H1 were true, it would be true in both runs.
- The 045 report's own evidence (step5-hw-health.txt: connected, enabled, dpms=On, bl_power=0) shows the connector/crtc/DPMS state is correct — the panel is in a state that SHOULD emit light.
- **H1 cannot explain why 043 glowed and 045 didn't** (same DRM code, same master, same panel state). H1 would need an additional variable (e.g. the fb content) to explain the differential.

### H2 — "the appletbdrm backlight is gated on a DRM property/commit sequence the oracle performs and tbard does not"

**REFUTED by the 043 counter-example.**

- 043: tbard (NOT the oracle) held master, and the bar glowed at external brightness 50. The oracle was NOT running (it was restart-looping on the busy card — 043 step6-stop-tbard.txt:32-55). **The oracle's DRM operations were NOT involved in 043's glow.**
- If the oracle performs a special DRM operation tbard does not, 043 would NOT have glowed (tbard was the sole renderer, the oracle never acquired the card during the glow observation).
- The oracle's DRM code (backup_old/tiny-dfr-mbp142/src/display.rs:105-174) is essentially identical to tbard's (same atomic-commit properties, same ALLOW_MODESET, no DPMS-on, no backlight property). Neither does a special panel-enable.
- **H2 is refuted**: the oracle does NOT perform a special DRM operation. 043 proves tbard alone is sufficient.

### H3 — "a T1/USB state the oracle's startup clears"

**REFUTED by the 043 counter-example.**

- 043: tbard started AFTER the oracle was stopped (STEP 1). The oracle did NOT perform its startup sequence during the tbard run (it was restart-looping on the busy card, never acquiring it). If the oracle's startup clears a T1/USB state, 043's tbard would have started with that state UNCLEARED — and the bar would NOT have glowed.
- 043 glowed. **The oracle's startup is NOT required.**
- **H3 is refuted.**

### H4 — "a timing/race where tbard's first flush happens before the backlight enable"

**WEAKENED, likely REFUTED.**

- 043: the same ordering (enable at main.rs:571, first flush at main.rs:716) was in effect. The 043 bar glowed. If the ordering were the problem, 043 would also have been dark.
- ADR-048 (v0.2.6) changed the enable-tick to use `compute_target()` (curve output 54) instead of raw 128 (backlight.rs:220-250). In 043 (v0.2.5), the enable wrote raw 128, then the first update() tick overwrote it with 54 (043 findings-abc-code-derived.txt Fact 3). In 045 (v0.2.6), the enable writes 54 directly (no 128→54 clobber). **The ordering is actually BETTER in 045** (no clobber) — if H4 were true, 043 would be MORE likely to fail (the 128→54 clobber is a bigger window for a race).
- **H4 cannot explain the differential.** The timing is if anything more favorable in 045 than 043.

### H1–H4 summary

| Hypothesis | Claim | 043 counter-example | Verdict |
|------------|-------|---------------------|---------|
| H1 | tbard's DRM scanout leaves backlight undrivable | 043 glowed with same DRM code | **WEAKENED/REFUTED** |
| H2 | oracle performs a DRM op tbard doesn't | 043 glowed WITHOUT the oracle | **REFUTED** |
| H3 | oracle's startup clears a T1/USB state | 043 glowed WITHOUT oracle startup | **REFUTED** |
| H4 | timing/race: flush before backlight enable | 043 had WORSE timing (128→54 clobber) and glowed | **WEAKENED/REFUTED** |

**All four hypotheses are weakened or refuted by the 043 counter-example.** They are all backlight/DRM-side hypotheses that cannot explain why 043 glowed and 045 didn't with the SAME DRM code, SAME master, SAME panel state.

### The hypothesis the report OMITS (the content hypothesis)

**HC (content hypothesis)**: the 045 bar appears dark because the framebuffer content is ALL-BLACK, not because the backlight isn't emitting. The Touch Bar is an LCD panel — a black framebuffer blocks the backlight at any brightness. "No glow at 255" is consistent with an all-black framebuffer.

**The 043 evidence FAVORS this hypothesis**:
- 043 glowed at brightness 50 with the DEFAULT page (esc + F1..F12 text labels). The white text was visible against the black background. The framebuffer was NOT all-black (it had white text pixels).
- 045 did NOT glow at brightness 255 with the RENDER-ONLY page. If the render-only page's text failed to rasterize (for ANY reason), the framebuffer would be all-black, and the bar would appear dark at any brightness.
- **The differential is the CONFIG (default page → render-only page), which is a CONTENT variable, not a backlight variable.**

**BUT**: the render path is identical (same `ButtonWidget::render`, same cairo `show_text`). The 043 text DID render. So the content hypothesis requires an ADDITIONAL explanation for why the render-only page's text fails when the default page's text didn't. Candidates:
- **(HC-a) The render-only page's flush never reaches the hardware** (the page builds but the flush is a no-op or the damage clip is wrong). UNLIKELY — the flush path is identical (drm_backend.rs:441-470) and the damage clip is the full framebuffer (main.rs:709-714).
- **(HC-b) The render-only page's layout produces zero-size rects** (the stretch math divides by zero or produces empty rects). UNLIKELY — the stretch math (page.rs:33-46) is the same; the render-only page's total stretch is 2+2+3+1+2=10 (plus auto-esc stretch=1 → 11), non-zero.
- **(HC-c) The time widget's "⏰" emoji fails to render** (the emoji is not in the font). POSSIBLE — but the other buttons ("STAGE 4", "render-only", "no-op", "esc") are ASCII and would still render. If ONLY the emoji fails, the other labels should still be visible. The human saw NOTHING — so this alone is insufficient.
- **(HC-d) The framebuffer is all-black for a reason BEYOND text failure** — e.g. the flush succeeds but the scanout is not armed (the fb is not bound to the plane). This is the `dri/2/framebuffers` + `dri/2/planes` check that NEITHER session performed. **This is the most likely content-side cause and the capture gap.**

**The content hypothesis (HC) is NOT refuted by 043 — it is the hypothesis the report's H1–H4 space omits, and the 043 evidence favors it as the differential direction (content variable, not backlight variable).**

---

## The physical-model error in the s047 report

The s047 report (findings-045.txt:41-43) states:
> NOT a render-pipeline issue: rendering would not affect whether the backlight emits light; the human saw no glow even at brightness 255 (a pure backlight value, no rendering involved).

**This is physically wrong for an LCD panel.** The Touch Bar is an LCD (liquid crystal display) with a backlight:
- The backlight emits light.
- The LCD layer modulates the light per-pixel.
- A BLACK framebuffer → the LCD blocks the backlight → **the bar appears dark even with the backlight at full brightness.**

"No glow at brightness 255" does NOT prove "the backlight isn't emitting." It proves "no light reaches the viewer." For an LCD, that can be caused by EITHER (a) the backlight not emitting, OR (b) the framebuffer being all-black. **The report conflated "backlight emitting" with "bar appears lit" — for an LCD, these are not the same.**

The report's evidence (sysfs brightness reads back 54/200/255 correctly, bl_power=0, dpms=On) confirms the BACKLIGHT is being told to emit. It does NOT confirm the framebuffer content is non-black. **The content side was never checked.**

---

## The capture gap (043 vs 045)

| Check | 043 | 045 | What it would show |
|-------|-----|-----|-------------------|
| `debugfs dri/2/clients` (master) | ✓ | ✓ | Who holds master |
| `debugfs dri/2/framebuffers` | ✗ | ✗ | Whether a fb is bound |
| `debugfs dri/2/planes` | ✗ | ✗ | Whether a plane is scanning out a fb |
| `debugfs dri/2/crtcs` | ✗ | ✗ | Whether the crtc is active + mode |
| sysfs `bl_power` | ✗ | ✓ (0=on) | Backlight power state |
| sysfs `dpms` | ✗ | ✓ (On) | DPMS state |
| sysfs `enabled` | ✗ | ✓ (enabled) | Connector enabled |
| sysfs `brightness` reads back | ✗ | ✓ (54/200/255) | Backlight value accepted |
| Human saw pixels | ✓ (glow at 50) | ✗ (no glow at 255) | Content visible |

**045 checked MORE sysfs state than 043, but NEITHER checked the DRM scanout state (fb/plane/crtc).** 043 didn't need to — the visible pixels confirmed the scanout was working. 045 DID need to — the absence of pixels is exactly the symptom that the scanout state would explain. **This is the capture gap the task identifies: 045 should have checked `dri/2/framebuffers`, `dri/2/planes`, `dri/2/crtcs` to determine whether the framebuffer is actually being scanned out.**

---

## Adjudication summary

| Claim in s047 report | Verdict | Reason |
|-----------------------|---------|--------|
| "NOT a render issue" (findings-045.txt:11) | **UNSUBSTANTIATED** | Content side never checked. Physical model is wrong for LCD. |
| "no glow at 255 proves not a render issue" (findings-045.txt:41-43) | **WRONG** | LCD black framebuffer blocks backlight at any brightness. |
| H1 (DRM scanout leaves backlight undrivable) | **WEAKENED/REFUTED** | 043 glowed with same DRM code. |
| H2 (oracle does a DRM op tbard doesn't) | **REFUTED** | 043 glowed without the oracle. |
| H3 (oracle startup clears T1/USB state) | **REFUTED** | 043 glowed without oracle startup. |
| H4 (timing/race: flush before enable) | **WEAKENED/REFUTED** | 043 had worse timing and glowed. |
| H1–H4 space completeness | **INCOMPLETE** | Omits the content hypothesis (HC) that the 043 evidence favors. |

**The 043 counter-example is the decisive evidence**: tbard content lit at external brightness 50 with no special panel-enable, same DRM code, same master, same sandbox. The differential between 043 (glow) and 045 (no glow) is the CONFIG (default page → render-only page) — a content variable. The report's H1–H4 are all backlight/DRM-side and cannot explain the differential. The content hypothesis (HC) — that the 045 framebuffer is all-black for a reason the scanout-state check would reveal — is the hypothesis the report should have considered.