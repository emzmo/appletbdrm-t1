# Touch Bar Backlight — ground-truth manual (MacBookPro14,2 / T1)

> Direct, unmediated hardware interaction research. Established
> 2026-09-26 (session 038) with the oracle
> (`tiny-dfr-mbp142.service`) RUNNING and lit the entire session.
> Every fact below is cited to a capture in
> `docs/test-logs/038/` or `docs/research/corpus/`. The tbard
> engine's bugs will later be validated AGAINST this manual — this
> document is the oracle-independent reference, not a description of
> tbard's behavior.

## 1. The sysfs knob

**Path:** `/sys/class/backlight/appletb_backlight/brightness`

**Driver:** `appletbdrm` (the T1 fork of the Apple Touch Bar DRM
driver). The backlight device's `device` symlink resolves to
`/sys/devices/pci0000:00/0000:00:14.0/usb1/1-3/1-3:2.3`, and its
driver is `/sys/bus/usb/drivers/appletbdrm` — the SAME driver that
owns the DRM card (`/dev/dri/card2`).
- **Capture:** `docs/test-logs/038/backlight-sysfs.txt` lines 87-90
  (`device -> ../../../1-3:2.3`, `driver -> .../appletbdrm`).
- **Significance (differs from prior-art.md's T2 framing):** on this
  T1 fork, `appletb_backlight` is owned by `appletbdrm`, NOT by
  `hid-appletb-bl`. `/sys/bus/hid/drivers/hid-appletb-bl` does not
  exist on this host. The T2 architecture separates the backlight
  (`hid-appletb-bl`, `05ac:8102`) from the display (`appletbdrm`,
  `05ac:8302`); the T1 fork unifies both under `appletbdrm` on the
  single iBridge USB interface `1-3:2.3`.

**Full attribute set** (capture: `backlight-sysfs.txt`):

| attribute | perms | value @ 21:24:50 | notes |
|-----------|-------|------------------|-------|
| `actual_brightness` | r-- | 1 | reads the current hardware/driver state |
| `bl_power` | rw- | 0 | `0` = FB_BLANK_UNBLANK (powered). Standard backlight power |
| `brightness` | rw- | 1 | the userspace knob; write within `[1..max]` |
| `max_brightness` | r-- | 255 | hard maximum |
| `scale` | r-- | `unknown` | no perceptual scale advertised |
| `type` | r-- | `raw` | raw linear value, no curve |
| `uevent` | rw- | (empty) | |
| `power/control` | rw- | `auto` | runtime PM; `power/runtime_status` = `unsupported` |
| `power/autosuspend_delay_ms` | rw- | I/O error | not supported by this driver |

`device` → `../../../1-3:2.3` (the appletbdrm USB interface).
`subsystem` → `class/backlight`.

## 2. Value semantics — what a write does

**A userspace write to `brightness` updates the value, moves mtime,
and produces a perceptible luminance change.** Verified by the T2
controlled-write sweep (oracle running, human observing):

| write | value before → after | mtime moved? | human observation |
|-------|----------------------|--------------|-------------------|
| 100 (from 54) | 54 → 100 | yes (21:24:15 → 21:33:17) | "Brighter than before" |
| 200 (from 100) | 100 → 200 | yes (→ 21:33:48) | "Clearly brighter than 100" |
| 50 (baseline) | 200 → 50 | yes (→ 21:34:42) | "Dim but visible" |
| 100 (from 50) | 50 → 100 | yes (→ 21:34:54) | "Clearly brighter than 50" |
| 200 (from 100) | 100 → 200 | yes (→ 21:35:07) | "Clearly brighter than 100" |
| 54 (restore) | 200 → 54 | yes (→ 21:35:17) | "Dim (like 50)" |
| 32 | 54 → 32 | yes (→ 21:35:33) | "Visible (dimmer than 54)" |
| 16 | 32 → 16 | yes (→ 21:36:19) | "Visible (dimmer than 32)" |
| 8 | 16 → 8 | yes (→ 21:36:29) | "Visible (dimmer than 16)" |
| 4 | 8 → 4 | yes (→ 21:36:39) | "Visible (dimmer than 8)" |
| 2 | 4 → 2 | yes (→ 21:36:50) | "Visible (dimmer than 4)" |
| 1 (floor) | 2 → 1 | yes (→ 21:36:57) | "Visible (dimmer than 2)" |
| 54 (final restore) | 1 → 54 | yes (→ 21:37:09) | "Back to dim reference (like 54)" |

- **Captures:** `docs/test-logs/038/t2-*.txt` (one file per write).
- **Read-back survives:** every write's `AFTER` read returned the
  written value (e.g. `t2-restore54.txt`: wrote 54, read back 54).
- **Oracle independence (the brief's proof):** throughout the entire
  sweep the oracle's rendered F-row content stayed UNCHANGED — only
  luminance moved. Human checkpoint verbatim: "Content unchanged;
  only brightness moved." This proves the backlight knob is
  independent of the DRM master and of the renderer: writing
  `brightness` does NOT disturb the oracle's scanout or rendered
  content. (Capture: `t2-restore54.txt` + the HC answer.)

## 3. Minimum visible brightness

**Minimum visible brightness = 1** (the floor of the permitted
`[1..max]` range; 0 was NEVER written per the safety bound).

- At `brightness=1` the human reported "Visible (dimmer than 2)" —
  the F-row is still readable at the floor.
- **Capture:** `docs/test-logs/038/t2-sweep-1.txt` + the HC answer.

**Perceptual curve = smooth/monotonic, NOT stepped.** Every
downward step (54→32→16→8→4→2→1) was reported as "Visible (dimmer
than previous)"; every upward step (50→100→200) was "Clearly
brighter than previous." There are no visible discrete levels — the
dimming is continuous across the full `[1..255]` range.

## 4. The mtime quirk (re-confirmed + extended)

**The `brightness` file's mtime reflects ONLY userspace writes.
Kernel-internal brightness changes do NOT move mtime.**

This was first discovered in session 037
(`docs/test-logs/037/devlog.md` "Methodology discovery") and is
**re-confirmed and extended** here with a stronger observation:

- At session start (21:24:33) `brightness` read 54, mtime =
  2026-09-26 21:24:15.939835979.
- By 21:24:50 (NO userspace write performed yet this session) the
  value read 1; by 21:25:13 it read 0 — all with mtime FROZEN at
  21:24:15.
- The human reported the F-row STILL LIT at the same moment sysfs
  read 0.
- **Capture:** `docs/test-logs/038/hc0-autonomous-dim.txt` +
  `brightness-watch.txt` (5s watch: value=0, mtime=1790454255
  throughout).

**Interpretation (ground truth):**
1. The appletbdrm driver autonomously dims the sysfs `brightness`
   value on idle (~15s decay 54→1→0) WITHOUT a userspace write, so
   mtime does not move. This is kernel-side behavior.
2. While a DRM master is scanning out (the oracle), the panel stays
   LIT independently of the sysfs `brightness` value — the knob is
   DECOUPLED from the panel-enable / scanout path. The human sees
   the F-row lit at sysfs=0.
3. When a userspace write DOES occur, the value tracks luminance
   perceptibly and mtime moves (the T2 sweep proves this).

**Two regimes:**
- **Idle / kernel-managed:** sysfs `brightness` drifts (auto-dim to
  0), mtime frozen, panel lit by the DRM master's scanout
  independently. sysfs value does NOT track panel luminance.
- **Userspace-written:** sysfs `brightness` = the written value,
  mtime moves, panel luminance tracks the value perceptibly and
  monotonically.

**Implication for the runbook (session-037 ADR-046 direction):**
the STEP 4b `mtime` probe is structurally invalid on this driver
(mtime is not a "did userspace write" witness — a write DOES move
it, but a kernel-internal change does NOT, and the two are
indistinguishable from mtime alone). The VALUE probe is reliable
ONLY in the userspace-written regime. A reliable "did tbard write"
test must read `brightness` immediately after the expected write
AND compare against the expected written value, not against mtime.
See `display-open-questions.md` for the interlock-session framing.

## 5. Write path (mechanism)

- A userspace process opens `/sys/class/backlight/appletb_backlight/brightness`
  for write and emits the decimal value as bytes. The value is
  clamped to `[0..max_brightness]` by the driver; the safety bound
  here restricted writes to `[1..255]` (0 was never written).
- `bl_power` is a separate knob (0 = unblank / powered). It was 0
  throughout this session and was NEVER written. The brief
  permitted only `brightness` writes.
- `actual_brightness` is read-only and tracks the current
  hardware/driver state (it followed `brightness` exactly during
  the T2 sweep: e.g. `t2-step1-write100.txt` shows actual 54→100).
- The driver (`appletbdrm`) owns the backlight via the same USB
  interface (`1-3:2.3`) that owns the DRM card. There is no
  separate HID backlight driver on this T1 fork.

## 6. Findings feeding ADR-044 / 045 / 046

These findings are LOGGED here for the interlock session; they are
NOT implemented (FREEZE on `src/`). They feed the ADRs proposed in
session 037:

- **ADR-044 (enable-write must override the trait method):**
  STRONGLY REINFORCED by session 039's S3 cold-ignition test (see
  §7). The T1 ground truth now confirms not only that the sysfs
  knob is writable and a write lights an already-lit panel
  perceptibly (T2 sweep, §2), but that a brightness write of a
  non-zero value IGNITES a DARK/idle bar from off (S3b verdict:
  "Yes, LIT UP (write ignited it)", capture
  `docs/test-logs/039/s3-cold-ignition.txt`). The enable-write of
  a non-zero value is necessary AND sufficient to light the panel
  from any state (lit, dim, or dark/idle) — NO companion is needed
  (no `bl_power` write, no touch-wake interplay; see §7 S4). The
  defect remains the trait-default-dispatch no-op (session 037's
  analysis stands); ADR-044 alone is sufficient to fix it.
