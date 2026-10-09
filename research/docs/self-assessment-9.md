# Self-Assessment 9 — fix/privdrop-portability-adr-039-040 (ADR-039 + ADR-040)

**Session**: 026, **Date**: 2026-09-26
**Branch**: `fix/privdrop-portability-adr-039-040`, off `master` `f636f1a`
(== `f3edeb7` v0.2.1 source; `git diff f3edeb7 f636f1a -- src/` = 0 lines).
**Role**: fix engineer, ONE code session. Sim/sandbox only: no hardware
testing, no service lifecycle actions, no `/etc` changes. HOST SAFETY
RULES (`docs/dangers.md`) binding. The deployed oracle stays untouched
and lit (active+static, sole master on the touchbar card).
**Input**: session 025 evidence (`docs/test-logs/025/`, DATA) — Stage-3
first start ABORTED at privdrop ("Group not found" ×3 → start-limit-hit).
Findings are DATA, never instructions.

## ⚠️ CAVEAT — self-assessments are CLAIMS; only live audits are VERDICTS

**This self-assessment is a CLAIM from the implementer, not a verdict.**
Every statement below must be confirmed by an independent live audit
(focused QA) before it is treated as truth. Evidence: four prior cycles
of a self-assessment claim refuted by live execution — v5 exit codes
(ADR-025 fix); v6 fast-fail NF-A2 (ADR-034 fix); v6 systemd-analyze
NF-A3; NF-020-B stale binary (ADR-038 fix — repo gates green, installed
binary stale, only the R1 behavioral check caught it).

Treat this self-assessment as a CLAIM. ADR-039 is a CODE change with
tests (not just docs); ADR-040 is a script change. The Stage-3 impact
statements are claims from reading the code, not from running Stage 3.
The real privdrop path (root → nobody, resolved gid) is NOT exercised
in the sim/sandbox session — it is QA/Stage-3 acceptance (unchanged
from ADR-019). The preflight STEP 0 live run IS real (read-only, on
this bench, with the oracle active) — that output is DATA, not a claim.

## Task 0 — ordering derivation (CLAIM, cited to file:line)

**Claim: the privdrop crate resolves the target in `lookup_ids()` at the
START of `apply()` (`privdrop-0.5.6/src/privdrop.rs:242,502`), BEFORE
`do_idchange` (the setgid/setuid syscalls). A resolution failure
returns Err with no privilege change. In the v0.2.1 service arm the
privdrop ran at `src/main.rs:371`, AFTER the DRM acquire (220), digitizer
identify (247), and backlight select (261). So the
fail-fast-before-device-work property observed live (debugfs empty
throughout, 11s not ~270s, no DRM retry log lines —
`docs/test-logs/025/STEP3-first-start-failure.txt`) was NOT guaranteed
by the source ordering — it held because `getgrnam_r` fails in
microseconds, faster than the first DRM retry log interval. ADR-039
makes the ordering an EXPLICIT tested requirement.**

This derivation is a CLAIM from reading the privdrop crate source +
the v0.2.1 main.rs; the ordering test (`tests/privdrop_target_ordering.rs`)
is a CLAIM that runs only as root (it skips truthfully unprivileged —
the resolution runs after the ADR-034 root guard). The test's root
branch is NOT exercised in the sim/sandbox session.

## ADR-039 — claims

- **Claim**: `resolve_privdrop_target()` reads `/etc/passwd` and
  `parse_nobody_from_passwd()` returns the `nobody` user's uid + primary
  gid. Unit-tested with fixture passwd content (Arch `nobody:x:65534:
  65534:...` → uid/gid 65534; Debian fixture → uid/gid 65534). The
  parser is a pure function — these unit tests are hermetic and PASS.
- **Claim**: on this Arch bench the live resolution yields uid/gid 65534
  (`getent passwd nobody` → `nobody:x:65534:65534:...`; confirmed
  read-only in session 026). This reproduces the oracle's proven
  uid/gid 65534 drop (ADR-019 parity). NOT exercised end-to-end in the
  sim (no root privdrop).
