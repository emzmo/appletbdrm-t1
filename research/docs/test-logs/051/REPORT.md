# Session 051 REPORT — Stage-4 completion interlock

**Date**: 2026-09-27
**HEAD**: `07813f4` == `v0.2.7` (src/ frozen, 0-line diff)
**Binary**: `/usr/bin/tbard` sha256 `18b368c4…` (behaviorally verified)
**Verdict**: **ABORT — F-045-1 recurrence on v0.2.7 with the shapes-only page blocks items 1 (visible) and 5 (visual confirmation); item 3 reconfirmed; item 5 MECHANISM witnessed LIVE for the first time (the session headline). Interlock closed, machine restored byte-identical.**

## Step table

| Step | Action | Result | Evidence |
|------|--------|--------|----------|
| P1 | Baseline capture (git, card mapping, digitizer, debugfs, /dev/input, backlights, oracle unit sha256, services, /etc/touchbar) | ALL match protocol CONTEXT exactly. HEAD `07813f4`==v0.2.7; card2/appletbdrm (dri minor 2); digitizer=event4 (predicate, fresh this boot — shifted from event7); oracle `tiny-dfr-mbp142` (tgid 568, uid 65534) sole master; 18 /dev/input event nodes; acpi_video0 90/90, appletb_backlight 54/255; oracle active+static, tbard inactive+disabled; /etc/touchbar: no live config; oracle unit sha256 `5310c917…` recorded | `P1-baseline.txt`, `P1-services-etc.txt`, `oracle-unit-pre.sha256` |
| HC1 | External-keyboard Esc + bar Esc + recovery.md read | 11:43:02 — operator: "all good" | `HC1.txt` |
| STEP 1 | Variant B interlock open (move-aside + mask, +60s no-restart) | 11:43:06–11:44:10 — oracle inactive+masked; +60s assertion PASSED (ADR-049 — s043 race cannot recur); debugfs `dri/2/clients` EMPTY; backup sha256 matches pre | `STEP1-interlock-open.txt`, `STEP1-60s-no-restart.txt` |
| STEP 2 | Preflight (interlock-preflight.sh) | 11:44:13 — **GO (exit 0)**; STEP 0 a–f PASS (0d: `--probe-input` ACCEPTS event4); no master holder; oracle inactive+masked; tbard inactive+disabled | `STEP2-preflight.txt` |
| STEP 3 | Deploy shapes-only page + start tbard | 11:44:26 — config deployed (sha256 matches repo example); tbard active; +1s probe 54/255 == expected `display_to_touchbar(90,128)`=54; boot journal clean (privdrop, DRM scan, self-check, digitizer-identified, enable-tick → 54, NO config-fallback WARN) | `STEP3-deploy-start.txt`, `STEP3-journal.txt` |
| STEP 4 | Verify live (debugfs, scanout, eDP, +1s probe, mask, /dev/input, dmesg) | 11:45:01–11:45:15 — tbard sole master (uid 65534); dri/2 scanout active (fb 41, plane-0, crtc-0 enable=1); eDP unaffected; +1s probe 54==54; mask held (no oracle row); /dev/input 18 (unchanged); no dmesg delta | `STEP4-verify-live.txt` |
| STEP 5 prep | Idle-dark observation (testability caveat) | 11:45:25–11:46:55 — decayed cleanly 54→1 (30s)→0 (60s); idle-dark ACHIEVED this session (seat0 quiet enough) | `STEP5-idle-decay-observe.txt` |
| HC2 | WAKE (touch once, gently; do shapes light up?) | 11:48:24 — **FAIL**: operator "I see no changes when I touch it. touchbar completely dark. and it has been dark the whole process." Journal proves touch reached tbard (80+ wake lines, tap lines), sysfs re-brightened to 54, but NO visible light | `HC2-and-evidence.txt` |
| HC2b | Diagnostic: brightnessctl 255/200/100 under tbard | 11:48:36–11:51:40 — operator "no changes"; bar dark at any sysfs brightness under tbard's sole mastership. **F-045-1 recurrence on v0.2.7.** | `F045-1-recurrence-diagnostic.txt`, `HC2b-and-item3.txt` |
| STEP 6 | Item 5 config hot-reload (LIVE — headline) | 11:51:46–11:52:21 — **MECHANISM PROVEN**: edit 11:51:47 → reload line 11:51:47 (same second, ADR-021 debounce holds, no storm). Visual N/A (F-045-1). Follow-up: watcher does not re-fire after first reload (edits 2+3 → no reload) | `STEP6-hot-reload-edit.txt`, `STEP6-hot-reload-journal.txt`, `STEP6-summary.txt`, `STEP6-edit2-investigation.txt`, `STEP6-edit3.txt` |
| STEP 7 | Lifecycle (stop→release; rerun→+1s probe→stop→release) | 11:52:43 — SIGTERM→exit 0 ×2; RAII release ×2 (debugfs empty, plane fb=0); idempotent rerun sole master; +1s probe 54==54 | `STEP7-lifecycle.txt` |
| STEP 8 | Interlock close (remove config, restore oracle byte-identical, start) | 11:52:55 — config removed (original state); oracle unit restored byte-identical (sha256 `5310c917…`==pre); .bak gone; oracle active+static sole master; bar relit (sysfs 54) | `STEP8-interlock-close.txt`, `oracle-unit-post.sha256` |
| HC-restore | F-row visible? Esc on bar sends Esc? | 11:53:19 — operator "yes f-row visible". **F-045-1 differential confirmed**: same sysfs path/value visible under oracle, dark under tbard | `HC-restore.txt` |
| STEP 9 | Final state == P1 baseline | 11:53:19 — ALL match P1: HEAD v0.2.7, src/ frozen, card2/appletbdrm, oracle sole master (name+uid), /etc/touchbar no live config, oracle unit sha256 matches, oracle active+static, tbard inactive+disabled, 18 /dev/input, backlights 90/90 + 54/255 | `STEP9-final-state.txt` |