- **ADR-045 (RUST_LOG=info):** no new evidence.
- **ADR-046 (revise STEP 4b):** STRONGLY reinforced. The mtime
  probe is structurally invalid (re-confirmed + extended: mtime
  does not move on kernel-internal value changes, and the value
  is decoupled from panel luminance in the idle regime). The VALUE
  probe is reliable only in the userspace-written regime. The
  runbook should: (a) drop the mtime probe entirely; (b) keep the
  value probe but read `brightness` immediately after the expected
  enable-write and compare against the expected clamp
  (`active_brightness.min(max_bl)` = 128); (c) account for the
  idle auto-dim — if the read happens too long after the write,
  the driver may have already auto-dimmed the value back down.
  Session 039 S2 MEASURED the auto-dim trajectory: a written 128
  decays to 1 by ~30s and to 0 by ~60s of idle (no touch, no
  write), mtime frozen throughout (capture
  `docs/test-logs/039/s2-persistence.txt`). The STEP 4b value
  probe must therefore read within ~1s of the enable-write, or the
  value will already have decayed and the read will not confirm
  the write.
- **NEW finding for the default-brightness value (feeds ADR-044
  follow-on / a future ADR):** the perceptual curve is smooth and
  monotonic across `[1..255]`; 54 (the oracle's boot value) is
  "Dim but visible"; 100 is "Clearly brighter"; 200 is "Clearly
  brighter than 100". A tbard default of 128 (the
  `active_brightness` clamp) would be comfortably visible and
  matches the adaptive curve's intent. The minimum visible value
  is 1, so any non-zero write lights the panel. The session-037
  dark-panel bug was NOT a brightness-range issue — it was the
  enable-write never executing (value stayed 0 because no write
  occurred, not because 0 was written).

