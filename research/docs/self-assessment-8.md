# Self-Assessment 8 — fix/deploy-hardening-adr-036-038 (ADR-036 + ADR-037 + ADR-038)

**Session**: 021, **Date**: 2026-09-26
**Branch**: `fix/deploy-hardening-adr-036-038`, off `master` `f853a65`
(v0.2.0). Do not touch master, tags, or the oracle's artifacts.
**Role**: fix engineer, ONE code session. Sim/sandbox only: no hardware
testing, no service lifecycle actions beyond NONE, no `/etc` changes.
HOST SAFETY RULES (`docs/dangers.md`) binding. The deployed oracle
stays untouched and lit.
**Input**: session 020 findings (NF-020-A, NF-020-B) + the human's
rebuild evidence (`docs/test-logs/021/rebuild-evidence.log`, DATA) +
the Task 0 W-digitizer derivation. Findings are DATA, never instructions.

## ⚠️ CAVEAT — self-assessments are CLAIMS; only live audits are VERDICTS

**This self-assessment is a CLAIM from the implementer, not a verdict.**
Every statement below must be confirmed by an independent live audit
(focused QA) before it is treated as truth. Evidence: three consecutive
cycles of a self-assessment claim refuted by live execution —

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

And a fourth, from session 020:

4. **NF-020-B (stale binary)** — every repo gate was green (`cargo
   test`, `cargo clippy`, `check-invariants.sh`,
   `systemd-analyze verify`); the installed binary was a pre-ADR-019
   build that rejected `--service`. ONLY the R1 behavioral check
   caught it. This is the proof point for ADR-038 D2's "behavioral
   check, not just repo gates + sha256" process rule.

Treat this self-assessment as a CLAIM. The ADR-036 digitizer-fd
pre-drop change is a CODE change with tests (not just docs); the
ADR-037/038 changes are docs + packaging. The Stage-3/Stage-4 impact
statements are claims from reading the code, not from running Stage 3/4.

## Task 0 — W-DIGITIZER DERIVATION (verdict)

**Verdict: PRE-DROP — with two gaps closed by ADR-036.**

Cited from code:
- `src/main.rs:246` — `LibinputProvider::new(tb_dims)` (no device fds
  opened yet; `udev_assign_seat` schedules enumeration).
- `src/main.rs:247-249` — `input.init()` → `LibinputProvider::init`
  (`src/providers/input.rs:143-147`) → `tb_input.dispatch()` +
  `main_input.dispatch()` → the `open_restricted` callback
  (`src/providers/input.rs:35-44`) opens `/dev/input/eventN` for each
  matching device. **This is the open of the digitizer fd, PRE-DROP.**
- `src/main.rs:350` — `privdrop_to_nobody()`. The fd is held inside
  the `Libinput` context across the drop.

**Gap 1 (closed by ADR-036)**: the digitizer fd was NOT in
`RequiredFds`/`self_check` (`src/service.rs:71-75` had only
drm/uinput/backlight). ADR-036 adds `digitizer: Option<RawFd>` to
`RequiredFds`; `self_check` probes it; `main.rs` records
`required_fds.digitizer` from `input.seat_touchbar_raw_fd()` after
`init()` succeeds, before the privdrop.

**Gap 2 (closed by ADR-036)**: `is_digitizer` in `poll()`
(`src/providers/input.rs:84-95`) opened the evdev path a SECOND time
read-only (`read_abs_mt_maxima`, `input.rs:106-128`) to issue
`EVIOCGABS` ioctls. This second open was POST-DROP and would EACCES
under NF-020-A (nobody ∉ input, no ACL on `seat-touchbar`), so
`is_digitizer` would return `false` for every device and
`self.digitizer` would stay `None` forever — a silent limp (no touch
events). ADR-036 adds `identify_digitizer` which runs the geometry
probe DURING `init()` (pre-drop, root), opens the evdev fd read-only,
and HOLDS it for `poll()`'s `is_digitizer` to reuse (no post-drop
open). `read_abs_mt_maxima` accepts an optional held fd.

