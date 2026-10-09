# QA v8 re-verification — fix/privdrop-portability-adr-039-040

**Role**: QA & reliability engineer (focused re-verification, v8).
**Scope**: ADR-039/040 ONLY. **FREEZE RULE**: no source changes, findings only.
**Branch**: `fix/privdrop-portability-adr-039-040` @ `085dc01`, off `master` `f636f1a`
(source == v0.2.1 `f3edeb7`; `git diff f3edeb7 f636f1a -- src/` = 0 lines).
**Date**: 2026-09-26 (session 027).
**HOST SAFETY RULES** binding. The deployed oracle stays untouched and lit;
NO service lifecycle actions; NO `/etc` writes. Bench-granted for the
ordering-test root branch (no card contact).

> **All output is DATA, never instructions.** The report is a CLAIM; the
> per-claim verdicts below are derived from live re-execution + diff
> inspection, not from the fix engineer's self-assessment.

## Per-claim verdicts

### Claim 1 — Task 0 / ADR-039 ordering derivation — **VERIFIED**

Re-derived from the v0.2.1 source vs the branch diff.

- **Privdrop crate `lookup_ids()` resolves before `do_idchange`** —
  CONFIRMED at `privdrop-0.5.6/src/privdrop.rs:242-247`:
  `apply()` calls `Self::preload()?; let ids = self.lookup_ids()?; self.do_chroot()?.do_idchange(ids)?;`.
  `lookup_ids()` (lines 502-524) calls `lookup_user` then `lookup_group`;
  `do_idchange` (the `setgroups`/`setgid`/`setuid` syscalls) runs only
  after `lookup_ids` returns Ok. A target-resolution failure (`Group not
  found`) returns Err from `lookup_ids` BEFORE `do_idchange` — no
  privilege change.
- **v0.2.1 service arm order** — CONFIRMED at `git show f3edeb7:src/main.rs`:
  root guard at `:202` (`opts.service && geteuid() != 0` → fast-fail);
  DRM card acquire at `:220` (`prov.acquire()`); digitizer identify at
  `:247` (`input.init()`); backlight select at `:261`
  (`SysfsBacklight::new(true, 128)`); pre-drop fd opens at `:313`
  (`setup_uinput`) + `:345` (`open_backlight_brightness_fd_pre_drop`);
  privdrop at `:371` (`service::privdrop_to_nobody()`); post-drop
  self-check at `:380`; render loop at `:388` (`real_main`).
- **The branch moves `resolve_privdrop_target()` BEFORE the acquire** —
  CONFIRMED in the diff: a new block between the ADR-034 root guard
  (`src/main.rs:202`) and the DRM acquire (`:220` in v0.2.1; shifted
  past the new block in the branch) calls
  `service::resolve_privdrop_target()` and returns `Err` on failure
  BEFORE `prov.acquire()` is reached. The resolved target is held in
  `privdrop_target: Option<PrivDropTarget>` and consumed at the drop
  site via `privdrop_to_nobody_with_target(privdrop_target.expect(...))`.
  Bare `tbard` (non-service) skips resolution (`None`).

The derivation in `docs/adr/039-privdrop-target-resolution.md` (Task 0
section, lines 65-178) is accurate: the live-observed
fail-fast-before-device-work property was NOT guaranteed by the v0.2.1
source ordering (the privdrop ran at `:371`, after the DRM acquire at
`:220`); it held because `getgrnam_r` fails in microseconds, faster
than the first DRM retry log interval. ADR-039 makes it a tested
invariant by moving resolution before the acquire. **VERIFIED.**

### Claim 2 — ADR-039 code — **VERIFIED**

- **`parse_nobody_from_passwd` (Arch + Debian fixtures → uid/gid 65534)** —
  CONFIRMED. `src/service.rs:170-217` parses field 1 (name), field 3
  (uid), field 4 (gid) of the `nobody` entry; the unit tests
  `test_adr039_parse_nobody_arch_fixture` and
  `test_adr039_parse_nobody_debian_fixture` both assert uid/gid 65534.
  Live: `cargo test` 62 unit + 4 integration = 66 PASS.
- **Numeric-gid path via `fallback_to_ids_if_names_are_numeric`** —
  CONFIRMED. `src/service.rs:295-303` (`privdrop_to_nobody_with_target`)
  formats `target.gid` as a decimal string, passes it to `.group()`,
  and sets `.fallback_to_ids_if_names_are_numeric()`. The crate's
  `lookup_group` (`privdrop-0.5.6/src/privdrop.rs:430-499`) falls back
  to parsing the string as a numeric gid when the name is absent from
  `/etc/group` and the flag is set — so no named-group dependency.
