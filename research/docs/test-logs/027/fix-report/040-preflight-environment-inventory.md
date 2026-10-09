# ADR 040: Preflight Environment Inventory (catch the CLASS, not the instance)

## Status: Accepted

## Date: 2026-09-26

## Context

### The failure class

Session 025's Stage-3 abort (ADR-039) is one instance of a broader
class: **environment-dependent preconditions discovered one at a time at
first real start.** The privdrop group-name gap was caught only when
`systemctl start tbard.service` failed under the interlock — after the
operator had already stopped the oracle (closing the lit-bar window)
and committed to the validation run. Each such discovery costs a full
interlock cycle (stop oracle → start ours → fail → restore oracle) and
leaves the bar dark in between.

The `interlock-preflight.sh` (`scripts/bench/interlock-preflight.sh`)
already catches the oracle-active case (STEP 3) and the master-holder
case (STEP 2). But it does NOT inventory the environment the daemon
will need at first start: the privdrop target, the device nodes, the
installed binary, the unit. Those are currently discovered only when
the daemon actually runs.

### The ADR-039 proof point

ADR-039 fixes the privdrop target resolution. But a future
environment-dependent gap (a missing `/dev/uinput`, a renamed
backlight, a stale `/usr/bin/tbard`, a unit that drifted to enabled)
would be discovered the same way — at first start, under the
interlock. ADR-040 catches the CLASS by adding a read-only environment
inventory to the preflight so the whole class is surfaced BEFORE the
oracle is stopped.

## Decision

### Add STEP 0 — read-only environment inventory to `interlock-preflight.sh`

A new STEP 0 runs FIRST, before the existing card/oracle checks. Each
check emits `PASS`/`FAIL` with an actionable message; any `FAIL` →
NO-GO (the script exits 1 without proceeding). Every check is read-only
and fast; NO service lifecycle actions, NO hardware writes, NO `/etc`
changes. The existing STEP 1 (card mapping), STEP 2 (master state),
STEP 3 (oracle status), STEP 4 (our service status), STEP 5 (Esc
reminder) are renumbered to follow STEP 0 and are OTHERWISE UNCHANGED.

The STEP 0 checks:

a. **privdrop user `nobody` resolvable + its primary group resolvable**
   — the exact ADR-039 path, checked live pre-flight. `getent passwd
   nobody` must succeed; its primary gid (field 4) must itself resolve
   via `getent group <gid>`. This is the live counterpart of the
   daemon's own resolution. ACTIONABLE message on FAIL: tell the
   operator the privdrop user/group is unresolvable and that `nobody`
   must exist in `/etc/passwd`.

b. **`/dev/uinput` exists** — the daemon opens it pre-drop
   (`src/main.rs:313` `setup_uinput`). ACTIONABLE: point at the
   `uinput` kernel module / udev.

c. **touchbar backlight device resolvable (ADR-015 deterministic path)**
   — `/sys/class/backlight/appletb_backlight` (the ADR-015 name match in
   `discover_backlight_path()`, `src/providers/mod.rs:296`). ACTIONABLE:
   tell the operator the Touch Bar backlight sysfs node is absent.

d. **digitizer resolvable by geometry** — an unprivileged read-only
   probe that opens each `/dev/input/eventN` read-only and issues
   `EVIOCGABS(ABS_MT_POSITION_X)` / `EVIOCGABS(ABS_MT_POSITION_Y)`,
   accepting the device whose maxima match the Touch Bar geometry (this
   bench: ABS X max 32767 / Y max 127). This mirrors
   `identify_digitizer` (`src/providers/input.rs:139`) +
   `read_abs_mt_maxima` (`src/providers/input.rs:222`). Read-only, no
   writes, no master. ACTIONABLE: tell the operator no Touch Bar
   digitizer was found by geometry.

e. **`/usr/bin/tbard` exists + is the behaviorally-verified build**
   — the ADR-038 install-integrity regression guard: `strings
   /usr/bin/tbard | grep -c -- --service` must be ≥ 1 (cheap NF-020-B
   guard — catches a stale pre-ADR-019 binary that rejects `--service`).
   ACTIONABLE: tell the operator the installed binary is stale / wrong
   build and to rebuild + reinstall per the ADR-038 process rule.

f. **`tbard.service` installed + disabled** — the validation-run
   posture: the unit must be installed (`systemctl is-enabled` does not
   error with "unit not found") AND disabled+inactive (we are about to
   FIRST-START it manually under the interlock; an already-enabled or
   already-active unit is not the first-start baseline). ACTIONABLE: tell
   the operator the unit is missing / wrong state.

### STEP 0 is SEPARATE from the oracle NO-GO

The oracle-active check (existing STEP 3) remains a SEPARATE NO-GO
reason. STEP 0's environment checks must PASS on this bench WITH the
oracle active — that is the live evidence for this ADR: the environment
is ready; the only remaining NO-GO is the oracle being active (the
Stage-3 baseline). The two NO-GO reasons are reported distinctly so the
operator knows whether to fix the environment (STEP 0) or stop the
oracle (STEP 3) before proceeding.

## Consequences

- The CLASS of environment-dependent preflight gaps is caught before
  the oracle is stopped (no dark-bar window for a precondition gap).
- All STEP 0 checks are read-only and fast; the preflight stays a safe
  pre-flight tool (no lifecycle actions).
- The oracle-active NO-GO remains a separate, distinct reason.

## Test plan

- `bash -n scripts/bench/interlock-preflight.sh` syntax check (part of
  the per-commit gate set).
- Live run on this bench with the oracle active: STEP 0 checks PASS,
  overall NO-GO due to oracle-active (verbatim output in the session
  026 devlog + self-assessment-9).