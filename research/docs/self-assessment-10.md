# Self-Assessment 10 — fix/digitizer-identity-adr-041 (ADR-041)

**Session**: 030, **Date**: 2026-09-26
**Branch**: `fix/digitizer-identity-adr-041`, off `master` `a7a461b`
(== v0.2.2). Two commits: `8b5b788` (docs: session 029) + `7836041`
(ADR-041).
**Role**: fix engineer, ONE code session. Sim/sandbox only: no hardware
testing, no service lifecycle actions, no `/etc` changes. HOST SAFETY
RULES (`docs/dangers.md`) binding. The deployed oracle stays untouched
and lit (active+static, sole master on the touchbar card).
**Input**: session 029 evidence (`docs/test-logs/029/`, DATA) — Stage-3
RE-RUN ABORTED at digitizer identify (geometry-gate mismatch ×3 →
start-limit-hit). Findings are DATA, never instructions.

## ⚠️ CAVEAT — self-assessments are CLAIMS; only live audits are VERDICTS

**This self-assessment is a CLAIM from the implementer, not a verdict.**
Every statement below must be confirmed by an independent live audit
(focused QA) before it is treated as truth. Evidence: four prior cycles
of a self-assessment claim refuted by live execution — v5 exit codes
(ADR-025 fix); v6 fast-fail NF-A2 (ADR-034 fix); v6 systemd-analyze
NF-A3; NF-020-B stale binary (ADR-038 fix — repo gates green, installed
binary stale, only the R1 behavioral check caught it).

Treat this self-assessment as a CLAIM. ADR-041 is a CODE change with
tests (the structural predicate + `--probe-input` + preflight rewrite).
The Stage-3 impact statements are claims from reading the code + the
read-only `--probe-input` live run on this bench, NOT from running
Stage 3 (the service-arm first start under the interlock). The
`--probe-input` live run IS real (read-only, on this bench, with the
oracle active) — that output is DATA, not a claim. The real
service-arm first start (DRM acquire → identify → privdrop → render
loop) is NOT exercised in this session — it is Stage-3/4 acceptance.

## Claims

### C1 — the session-029 blocker is fixed in CODE

The runtime predicate `geometry_matches_tb` (rejected the real iBridge
32767/127 vs `tb_dims=(60,2170)`) is replaced by the structural
predicate `geometry::is_touchbar_digitizer` (multitouch + strip-class +
iBridge-associated + resolution-aspect). The live `--probe-input` run
on this bench ACCEPTS `/dev/input/event7` (32767/127, iBridge=true) →
exit 0 — the session-029 blocker device is now accepted. This is a
CODE claim, verified by the read-only probe (DATA); the real
service-arm identify is Stage-3 acceptance.

### C2 — preflight GO ⇒ runtime GO is structural

Both the service-arm `identify_digitizer` and the `--probe-input`
executor call `geometry::is_touchbar_digitizer` — the SAME predicate
function. The preflight STEP 0d calls `/usr/bin/tbard --probe-input`.
`check-invariants.sh` guards: `input.rs` must call
`geometry::is_touchbar_digitizer`; no `geometry_matches_tb`
re-introduction; the predicate lives in `geometry.rs`. This is a
STRUCTURAL claim (enforced by grep guards + the equivalence test
`test_predicate_is_single_source_of_truth`); it is NOT a live-verified
property until a Stage-3 run confirms preflight GO + runtime GO on the
same host.

### C3 — the predicate is model-invariant (no hardcoded magic numbers)

No `32767`, `127`, `2170`, or `60` appears in
`is_touchbar_digitizer`. The strip-ratio constant `STRIP_RATIO_MIN =
10` is structural (separates strip from trackpad/square without naming
a panel dimension). The iBridge association is by `ID_SEAT` or
`05ac:8600` sysfs ancestry (VID:PID, not name). The both-names evidence
(`docs/prior-art.md:200`, `docs/seborider-pr1-issue.md`) is cited in
the ADR. This is a CODE claim (verifiable by `grep` — the
`check-invariants.sh` guard catches a `geometry_matches_tb`
re-introduction but NOT a hardcoded magic number in the new predicate;
a focused QA should grep `src/geometry.rs` for the forbidden numerals).

