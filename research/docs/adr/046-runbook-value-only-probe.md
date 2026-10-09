# ADR 046: Runbook revision — value-only backlight probe (drop mtime)

## Status: Accepted

## Date: 2026-09-26

## Context

Session 037 (`docs/test-logs/037/step3-5-start-live-state-hc2.txt` STEP
4b "DECISIVE") and session 038
(`docs/research/touchbar-interaction-manual/backlight.md` §4 "the mtime
quirk") established that the sysfs `brightness` file mtime is NOT a
reliable "did userspace write" witness on the `appletbdrm` driver:

- The appletbdrm driver autonomously dims the sysfs `brightness` value
  on idle WITHOUT a userspace write, and kernel-internal changes do
  NOT move mtime (`docs/test-logs/038/hc0-autonomous-dim.txt`,
  `docs/test-logs/039/s2-persistence.txt`).
- A userspace write DOES move mtime (`docs/test-logs/038/t2-*.txt`
  controlled sweep) — but the two cases (kernel-internal change vs
  userspace write) are INDISTINGUISHABLE from mtime alone.
- Session 037 observed the oracle's restore write lit the bar (value
  0→54) WITHOUT moving the sysfs mtime off boot+7s
  (`docs/test-logs/037/devlog.md` "Methodology discovery"). The
  runbook's prior "mtime moved since boot" criterion is structurally
  unsatisfiable on this driver.

Session 039 (`docs/test-logs/039/s2-persistence.txt`) MEASURED the
auto-dim trajectory: a userspace-written 128 decays to 1 by ~30s and
to 0 by ~60s of idle (no touch, no write), mtime FROZEN throughout
the decay, `bl_power` stays 0. The value probe is reliable ONLY in
the userspace-written regime AND ONLY if read within ~1s of the
write — BEFORE the decay begins.

The runbook's STEP 4b (the post-start backlight-write acceptance
probe) must be revised to match the driver's actual behavior: drop
the mtime probe entirely, keep the value probe but read within ~1s,
and document the auto-dim decay as a known limitation so nobody
"fixes" an unreliable late read by re-adding mtime.

## Decision

### 1. STEP 4b is VALUE-ONLY (read within ~1s; expect 128 clamped)

The canonical STEP 4b procedure (`docs/test-plan.md` "STEP 4 —
verify live state (ADR-046 value-only probe)"):

```bash
# Immediately after `systemctl start tbard.service` (within ~1s):
cat /sys/class/backlight/appletb_backlight/brightness
cat /sys/class/backlight/appletb_backlight/max_brightness
# ADR-045 (RUST_LOG=info): the journal witness —
journalctl -u tbard.service --no-pager | grep "backlight enable-write"
```

- **EXPECT:** `brightness` == the written value
  (`active_brightness` clamped to `max_bl`, default 128) — NOT 0.
  The `tbard: backlight enable-write 128 (max 255,
  active_brightness 128)` INFO line (ADR-045) confirms the write
  fired from the journal.
- **DO NOT use mtime.** The `brightness` file mtime is NOT a reliable
  write-probe on `appletbdrm` (s038 §4, s039 §7.2). The mtime probe
  is DROPPED by this ADR. Do not re-add it.
- **If the read is later than ~1s after start:** the value may have
  decayed (s039 S2: 128→1 by ~30s, →0 by ~60s of no touch). A late
  read of 0 or 1 is UNRELIABLE — it does NOT prove the enable-write
  failed. Re-run the start and read within ~1s, OR rely on the
  ADR-045 journal INFO line (the `backlight enable-write 128` line
  confirms the write fired regardless of the current decayed value).

### 2. HC2 timing alignment

HC2 (the "first pixels" human checkpoint) must account for BOTH
decay sources. A lit bar observed minutes after start may
legitimately be dim/dark:

1. **Kernel-side auto-dim** (`appletbdrm` driver): a userspace-
   written value decays on idle (s039 S2: 128→1 by ~30s, →0 by
   ~60s), mtime FROZEN, `bl_power` stays 0. This is the driver's
   own idle-dim, independent of tbard.
2. **tbard's own ported adaptive path** (`update()` at loop-bottom,
   `src/providers/backlight.rs:222-266`, called at
   `src/main.rs:821`): the engine dims itself by design during a
   no-touch validation window — `BRIGHTNESS_DIM_TIMEOUT_MS = 30s` →
   `DIMMED_BRIGHTNESS = 1`, `BRIGHTNESS_OFF_TIMEOUT_MS = 60s` → 0
   (`backlight.rs:17-19`). A no-touch validation run WILL dim the
   bar by design; this is NOT a defect.

The HC2 protocol (`docs/test-plan.md` "HC2 — first pixels (ADR-046
timing alignment)"):

- Ask HC2 **within ~30s of `systemctl start`**, OR have the human
  **touch the bar first** (wake-to-bright: a touch event wakes the
  bar via tbard's adaptive `notify_activity` path, resetting
  `last_active` and re-brightening to `active_brightness`), THEN
  answer.
- Document the chosen protocol in the session log.
- If HC2 is asked later than ~60s after start with no touch in
  between, a "Dark / no pixels" answer is UNRELIABLE — it may
  reflect decay, not a write failure. Re-run with the
  ~30s-or-touch protocol.

s037's HC2 was asked minutes after start, by which time the
enable-write of 128 had decayed to 0 under the no-touch validation
window — the "Dark / no pixels" answer was consistent with a
SUCCESSFUL write + decay, not a missing write (ADR-044 V5).

