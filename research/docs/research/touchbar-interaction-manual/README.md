# Touch Bar Interaction Manual — MacBookPro14,2 (T1)

Ground-truth reference for the Touch Bar's backlight and input
surfaces, established by direct hardware interaction research
(session 038, 2026-09-26; backlight coupling regimes refined in
session 039, 2026-09-26). Independent of the tbard engine's
abstractions. The engine's bugs will later be validated AGAINST
this manual.

## Sections

- **[backlight.md](backlight.md)** — the sysfs knob: full attribute
  set, value semantics, minimum visible brightness, the mtime
  quirk, the write path, findings for ADR-044/045/046, and the
  coupling regimes (§7, session 039: S1 ignition, S2 auto-dim
  timing, S3 cold-ignition verdict, S4 bl_power correlation).
- **[input.md](input.md)** — the digitizer: node identity, full
  evdev capabilities, the event protocol, the gesture corpus
  index, the multi-reader coexistence proof.
- **[display-open-questions.md](display-open-questions.md)** — the
  open display questions (64-vs-60 fb, panel orientation, stall,
  write-0 decoupling, debugfs accessibility) for the interlock
  session.

## Method

- Oracle (`tiny-dfr-mbp142.service`) RUNNING and lit the entire
  session. tbard disabled+inactive (FREEZE on `src/`).
- Read-only inventory captures + controlled brightness writes
  within `[1..255]` (NEVER 0), restored to 54 at session end.
- Human checkpoints for all observations: asked, waited, recorded
  verbatim.
- Every fact cited to a capture in `docs/test-logs/038/`,
  `docs/test-logs/039/`, or `docs/research/corpus/`.

## Headline results

- **Minimum visible brightness = 1** (the floor of `[1..255]`;
  perceptual curve smooth/monotonic, not stepped). Confirmed by
  an ignition test at value 2 in session 039 (S1), not just a
  downward sweep — the residual-luminance hypothesis is
  disconfirmed.
- **The brightness knob is independent of the DRM master and the
  renderer** — writing `brightness` changes luminance only; the
  oracle's rendered content stayed unchanged throughout.
- **A brightness write ignites the panel from ANY state**
  (session 039 S3, the discriminating test): a write of 128 to a
  DARK/idle bar LIT it. The enable-write of a non-zero value is
  necessary AND sufficient — no `bl_power` companion, no
  touch-wake interplay needed. ADR-044 alone fixes ADR-043's
  dead-code defect.
- **The sysfs `brightness` value is DECOUPLED from panel
  luminance in the idle regime** — the appletbdrm driver
  auto-dims sysfs on idle WITHOUT moving mtime. Session 039 S2
  MEASURED the decay: 128→1 by ~30s, →0 by ~60s of idle. Under
  sustained idle (300s untouched) the panel goes DARK even with
  the oracle running and `bl_power=0`. This corrects 038's
  "panel stays lit independently of sysfs value" claim, which was
  observed only in the recently-active regime.
- **`bl_power` does NOT track luminance on this T1 fork** (S4):
  it stayed 0 (powered) through lit, dim, dark, and
  post-ignition states. `brightness` is the on/off control.
- **T1 architecture differs from prior-art.md's T2 framing**:
  `appletb_backlight` is owned by `appletbdrm` (USB interface
  1-3:2.3), NOT by `hid-appletb-bl`.
- **Digitizer**: `/dev/input/event7`, hid-multitouch, ABS_X
  0..32767, ABS_MT_SLOT 0..10, ABS_MT_TRACKING_ID 0..65535. Y is
  NEVER emitted. No pressure/major/minor axes. Idle noise floor
  is zero.
- **Multi-reader coexistence proven**: evtest (no `--grab`) read
  the digitizer alongside the oracle with zero disturbance to the
  oracle's input handling.