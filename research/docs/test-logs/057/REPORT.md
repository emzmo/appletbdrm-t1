# Session 057 — Stage-4 Completion Interlock — FINAL REPORT

## Verdict: STAGE 4 PASS — 7/7

The Touch Bar is a working display + input surface under tbard, end to end,
with every acceptance item witnessed live on hardware.

## HC answers (verbatim, with timings)

- HC1 (19:08): "all ok" — external USB keyboard Esc tested; bar Esc sends Esc; recovery.md read
- HC2-visible (19:11): "shapes across the full width of it on different gray" — ADR-054 full-bar clip proven
- HC2-wake (19:16): "the bar lights when I touch it :D" — ADR-057 wake-before-gate proven on hardware
- HC3-tap (19:18): "I did a double tap on the left" — journal: tap logical=(395,30) hit=Some(1) ×2 — ADR-056 input scale proven
- HC4-hot-reload (19:26): "it works. the 4 shapes changed to one shape" — ADR-055 directory watch + ADR-054 full-bar render, both live
- HC-restore (19:30): "restored correctly" — oracle F-row + Esc confirmed

## Step table

| Step | Result | Evidence |
|------|--------|----------|
| P1 baseline | Clean (v0.2.9, oracle sha 5310c917…, card2 appletbdrm, 20 input, 90/54) | P1-baseline |
| HC1 | PASS | "all ok" |
| STEP 1 mask oracle (Variant B) | PASS — inactive +60s, debugfs empty | step1 |
| STEP 2 preflight | PASS — GO (exit 0), STEP 0 a–f PASS | step2 |
| STEP 3 deploy + start | PASS — shapes page loaded; enable-tick → 54; privdrop; self-checks OK | step3 journal |
| STEP 4 verify live | PASS — tbard sole master uid 65534; brightness 54; mask held | step4 |
| STEP 5 HC2-visible | PASS — "shapes across the full width" | HC2 |
| STEP 5 HC2-wake | PASS — bar dark after 75s decay → touch → "the bar lights when I touch it" | journal: touch wake → notify_activity ×2 |
| STEP 5 HC3-tap | PASS — "double tap on the left" → tap logical=(395,30) hit=Some(1) ×2 | journal |
| STEP 6 HC4-hot-reload | PASS — config rewritten (4 shapes → 1 white) → "the 4 shapes changed to one shape" | journal: config reloaded ×4 |
| STEP 7 stop tbard | PASS — exit 0, Result=success, debugfs empty (RAII release) | step7 |
| STEP 8 restore oracle | PASS — byte-identical (5310c917…), sole master, bar at 54, lit | step8 |
| HC-restore | PASS — "restored correctly" | HC-restore |
| STEP 9 final state | == P1 baseline | — |

## Stage-4 acceptance board — FINAL

| # | Item | Verdict | ADR |
|---|------|---------|-----|
| 1 | Visible wake on safe page | ✅ VERIFIED | ADR-057 (wake-before-gate) |
| 2 | Gate semantics | ✅ VERIFIED (prior) | ADR-047 |
| 3 | Tap log with hit | ✅ VERIFIED | ADR-056 (input scale) |
| 4 | Curve-maintained brightness | ✅ VERIFIED | ADR-048 (coordination) |
| 5 | Config hot-reload (visual) | ✅ VERIFIED | ADR-055 (directory watch) + ADR-054 (full-bar clip) |
| 6 | Mask interlock | ✅ VERIFIED | ADR-049 (interlock hardening) |
| 7 | Lifecycle contract | ✅ VERIFIED | ADR-025 (exit codes) |

## What was proven on hardware for the first time

1. ADR-057 (wake-before-gate): touch on a DARK bar fires notify_activity →
   loop-bottom update writes 54 → bar lights under the finger. The gate
   (backlight.brightness() == 0) now reads directly from the backlight
   provider, AFTER the wake — matching the oracle's pre-gate process_event.
   The waking touch is consumed (macOS UX); the second touch processes.

2. ADR-056 (input scale): taps land at y=30 (correct for a 60-tall bar,
   not 1068) and hit widgets (hit=Some(1)). The (2,1068) hit=None era is over.

3. ADR-055 (directory watch): FOUR config edits → FOUR reloads (19:20:24,
   19:23:50, 19:24:16, 19:26:36) — the directory watch survives atomic
   replace (sed -i, tee). s051's one-reload-then-silence bug is dead.

4. ADR-054 (clip fix): shapes render across the FULL bar width, not just
   the leftmost 60px. The transposed ClipRect corner construction is fixed.

5. Zero injection: the render-only page's action:[] held — no key events,
   /dev/input count unchanged. Safety by CONFIG, not by accident.

## Closing

STAGE 4 PASS — 7/7. The Touch Bar under tbard is a working display + input
surface: shapes render visibly across the full bar, touch wakes from dark,
taps hit widgets, config hot-reloads visually, and the lifecycle contract
holds (exit 0, RAII release, clean restore). The oracle is restored
byte-identical and sole master. Machine safe.

The staircase is complete: privilege → identity → backlight-write → content
→ clip → scale → wake — every layer individually proven, the whole chain
witnessed live.