### 3. The ~1s window is BEFORE the auto-dim decay (s039 timing)

s039 S2 measured the decay: 128 → 1 by ~30s, → 0 by ~60s. The ~1s
read window is comfortably before the decay begins (the first
sample at T+30s was already 1, but the decay starts earlier — the
~1s window is the safe read point where the value is still the
written 128). The value probe is reliable in this window because
tbard's enable-write is a userspace write (the userspace-written
regime, `docs/research/touchbar-interaction-manual/backlight.md`
§7.5), and the decay has not yet started.

### 4. Drop the mtime probe entirely (do not re-add)

The mtime probe is STRUCTURALLY INVALID on `appletbdrm` (s038 §4:
the driver's kernel-internal brightness changes do not move mtime;
a userspace write does — the two are indistinguishable from mtime
alone). This ADR DROPS the mtime probe from the runbook. The
limitation is documented here and in the runbook so nobody "fixes"
an unreliable late value read by re-adding mtime — mtime would be
EQUALLY unreliable (a late read after decay has mtime frozen AND
value decayed; neither proves the write failed). The ADR-045
journal INFO line is the post-decay reliable witness: the
`backlight enable-write 128` line is emitted at scanout-begin
BEFORE the decay begins, and persists in the journal independent of
the current sysfs value.

## Alternatives considered

- **Keep the mtime probe as a secondary signal.** Rejected: it is
  structurally invalid (s038 §4, s039 §7.2). Keeping it would
  invite operators to trust it and reach the s037 misdiagnosis
  again. The ADR-045 journal INFO line is a strictly better
  witness (emitted before decay; persists in the journal).
- **Read the value at a fixed later time (e.g. 30s) and accept the
  decayed value.** Rejected: the decayed value (1 or 0) is
  indistinguishable from a failed write. The ~1s window is the
  only reliable value-read point; the ADR-045 journal line covers
  the late case.
- **Touch the bar before the value read to reset the decay.**
  Considered: a touch wakes the bar (s039 S2b observation) but
  resets the value to the adaptive level (54, the oracle's
  default — or tbard's `active_brightness` if tbard's
  `notify_activity` path handles it). The value read after a touch
  does NOT confirm the enable-write value (128) — it confirms the
  wake value. The touch protocol is for HC2 (first pixels), not
  for the 4b value probe.
- **Use `actual_brightness` instead of `brightness`.** Considered:
  `actual_brightness` tracks the current hardware/driver state
  (`docs/research/touchbar-interaction-manual/backlight.md` §1) and
  follows `brightness` exactly during the userspace-written
  regime. It is NOT a better probe — it decays on idle just like
  `brightness` (s039 S2: actual followed brightness 128→1→0). The
  `brightness` knob is the write target and the correct read.

## Impact list

- `docs/test-plan.md` — new canonical "STEP 4 — verify live state
  (ADR-046 value-only probe)" subsection + "HC2 — first pixels
  (ADR-046 timing alignment)" subsection + revised "Intended pass
  criteria" (drop mtime; add the value-within-1s + HC2-timing
  criteria).
- `scripts/bench/interlock-preflight.sh` — header comment + STEP 0c
  comment updated to reference ADR-046 (the preflight runs BEFORE
  start; it does NOT perform the value probe, only checks the
  device is resolvable; the post-start value probe is in the
  runbook).
- `docs/adr/046-runbook-value-only-probe.md` — this file (new).
- `CHANGELOG.md` — `[Unreleased — ADR-046 runbook revision]`
  subsection.
- `devlog.md` — session 040 entry (ADR-046 section).

No `src/` change (the adaptive `update()` decay constants are
already correct at `src/providers/backlight.rs:17-19`; this ADR
documents the runbook's alignment with them, not a code change).

## References

- `docs/test-logs/038/hc0-autonomous-dim.txt` + `brightness-watch.txt`
  — the mtime quirk (kernel-internal changes do not move mtime).
- `docs/test-logs/039/s2-persistence.txt` — the auto-dim trajectory
  (128→1 by ~30s, →0 by ~60s of idle, mtime FROZEN, `bl_power` 0).
- `docs/test-logs/039/s3-cold-ignition.txt` — a 128 write lights a
  DARK bar (the value path works when the write reaches sysfs).
- `docs/research/touchbar-interaction-manual/backlight.md` §4, §7.2,
  §7.5 — the mtime quirk, the auto-dim trajectory, the two-regime
  operational definition (userspace-written vs kernel-auto-dim).
- `src/providers/backlight.rs:17-19` — `BRIGHTNESS_DIM_TIMEOUT_MS
  = 30s`, `BRIGHTNESS_OFF_TIMEOUT_MS = 60s`, `DIMMED_BRIGHTNESS = 1`
  (tbard's own adaptive decay constants — by design, not a defect).
- `src/providers/backlight.rs:222-266` — `update()` (the adaptive
  path; dims on idle by design).
- `src/main.rs:821` — the loop-bottom `update()` call.
- `docs/adr/045-observability-rust-log-info.md` — the RUST_LOG=info
  journal witness (the `backlight enable-write 128` INFO line is
  the post-decay reliable signal).
- `docs/adr/044-backlight-provider-dispatch-audit.md` V5 — the
  corrected s037 dark-bar explanation (successful write + decay +
  observation timing) that this ADR's runbook revision makes
  operationally testable.