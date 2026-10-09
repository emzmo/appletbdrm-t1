# Touch Bar Display — open questions for the interlock session

> Ground-truth display findings that are NOT yet closed, framed as
> open questions for a future interlock session (NOT this one —
> this session was read-only + the brightness knob only). Every
> question is cited to a capture in `docs/test-logs/038/` or prior
> sessions.

## OQ-1: Framebuffer 64×2170 vs mode 60×2170

**The observed framebuffer is 64×2170; the DRM mode is 60×2170.**

- **Mode (driver-resolved):** `modetest -M appletbdrm` shows
  connector USB-1 connected, mode `60x2170` @60Hz, crtc-0 at
  60×2170, fb 41 on plane-0 at 60×2170.
  - **Capture:** `docs/test-logs/038/drm-connector.txt` (modetest
    output, lines: "modes: #0 60x2170 60.00 ...", "CRTCs: id 37 fb
    41 pos (0,0) size (60x2170)").
- **Framebuffer (session-037 debugfs):** the oracle / tbard
  allocates a 64×2170 XR24 framebuffer. Session 037's debugfs
  capture (`docs/test-logs/037/step3-5-start-live-state-hc2.txt`
  lines 93-99): `framebuffer[41]: ... format=XR24, size=64x2170,
  pitch[0]=256 ...`; `plane[35]: plane-0 crtc=crtc-0 fb=41
  crtc-pos=60x2170+0+0 src-pos=60.000000x2170.000000+0+0`.
- **The discrepancy:** the fb is 64px wide but the plane sources a
  60px-wide region from it (`src-pos=60.000000x2170`). The 4px
  difference (64 vs 60) is either padding/stride alignment or an
  off-by-something in the allocator.

**Open question for the interlock session:** is the 64×2170 fb
allocation correct (and the plane crops to 60), or should the
allocator produce a 60×2170 fb to match the mode? Does the 4px
padding affect rendering (e.g. are the rightmost 4 columns of the
fb invisible / garbage)? This needs a render of a known test
pattern (e.g. a left-to-right gradient or a right-edge marker)
observed by the human — which is an interlock-session task (the
oracle must be stopped and tbard rendered), NOT this session.

**Relevant to:** ADR-024 (scale wiring) — if the fb is 64 wide but
the visible region is 60 wide, the scale factor's denominator may
be wrong. The session-033/037 dark-panel bug masked this (no
pixels to inspect).

## OQ-2: Panel-orientation "Right Side Up" (value 3) — flip semantics

**The DRM connector advertises `panel orientation = Right Side Up
(value 3)`.**

- **Capture:** `docs/test-logs/038/drm-connector.txt` (modetest
  props: "40 panel orientation: enums: Normal=0 Upside Down=1 Left
  Side Up=2 Right Side Up=3, value: 3").

**Open question for the interlock session:** "Right Side Up"
typically means the panel is mounted rotated 90° clockwise
relative to the scanout orientation, so the compositor must apply a
counter-rotation to render upright. Does tbard's renderer account
for this? The Touch Bar is a long thin strip — is the 60×2170 mode
"rotated" (i.e. the physical panel is 2170 wide × 60 tall, scanned
out as 60 wide × 2170 tall)? If so, a renderer that treats X as
the long axis (which the digitizer does — ABS_MT_POSITION_X is
0..32767 along the long axis) may be consistent with the
scanout-as-rendered orientation, but the orientation property
suggests the fb pixels need a transform. This needs a rendered
test pattern with a known orientation marker (an "L" or an arrow)
to determine whether the scanout is upright or rotated.

**Relevant to:** ADR-020 (coordinate spaces) — the input X
(0..32767) maps to the long axis; the display mode is 60×2170
(tall-narrow in raw pixels). If the panel is "Right Side Up", the
rendered fb may need rotation. This is unresolved.

## OQ-3: The display-stream stall question (T2 display, not backlight)

**Prior-art.md and the seborider-pr1-issue.md describe a T2
display-stream stall that requires heartbeat flushes. Does the T1
fork exhibit the same?**

- **Context:** `docs/seborider-pr1-issue.md` (T2 stall) +
  `docs/prior-art.md` §2 (T1 uses the same DRM protocol as T2 with
  three dialect deviations: a 16-byte short-transfer preamble, a
  one-behind ACK scheme, and stale bulk pipes cleared at probe).
- **Capture (this session):** no stall observed — but this session
  was read-only with the oracle rendering; tbard was NOT run.

**Open question for the interlock session:** when tbard is the DRM
master (after ADR-044 lands and the enable-write works), does the
display stream stall under sustained rendering (the T2 symptom:
the panel freezes after N frames and needs a heartbeat)? The T1
fork's "one-behind ACK" dialect difference may change the stall
characteristics. This needs a multi-minute tbard render with a
frame counter observed by the human — an interlock-session task.

**Relevant to:** the engine's heartbeat/retry design (ADRs
021/022/027/033). Ground-truth T1 stall behavior is unknown.

## OQ-4: Brightness decoupling — does writing 0 actually darken the panel?

**This session NEVER wrote 0 (safety bound).** The HC0 finding
showed the sysfs value can read 0 while the panel is lit (kernel-
side auto-dim with a DRM master scanning out). But a USERSPACE
write of 0 was not tested.

- **Capture:** `docs/test-logs/038/hc0-autonomous-dim.txt` (sysfs
  read 0, human saw "Still lit (F-row visible)").

**Open question for the interlock session:** does an explicit
userspace write of 0 to `brightness` darken the panel while a DRM
master is scanning out, or is the knob fully decoupled (the write
moves sysfs but the panel stays lit by the scanout)? This matters
for tbard's failsafe: if the knob is decoupled, the "write 0 to
darken on shutdown" failsafe may NOT darken the panel, and the
human loses the Esc row only when the DRM master releases. This
was NOT tested this session (safety bound forbade writing 0) and
is flagged for a controlled interlock-session test with the human
observing and the fallback-Esc precondition confirmed.

**Relevant to:** ADR-008 (backlight failsafe), ADR-043/044
(enable-write on the render path). If the knob is decoupled, the
failsafe's "darken the panel" guarantee needs re-examination.

## OQ-5: DRM debugfs accessibility for the value probe

**The runbook's STEP 4b value probe reads
`/sys/class/backlight/appletb_backlight/brightness` (sysfs), NOT
debugfs.** But the framebuffer-state check (fb on plane, crtc
active) reads `/sys/kernel/debug/dri/<N>/state` and
`/framebuffer`, which requires root this session (debugfs was
permission-denied for the unprivileged user).

- **Capture:** `docs/test-logs/038/drm-sysfs.txt` lines 70-71
  (`ls /sys/kernel/debug/dri/`: Permission denied). Session 037's
  debugfs captures were read with sudo.

**Open question for the interlock session:** the value probe
itself is unprivileged (sysfs is world-readable). But the
framebuffer-state check needs root. Should the runbook require
sudo for the debugfs reads, or should tbard expose the
framebuffer state via a more accessible path (e.g. a status
journal line at INFO — which loops back to ADR-045's
`RUST_LOG=info`)? The latter would let the runbook verify
render-to-plane from the journal alone, without debugfs.

**Relevant to:** ADR-045 (RUST_LOG=info) — if tbard logs the fb
id + plane + crtc state at INFO on scanout-begin, the debugfs
dependency goes away for the interlock runbook.

## Summary — what the interlock session owes

After ADR-044 (+045/046) lands on a branch, merges, and
`/usr/bin/tbard` is reinstalled from the tip, the interlock
session re-runs Stage 3 from P1 and owes:

1. **Item 4 (first pixels)** — render a known test pattern,
   human observes it (resolves OQ-1 64-vs-60 and OQ-2 orientation
   if the pattern has orientation markers).
2. **Item 9 (backlight write via held fd)** — the value probe
   (NOT mtime — ADR-046) confirms tbard's enable-write lit the
   panel.
3. **OQ-3 (stall)** — a multi-minute sustained render with a
   frame counter, human observes whether the panel freezes.
4. **OQ-4 (write-0 decoupling)** — a controlled test of an
   explicit write of 0 with the human observing and fallback-Esc
   confirmed (optional; lower priority than items 4 + 9).

This session (038) closed the backlight-knob ground truth
(min-visible=1, smooth curve, mtime quirk, knob independent of
DRM master) and the input ground truth (full evdev caps, corpus,
coexistence). The display open questions are the interlock
session's remit.