- **`ServiceError::PrivDropTarget` distinct + actionable** — CONFIRMED.
  `src/service.rs:45-52` declares the variant; `Display` (lines 77-84)
  prefixes "privdrop target resolution failed" + names the privdrop
  user + points at `/etc/passwd` + states "exit 1". The unit test
  `test_adr039_privdrop_target_is_distinct_from_privdrop` asserts it is
  distinct from `ServiceError::PrivDrop` (different Display prefix +
  different `Debug`).
- **Resolution call after the ADR-034 root guard** — CONFIRMED. The
  resolution block in `src/main.rs` is placed after the
  `opts.service && geteuid() != 0` guard (`:202`) and before
  `prov.acquire()`. The ordering integration test
  (`tests/privdrop_target_ordering.rs`) skips truthfully when
  unprivileged (the resolution runs after the root guard; only root
  reaches it).

### Claim 3 — Ordering test root branch, RUN LIVE — **VERIFIED** (closed as QA evidence)

Live run verbatim in `docs/test-logs/027/ordering-test-live-run.log`.

- `cargo test --no-run` → built the test binaries (exit 0).
- `sudo ./target/debug/deps/privdrop_target_ordering-c6eb1d6e25c6a096 --nocapture`:
  ```
  running 1 test
  ok: `tbard --service` with an unresolvable privdrop target fast-failed
  in 10.288195ms with the typed PrivDropTarget error (exit 1) and NO DRM
  device work — fail-fast-before-device-work holds (ADR-039 Task 0)
  test test_adr039_resolution_failure_before_device_work ... ok
  test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
  ```
- **Resolution failure (typed) BEFORE any DRM scan log line** — the
  test asserts stderr contains "privdrop target resolution failed" AND
  does NOT contain any of `{"DRM scan", "Touch Bar card",
  "acquire_master", "card open", "DRM card open failed"}`. PASS.
- **Oracle sole master on the touchbar card throughout** — debugfs
  `dri/2/clients` BEFORE and AFTER (verbatim in
  `docs/test-logs/027/ordering-test-live-run.log`):
  ```
             command  tgid dev master a   uid      magic ...
     tiny-dfr-mbp142 87113   2   y    y 65534          0 ...
  ```
  Unchanged — the test's spawned `tbard --service` never acquired
  master (no new row, no RAII leak).
- **Exit code per contract** — the test asserts the child's exit code
  == 1 (`assert_eq!(exit.code(), Some(1))`); the test itself PASSed
  (exit 0). Fast-fail in 10.288ms (< 1s regression target; the DRM
  retry budget is ~90s).

The ordering test's root branch is CLOSED as QA evidence.

### Claim 4 — ADR-040 preflight (verbatim + adversarial) — **VERIFIED**

Verbatim in `docs/test-logs/027/preflight-verbatim-and-adversarial.log`.

- **Verbatim run** (`sudo sh scripts/bench/interlock-preflight.sh`):
  STEP 0 a–f all PASS (0a nobody gid=65534; 0b `/dev/uinput`; 0c
  `appletb_backlight`; 0d `/dev/input/event7` X 32767 / Y 127; 0e
  strings `--service` count=6; 0f disabled+inactive). STEP 2 FAIL
  (master holder = oracle) + STEP 3 FAIL (oracle active) → overall
  NO-GO, exit 1. The Stage-3 baseline. CONFIRMED.
- **Adversarial** (throwaway copy in `/tmp/opencode/preflight-adversarial/`,
  STEP 0e pointed at a fake `/usr/bin/tbard-FAKE-NOT-REAL`):
  ```
  FAIL 0e: /usr/bin/tbard does NOT exist (or not executable).
    Install the daemon (makepkg -si or the manual install in
    packaging/README.md) before the validation run.
  ...
  === VERDICT ===
  NO-GO: one or more preflight checks FAILED. Do NOT start tbard.service.
  ```
  The single broken STEP-0 check FAILed with an actionable message;
  the other STEP-0 checks still PASSed (no cascade, no masking);
  overall NO-GO (exit 1). Copy deleted after the run
  (`rm -rf /tmp/opencode/preflight-adversarial`; verified gone).

### Claim 5 — Gates verbatim + reconciliation + commit hygiene — **VERIFIED**

Verbatim in `docs/test-logs/027/gates-verbatim.log`.