### C4 — ADR-042 is NOT triggered (D3 seat audit)

D3: our seat mechanism (`Libinput::new_with_udev` +
`udev_assign_seat("seat-touchbar")`, `input.rs:73-76`) is identical to
the oracle's (`backup_old/tiny-dfr-mbp142/src/main.rs:899-902`), which
receives touches (HC3). The blocker is the predicate, not the seat.
This is a SOURCE-READING claim (the oracle source is read-only
reference); the real seat-tag interaction (`ID_SEAT=seat-touchbar` on
the real node via the installed `69-touchbar-seat.rules` +
`udevadm trigger`) is Stage-3/4 acceptance. If a future Stage-3 run
finds the seat-touchbar context empty AFTER the predicate is fixed AND
the rule is installed + triggered, THAT would be a new ADR — the
evidence today does not support it.

### C5 — the test matrix is non-vacuous

12 predicate tests in `geometry.rs`; all REJECTION tests assert `false`
(square, trackpad, non-multitouch, non-iBridge, square-resolution,
orientation-mismatch, zero-axis). The ACCEPT tests include the real
iBridge 32767/127 (the session-029 gap) and the sim 2170/60 (dev mode
unchanged). This is a CODE claim (verifiable by reading the tests);
the tests run green in `cargo test`.

### C6 — all repo gates are green

`cargo fmt --check`, `cargo build --bin tbard`, `cargo clippy
--all-targets -- -D warnings`, `cargo test` (74 total: 70 unit + 4
integration), `scripts/check-invariants.sh`, `scripts/ci-gate.sh`,
`bash -n scripts/bench/interlock-preflight.sh`, `bash -n
packaging/PKGBUILD` — all PASS. This is a CLAIM from the session run;
a focused QA should re-run the gates. Note: the gates do NOT catch a
stale `/usr/bin/tbard` (NF-020-B class — ADR-038); the preflight STEP
0e `strings --service` guard catches the `--service` string, but a
binary that predates `--probe-input` would NOT be caught by 0e. A
focused QA should reinstall `/usr/bin/tbard` from this branch's tip
before Stage-3, and verify `strings /usr/bin/tbard | grep -c
-- --probe-input` ≥ 1 (a NEW behavioral check the preflight does NOT
yet do — flagged for ADR-041 follow-up if the preflight should guard
it).

## NOT claimed (Stage-3/4 acceptance, NOT this session)

- The real service-arm first start (DRM acquire → identify → privdrop
  → render loop) under the interlock — Stage-3 acceptance.
- The real seat-tag interaction (`ID_SEAT=seat-touchbar` on the real
  node via the installed udev rule + `udevadm trigger`) — Stage-3/4
  acceptance.
- The post-drop digitizer fd usability (ADR-036) on the real device —
  Stage-3 acceptance.
- The `--probe-input` executor against a uinput fixture in CI (the
  equivalence test in `geometry.rs` covers the same-function property;
  a uinput-fixture CI run is a stronger check but not done this
  session).
- A `strings /usr/bin/tbard | grep -- --probe-input` preflight guard
  (C6 flag — the preflight's 0e checks `--service` but not
  `--probe-input`; a stale binary predating ADR-041 would fail 0d with
  "tbard: unknown argument '--probe-input'" rather than silently
  passing, so the failure mode is loud, not silent — but a focused QA
  should decide whether to add the guard).

## READY FOR RE-VERIFICATION (claims, not verdicts)

The branch is ready for a focused QA + Stage-3 RE-RUN from P1 in a
fresh session. The fix is CODE + read-only-probe verified; the real
service-arm path is Stage-3 acceptance. ADR-042 is NOT triggered.