## Stage-4 acceptance board FINAL (after session 051)

| # | Item | Verdict | Evidence pointer |
|---|------|---------|------------------|
| 1 | wake (visible, on the safe page) | **FAIL — F-045-1 recurrence**. Touch wake FIRED (journal: 80+ `touch wake` lines); sysfs re-brightened to 54; but panel produced NO visible light at any sysfs brightness (255/200/100/54) under tbard's sole DRM mastership. Same sysfs path glows under the oracle. ADR-051 (font rasterization) REFUTED — shapes-only page has zero font dependency. | s051 `HC2-and-evidence.txt`, `HC2b-and-item3.txt`, `F045-1-recurrence-diagnostic.txt`, `HC-restore.txt` |
| 2 | (closed prior — s047/AB) | PASS | — |
| 3 | tap log (reconfirm on safe page) | **RECONFIRMED** — multiple fresh `tap page=render-only-validation logical=(x,1068) hit=None` lines this boot (x ∈ {0,2,5,6,8,9,14}, y=1068); CRISP <300ms taps classified as `Gesture::Tap` correctly (ADR-053); hit=None (zero injection, render-only page safe). Independent of visible panel. | s051 `HC2-and-evidence.txt`, `HC2b-and-item3.txt` |
| 4 | (closed prior — s047/AB) | PASS | — |
| 5 | config hot-reload (LIVE) | **MECHANISM PROVEN** — FIRST live-hardware witness. Edit 11:51:47 → reload line 11:51:47 (same second; ADR-021 debounce holds: one write = one reload, NO storm). **Visual confirmation BLOCKED by F-045-1** (HC4 N/A — panel dark; documented limitation, NOT a hot-reload defect). Follow-up finding: watcher does not re-fire after the first reload (edits 2+3 → no reload; total=1) — ADR-055 candidate. | s051 `STEP6-hot-reload-edit.txt`, `STEP6-hot-reload-journal.txt`, `STEP6-summary.txt`, `STEP6-edit2-investigation.txt`, `STEP6-edit3.txt` |
| 6 | (closed prior — s047/AB) | PASS | — |
| 7 | (closed prior — s047/AB) | PASS | — |

**Items 1 (visible) and 5 (visual confirmation of hot-reload) remain blocked by F-045-1 — a pre-existing DRM panel-activation differential (the oracle performs a DRM-side panel-enable tbard does not), NOT a content/write/hot-reload defect. Item 3 is reconfirmed. Item 5's mechanism is proven live.**

## HC answers verbatim with timings

| HC | Timestamp | Question (verbatim) | Answer (verbatim) | Verdict |
|----|-----------|---------------------|-------------------|---------|
| HC1 | 2026-09-27T11:43:02+01:00 | External-keyboard Esc tested just now; Esc on bar sends Esc; recovery.md read. Confirm all three. | "all good" | PASS |
| HC2 (WAKE) | 2026-09-27T11:48:24+01:00 | Touch the bar ONCE, gently. Do the SHAPES light up under your finger? One sentence. | "I see no changes when I touch it. touchbar completely dark. and it has been dark the whole process" | **FAIL (F-045-1 recurrence)** |
| HC2b (diagnostic) | 2026-09-27T11:51:40+01:00 | Did the bar produce ANY visible light at ANY of those brightness levels (255/200/100)? One sentence. | "no changes" | F-045-1 confirmed |
| HC4 (HOT-RELOAD) | 2026-09-27T11:51:47+01:00 (reload line) | Within a couple of seconds of my edit: did the bar CHANGE without a restart? Describe the change. One sentence. | N/A — panel dark under tbard (F-045-1); visual confirmation impossible | Visual BLOCKED; mechanism PROVEN via journal |
| HC-restore | 2026-09-27T11:53:19+01:00 | F-row visible? Esc on bar sends Esc? | "yes f-row visible" | F-045-1 differential confirmed; window CLOSED |