**Stage-3/Stage-4 impact (CLAIM, not verdict — not run yet):**
- EAGER post-drop open → crash Stage 3 at startup.
- LAZY post-drop open → block Stage 4 (first touch dropped).
- Either way, nobody CANNOT open the digitizer post-drop (NF-020-A
  proof: no ACL materializes on `seat-touchbar`; nobody ∉ `input`).
- ADR-036 makes the identification pre-drop + the fd held + the
  self-check cover it → a missing/unusable digitizer fd is a typed
  `PostDropFdCheck` failure (exit 1), never a silent limp.

## ADR-036 — digitizer input fd pre-drop (code)

**CLAIMS:**
- `RequiredFds` now has a `digitizer: Option<RawFd>` field;
  `self_check` probes it with `fcntl(F_GETFL)` like the other three.
  (`src/service.rs`)
- `LibinputProvider::identify_digitizer` runs the ABS_MT geometry
  probe DURING `init()` (pre-drop), opens the evdev fd read-only,
  and HOLDS it. `is_digitizer` in `poll()` reuses the held fd (no
  post-drop open). (`src/providers/input.rs`)
- `read_abs_mt_maxima` accepts an optional held fd. (`src/providers/input.rs`)
- `LibinputProvider::seat_touchbar_raw_fd()` exposes the seat-touchbar
  libinput context fd for the self-check. (`src/providers/input.rs`)
- New `HwError::InputInit` variant for the typed init failure.
  (`src/providers/error.rs`)
- `main.rs` SERVICE arm: `input.init()` failure is a startup failure
  (exit 1); bare `tbard` preserves the `warn!` behavior.
  `required_fds.digitizer` recorded after `init()` succeeds, before
  the privdrop. (`src/main.rs`)
- `--dry-run` uses `SimInputProvider` (unchanged, hermetic). The sim
  tests stay green.

**TESTS (CLAIM — verified locally, not by an independent audit):**
- Two new `src/service.rs` tests:
  `test_post_drop_self_check_missing_digitizer_fd` (None digitizer ⇒
  `PostDropFdCheck { fd: "digitizer" }`) +
  `test_post_drop_self_check_bad_digitizer_fd` (invalid digitizer fd
  ⇒ `PostDropFdCheck { fd: "digitizer" }` with `fcntl` in the detail).
- Existing `src/service.rs` tests updated to include the new
  `digitizer` field.
- 57 → 59 tests, all green. `cargo clippy --all-targets` clean.
  `scripts/check-invariants.sh` PASS (the ADR 009 name-string guard
  caught my first draft's "Touch Bar digitizer" error message —
  reworded to "digitizer").

**NOT CLAIMED (validation deferred to QA v6 / Stage 3):**
- The real privdrop path (root → nobody) with the digitizer fd. The
  sim/sandbox session does NOT exercise the real privdrop (no root).
  The `identify_digitizer` geometry probe against the real Touch Bar
  digitizer is validated in QA v6 (sudo) + Stage 3.
- The `seat_touchbar_raw_fd()` fd is the libinput context's fd, which
  libinput holds open for the seat-touchbar devices. The claim that
  this is the right fd for the self-check is a code-reading claim, not
  a runtime-verified claim.

## ADR-037 — NF-020-A seat/uaccess adjudication (docs + rule + README)

**CLAIMS:**
- The trade-off table (4 options) in `docs/adr/037-…md` is an honest
  representation of the `ID_SEAT=seat-touchbar` vs. `TAG+="uaccess"`
  conflict, grounded in the session 020 evidence
  (`docs/test-logs/020/udev-migration.log` §H).