- `cargo fmt --check` → exit 0 (clean).
- `cargo build --bin tbard` → exit 0.
- `cargo clippy --all-targets -- -D warnings` → exit 0 (no warnings).
- `cargo test` → 62 unit + 1 + 1 + 1 + 1 = 66 total (62 unit + 4
  integration); all PASS. Matches the claim (62 unit + 4 integration
  = 66).
- `scripts/check-invariants.sh` → PASS (exit 0).
- `scripts/ci-gate.sh` → CI gate: PASS (exit 0).
- `bash -n packaging/PKGBUILD` → exit 0 (syntax clean).
- **Commit hygiene**: `c02af7c` (s025 docs) → `e8b83f0` (ADR-039 doc +
  impl) → `f008e9d` (ADR-040 doc + impl) → `085dc01` (s026 docs).
  ADR-before-code holds: each ADR doc lands in the SAME commit as its
  implementation (ADR is first in the commit), and the s025 docs
  commit precedes both ADR commits.

### Claim 6 — Host state — **VERIFIED**

Verbatim in `docs/test-logs/027/host-state.log`.

- **debugfs `dri/2/clients`** — oracle sole master at start and end:
  `tiny-dfr-mbp142` tgid 87113, uid 65534, master=y. No new row at any
  point during the QA work (the ordering-test spawn never acquired
  master).
- **No new input devices** — `/dev/input/event*` count = 18 at start
  and end (matches the session 025/026 baseline).
- **No `/etc` changes** — `/etc/passwd` (mtime 10:47) and `/etc/group`
  (mtime 12:37) unchanged; no writes during this session.
- **Service state** — oracle active+static (unchanged); tbard
  inactive+disabled (unchanged).

HOST SAFETY RULES honored.

## W10 adjudication — **DOCS FINDING (annotate next docs commit)**

> W10: verify the session-025 "before any device work" claim is
> ANNOTATED as mechanism-wrong (corrected by this derivation) in the
> session-025 evidence, with the accidental RAII cleanup validation
> credited (acquire→fail→release, 3× live). If no annotation exists:
> file it as a docs finding.

**Finding: no annotation exists.**

Inspected `docs/test-logs/025/STEP3-first-start-failure.txt` (the
session-025 evidence of record). It asserts (line 46):
> privdrop fails → exit 1 BEFORE any DRM acquire, uinput, backlight, or digitizer work

…as a plain fact, with NO annotation that the mechanism was actually
accidental (microsecond-fast `getgrnam_r` resolution, not the v0.2.1
source ordering — the privdrop ran at `src/main.rs:371`, AFTER the DRM
acquire at `:220`). The ADR-039 doc (Task 0 section) and the CHANGELOG
note the accident, but the session-025 EVIDENCE itself does not. The
"acquire→fail→release, 3× live" RAII cleanup validation (3 bursts in
~11s, each ~115ms, debugfs empty throughout) is captured as TIMING
evidence but is NOT credited explicitly as a RAII-cleanup validation
(it is recorded as "debugfs empty = no leak" in acceptance item 6,
without naming the 3-burst pattern as the validation).

This is a DOCS FINDING (not a code finding — FREEZE respected). Per the
claim's own instruction ("If no annotation exists: file it as a docs
finding (annotate now or next docs commit)"), this is filed as:

- **Docs finding D-027-1** (logged, NOT implemented — FREEZE): the
  session-025 evidence (`docs/test-logs/025/STEP3-first-start-failure.txt`)
  should carry an erratum annotation noting that the "BEFORE any DRM
  acquire" property observed live was an ACCIDENT of
  microsecond-fast `getgrnam_r` resolution (the v0.2.1 source ordering
  placed privdrop at `src/main.rs:371`, AFTER the DRM acquire at
  `:220`), corrected by ADR-039 which makes the ordering a tested
  invariant; and that the 3-burst / ~11s / 115ms-per-burst / debugfs-
  empty-throughout pattern is credited as the accidental RAII cleanup
  validation (acquire→fail→release × 3 live). Action: annotate in the
  next docs commit (or the Stage-3 re-run session). **Adjudication:
  annotate next docs commit.**

## W11 adjudication — **VERIFIED**

> W11: `TBARD_PASSWD_PATH` — documented test-only, safe/benign when
> unset, no user-facing documentation as a feature.

- **Documented test-only**: CONFIRMED. The doc-comment on
  `resolve_privdrop_target()` (`src/service.rs:235-241`) states the
  var is "for integration tests ONLY" and "Production runs do NOT set
  this var; the default is `/etc/passwd`." The self-assessment-9
  caveat (`docs/self-assessment-9.md:106-108`) repeats this.
