# Session 052 — F-045-1 Discriminating Observation (transposed-clip confirmation)

Date: 2026-09-27. Executor: pygpt-orchestrator (direct tooling, human-approved).
Result: TRANSPOSED-CLIP HYPOTHESIS **CONFIRMED LIVE** (HC2) + NEW BUG: input scale
transposition (ADR-056 candidate) discovered from tap coordinates in the same window.

## Method
Read-only three-source derivation, then a 12-minute interlock reusing the validated
protocol (Variant B move-aside + mask):
- P1 baseline (oracle unit sha 5310c917… recorded pre-move) — P1-baseline.txt
- STEP 1 interlock open (move-aside + daemon-reload + stop; inactive through +60s;
  debugfs empty) — STEP1-interlock-open.txt
- STEP 2 preflight GO (STEP 0 a–f PASS) — STEP2-preflight.txt
- STEP 3 start tbard, NO config (the 043/Run-A condition; default page) — STEP3-start.txt
- STEP 4 idle decay 54→1 (30s) →0 (60s), no touch — STEP4-idle-decay.txt
- STEP 5 external write 255 — STEP5-external-255.txt
- HC2 (human, verbatim, timed): “Bright fragment at far left, sharply cut off, rest
  black. its brightness is not 255, just looks as dimm like 54 (confirmed by reading
  brightnessctl tool)” — HC2-verdict.txt (+ HC2-injection-check.txt)
- STEP 6 stop (exit 0, Result=success, NRestarts=0, 14min32s) — STEP6-stop-tbard.txt
- STEP 8 restore oracle byte-identical (5310c917… match), sole master, bar relit —
  STEP8-restore.txt

## Finding 1 — F-045-1 = transposed damage clip (ADR-054)
Three sources, cited:
1. drm-0.14.1 crate: `ClipRect::new(x1, y1, x2, y2)` — CORNER coords.
2. Our flush (src/providers/drm_backend.rs:459-462): full-screen fb rect {0,0,60,2170}
   mapped to `new(0,0, 2170, 60)` → on a 60×2170 fb, x2=2170 clamps, y2=60 → the
   damage window covers only x 0..60, y 0..60 — the leftmost ~60px of the bar.
3. Driver (backup_old/appletbdrm-1.2/appletbdrm.c:1055-1068): `drm_rect_intersect`
   CLAMPS (never rejects), then transmits only the intersected region over USB
   (frame->begin_x/begin_y/width/height). Everything outside never reaches the panel.
   No error is ever returned — matches every observed silent-dark run.
The oracle reference (backup_old/.../main.rs:842,860): destructures mode().size() as
(height, width)=(60,2170) and passes `new(0,0,60,2170)` = FULL fb — correct. Our port
transposed a rect that was already in fb space.
HC2 confirmed the prediction IN ADVANCE with specific geometry: bright fragment at
far left, sharply cut off, rest black. Retrodicts 043 (visible esc fragment), 047 A/B,
051 (shapes mid-bar + auto-esc black shape covering the window), and the absence of
any error across all runs.
**This CONFIRMS the content-family explanation and REFUTES s051's closing “DRM-side
panel-activation differential” conclusion** (modeset sequences structurally identical;
the differential was the clip). s051's REPORT closing paragraph needs the standard
erratum annotation (annotate, don't rewrite).

## Finding 2 — input scale transposition (ADR-056 candidate; found in this window)
The human's 4 taps (13:10:59) logged `tap page=primary logical=(2,1068) hit=None`.
y=1068 is impossible in logical space (height=60). Arithmetic: raw Y≈62 ÷127 × **2170**
= 1060 ≈ 1068 — the Y denominator is the portrait width instead of the logical height.
Root cause (code, cited): src/main.rs:325-329 — `tb_dims = drm.display_info()` returns
PORTRAIT fb dims (60, 2170), consumed as `(width, height)` in input.rs:519-521 for
`x_transformed(width) / y_transformed(height)`. X and Y scale targets are swapped.
Consequences: every hardware tap so far logged but hit NOTHING (hit=None in 047/051/052
— the tap-log “reconfirmations” logged classification, not hit-test integration);
AND a safety note: on the default page, once fixed, the same touch WOULD inject Esc —
this run was protected only by the bug. Runbook: never touch during default-page
observation windows (now evidence-backed).

## Stage-4 status after this session
5/7. Items 1 (visible wake on safe page) and 5 (visual hot-reload confirmation) remain
blocked on the clip fix; item 3's hit-test integration now also requires the scale fix.
Remaining fixes are known and small: clip extents (one line), input scale dims (one
line), watcher re-arm (ADR-055), regression guards for each class.

## Safety / host state
No /etc writes (oracle unit moved aside and restored byte-identical; sha chain in
STEP8-restore.txt). Oracle untouched-as-a-process except stop/start per protocol.
tbard never enabled. Freezer respected: no src/ changes this session (docs only).