## 7. Coupling regimes (session 039 — the discriminating experiment)

> Established 2026-09-26 (session 039) with the oracle
> (`tiny-dfr-mbp142.service`) RUNNING and lit throughout. Every
> fact below is cited to a capture in `docs/test-logs/039/`.
> Safety bound honored: writes within `[1..255]`, NEVER 0,
> restored to 54 at end. `bl_power` read-only; never written.

Session 038 left an ambiguity: its HC0 ("54→1→0 panel stays lit"
at idle) was observed in a recently-active regime, while its T2
sweep ("1 visible") tested a downward sweep from a lit state —
leaving open whether 1 was an ignition value or residual
luminance. Session 039's T2 refinement settles this with four
tests (S1–S4).

### 7.1 S1 — low-value ignition from a lit baseline

**A low value write to a lit bar IS visible at the corresponding
level.** Wrote 54 (confirmed lit), then wrote 2 from the lit-54
baseline: human answered verbatim "Visible (dimmer than 54)".
Read-back: value=2, actual=2, mtime moved.
- **Capture:** `docs/test-logs/039/s1-ignition.txt`.
- **Corpus correction (038's "minimum visible = 1"):** 038's T2
  downward sweep was testing actual luminance, NOT reading
  residual. 2 written from a lit-54 baseline produces a
  corresponding dim-but-visible luminance; there is no reason to
  doubt 038's "1 visible" was real. The annotation to 038 §3 is:
  the claim STANDS, and is now corroborated by an ignition test
  (not just a sweep) at value 2; the residual-luminance
  hypothesis is DISCONFIRMED.

### 7.2 S2 — auto-dim timing and the persistence question

**The driver auto-dims a userspace-written value on idle, with a
measured trajectory, and the panel goes DARK under sustained
idle.** Wrote 128 (confirmed "lit, brighter than 54"), then
waited untouched, sampling sysfs every 30s:

| elapsed | brightness | actual | bl_power | mtime | panel observed |
|---------|------------|--------|----------|-------|----------------|
| 0s      | 128        | 128    | 0        | moved | lit (bright) |
| 30s     | 1          | 1      | 0        | FROZEN | dim, then dark |
| 60s     | 0          | 0      | 0        | FROZEN | dark |
| 90s     | 0          | 0      | 0        | FROZEN | dark |
| 300s    | 0          | 0      | 0        | FROZEN | dark |

- **Captures:** `docs/test-logs/039/s2-persistence.txt` (full
  trajectory + human checkpoints).
- **Auto-dim trajectory:** a written 128 decays to 1 by ~30s and
  to 0 by ~60s of idle (no touch, no write). mtime is FROZEN
  throughout the decay (kernel-internal change; re-confirms the
  038 mtime quirk). The value then holds 0 indefinitely.
- **The panel goes DARK under sustained idle** even with the
  oracle running and `bl_power=0`. Human checkpoint at 300s
  (verbatim): "Went dark, stayed dark".
- **THIS CORRECTS 038 §4's "panel stays LIT independently of the
  sysfs brightness value" claim.** 038's HC0 (sysfs=0, panel lit)
  was observed in a recently-active regime — the bar had been
  touched/woken moments before. Under sustained idle (300s
  untouched), the bar goes DARK at sysfs=0. The 038 "decoupled"
  framing is regime-dependent: the panel stays lit at sysfs=0
  only in the recently-active regime, NOT under sustained idle.
- **Touch-wake interplay (observed in passing, NOT the focus):**
  during S2b the human reported (verbatim): "It was lit (dim,
  visible) but a few second after it turned off. Once I pressed
  the keyboard it came bright back again." A keyboard press woke
  the bar to 54 (the oracle's adaptive default), NOT to the
  last-written 128. mtime did NOT move on the wake (value moved
  1→54, mtime frozen) — consistent with the oracle's adaptive
  path writing via the kernel-internal route, OR the mtime quirk
  applying to the oracle's write. This wake is the oracle's
  input-reactive adaptive logic, not a kernel-only touch-wake.
  This is logged as an observation, not a controlled test; a
  future session may isolate the wake source.

### 7.3 S3 — the cold-ignition test (the discriminating experiment)

**A brightness write DOES ignite a DARK/idle bar.** With the bar
DARK (sustained idle complete) and sysfs reading 54 (note: sysfs
HIGH, panel DARK — the decoupled regime in the opposite direction
from 038's HC0), wrote 128. Human answered verbatim: "Yes, LIT UP
(write ignited it)". Read-back: value=128, actual=128, mtime
moved.
- **Capture:** `docs/test-logs/039/s3-cold-ignition.txt`.
- **S3 VERDICT — outcome (a):** the value coupling is fine. A
  non-zero brightness write lights the panel from ANY state
  (lit, dim, or dark/idle). ADR-043's dead code (the enable-write
  never executing via trait-default dispatch) was the ONLY bug.
  ADR-044 alone (making the enable-write actually execute via the
  trait override) is SUFFICIENT — no companion is needed.
- **Prediction for attempt #5's STEP 4b:** IF ADR-044 lands the
  trait override so the enable-write of 128 actually executes on
  scanout-begin, the panel WILL light on tbard's first scanout,
  REGARDLESS of the bar's prior idle state (lit, dim, or dark).
  Attempt #5's STEP 4b will be testing in the **userspace-written
  regime**: the enable-write is a userspace write, so the value
  probe (read `brightness` immediately after the write, compare
  against 128) is reliable — PROVIDED the read happens within
  ~1s of the write, before the auto-dim decay begins (§7.2). The
  mtime probe remains structurally invalid (§4, §7.2).

### 7.4 S4 — bl_power correlation (read-only)

**`bl_power` does NOT track luminance on this driver; it is NOT
the on/off control.** `bl_power` was 0 (`FB_BLANK_UNBLANK` /
powered) throughout EVERY observed state:

| state | brightness | actual | bl_power | panel observed |
|-------|------------|--------|----------|----------------|
| S0 baseline (lit, recently active) | 54 | 54 | 0 | lit |
| S1a write 54 | 54 | 54 | 0 | lit |
| S1b write 2 | 2 | 2 | 0 | visible (dim) |
| S2a write 128 | 128 | 128 | 0 | lit (bright) |
| S2b 60s idle (auto-dim 128→1) | 1 | 1 | 0 | dim, then dark |
| S2d 300s idle (auto-dim →0) | 0 | 0 | 0 | dark |
| S2b post-keyboard wake | 54 | 54 | 0 | lit (bright) |
| S3 pre-write (DARK, sysfs=54) | 54 | 54 | 0 | DARK |
| S3b write 128 to DARK bar | 128 | 128 | 0 | LIT UP |

- **Capture:** `docs/test-logs/039/s4-blpower-probe.txt`.
- **Verdict:** the panel went DARK (S2d, S3 pre-write) while
  `bl_power` stayed 0; the panel LIT from a brightness write
  (S3b) while `bl_power` stayed 0. On this T1 fork, `brightness`
  IS the on/off control; `bl_power` is a vestigial/always-0
  attribute that does not gate the panel. `bl_power` would NOT
  be a useful companion to the enable-write.
- **`bl_power` was NEVER written this session** (safety: read-only
  probe only; the brief required explicit human approval for any
  `bl_power` write, which was not requested).

### 7.5 Regime summary (operational definition)

The backlight has TWO operational regimes, refined from 038 §4:

1. **Userspace-written (active):** a userspace write to
   `brightness` sets the value, moves mtime, and lights the panel
   at the corresponding level — from ANY prior state (lit, dim,
   or dark/idle; S3 proves the dark-idle case). The value tracks
   luminance perceptibly and monotonically (038 §2 sweep + 039
   S1). This is the regime tbard's enable-write operates in.
2. **Kernel-auto-dim (idle):** after ~30s of no input/write
   activity, the driver auto-dims the sysfs value (128→1 by
   ~30s, →0 by ~60s; S2 measured), mtime FROZEN, `bl_power`
   stays 0. The panel goes DARK under sustained idle (300s,
   S2d). The sysfs value does NOT reliably indicate panel
   luminance in this regime — it can read 54 while the panel is
   dark (S3 pre-write), or read 0 while the panel is lit in the
   recently-active sub-regime (038 HC0).

The regime boundary is INPUT ACTIVITY, not time alone: a keyboard
or touch event wakes the bar (S2b observation) and resets the
sysfs value (to 54, the oracle's adaptive default) via the
oracle's adaptive path, mtime frozen. The "idle regime" 038
described is therefore the kernel-auto-dim regime above; its
"decoupling" is the observation that sysfs value ≠ panel
luminance in that regime, which is correct but regime-dependent
(not absolute — under sustained idle the panel does go dark).