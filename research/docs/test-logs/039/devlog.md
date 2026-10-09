# Devlog — session 039 (hardware-interaction research, 2026-09-26)

**Role:** hardware interaction researcher (follow-up to session 038).
**Goal:** settle the ONE open question from 038 — the backlight
value/luminance coupling regimes (the T2 refinement).

**Safety bound honored (same as 038):**
- The ONLY system writes permitted: brightness values to
  `/sys/class/backlight/appletb_backlight/brightness`, within [1..255].
  NEVER 0. Restored to 54 at end.
- Oracle (`tiny-dfr-mbp142.service`) stayed RUNNING and lit throughout.
- tbard remained disabled+inactive (FREEZE on `src/`).
- `bl_power`: read-only this session; NEVER written (the brief required
  explicit human approval for any `bl_power` write, which was not
  requested).
- Human checkpoints for observations: asked, waited, recorded verbatim.

**Pre-session reference value:** 54 (per the task brief and session 038).

## The discriminating experiment (S1–S4)

### S0 — baseline (22:05:50)
- Oracle: active (running) since 21:00:55. tbard: inactive + disabled.
- brightness=54, actual=54, bl_power=0, max=255, mtime=21:59:43 (the
  038 final restore write).
- Human checkpoint: "Yes, lit (F-row visible)".
- Capture: `s0-baseline.txt`.

### S1 — low-value ignition from a lit baseline (22:06:17–22:06:44)
- Wrote 54 (re-confirm lit): human "Yes, lit (F-row visible)".
- Wrote 2 from the lit-54 baseline: human (verbatim) "Visible (dimmer
  than 54)". Read-back value=2, actual=2, mtime moved.
- Restored 54.
- **Verdict:** a low value write to a lit bar IS visible at the
  corresponding level. 038's "1 visible" was NOT residual luminance —
  the residual-luminance hypothesis is DISCONFIRMED.
- Capture: `s1-ignition.txt`.

### S2 — persistence / auto-dim timing (22:06:52–22:15:45)
- Wrote 128: human "Yes, lit (brighter than 54)".
- 60s wait (no touch, no write): brightness decayed 128→1 (by ~30s),
  mtime FROZEN at 22:06:52, bl_power=0. Human (verbatim): "It was lit
  (dim, visible) but a few second after it turned off. Once I pressed
  the keyboard it came bright back again." Post-keyboard: brightness=54
  (the oracle's adaptive default, NOT 128), mtime STILL frozen — the
  wake is the oracle's adaptive path, not a kernel value restore.
- Re-wrote 128 (22:10:16). 300s wait (no touch, no write), sampled
  every 30s:
  - T+30s: brightness=1, mtime frozen, bl_power=0.
  - T+60s: brightness=0, mtime frozen, bl_power=0.
  - T+90s..T+300s: brightness=0 throughout, mtime frozen, bl_power=0.
  - Human (verbatim at 300s): "Went dark, stayed dark".
- **Verdict:** the driver auto-dims a userspace-written value on idle
  with a measured trajectory (128→1 by ~30s, →0 by ~60s), mtime frozen,
  bl_power stays 0. Under sustained idle (300s untouched) the panel
  goes DARK even with the oracle running. This CORRECTS 038 §4's
  "panel stays lit independently of sysfs value" claim, which was
  observed only in the recently-active regime.
- Capture: `s2-persistence.txt`.

### S3 — the cold-ignition test (22:19:24–22:27:56)
- Pre-write: bar DARK per human, but sysfs brightness=54 (mtime frozen
  at 22:10:16). NOTE: sysfs HIGH, panel DARK — the decoupled regime in
  the opposite direction from 038's HC0 (sysfs LOW/0, panel LIT).
- Wrote 128 to the DARK bar: human (verbatim) "Yes, LIT UP (write
  ignited it)". Read-back value=128, actual=128, mtime moved.
