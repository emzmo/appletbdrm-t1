# Session 051 devlog — Stage-4 completion interlock (F-045-1 recurrence; item 5 mechanism witnessed)

**Date**: 2026-09-27
**Session**: 051
**HEAD**: `07813f4` == `v0.2.7` (clean; `src/` frozen — 0-line diff vs v0.2.7)
**Binary**: `/usr/bin/tbard` sha256 `18b368c44cab753d92353ba197b0248f41b8768d171cf8fac11d3ed4c426474e`
(behavioral: `strings --service`=7, `--probe-input`=3 — ADR-038 + ADR-041 guards)
**Goal**: close Stage-4 items 1, 3, 5 on hardware with the shapes-only validation page.
**Result**: **ABORT — HC2/HC4 visible FAIL (F-045-1 recurrence on v0.2.7 with the shapes-only page); item 3 reconfirmed; item 5 MECHANISM witnessed live for the first time (visual confirmation blocked by F-045-1); interlock closed, machine restored byte-identical.**

## Summary

This session attempted the Stage-4 completion interlock with the ADR-051
shapes-only validation page (`examples/render-only-validation-page.yaml`,
visible-by-construction — zero font dependency in the draw path). The
interlock protocol (P1 → HC1 → STEP 1–9) executed verbatim; the Variant
B move-aside + mask held throughout (oracle inactive+masked at +60s,
ADR-049 assertion passed, no oracle row in debugfs mid-run). The
preflight was GO (STEP 0 a–f PASS, including 0d:
`/usr/bin/tbard --probe-input` ACCEPTS `/dev/input/event4` — the
digitizer resolved fresh this boot by predicate, shifted from event7 on
the prior boot as predicted).

tbard started cleanly at 11:44:26 (PID 33476): full boot sequence in the
INFO journal — privdrop to nobody/65534, DRM scan accepted card2
(appletbdrm, 60×2170), post-drop fd self-check OK, **post-drop
digitizer-identified self-check OK (ADR-047)**, framebuffer 60×2170 →
logical 2170×60, **backlight enable-tick → 54** (exactly the expected
`display_to_touchbar(90, 128)` = `sqrt(90/509)*128+1` = 54; ADR-048
adaptive curve). NO config-fallback WARN — the shapes-only page loaded
cleanly. STEP 4 verified tbard sole master (uid 65534), dri/2 scanout
active (fb 41 on plane-0, crtc-0 enable=1 active=1, connector USB-1),
eDP unaffected, /dev/input unchanged (18, no uinput device — render-only
page), no dmesg delta, mask held.