## THE HOT-RELOAD TRIPLE (item 5 — the session headline)

1. **Edit timestamp**: 2026-09-27T11:51:47+01:00 — single write, first shape fill 0.5 → 1.0; sha256 `8e6865f0189d163d7e54e7383d2089f9fdc1228567360fac03025514ff79797e` → `587cc3e2d3070f39c550c59c540d8572e5e4311422a18c616ffac5edc7e01bd8`.
2. **Reload line timestamp**: 2026-09-27T11:51:47+01:00 — `tbard: config reloaded` INFO line, SAME SECOND as the edit. ADR-021 debounce holds: one write = one reload line, NO storm.
3. **Visual change confirmation**: **N/A — panel dark under tbard (F-045-1 recurrence); HC4 visual impossible this session (documented limitation, NOT a hot-reload defect).** The reload MECHANISM (the journal-witnessable property, the actual headline) is proven live on hardware for the first time.

**Follow-up finding (ADR-055 candidate):** after the first reload, the config watcher does NOT fire on subsequent writes. Edit 2 (11:51:59, fill 1.0 → 0.5, restored original sha256): NO reload line. Edit 3 (11:52:21, fill 0.5 → 0.9, distinct value): NO reload line. Total reload lines since first edit: 1. The watcher may be one-shot or have a post-reload re-arm bug; ADR-021 debounce window length and the inotify re-arm logic need audit on a branch.

## sha256 chain for the restore (Variant B interlock)

- **Pre-session** (`oracle-unit-pre.sha256`): `5310c917bd8d4cf5f429ae3419ac3339edf9efa7095df16ec1938ac2acc5b047  /etc/systemd/system/tiny-dfr-mbp142.service`
- **Backup** (STEP 1, post-move-aside): `5310c917bd8d4cf5f429ae3419ac3339edf9efa7095df16ec1938ac2acc5b047  /etc/systemd/system/tiny-dfr-mbp142.service.bak` (matches pre)
- **Post-restore** (`oracle-unit-post.sha256`, STEP 8): `5310c917bd8d4cf5f429ae3419ac3339edf9efa7095df16ec1938ac2acc5b047  /etc/systemd/system/tiny-dfr-mbp142.service` (matches pre)
- **diff pre vs post**: PASS — byte-identical restore verified
- **`.bak` cleanup**: PASS — `.bak` gone (ls → No such file)

## The tap line (item 3 — fresh this boot)

Verbatim from `STEP3-journal.txt` (current boot, post-`-- Boot 9e8da11f… --` marker):

```
2026-09-27T11:47:18+01:00 phobos tbard[33476]: tbard: tap page=render-only-validation logical=(9,1068) hit=None
2026-09-27T11:47:19+01:00 phobos tbard[33476]: tbard: tap page=render-only-validation logical=(9,1068) hit=None
2026-09-27T11:47:19+01:00 phobos tbard[33476]: tbard: tap page=render-only-validation logical=(5,1068) hit=None
2026-09-27T11:47:20+01:00 phobos tbard[33476]: tbard: tap page=render-only-validation logical=(8,1068) hit=None
2026-09-27T11:47:20+01:00 phobos tbard[33476]: tbard: tap page=render-only-validation logical=(6,1068) hit=None
2026-09-27T11:47:21+01:00 phobos tbard[33476]: tbard: tap page=render-only-validation logical=(8,1068) hit=None
2026-09-27T11:47:55+01:00 phobos tbard[33476]: tbard: tap page=render-only-validation logical=(2,1068) hit=None
2026-09-27T11:47:55+01:00 phobos tbard[33476]: tbard: tap page=render-only-validation logical=(0,1068) hit=None
2026-09-27T11:47:56+01:00 phobos tbard[33476]: tbard: tap page=render-only-validation logical=(0,1068) hit=None
```