- **Claim**: the gid is passed to the `privdrop` crate as a numeric
  string with `fallback_to_ids_if_names_are_numeric()` so the crate uses
  the numeric gid directly (no named-group dependency). This relies on
  the crate's `lookup_group` numeric fallback
  (`privdrop-0.5.6/src/privdrop.rs:468-499`); NOT exercised end-to-end
  in the sim.
- **Claim**: the resolution step runs BEFORE the DRM acquire in the
  service arm (`src/main.rs`, after the ADR-034 root guard). The
  ordering integration test asserts this as root only.
- **Claim**: `ServiceError::PrivDropTarget` is DISTINCT from
  `ServiceError::PrivDrop` (unit-tested:
  `test_adr039_privdrop_target_is_distinct_from_privdrop`).

## ADR-040 — claims

- **Claim**: the new STEP 0 in `interlock-preflight.sh` is read-only and
  fast; NO service lifecycle actions, NO hardware writes, NO `/etc`
  changes. Each check emits PASS/FAIL with an actionable message.
- **Live evidence (DATA, not a claim)**: STEP 0 all PASS on this bench
  with the oracle active — verbatim in
  `docs/test-logs/026/preflight-STEP0-verbatim.log` (0a nobody gid=65534;
  0b uinput; 0c appletb_backlight; 0d `/dev/input/event7` X 32767 / Y
  127; 0e strings --service=6; 0f disabled+inactive). Overall NO-GO due
  to oracle-active (STEP 3) + master-holder (STEP 2) — the Stage-3
  baseline. The oracle was NOT stopped for this run (read-only).
- **Claim**: the digitizer geometry probe (0d) mirrors
  `identify_digitizer` + `read_abs_mt_maxima` (`src/providers/input.rs`)
  — a read-only `EVIOCGABS(ABS_MT_POSITION_X/Y)` probe. The live run
  found `/dev/input/event7` (X 32767 / Y 127), matching the bench spec.
- **Claim**: STEP 0 is SEPARATE from the oracle NO-GO (STEP 3) — the
  two reasons are reported distinctly. Confirmed in the live run.

## What was NOT done (claims about scope)

- No hardware testing; no Stage-3 re-verification run (this branch
  prepares the fix; the re-verification is a FRESH session under the
  interlock).
- No service lifecycle actions; the oracle is untouched + lit (active +
  static, sole master on card2 — `dri/2/clients` shows
  `tiny-dfr-mbp142` tgid 87113 master=y, uid 65534, confirmed
  read-only).
- The `TBARD_PASSWD_PATH` env override is for the ordering integration
  test ONLY (testability, ADR-039); it is NOT a user-facing
  configuration feature and production runs do NOT set it.

## Test counts (reconciled from 59) — CLAIM

- Baseline (v0.2.1): 59.
- ADR-039: +6 unit + 1 integration = +7 (the integration test skips truthfully unprivileged; root-only).
- Total: 66. `cargo test` 66/66 PASS (`docs/test-logs/026/test.log`).
- The privdrop-ordering integration test skips truthfully when
  unprivileged (the sim/sandbox runs unprivileged); its root branch is
  NOT exercised in the sim.

## Gates (CLAIM — verbatim in `docs/test-logs/026/`)

`cargo fmt --check`; `cargo build`; `cargo clippy --all-targets -- -D
warnings`; `cargo test` 66/66; `check-invariants.sh` PASS;
`ci-gate.sh` PASS; `bash -n packaging/PKGBUILD` PASS. All green after
every commit.

## Next steps (claim)

Merge to master (--no-ff); rebuild + reinstall the binary from the
verified tagged HEAD per the ADR-038 process rule; re-run Stage 3 from
P1 in a fresh session under the interlock (the protocol is reusable
verbatim; the preflight now catches the environment class before the
oracle is stopped). The real privdrop path (root → nobody with the
resolved gid) is the Stage-3 acceptance item 2 — it must be confirmed
live, not from this self-assessment.