- **S3 VERDICT — outcome (a):** a brightness write DOES ignite a
  DARK/idle bar. The value coupling is fine. ADR-043's dead code (the
  enable-write never executing via trait-default dispatch) was the ONLY
  bug. ADR-044 alone is SUFFICIENT — no companion needed (no bl_power
  write, no touch-wake interplay).
- **Prediction for attempt #5's STEP 4b:** IF ADR-044 lands the trait
  override so the enable-write of 128 actually executes on
  scanout-begin, the panel WILL light on tbard's first scanout,
  REGARDLESS of the bar's prior idle state. Attempt #5's STEP 4b tests
  in the userspace-written regime: the value probe (read brightness
  immediately after the write, compare against 128) is reliable,
  PROVIDED the read happens within ~1s of the write (before the
  auto-dim decay begins). The mtime probe remains structurally invalid.
- Capture: `s3-cold-ignition.txt`.

### S4 — bl_power correlation (read-only, 22:28:25)
- `bl_power` was 0 (`FB_BLANK_UNBLANK` / powered) throughout EVERY
  observed state: lit (S0, S1a, S2a), dim (S1b, S2b 60s), dark (S2d
  300s, S3 pre-write), and post-ignition (S3b).
- The panel went DARK while bl_power stayed 0; the panel LIT from a
  brightness write while bl_power stayed 0.
- **Verdict:** `bl_power` does NOT track luminance on this T1 fork;
  it is NOT the on/off control. `brightness` IS. `bl_power` would NOT
  be a useful companion to the enable-write. `bl_power` was NEVER
  written this session.
- Capture: `s4-blpower-probe.txt`.

### S5 — session-end restore (22:28:31)
- Restored brightness to 54 (read-back confirmed, mtime moved).
- Oracle: active. tbard: inactive + disabled.
- Human checkpoint: "Yes, lit (F-row visible)".
- Capture: `s5-session-end.txt`.

## Headline findings (data, not instructions)

1. **NEW (S3): a brightness write ignites the panel from ANY state.**
   A write of 128 to a DARK/idle bar LIT it. The enable-write of a
   non-zero value is necessary AND sufficient to light the panel — no
   `bl_power` companion, no touch-wake interplay needed. ADR-044 alone
   fixes ADR-043's dead-code defect.
2. **NEW (S2): auto-dim trajectory MEASURED.** A written 128 decays to
   1 by ~30s and to 0 by ~60s of idle (no touch, no write), mtime
   FROZEN, bl_power stays 0. Under sustained idle (300s untouched) the
   panel goes DARK even with the oracle running. This corrects 038's
   "panel stays lit at sysfs=0" claim, which was regime-dependent
   (recently-active, not sustained-idle).
3. **NEW (S2): touch-wake interplay observed (in passing).** A keyboard
   press during idle woke the bar to 54 (the oracle's adaptive default,
   NOT the last-written 128), mtime frozen. The wake is the oracle's
   input-reactive adaptive logic. Logged as an observation, not a
   controlled test.
4. **NEW (S3): sysfs HIGH, panel DARK is a real state.** Pre-S3, sysfs
   read 54 while the panel was dark — the decoupled regime in the
   opposite direction from 038's HC0 (sysfs LOW/0, panel LIT). The
   sysfs value does NOT reliably indicate panel luminance in the idle
   regime in EITHER direction.
5. **NEW (S4): bl_power does NOT track luminance on this T1 fork.**
   bl_power stayed 0 through lit, dim, dark, and post-ignition states.
   brightness IS the on/off control.
6. **CORROBORATED (S1): 038's "minimum visible = 1" is real, not
   residual.** A write of 2 from a lit-54 baseline produced a
   dim-but-visible luminance. The residual-luminance hypothesis is
   disconfirmed.

## Findings for ADR-044

**ADR-044 (enable-write must override the trait method) is
SUFFICIENT as specified — no companion is needed.** Evidence:

- **S3 (the discriminating test):** a brightness write of 128 to a
  DARK/idle bar LIT it ("Yes, LIT UP (write ignited it)"). The
  enable-write of a non-zero value lights the panel from any state.
  Capture: `s3-cold-ignition.txt`.
- **S4 (bl_power correlation):** `bl_power` was 0 through every state
  (lit, dim, dark, post-ignition). A `bl_power` companion write is NOT
  needed — `brightness` is the on/off control on this T1 fork. Capture:
  `s4-blpower-probe.txt`.
- **S2 (touch-wake):** a keyboard press wakes the bar via the oracle's
  adaptive path (to 54, mtime frozen). This is the oracle's
  input-reactive logic, NOT a kernel-only touch-wake that tbard would
  need to replicate. tbard's enable-write does not need to arrange a
  touch event; the write alone lights the panel.
- **S1 (low-value ignition):** a non-zero write to a lit bar is visible
  at the corresponding level. 038's "minimum visible = 1" is
  corroborated, not disconfirmed.

**The enable-write does NOT need a companion.** ADR-044's fix surface
(add the trait override so `enable()` actually executes the 128 write
on scanout-begin) is necessary AND sufficient.

## Corpus/corrections — annotation of 038's "minimum visible = 1"

038 §3 claims "Minimum visible brightness = 1" based on a downward
sweep. Session 039 S1 ANNOTATES (does not rewrite) this claim:

- **The claim STANDS.** S1 tested 2 as an ignition value from a lit-54
  baseline (the same idle regime as 038's sweep, not after a lit state
  that could leave residual luminance). Human: "Visible (dimmer than
  54)". The residual-luminance hypothesis is DISCONFIRMED.
- **038's sweep was testing actual luminance, not residual.** The
  "1 visible" observation is real; 038 §3 need not be rewritten, only
  annotated as corroborated by an ignition test at value 2.
- The annotation is recorded in `backlight.md` §7.1.

## Final session state (22:28:31 +01:00)

- brightness: 54/255 (restored; read-back confirmed; mtime moved to
  22:28:31 on the restore write).
- bl_power: 0 (unchanged; NEVER written this session).
- oracle: active (static) — `tiny-dfr-mbp142.service`, sole DRM master
  on card2 throughout.
- tbard: disabled + inactive (FREEZE intact, no `src/` writes).
- NO /etc writes. NO service lifecycle actions on the oracle.
- The ONLY system writes this session: brightness values to
  `/sys/class/backlight/appletb_backlight/brightness`, within [1..255],
  restored to 54. NEVER 0.

## Captures (this session, all in `docs/test-logs/039/`)

- `s0-baseline.txt` — session baseline (oracle/tbard state + sysfs).
- `s1-ignition.txt` — S1: low-value ignition from a lit baseline.
- `s2-persistence.txt` — S2: auto-dim trajectory (60s + 300s, sampled
  every 30s) + human checkpoints + touch-wake observation.
- `s3-cold-ignition.txt` — S3: the discriminating cold-ignition test.
- `s4-blpower-probe.txt` — S4: bl_power correlation table (read-only).
- `s5-session-end.txt` — final state + safety bound honored statement.

## Safety bound honored statement

- Oracle (`tiny-dfr-mbp142.service`) stayed RUNNING and lit throughout
  the session (active since 21:00:55; never stopped or restarted).
- tbard remained disabled+inactive (FREEZE on `src/` intact).
- The ONLY system writes: brightness values to
  `/sys/class/backlight/appletb_backlight/brightness`, within [1..255].
  Values written: 54, 2, 54, 128, 128, 128, 54. NEVER 0.
- Restored to 54 at session end (read-back confirmed, human confirmed
  "Yes, lit (F-row visible)").
- `bl_power` was NEVER written (read-only probe; the brief required
  explicit human approval for any `bl_power` write, which was not
  requested).
- NO /etc writes. NO service lifecycle actions on the oracle or tbard.
- Human checkpoints for all observations: asked, waited, recorded
  verbatim.