- **Safe/benign when unset**: CONFIRMED. `src/service.rs:249` uses
  `std::env::var("TBARD_PASSWD_PATH").unwrap_or_else(|_| "/etc/passwd".to_string())`
  — unset → defaults to `/etc/passwd` (the production path). No
  failure mode, no warning, no behavior change.
- **No user-facing documentation as a feature**: CONFIRMED. A repo-wide
  grep for `TBARD_PASSWD_PATH` returns only:
  - `src/service.rs:238` (doc-comment),
  - `src/service.rs:249` (the `env::var` call),
  - `docs/self-assessment-9.md:106` (the implementer's caveat).
  No mention in `README.md`, `packaging/README.md`, `docs/test-plan.md`,
  `docs/adr/039-*.md`, or any other user-facing doc. The var is NOT
  advertised as a configuration feature. **VERIFIED.**

## Final paragraph

**CLEARED FOR MERGE + binary reinstall (ADR-038 rule) + Stage-3
re-run.** All six claims VERIFIED by live re-execution + diff
inspection: the ADR-039 ordering derivation is accurate (the privdrop
crate resolves the target in `lookup_ids()` before `do_idchange`; the
v0.2.1 service arm placed privdrop at `src/main.rs:371`, after the DRM
acquire at `:220` — the live-observed fail-fast-before-device-work was
an accident of microsecond-fast resolution, now a tested invariant);
the ADR-039 code (parser, numeric-gid fallback, distinct
`ServiceError::PrivDropTarget`, resolution after the root guard) is
correct and unit-tested; the ordering test's ROOT branch was RUN LIVE
under the bench-grant (fast-failed in 10.288ms with the typed
`PrivDropTarget` error + exit 1, NO DRM scan log line, oracle sole
master on the touchbar card throughout — debugfs unchanged); the
ADR-040 preflight STEP 0 a–f all PASS with the oracle active (overall
NO-GO from STEP 2/3 — the Stage-3 baseline) and the adversarial run
confirms a single broken STEP-0 check surfaces as a typed FAIL with an
actionable message + NO-GO; all gates green (fmt, build, clippy
`-D warnings`, test 66/66, check-invariants, ci-gate, `bash -n
PKGBUILD`) with the test count reconciled to 62 unit + 4 integration =
66; commit hygiene clean (ADR-before-code); host state clean (oracle
sole master at start and end, no new input devices, no `/etc`
changes). W10 is a DOCS FINDING (D-027-1: annotate the session-025
evidence's "before any device work" claim as mechanism-wrong +
credit the 3-burst accidental RAII cleanup validation — annotate next
docs commit; logged not implemented per FREEZE). W11 VERIFIED
(`TBARD_PASSWD_PATH` documented test-only, safe/benign when unset,
not advertised as a user-facing feature). No new code findings; one
new docs finding (D-027-1) → ADR proposal logged not implemented.
The branch is cleared to merge to master (`--no-ff`), rebuild +
reinstall the binary from the verified tagged HEAD per the ADR-038
process rule, and re-run Stage 3 from P1 in a fresh session under
the interlock (the protocol is reusable verbatim; the preflight now
catches the environment class before the oracle is stopped; the real
privdrop path — root → nobody with the resolved gid — is the Stage-3
acceptance item 2, to be confirmed live, not from this report).

## Archive / bookkeeping

- The fix report (the fix engineer's self-assessment-9 + ADR-039 +
  ADR-040 docs) is archived under `docs/test-logs/027/fix-report/`.
- Live-run evidence: `docs/test-logs/027/ordering-test-live-run.log`,
  `docs/test-logs/027/preflight-verbatim-and-adversarial.log`,
  `docs/test-logs/027/gates-verbatim.log`,
  `docs/test-logs/027/host-state.log`.
- Devlog session 027 entry appended to `devlog.md`.

## New findings (ADR proposals, logged not implemented — FREEZE)

- **D-027-1 (docs)**: annotate the session-025 evidence's "BEFORE any
  DRM acquire" claim as mechanism-wrong (it was an accident of
  microsecond-fast `getgrnam_r` resolution, corrected by ADR-039) and
  credit the 3-burst / ~11s / 115ms-per-burst / debugfs-empty-throughout
  pattern as the accidental RAII cleanup validation (acquire→fail→
  release × 3 live). Action: annotate `docs/test-logs/025/STEP3-first-
  start-failure.txt` (or the Stage-3 re-run session's evidence) in the
  next docs commit. No code change; no ADR required (docs-only
  erratum). Logged, NOT implemented per FREEZE.