**HC2 (WAKE) at 11:48:24 — FAIL.** Operator: "I see no changes when I
touch it. touchbar completely dark. and it has been dark the whole
process." The journal PROVES the touch reached tbard (80+ `touch wake →
backlight.notify_activity()` INFO lines at 11:47:18–11:47:56; multiple
`tap page=render-only-validation logical=(x,1068) hit=None` lines —
FRESH this boot, CRISP taps <300ms classified correctly per ADR-053,
hit=None = zero injection, render-only page safe). tbard's adaptive
write re-brightened sysfs to 54. **But the panel produced NO visible
light.** Direct `brightnessctl` writes of 255/200/100 all read back
correctly under tbard's sole mastership — **HC2b: "no changes"** — the
bar stays dark at any sysfs brightness under tbard.

**STEP 8 restore confirmed the F-045-1 differential**: the same sysfs
path (value 54) that was dark under tbard's sole DRM mastership is
VISIBLE under the oracle's sole DRM mastership — HC-restore: "yes f-row
visible". **ADR-051 (font rasterization) is REFUTED**: the shapes-only
page has zero font dependency yet the bar was dark under tbard. The
differential is a DRM-side panel-activation issue (the oracle performs a
DRM-side panel-enable tbard does not), NOT a content or sysfs-write
issue. F-045-1 is NOT closed by ADR-051; it is a distinct, deeper
defect. The ADR-051 shapes-only page is STILL the correct validation
page (it removes the font failure mode and is the right HC target per
F-13-1) — it just doesn't fix F-045-1, which ADR-051 never claimed to
fix (ADR-051 fixed the *content* hypothesis; F-045-1 is the
*panel-activation* differential).

**Item 3 (tap log) — RECONFIRMED on the safe page via journal evidence**
(this boot's tap lines, not the prior-boot 12+5): multiple
`tap page=render-only-validation logical=(x,1068) hit=None` at
11:47:18–11:47:56, x ∈ {0,2,5,6,8,9,14}, y=1068 (mid-strip), hit=None
(shape widgets have no action). Independent of the visible panel — the
gesture handler ran on real digitizer events.

**Item 5 (config hot-reload, LIVE — the session headline) — MECHANISM
PROVEN, visual blocked by F-045-1.** First live-hardware witness of
config hot-reload:

- **HOT-RELOAD TRIPLE**:
  1. Edit timestamp: 2026-09-27T11:51:47+01:00 (single write, first
     shape fill 0.5 → 1.0; sha256 `8e6865f0…` → `587cc3e2…`).
  2. Reload line timestamp: 2026-09-27T11:51:47+01:00 — `tbard: config
     reloaded` INFO line, SAME SECOND as the edit. ADR-021 debounce
     holds: one write = one reload line, NO storm.
  3. Visual change confirmation: **N/A — panel dark under tbard
     (F-045-1 recurrence); HC4 visual impossible this session.** The
     reload MECHANISM (the journal-witnessable property, the actual
     headline) is proven live on hardware for the first time; the visual
     CONFIRMATION is blocked by the pre-existing F-045-1 panel
     differential, NOT a hot-reload defect.

- **Follow-up finding (ADR candidate, NOT an abort criterion)**: after
  the first reload, the config watcher does NOT fire on subsequent
  writes. Edit 2 (11:51:59, fill 1.0 → 0.5, restored original sha256
  `8e6865f0…`): NO reload line. Edit 3 (11:52:21, fill 0.5 → 0.9,
  distinct value, sha256 `bff30586…`): NO reload line. Total reload
  lines since the first edit: 1 (the first reload only). Hypothesis
  (read-only, no code change): the watcher may be one-shot, or there is
  a state-machine / inotify re-arm issue post-first-reload. ADR-021's
  debounce window length and the inotify re-arm logic need audit on a
  branch. The headline (first reload witnessed) stands.

## Lifecycle contract (STEP 7) — re-verified

SIGTERM → exit 0 ×2 (ExecMainStatus=0, ExecMainCode=0, Result=success
both stops). RAII release ×2: debugfs `dri/2/clients` EMPTY after both
stops; `plane-0 fb=0` (detached). Idempotent rerun: second start
acquired sole master cleanly (PID 35383, uid 65534). +1s probe on rerun:
54/255 == expected. /dev/input returned to 18 at STEP 9 (transient 17
mid-STEP-7 was the rerun window).

## Interlock (Variant B, F-045-3) — clean open + close

- **Open (STEP 1)**: oracle unit sha256 `5310c917…` recorded pre-move;
  cp to `.bak`, rm original, `ln -s /dev/null`, daemon-reload, stop →
  inactive+masked; +60s no-restart assertion PASSED (ADR-049 — the s043
  race cannot recur); debugfs `dri/2/clients` EMPTY.
- **Close (STEP 8)**: removed `/etc/touchbar/config.yaml` (original
  state: no live config — only `config.yaml.example`); reversed the
  move-aside; daemon-reload; start → active+static, sole master
  (`tiny-dfr-mbp142` tgid 35563, uid 65534 — identity by name+uid); bar
  relit (sysfs 54, VISIBLE — HC-restore "yes f-row visible").
- **sha256 chain**: pre `5310c917bd8d4cf5f429ae3419ac3339edf9efa7095df16ec1938ac2acc5b047`
  == post `5310c917…` — byte-identical restore verified. `.bak` gone
  (cleanup complete).

## STEP 9 final state == P1 baseline

git HEAD `07813f4` == `v0.2.7`; `src/` frozen (0 diff vs v0.2.7); only
`docs/test-logs/051/` untracked. Touchbar card = card2/appletbdrm
(driver-resolved). Oracle sole master (name+uid). /etc/touchbar: only
`config.yaml.example`. Oracle unit sha256 matches pre-session.
Oracle active+static; tbard inactive+disabled. /dev/input = 18 event
nodes. Backlights: acpi_video0 90/90, appletb_backlight 54/255.

## Stage-4 acceptance board (this session's contribution)

| # | Item | Verdict | Evidence |
|---|------|---------|----------|
| 1 | wake (visible, on the safe page) | **FAIL (F-045-1 recurrence)** — touch wake FIRED (journal), sysfs re-brightened to 54, but panel produced NO visible light at any brightness under tbard | `HC2-and-evidence.txt`, `HC2b-and-item3.txt`, `F045-1-recurrence-diagnostic.txt` |
| 2 | (closed prior) | — | s047/AB |
| 3 | tap log (reconfirm on safe page) | **RECONFIRMED** — multiple fresh `tap page=render-only-validation logical=(x,1068) hit=None` lines this boot; CRISP <300ms taps classified correctly; hit=None (zero injection) | `HC2-and-evidence.txt`, `HC2b-and-item3.txt` |
| 4 | (closed prior) | — | s047/AB |
| 5 | config hot-reload (LIVE) | **MECHANISM PROVEN** (first live-hardware reload witnessed: edit 11:51:47 → reload line 11:51:47, ADR-021 debounce holds, no storm); **visual confirmation BLOCKED by F-045-1** (HC4 N/A — panel dark); follow-up finding: watcher does not re-fire after the first reload (ADR candidate) | `STEP6-hot-reload-edit.txt`, `STEP6-hot-reload-journal.txt`, `STEP6-summary.txt`, `STEP6-edit2-investigation.txt`, `STEP6-edit3.txt` |
| 6 | (closed prior) | — | s047/AB |
| 7 | (closed prior) | — | s047/AB |

Items 1 (visible) and 5 (visual confirmation of hot-reload) remain
blocked by F-045-1 — a pre-existing DRM panel-activation differential
(the oracle performs a DRM-side panel-enable tbard does not), NOT a
content/write/hot-reload defect. Item 3 is reconfirmed. Item 5's
mechanism is proven live.

## ADR proposals (for a future branch; NOT implemented on the air)

- **ADR-054 (proposed): DRM-side panel-activation — the F-045-1
  differential.** tbard's scanout is active (fb on plane, crtc enable=1
  active=1, connector enabled), bl_power=0, USB Config 2, sysfs writes
  accepted + read back correctly — yet the panel produces NO photons at
  any brightness (255/200/100/54 all dark under tbard, all visible under
  the oracle with the same sysfs value). The oracle performs a DRM-side
  panel-enable (DPMS-on / connector set_property / page-flip flag / T1
  USB init) that tbard omits. ADR-051 (shapes-only page, font-free) is
  REFUTED as the F-045-1 fix — the bar is dark with zero font
  dependency. Read-only diff of the oracle's DRM init/flush path
  (`backup_old/tiny-dfr-mbp142/src/`) vs tbard's
  `src/providers/drm.rs` + `src/main.rs` render loop is the next step
  (between sessions). Candidate surfaces: a `DRM_MODE_DPMS_ON`
  connector property set; a `set_property` call the oracle makes at
  acquire; a page-flip flag; a T1/USB init sequence the oracle's startup
  performs (`backup_old/tiny-dfr-mbp142/src/main.rs`).
- **ADR-055 (proposed): config-watcher re-arm after the first reload.**
  The first config edit produces a clean `config reloaded` line (same
  second, ADR-021 debounce holds). Subsequent edits (edit 2 restored
  original sha256; edit 3 a distinct value) produce NO reload line —
  total reload lines = 1. The watcher does not re-fire after the first
  reload. Hypotheses (read-only): the inotify watch is one-shot and not
  re-armed; the debounce coalescer enters a stuck state after the first
  reload; the file-watcher state machine has a post-reload bug. Audit
  `src/config/watch.rs` (or equivalent) on a branch: the watcher must
  re-fire on every subsequent write (the production-intent property —
  operators will edit the config multiple times). Add a regression test
  that does TWO edits and asserts TWO reload lines.

## FREEZE

`src/` untouched (0-line diff vs v0.2.7). Only `docs/test-logs/051/` +
the docs commits (devlog, CHANGELOG, test-plan Stage-4 verdict) are
untracked/modified. No code fixes on the air.