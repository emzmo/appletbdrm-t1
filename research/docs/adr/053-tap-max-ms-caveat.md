# ADR 053: TAP_MAX_MS=300ms tap-classification caveat (documentation-only)

## Status: Accepted (documentation-only — no code change)

## Date: 2026-09-27

## Context

Session 046's Task 0 (`docs/test-logs/046-f045-1-analysis/task0-tap-line-verdict.md`)
derived from the archived journal that the 045 tap lines were absent
because the touch exceeded `TAP_MAX_MS` (300ms), NOT because of a gate
failure. The gate was OPEN (current_bl=54, pushed by
`set_current_backlight`); the 14 `tbard: touch wake →
backlight.notify_activity()` INFO lines confirm touches reached the
wake path. The `tap page=...` info line fires only if `update_gesture`
returns `Some(Gesture::Tap)` — which requires a Down→Up within 300ms
(`src/widgets/mod.rs:87`, `TAP_MAX_MS`). The 043 evtest capture showed
a 758ms tap duration; the 045 touch likely exceeded 300ms too.

Session 047's A/B pair confirmed this: Run A produced 12 TAP lines and
Run B produced 5 TAP lines (`docs/test-logs/047-ab/run{A,B}-step4e-hc-tap.log`)
— both touches were crisp (<300ms), so both produced tap lines. The
threshold is the correct gesture-classification boundary; the absence
of a tap line after a slow touch is NOT a defect.

### The threshold

`TAP_MAX_MS = 300` (`src/widgets/mod.rs:87`). `update_gesture`
(`src/widgets/mod.rs:90-175`) classifies a Down→Up as `Gesture::Tap`
only if `time.elapsed() <= TAP_MAX_MS` (`mod.rs:117-119`). A slower
Down→Up yields `(GestureState::Up, None)` — no tap, no `tap page=...`
log line, no key emission.

### The corpus observation

Normal human taps in the corpus are ~750ms (the 043 evtest capture).
The 300ms threshold therefore requires a CRISP, deliberate tap for a
touch to classify as a tap. This is intentional: the boundary separates
a tap from a hold/drag, and the Touch Bar's gesture vocabulary
(slider swipe, page switch) needs the longer-than-300ms window to
disambiguate. The trade-off is that a casual operator touch may not
classify as a tap — which is correct behavior, not a bug.

## Decision

DOCUMENT the caveat — no code change. The `TAP_MAX_MS=300ms` threshold
is correct; the documentation gap (a missing tap line was misread as a
gate/input defect in 045) is the issue. Record the caveat in:

1. `src/widgets/mod.rs:87` — a doc comment on `TAP_MAX_MS` stating the
   corpus observation (~750ms normal taps), the crisp-tap requirement
   (<300ms), and the "re-touch crisply before filing" guidance.
2. `docs/test-plan.md` — a Stage-4 runbook caveat note so future
   sessions interpret a missing tap line correctly (re-touch crisply,
   do NOT file an input defect).
3. This ADR.

## Consequences

- Future Stage-4 sessions interpret a missing tap line as "re-touch
  crisply (<300ms)," NOT as a gate failure or input defect.
- The threshold value (300ms) is documented as intentional; no one
  bumps it to 750ms to "fix" the missing tap lines (that would break
  the tap/hold/drag disambiguation).
- No code change — the threshold stays 300ms.

## Relation to ADR-051 / ADR-052

ADR-053 is independent of ADR-051 (shape widget) and ADR-052 (text
rasterization). It is a documentation-only ADR that records a
testability/interpretation caveat for the gesture classifier. It
ships as a ride-along with the session-048 fix work.