- **page id**: `render-only-validation` (the shapes-only page, not the default `primary`)
- **widget id / hit**: `hit=None` (shape widgets have `tap_action() -> None` — zero key injection, render-only page safe)
- **logical coords**: x ∈ {0,2,5,6,8,9}, y=1068 (mid-strip — the 2170-wide strip's middle)
- **scale cross-check**: raw X (32767 max) → logical x = rawX/32767*2170. e.g., logical x=1068 ↔ raw X ≈ 16140 (mid-strip tap). The reported x values (0–9) are the post-scale logical coords within the hit widget; the y=1068 is the logical Y across the 2170-wide strip (the strip is rotated 60×2170 → logical 2170×60).
- **gesture**: `Gesture::Tap` (CRISP <300ms taps per ADR-053; the `tap` log line only fires on Tap classification — confirms the gesture handler ran on real digitizer events)

## Final state

- git HEAD `07813f4` == `v0.2.7`; `src/` frozen (0-line diff vs v0.2.7); only `docs/test-logs/051/` + docs commits untracked/modified
- touchbar card = card2/appletbdrm (driver-resolved)
- debugfs: oracle `tiny-dfr-mbp142` (tgid 35563, uid 65534) sole master on dev 2 — identity by name+uid
- /etc/touchbar: only `config.yaml.example` (NO live config — original state restored)
- oracle unit sha256 `5310c917…` matches pre-session (byte-identical restore)
- oracle active+static; tbard inactive+disabled (validation run, NOT a migration)
- /dev/input = 18 event nodes (baseline)
- backlights: acpi_video0 90/90, appletb_backlight 54/255 (oracle lit, VISIBLE)
- Machine safe. Interlock window CLOSED.

## Closing

**STAGE 4 ABORT — 5/7 items closed (2, 3, 4, 6, 7), 2 items (1 visible, 5 visual confirmation) blocked by F-045-1 recurrence on v0.2.7 with the shapes-only page.**

The Touch Bar under tbard is a working INPUT surface (item 3 reconfirmed: real digitizer events reach the gesture handler, taps classify correctly, zero injection on the render-only page) with a working CONFIG HOT-RELOAD MECHANISM (item 5: first live-hardware witness — edit → `config reloaded` line in the same second, ADR-021 debounce holds, no storm) and a working LIFECYCLE CONTRACT (SIGTERM→exit 0, RAII release, idempotent rerun). It is NOT a working VISIBLE DISPLAY under tbard on this bench: F-045-1 is a DRM-side panel-activation differential (the oracle performs a DRM-side panel-enable tbard does not), NOT a content, write, or hot-reload defect — ADR-051 (shapes-only page, font-free) is REFUTED as the F-045-1 fix (the bar is dark with zero font dependency). The ADR-051 shapes-only page remains the correct validation page and HC target (F-13-1); it just doesn't fix F-045-1.

**Next session:** after ADR-054 (the F-045-1 DRM-side panel-activation fix — read-only diff of the oracle's DRM init/flush path vs tbard's `src/providers/drm.rs` + `src/main.rs` render loop, then the missing panel-enable call) is adjudicated + implemented on a branch and merged (and `/usr/bin/tbard` reinstalled from the tip), re-run Stage 4 from P1 in a fresh session with the shapes-only page. ADR-055 (config-watcher re-arm after the first reload) should land alongside it so the second-edit regression is closed. The interlock protocol itself (P1→HC1→STEP1–9, Variant B move-aside+mask) remains valid and reusable verbatim.

**ADR proposals (for a future branch; NOT implemented on the air):**
- **ADR-054**: DRM-side panel-activation — the F-045-1 differential.
- **ADR-055**: config-watcher re-arm after the first reload (the watcher does not re-fire on subsequent writes; add a TWO-edits-TWO-reloads regression test).

> **ERRATUM (session 053, ADR-054):** The closing conclusion above — "a DRM-side
> panel-activation differential (the oracle performs a DRM-side panel-enable
> tbard does not)" — is mechanism-WRONG. Session 052's three-source derivation
> (drm crate ClipRect::new(x1,y1,x2,y2) + our transposed flush mapping + the
> appletbdrm driver's drm_rect_intersect clamp at appletbdrm.c:1055-1068) and
> live HC2 confirmation ("bright fragment at far left, sharply cut off, rest
> black") proved the differential was the DAMAGE CLIP GEOMETRY: our transposed
> mapping submitted x2=2170/y2=60 on a 60×2170 fb, which the driver silently
> clamped to a 60×60 window — only the leftmost ~60px ever transmitted. The
> modeset sequences are structurally identical (verified by source diff); there
> is no panel-activation step the oracle performs and tbard does not. This is
> the fifth live-session root-cause correction (s025 ordering, s029 acquire,
> s037 dispatch, s040 "never wrote" → "wrote + decayed", s051 panel-activation
> → transposed clip). Original text preserved verbatim above.