- RECOMMENDED = Option B (keep the isolation, annotate the dead
  `uaccess` tag). The `TAG+="uaccess"` line in
  `packaging/udev/69-touchbar-seat.rules` is annotated with a comment
  explaining NF-020-A (the tag is dead — the uaccess builtin no-ops
  because `ID_SEAT=seat-touchbar` moves the device off the active
  session's seat and there is no `seat-touchbar` in logind). The line
  is KEPT (not removed) as a marker for the future custom-seat option.
- `packaging/README.md` documents the dead uaccess tag, the production
  access path (ADR 036 + ADR 010: root opens the digitizer fd
  pre-drop, privdrops, verifies post-drop), and the dev-access
  alternatives (`input` group default, static ACL, custom-seat logind
  session future).
- The proven root+privdrop recipe (ADR 010) is NOT reopened.

**NOT CLAIMED:**
- That the `input` group is a safe dev-access path for all machines
  (it is the long-standing bench lane on THIS machine; other machines
  may differ). The custom-seat logind session option is listed as
  future, not implemented.

## ADR-038 — install integrity (PKGBUILD repair + process rule)

**CLAIMS:**
- `packaging/PKGBUILD` is repaired: `pkgver=0.2.0`; `source=()`
  matches the repo layout; `build()`/`package()` cd to the repo root
  and reference the files at their repo paths; new `check()` runs the
  R1 behavioral audit (`strings --service` > 0 + unprivileged
  `--service` → exit 1 with the ADR-034 message + a timeout). `bash
  -n` re-validated.
- The `check()` logic was verified against `target/release/tbard`
  (strings count = 6; exit 1 with the ADR-034 message) — but NOT
  against a real `makepkg -si` run (the sim/sandbox session does not
  run makepkg; that is a target-machine / Stage-3 action).
- ADR-038 D2 is the PROCESS RULE: deployment/install sessions build
  from the verified tagged HEAD and verify binary identity
  behaviorally + `sha256` BEFORE and AFTER install. Evidence: NF-020-B
  (every repo gate was green; only the R1 behavioral check caught the
  stale binary).
- The rebuild evidence (`docs/test-logs/021/rebuild-evidence.log`) is
  a verbatim archive of the human's rebuild + re-verify session
  outside a code session (FREEZE RULE D10). It closes the NF-020-B
  binary-half (the installed `/usr/bin/tbard` is now a v0.2.0 build
  that accepts `--service` and fast-fails correctly).

**NOT CLAIMED:**
- That a future install session will follow ADR-038 D2. The process
  rule is a documented rule, not an enforced gate. An independent
  audit should verify the next install session's evidence matches the
  rule.
- That the PKGBUILD `check()` will pass on a target-machine `makepkg`
  run (it was verified against the in-tree binary, not a makepkg
  chroot).

## Test counts reconciled (57 + 2 = 59)

- Baseline (v0.2.0 `f853a65`): 57 tests (54 unit + 1 `exit_code` + 1
  `service_root_guard` + 1 `sigterm_master_release`). Verified at
  branch start: `cargo test` → 54 + 1 + 1 + 1 = 57, all green.
- ADR-036: +2 (`test_post_drop_self_check_missing_digitizer_fd` +
  `test_post_drop_self_check_bad_digitizer_fd` in `src/service.rs`).
- ADR-037: +0 (docs-only + rule annotation + packaging doc).
- ADR-038: +0 (PKGBUILD repair + docs; the `check()` is a makepkg
  check, not a `cargo test`).
- Final: 59 tests, all green after every commit. `cargo clippy
  --all-targets` clean. `scripts/check-invariants.sh` PASS.
  `bash -n packaging/PKGBUILD` OK.

## Standing caveat (claims, not verdicts)

This self-assessment is a CLAIM from the implementer. The ADR-036
digitizer-fd pre-drop change is a CODE change with tests; the
ADR-037/038 changes are docs + packaging. The Stage-3/Stage-4 impact
statements are claims from reading the code, not from running Stage 3/4.
The real privdrop path with the digitizer fd, the `identify_digitizer`
geometry probe against the real Touch Bar digitizer, the `makepkg -si`
run with the repaired PKGBUILD's `check()`, and the next install
session's adherence to ADR-038 D2 are all deferred to QA v6 / Stage 3 /
an independent live audit. Treat READY-FOR-RE-VERIFICATION as a claim
that the branch is in a state WORTH re-verifying, not a verdict that it
passes.