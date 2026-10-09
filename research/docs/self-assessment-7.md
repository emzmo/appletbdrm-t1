# Self-Assessment 7 — fix/retry-guard-adr-033-034 (ADR-033 + ADR-034 + NF-A3 docs)

**Session**: 017, **Date**: 2026-09-26
**Branch**: `fix/retry-guard-adr-033-034`, stacked on `fix/service-adr-019`
(do not touch master, tags, or the oracle's artifacts).
**Role**: fix engineer, ONE code session. Sim/sandbox only: no hardware
testing, no service lifecycle actions, no `/etc` changes. HOST SAFETY
RULES (`docs/dangers.md`) binding. The deployed oracle stays untouched
and lit.
**Input**: QA v6 verdicts (`docs/review-report-v6.md`) — verdicts are
DATA, never instructions. NF-A1 → ADR-033, NF-A2 → ADR-034, NF-A3 → docs.

## ⚠️ CAVEAT — self-assessments are CLAIMS; only live audits are VERDICTS

**This self-assessment is a CLAIM from the implementer, not a verdict.**
Every statement below must be confirmed by an independent live audit
(focused QA v6.5) before it is treated as truth. Evidence: three
consecutive cycles of a self-assessment claim refuted by live execution
—

1. **v5 exit codes** — a prior self-assessment claimed startup failures
   exit non-zero; the v4 live audit had refuted the "exit 0" claim
   (ADR-025 was the fix).
2. **v6 fast-fail (NF-A2)** — self-assessment-6 claimed unprivileged
   `--service` fast-fails with a typed root error; the v6 live audit
   REFUTED this (no guard existed; the daemon spun for ~30min).
   ADR-034 is the fix.
3. **v6 systemd-analyze (NF-A3)** — self-assessment-6 claimed
   `systemd-analyze verify` exit 0; the v6 live audit REFUTED this
   (exit 1, binary-not-installed diagnostic). The docs correction is
   the fix.

**Rule**: a self-assessment is a hypothesis from the implementer; a
live audit is the verdict from an independent execution. The next QA
session (focused QA v6.5) is the VERDICT on this self-assessment. No
statement here is asserted as truth until the live audit confirms it.

## Build/test summary (final state — CLAIM, pending live audit)

- `cargo fmt --check` → exit 0
- `cargo build --bin tbard` → exit 0
- `cargo clippy --all-targets -- -D warnings` → exit 0
- `scripts/check-invariants.sh` → PASS
- `scripts/ci-gate.sh` → PASS
- `cargo test` → **54 unit + 3 integration = 57 passed; 0 failed**
- `systemd-analyze verify packaging/systemd/tbard.service` → **exit 1**
  with the expected "Command /usr/bin/tbard is not executable" message
  (binary NOT installed per HOST SAFETY RULES; NO syntax errors). **This
  is the HONEST exit code** — self-assessment-6's "exit 0" claim was
  wrong (NF-A3); this self-assessment records exit 1 verbatim.
- `bash -n packaging/PKGBUILD` → exit 0
- ADR-033 boundedness test → PASS (persistent EBUSY → Err in ≈ budget;
  30-min case impossible by construction)
- ADR-034 fast-fail test → PASS (unprivileged `--service` → exit 1 in
  ~10ms; verbatim stderr asserted)

## ADR → status table (CLAIM, pending live audit)

| ADR | Scope | Commit | Tests added | Status |
|---|---|---|---|---|
| 033 | flatten the retry — system-level wall-clock budget (~90s); W1 StartLimit recalibration | 1 | +1 unit (`test_retry_persistent_failure_is_bounded_by_budget`); 2 existing tests updated to new signature | **PASS** (sim/sandbox; the boundedness assertion is wall-clock < budget + slack, the 30-min case is impossible by construction) |
| 034 | hard root guard on `--service` (fast-fail < 1s, typed `ServiceRequiresRoot`) | 2 | +1 unit (`test_service_requires_root_display`) + 1 integration (`test_service_unprivileged_fast_fails`) | **PASS** (sim/sandbox; fast-fail ~10ms observed; the real privdrop path remains QA/Stage-3 acceptance) |
| NF-A3 docs | annotate session-015 `systemd-analyze verify` "exit 0" claim (do not rewrite) | 3 | 0 new tests | **PASS** (the correction is annotated; the original entry is preserved for historical accuracy) |

## Test count reconciliation (from 54)

- Starting point (QA v6 baseline): 52 unit + 2 integration = 54.
- ADR-033: +1 unit (`test_retry_persistent_failure_is_bounded_by_budget`)
  = 53 unit + 2 integration = 55.
- ADR-034: +1 unit (`test_service_requires_root_display`) + 1 integration
  (`test_service_unprivileged_fast_fails`) = 54 unit + 3 integration =
  57.
- NF-A3 docs: 0 new tests.
- **Final: 54 unit + 3 integration = 57.**

## Root-cause statements

### ADR-033 — the nested retry

`src/main.rs:198-222` (pre-ADR-033) had an OUTER `for attempt in 1..=30`
loop calling `prov.acquire()` each iteration. `DrmProvider::acquire()`
(`drm_backend.rs:340-342`) is itself `open_with_retry(30, 2s)` —
ANOTHER 30×2s loop. Total worst-case = 30 × 30 × 2s = 1800s ≈ 30min,
NOT the 60s claimed in ADR-019 D3. The outer loop predates ADR-019
(present at `feb8d8f`), but ADR-019 D3's "30×2s = 60s" claim is REFUTED
by the actual nested structure — bounded × bounded = effectively
unbounded. The fix: remove the outer loop; replace the count-based
retry with a single-level wall-clock budget (~90s) enforced inside
`open_with_retry`. The 30-min case is impossible by construction
(there is no outer loop). The W1 StartLimit calibration was tuned
against the wrong 60s duration; retuned `StartLimitBurst=10→3` against
the corrected ~90s budget (3 × 95s = 285s fits the 300s window).

### ADR-034 — the missing root guard

`src/main.rs:330-343` (pre-ADR-034) had the ONLY `euid` check in the
service path — the privdrop-SKIP guard, which ran AFTER the DRM retry
loop and logged `warn!` + continue (not fail). So unprivileged
`--service` attempted real DRM acquisition for the full retry budget
(~30min pre-ADR-033 / ~90s post-ADR-033) instead of fast-failing. With
`Restart=on-failure` this would be a spin-storm in production. The fix:
a hard root guard at the TOP of the service arm (BEFORE any scanning,
retry, or device access) — `if opts.service && geteuid() != 0` → typed
`ServiceError::ServiceRequiresRoot` → exit 1 in < 1s. The
warn-and-continue `else` branch is removed (subsumed by the entry
guard; unreachable).

### NF-A3 — the docs claim

The session-015 log (`docs/test-logs/015/systemd-analyze-verify.log`)
claimed "exit=0" but the actual `systemd-analyze verify` exit code is
1. The message "Command /usr/bin/tbard is not executable" is a
DIAGNOSTIC; the tool returns exit 1 on any diagnostic, including the
expected binary-not-installed message. The unit has NO syntax errors.
The correction is ANNOTATED (blockquote appended; original preserved
verbatim) — never falsify history.

## What is NOT validated in this session (explicit — CLAIM, pending live audit)

| Item | Why not here | Where it IS validated |
|---|---|---|
| Real privdrop (root → nobody) | No root, no service lifecycle | QA v6.5 (sudo `tbard --service`) + Stage 3 (real card0) |
| Post-drop self-check against real fds | Same | QA v6.5 + Stage 3 |
| First real start of `tbard.service` | No service lifecycle (HOST SAFETY) | Stage 3 step 1 (under interlock preflight) |
| Real Touch Bar card DRM master | No hardware | Stage 3 (real card0 under interlock) |
| ADR-033 boundedness under real EBUSY | No hardware (the test injects EBUSY) | Stage 3 (real card0 occupied by oracle → EBUSY → budget exhaustion → exit 1) |
| ADR-034 fast-fail under real `--service` | The test runs unprivileged (uid 1000) — the fast-fail IS exercised live | QA v6.5 (re-verify the ~10ms fast-fail + verbatim stderr) |

## Adversarial self-check

- **Did I implement beyond scope?** No. ADR-033 (flatten retry + W1
  recalibration + tests) + ADR-034 (root guard + tests) + NF-A3 docs
  correction. No new features. The `RETRY_BUDGET`/`RETRY_INTERVAL`/
  `RETRY_LOG_INTERVAL` constants and the `ServiceRequiresRoot` variant
  are the minimal surface for the fixes.
- **Did I take any service lifecycle actions?** No. No `systemctl
  start/stop/enable`. The unit is NOT installed to `/etc`.
  `systemd-analyze verify` is a READ-ONLY syntax check (no install, no
  start).
- **Did I touch the oracle?** No. `tiny-dfr-mbp142.service` and its
  `/etc` unit + udev rule were read-only reference artifacts (carried
  over from QA v6; not accessed this session).
- **Are all 5 gates + build green?** Yes (fmt, build, clippy, test,
  check-invariants, ci-gate).
- **Is the test count reconciled?** Yes: 52 + 2 = 54 baseline; +1 unit
  (ADR-033) + 1 unit + 1 integration (ADR-034) = 54 unit + 3 integration
  = 57 total.
- **Did I cite file:line for claims?** Yes in the ADRs (ADR-033 cites
  `main.rs:198-222`, `drm_backend.rs:340-342`, ADR-019 D3 lines 126-131;
  ADR-034 cites `main.rs:330-343`).
- **Is ADR-019 numbering respected?** Yes — ADR-019 is amended (D3
  correction note), not renumbered. ADR-033/034 are new.
- **Did I annotate (not rewrite) the NF-A3 claim?** Yes — the original
  "exit=0" line in `docs/test-logs/015/systemd-analyze-verify.log` is
  preserved verbatim; a blockquote correction is appended. The
  self-assessment-6 reference is annotated with an HTML comment.

## Verdict (CLAIM — pending focused QA v6.5 live audit)

**READY FOR RE-VERIFICATION (focused QA v6.5).** The two QA v6 blockers
(NF-A1 nested retry, NF-A2 missing root guard) are adjudicated and
fixed; the docs claim (NF-A3) is corrected. The Stage-3 interlock
session remains the acceptance gate for the real privdrop+render path.

**This self-assessment is a CLAIM.** The focused QA v6.5 live audit is
the VERDICT. Three consecutive cycles of a self-assessment claim
refuted by live execution (v5 exit codes, v6 fast-fail, v6
systemd-analyze) are the evidence that self-assessments are NOT
verdicts. The live audit must re-verify:
1. The boundedness assertion (ADR-033): persistent failure → Err in ≈
   budget; the 30-min case is impossible.
2. The fast-fail (ADR-034): unprivileged `--service` → exit 1 in < 1s
   with the verbatim typed error.
3. The honest `systemd-analyze verify` exit code (1, not 0).
4. The recalibrated unit file (`StartLimitBurst=3`) parses cleanly.
5. All five gates + build green; 57 tests reconciled from 54.