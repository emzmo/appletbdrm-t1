# QA v9 — Focused Re-Verification of fix/digitizer-identity-adr-041 (ADR-041)

**Session**: 031, **Date**: 2026-09-26
**Role**: QA & reliability engineer (focused re-verification, v9).
**Branch**: `fix/digitizer-identity-adr-041` off `master` `a7a461b` (== v0.2.2).
**Scope**: ADR-041 + Task 0 derivations (D1/D2/D3) only. ADR-042 NOT
triggered — this report verifies that decision.
**FREEZE**: no source changes (the branch is read-only for QA; all
mutations were on a throwaway `/tmp/opencode/touchbar-adv` copy, deleted).
**HOST SAFETY RULES** binding; the oracle (`tiny-dfr-mbp142.service`)
stayed untouched and lit throughout; no service lifecycle actions; no
`/etc` writes; no `udevadm trigger`. Audit D confirms.

**Commits under test**: `8b5b788` (docs: session 029) → `7836041`
(ADR-041: structural predicate + --probe-input) → `bd36962` (docs:
session 030 closure). HEAD = `bd36962`.

**The report is a CLAIM; the live audits are VERDICTS.** The
self-assessment-10 (`docs/self-assessment-10.md`) is the implementer's
CLAIM; every claim below was re-derived from the diffs and adjudicated
against live execution. New findings → ADR proposals, logged not
implemented per FREEZE.

---

## Per-claim verdicts

### Claim 1 — D1 ordering: service-arm step order — **VERIFIED (with annotation gap)**

Re-derived from `src/main.rs` (HEAD, post-ADR-041 — the probe-input arm
shifted the service-arm line numbers DOWN from the ADR's citations,
which match the pre-fix tree `a7a461b`). The ORDER is unchanged and
correct:

| Step | ADR-041 D1 cite (a7a461b) | HEAD `bd36962` cite | What |
|------|---------------------------|---------------------|------|
| 1. root guard | main.rs:202-208 | main.rs:256-262 | `opts.service && geteuid()!=0` → fast-fail |
| 2. privdrop target resolution | main.rs:226-242 | main.rs:280-296 | `resolve_privdrop_target()` → `Option<PrivDropTarget>` |
| 3. DRM acquire | main.rs:252-273 | main.rs:306-327 | `prov.acquire()` → `drm` |
| 4. tb_dims derivation | main.rs:276-279 | main.rs:330-333 | `drm.display_info().map(...).unwrap_or((60,2170))` |
| 5. digitizer identify | main.rs:280-294 | main.rs:334-348 | `LibinputProvider::new(tb_dims)` + `input.init()` |
| 6. backlight select+fd open | main.rs:295-302 / 379-391 | main.rs:349-356 / 433-445 | `SysfsBacklight::new` + `open_backlight_brightness_fd_pre_drop` |
| 7. pre-drop fd assembly | main.rs:338-372 | main.rs:392-445 | `required_fds` (uinput :411, drm :417, digitizer :426, backlight :435) |
| 8. privdrop | main.rs:405-411 | main.rs:459-465 | `privdrop_to_nobody_with_target(privdrop_target.expect(...))` |
| 9. post-drop self-check | main.rs:417-421 | main.rs:471-475 | `required_fds.self_check()` |
| 10. render loop | main.rs:424-433 | main.rs:478-487 | `real_main(...)` |

The ADR-041 D1 line citations match the `a7a461b` baseline (verified by
`git show a7a461b:src/main.rs`); the probe-input arm (main.rs:152-184
at HEAD) inserted ~54 lines above the service arm, shifting every
service-arm line down. The ORDERING derivation is accurate; the line
citations are baseline-accurate (the ADR was derived against the
pre-fix tree, which is the correct tree for a "what was wrong / what
must change" derivation).

**ANNOTATION GAP (Claim 1 second clause): NOT CONFIRMED — new finding
D-031-1.** The task requires confirming the session-029 evidence is
ANNOTATED as mechanism-wrong (acquire DID run; RAII released;
acceptance-1 live-verified 6×), same annotate-never-rewrite discipline
as D-027-1. Inspected `docs/test-logs/029/step3-diagnosis.txt` lines
12-17:

> tbard fails at `identify_digitizer` (src/providers/input.rs:181-190)
> BEFORE reaching privdrop (ADR-039) or DRM master acquire. The Touch
> Bar card stayed empty in debugfs throughout — tbard never became
> master.

This asserts the acquire NEVER ran as a PLAIN FACT, with NO erratum
header or annotation marking it mechanism-wrong. The ADR-041 D1 text
(lines 62-69) DOES reconcile it ("the DRM acquire SUCCEEDED... the `drm`
value dropped via RAII `Drop`... acceptance-1's live status: the DRM
acquire DID run and DID release via RAII") — but the EVIDENCE FILE
ITSELF is unannotated. This contrasts with D-027-1, which DID add an
erratum header to `docs/test-logs/025/STEP3-first-start-failure.txt`
(lines 2-21: "> D-027-1 ERRATUM (session 028, 2026-09-26; docs-only
correction; ..."). The session-029 evidence has no such erratum.

The "acceptance-1 live-verified 6×" framing maps to QA v8's "All six
claims VERIFIED by live re-execution" (`docs/review-report-v8.md:249`)
— the ADR-039 ordering test ROOT branch run live. The session-029
evidence does not credit this either.

**Verdict**: the ordering derivation is VERIFIED (the code order is
correct and the ADR's reconciliation of the mechanism is sound). The
ANNOTATION discipline is NOT confirmed — the session-029 evidence file
is unannotated, unlike D-027-1's session-025 erratum. Filed as **new
finding D-031-1** (docs-only): annotate `docs/test-logs/029/step3-diagnosis.txt`
with an erratum header noting the "tbard never became master / BEFORE
DRM master acquire" claim was mechanism-wrong (the acquire DID run at
step 3 and released via RAII Drop at the step-5 failure, per ADR-041
D1; the debugfs-empty observation was the RAII cleanup, not
never-acquired), and credit acceptance-1's live-verified status. Logged
NOT implemented per FREEZE.

### Claim 2 — D2 predicate: `is_touchbar_digitizer` structural — **VERIFIED**

`src/geometry.rs:163-199` (the predicate function body):
- **STRUCTURAL only**: `grep "32767\|127\|2170\|60"` on lines 163-199
  returns NO matches (exit 1). The only constants are
  `STRIP_RATIO_MIN: i32 = 10` (geometry.rs:133) and
  `STRIP_AXIS_MIN: i32 = 2` (geometry.rs:138). `STRIP_RATIO_MIN=10` is
  scale-free (iBridge 32767/127 ratio ≈ 258; trackpad 1280/800 ≈ 1.6;
  square 1024/768 ≈ 1.3 — 10 separates strip from non-strip without
  naming a panel dimension). The ADR's "structural constant, not a
  hardware magic number" justification holds.
- **iBridge association clause** (geometry.rs:176-178):
  `if !candidate.is_ibridge_associated { return false }`. The
  `is_ibridge_associated` builder (`src/providers/input.rs:372-422`)
  implements the ADR's OR: `ID_SEAT == "seat-touchbar"` (fast path,
  input.rs:387-393) OR sysfs ancestry contains a `usb` subsystem node
  with `idVendor=05ac` + `idProduct=8600` (fallback, input.rs:395-420).
  Both paths verified live (Audit B: event7 has `ID_SEAT=seat-touchbar`
  via the installed `69-touchbar-seat.rules` AND sysfs ancestry
  `.../usb1/1-3` with `ATTRS{idVendor}=="05ac" ATTRS{idProduct}=="8600"`
  — either clause alone satisfies the predicate).
- **Resolution present/absent handling** (geometry.rs:182-197): when
  BOTH `abs_mt_x_resolution` and `abs_mt_y_resolution` are non-zero,
  the resolution long/short ratio must be ≥ STRIP_RATIO_MIN with the
  SAME long/short orientation as the ranges (rejects a strip range with
  a square resolution, and a strip-X range with a strip-Y resolution).
  When EITHER resolution is 0 (the iBridge reports 0 for both), the
  check is SKIPPED — the range strip check (geometry.rs:172-175)
  carries it. Absence-tolerant, per the ADR.

**Rejection tests assert false (non-vacuous)** — spot-checked:
- **square fixture** (`test_predicate_rejects_square_decoy`,
  geometry.rs:330-336): `strip_candidate(1024, 768)` →
  `assert!(!is_touchbar_digitizer(&c))`. 1024/768 = 1 (integer
  division) < 10 → rejected. NON-VACUOUS (the assert can fail).
- **trackpad fixture** (`test_predicate_rejects_trackpad`,
  geometry.rs:341-347): `strip_candidate(1280, 800)` →
  `assert!(!is_touchbar_digitizer(&c))`. 1280/800 = 1 < 10 → rejected.
  NON-VACUOUS.
- Also non-vacuous: non-multitouch (352-365), non-iBridge (371-378),
  square-resolution (403-416), orientation-mismatch (422-436),
  zero-axis (459-465). All assert `false` and CAN fail.

**Accept tests**: real iBridge 32767/127 (geometry.rs:298-311, both
orientations) + sim 2170/60 (316-325, both orientations) + resolution-
present strip (385-398) + resolution-absent fallback (444-454) +
equivalence single-source-of-truth (478-490). All green in `cargo test`.

**Code grep for forbidden numerals outside fixtures**: occurrences of
32767/127/2170/60 in `src/geometry.rs` are ALL in the test module
(lines 209-231 are the pre-existing ADR-020 paint-matrix tests; the
rest are test-input literals in `strip_candidate`/`DigitizerCandidate`
construction). The predicate body (163-199) is clean. In
`src/providers/input.rs`, the only "2170/60"-class literal is the
probe's `tb_dims` fallback `(60, 2170)` passed to
`LibinputProvider::new` at main.rs:166 — which the ADR explicitly notes
is UNUSED by the structural predicate (the predicate is scale-free;
`tb_dims` is carried for the `is_digitizer` post-drop re-check path
that no longer consults it).

**Verdict**: VERIFIED. The predicate is structural, scale-free,
model-invariant, with the iBridge-association clause and
resolution-aspect handling exactly as the ADR specifies. Rejection
tests are non-vacuous.

### Claim 3 — D3 / ADR-042 non-trigger — **VERIFIED**

- **Our `udev_assign_seat("seat-touchbar")`** (`src/providers/input.rs:75`,
  per the ADR; the line is inside `LibinputProvider::new`) == **oracle's**
  (`backup_old/tiny-dfr-mbp142/src/main.rs:901`,
   `input_tb.udev_assign_seat("seat-touchbar").unwrap();`). Verified
  byte-for-byte: both use `Libinput::new_with_udev(Interface)` +
  `udev_assign_seat("seat-touchbar")`. The oracle's
  `input_main.udev_assign_seat("seat0")` at line 902 also matches our
  `main_input.udev_assign_seat("seat0")` at input.rs:76.
- **Oracle name-string path cited correctly**: oracle
  `main.rs:1036` (`for event in &mut input_tb.clone().chain(input_main.clone())`)
  + `main.rs:1043-1044` (`if dev.name().contains(" Touch Bar") || dev.name().contains("iBridge Touchpad")`).
  Verified by `grep -n` on `backup_old/tiny-dfr-mbp142/src/main.rs`:
  exact line hits at 1036, 1043, 1044. The oracle finds the digitizer
  by NAME in the chained seat-touchbar+seat0 iteration, which is why it
  works even when the seat-touchbar context is empty (the session-029
  bench state).
- **ADR-042 documented as not-triggered**: ADR-041 D3 (lines 130-160)
  + Alternatives (line 174: "ADR-042 (custom seat). NOT triggered — D3
  shows our seat mechanism is identical to the oracle's, which receives
  touches. The blocker is the predicate, not the seat."). The
  citations (899-902, 1036, 1043-1044) are in the ADR text (D3 section).

**Bench-state evolution (data, not a defect)**: since session-029, the
`69-touchbar-seat.rules` is now installed in
`/usr/lib/udev/rules.d/` and triggered — event7 NOW carries
`ID_SEAT=seat-touchbar` (Audit B / `udevadm info`). This is a CHANGE
from session-029's "no /dev/input device carries ID_SEAT=" observation
but does NOT trigger ADR-042: the seat mechanism is unchanged (ours ==
oracle's); the tag is now applied by the installed rule, so the
seat-touchbar context WILL enumerate event7 on a Stage-3 run. The
ADR-042 non-trigger decision is if anything STRONGER now (the tag is
applied; the mechanism is proven by the oracle AND by the probe's
ID_SEAT fast path succeeding). The ADR's caveat ("If a future Stage-3
run finds the seat-touchbar context empty AFTER the predicate is fixed
AND the 69-touchbar-seat.rules is installed + udevadm trigger-ed, THAT
would be a new ADR") is not engaged: the rule IS installed + triggered,
and the probe ACCEPTed event7.

**Verdict**: VERIFIED. ADR-042 is correctly NOT triggered. The seat
mechanism is identical to the oracle's; the oracle receives touches;
the blocker was the predicate (now fixed). Citations accurate.

### Claim 4 — Probe + preflight unification — **VERIFIED with W12 (expected) + new finding D-031-2**

- **`--probe-input` read-only, exit 0/1**: `src/main.rs:152-184` (the
  `if opts.probe_input { ... }` arm) constructs a `LibinputProvider`
  with the `(60, 2170)` fallback `tb_dims` (unused by the structural
  predicate) and calls `input.probe_digitizer()`
  (`src/providers/input.rs:218-289`). The probe: dispatches the
  seat-touchbar libinput context, iterates devices, prints
  per-candidate diagnostics (evdev path, ABS_MT maxima, resolutions,
  iBridge flag, predicate verdict), exits 0 if a digitizer was
  identified (`Ok(Some(_))` → main.rs:172-176), 1 otherwise
  (`Ok(None)` → main.rs:177-181; `Err` → main.rs:182-185). NO DRM
  master acquire, NO privdrop, NO uinput/backlight opens — confirmed
  by Audit D (the touchbar card's client table was unchanged across
  the probe run; the oracle stayed sole master). Read-only: VERIFIED.
- **Preflight STEP 0d invokes `/usr/bin/tbard --probe-input`**:
  `scripts/bench/interlock-preflight.sh:103-130` (the rewritten 0d
  block). Calls `/usr/bin/tbard --probe-input`, captures output +
  exit, prints it inline, PASS on exit 0, FAIL+STATUS=1 on non-zero.
  `bash -n` passes. **W12**: the installed `/usr/bin/tbard` predates
  ADR-041 (lacks `--probe-input`) → exit 2 → 0d FAIL → overall NO-GO
  (Audit C verbatim). This is the reinstall precondition, NOT a
  defect — the branch build's probe (`./target/debug/tbard
  --probe-input`) ACCEPTed event7 (Audit B). After `makepkg -si`
  (reinstall from this branch's tip), 0d will PASS.
- **Equivalence — single source of truth**: both
  `identify_digitizer`/`is_digitizer` (`src/providers/input.rs:130,194`)
  and `probe_digitizer` (`src/providers/input.rs:280`) call
  `crate::geometry::is_touchbar_digitizer(&candidate)` — the SAME
  predicate function. Verified by `grep`. The
  `test_predicate_is_single_source_of_truth` test (geometry.rs:478-490)
  asserts the predicate's identity (feeds the same candidate to the
  public function and confirms the verdict).
- **check-invariants guards**: `scripts/check-invariants.sh` guard #7
  (lines 117-145): (a) `grep -qE 'geometry::is_touchbar_digitizer'
  src/providers/input.rs` (must call the predicate); (b) `grep -rnE
  'fn geometry_matches_tb' src/` (no second predicate re-introduced);
  (c) `grep -qE 'pub fn is_touchbar_digitizer' src/geometry.rs`
  (predicate lives in geometry.rs).

**ADVERSARIAL (throwaway copy, deleted after — `docs/test-logs/031/adversarial-invariants.log` verbatim)**:
- **(a) re-add a `geometry_matches_tb` reimplementation** →
  `check-invariants.sh` FAIL (exit 1, "re-introduced fn
  geometry_matches_tb"). **CONFIRMED** — guard #7b catches it.
- **(b) point input.rs at a local copy** (replace all 3 real call sites
  `crate::geometry::is_touchbar_digitizer(&candidate)` with
  `local_is_touchbar_digitizer(&candidate)`, leave the doc comments
  mentioning `geometry::is_touchbar_digitizer` untouched) →
  `check-invariants.sh` PASS (exit 0). **REFUTED — guard weakness**.
  Guard #7a (`grep -qE 'geometry::is_touchbar_digitizer'
  src/providers/input.rs`) is NOT scoped to code lines: it matches the
  `//` and `///` comments (lines 113, 230, 534) that mention the
  predicate, so replacing ALL real call sites with a local predicate
  while leaving the comments untouched SATISFIES the guard. When the
  comments were ALSO scrubbed (`geometry::is_touchbar_digitizer` →
  `geometry::REMOVED_predicate`), the guard correctly FAILed —
  confirming the weakness is specifically the comment-only mentions.
  The other guards in the same script (#1, #2, #5, #6) DO scope to
  code lines via `grep -vE '^[0-9]+:\s*//'`; guard #7 omits this
  filter. This is the same class of lesson as ADR-031/NF-5 (grep
  guards must be code-scoped or they are theatrical).

**Verdict**: VERIFIED with caveats. The probe is read-only + exit
0/1 (Audit B live); the preflight unification is correct (W12 expected
stale-binary FAIL, reinstall precondition); the equivalence is
structural. The adversarial (a) confirms guard #7b; the adversarial
(b) REFUTES guard #7a's strength → **new finding D-031-2** (ADR
proposal: scope guard #7a to code lines, or require a real CALL site
`is_touchbar_digitizer(`). Logged NOT implemented per FREEZE.

---

## W12/W13 adjudications

### W12 — installed-binary delta (stale `/usr/bin/tbard`) — **CONFIRMED, expected, reinstall precondition**

- `/usr/bin/tbard --probe-input` → exit 2 "unknown argument
  '--probe-input'" + old usage (Audit C verbatim). The installed
  binary predates ADR-041.
- `interlock-preflight.sh` STEP 0d → FAIL (exit 2) → overall NO-GO
  (Audit C verbatim). STEP 2/3 also FAIL (oracle active — correct,
  HOST SAFETY).
- This is the NF-020-B stale-binary class (ADR-038): repo gates green,
  installed binary stale. The failure mode is LOUD (exit 2 + usage),
  not silent — the preflight cannot falsely PASS 0d with a stale
  binary. The branch build's probe ACCEPTed event7 (Audit B).
- **Reinstall precondition**: `makepkg -si` from this branch's tip,
  then verify `strings /usr/bin/tbard | grep -c -- --probe-input` ≥ 1
  (the NEW behavioral check self-assessment-10 C6 flags as a preflight
  follow-up — see D-031-3 below). After reinstall, 0d will PASS.
- NOT a defect in the branch. The branch is CLEARED; the reinstall is
  a deployment step.

### W13 — hermetic dry-run smoke — **CANNOT-EXECUTE-HERE (environmental, NOT a regression; sim path unaffected by ADR-041)**

- `HOME=$(mktemp -d) timeout 25 ./target/debug/tbard --dry-run` →
  `[ERROR tbard] tbard: dry-run SimDisplay acquire failed: Permission
  denied (os error 13)` / exit 1 (Audit A verbatim).
- **Reason**: the dry-run opens a vkms DRM card (`find_vkms_card` →
  `/dev/dri/card0`, driver=vkms) and calls `acquire_master_lock()`.
  On this bench Hyprland + systemd-logind ALREADY HOLD DRM master on
  card0 (`sudo cat /sys/kernel/debug/dri/0/clients` → both `master=y`).
  `acquire_master_lock()` on an already-mastered card returns
  EACCES/EPERM. This is the SAME documented environmental constraint
  recorded in QA v5-5 (line 183-185) and v6-5 (line 376-377, 636-643):
  "the 3 master-gated tests CANNOT execute here (Hyprland holds vkms
  master)".
- **NOT a regression, NOT an ADR-041 issue**: the failure is at
  SimDisplay acquire (display), BEFORE input init. ADR-041 changed the
  input identification predicate, not the display acquire path. The
  dry-run would fail identically on `a7a461b` (v0.2.2) in this bench
  class.
- **W13's core question — does the SIM path still identify/enumerate
  its uinput digitizer under the new predicate?**: the SIM path does
  NOT run the structural predicate AT ALL, by design.
  `SimInputProvider::new` (`src/providers/sim_input.rs:103-105`)
  creates its own uinput device (vendor=0x1209, product=0x316E — NOT
  05ac:8600) and matches it by evdev path (`dev_node == my_path`) in
  `poll()` (sim_input.rs:255-260), NOT via `is_touchbar_digitizer`.
  The ADR-041 equivalence claim is scoped to the REAL identification
  path (runtime `identify_digitizer` + `--probe-input`), NOT the sim.
  The ADR itself acknowledges this (line 20: "the sim, which bypasses
  the gate"; line 107: "the ADR-024 scale test exercises the scale,
  not the gate"). The task's W13 framing ("if the sim digitizer is
  REJECTED by the predicate (iBridge association unsatisfiable for
  uinput), that is a REGRESSION") is moot for the sim path because the
  sim never runs the predicate. No REGRESSION.
- The render/tap/SIGTERM sub-checks are NOT reachable (the dry-run
  fails at display acquire before input init). The `cargo test` suite
  DOES exercise the sim path where master is available: 70 unit tests
  pass, including `test_sim_input_creates_uinput_device` +
  `test_sim_input_scales_real_abs_range_to_logical` (both green),
  confirming the sim path itself is functional. The render loop is
  exercised by the integration tests + the sim-input tests.
- Recording CANNOT-EXECUTE-HERE per the v5-5/v6-5 precedent. To
  execute W13 fully, one would need to free vkms master (stop Hyprland
  — a service lifecycle action on a non-oracle service the interlock
  does not cover → violates HOST SAFETY) or run under sudo on a free
  VT (ADR-010 path b). Neither is in scope for a read-only QA session
  with the oracle lit.

---

## Live audits A–D (verbatim summaries; full logs in `docs/test-logs/031/`)

### Audit A — W13 dry-run smoke — **CANNOT-EXECUTE-HERE** (see W13 above)
Full log: `docs/test-logs/031/audit-A-dryrun.log`.
`HOME=$(mktemp -d) timeout 25 ./target/debug/tbard --dry-run` →
`SimDisplay acquire failed: Permission denied (os error 13)` / exit 1.
Hyprland holds vkms master on card0. Environmental, NOT a regression.
Sim path does not run the predicate (no REGRESSION possible).

### Audit B — `./target/debug/tbard --probe-input` — **PASS**
Full log: `docs/test-logs/031/audit-B-probe.log`.
```
probe: candidate /dev/input/event7 (sysname=event7) → ABS_MT X max=32767 Y max=127 res=(0,0) iBridge=true
   predicate verdict: ACCEPT
probe-input: digitizer IDENTIFIED (exit 0)
PROBE_EXIT=0
```
event7 ACCEPTED (X 32767 / Y 127, res=(0,0), iBridge=true), exit 0.
The session-029 blocker device is now ACCEPTED by the structural
predicate — the CODE fix is verified read-only on the real device.
iBridge=true via ID_SEAT=seat-touchbar fast path (rule now installed +
triggered) AND/OR sysfs ancestry fallback (parent usb1/1-3 has
idVendor=05ac + idProduct=8600). Oracle sole master throughout (Audit D).

### Audit C — installed binary + preflight — **W12 CONFIRMED (expected NO-GO)**
Full log: `docs/test-logs/031/audit-C-installed-preflight.log`.
- `/usr/bin/tbard --probe-input` → exit 2 "unknown argument
  '--probe-input'" + old usage (stale binary predates ADR-041).
- `interlock-preflight.sh` → STEP 0d FAIL (exit 2) → overall NO-GO.
  STEP 0a/0b/0c/0e/0f PASS; STEP 2/3 FAIL (oracle active — correct).
- Reinstall precondition, NOT a defect. After `makepkg -si` from this
  branch's tip, 0d will PASS (branch probe ACCEPTed event7).

### Audit D — host state — **PASS**
Full log: `docs/test-logs/031/audit-D-host-state.log`.
- **dri/2 (touchbar card) clients, START**: `tiny-dfr-mbp142 tgid=105638
  uid=65534 master=y` — oracle sole master.
- **dri/2 clients, END**: IDENTICAL (`tiny-dfr-mbp142 tgid=105638
  uid=65534 master=y`) — no tbard process acquired master; the probe is
  read-only (no DRM master acquire).
- **/dev/input count**: 18 (start) → 18 (end). Unchanged.
- **/etc**: no writes (no systemctl enable/disable/start/stop for tbard
  or the oracle; no udevadm trigger; no makepkg/install; mtimes stable).
- Oracle stayed lit throughout. HOST SAFETY RULES respected.

---

## Gates (verbatim)

Full log: `docs/test-logs/031/gates-verbatim.log`. All GREEN:
- `cargo fmt --check` — exit 0 (no output).
- `cargo build --bin tbard` — exit 0 (`Finished dev profile`).
- `cargo clippy --all-targets -- -D warnings` — exit 0.
- `cargo test` — exit 0. **70 unit + 4 integration = 74 PASS**
  (matches the ADR-041 commit message claim; was 66 pre-ADR-041, +8 new
  geometry predicate tests).
- `scripts/check-invariants.sh` — `check-invariants: PASS` (exit 0).
- `scripts/ci-gate.sh` — `CI gate: PASS` (exit 0; runs fmt + build +
  clippy + check-invariants).
- `bash -n scripts/bench/interlock-preflight.sh` — exit 0.
- `bash -n packaging/PKGBUILD` — exit 0.
- **Commit hygiene**: `8b5b788` (docs: session 029) → `7836041`
  (ADR-041 + code, atomic) → `bd36962` (docs: session 030). ADR-before-
  code satisfied by the atomic ADR+code commit (matches the ADR-039
  precedent, commit `e8b83f0`).

---

## Adversarial invariant tests (verbatim summary)

Full log: `docs/test-logs/031/adversarial-invariants.log`. Throwaway
copy at `/tmp/opencode/touchbar-adv`, deleted after. No working-repo
source changes (FREEZE respected).
- **(a) re-add `fn geometry_matches_tb` in src/geometry.rs** →
  `check-invariants.sh` FAIL (exit 1, guard #7b fires). **CONFIRMED**.
- **(b) replace all 3 real call sites in input.rs with
  `local_is_touchbar_digitizer`, leave doc comments untouched** →
  `check-invariants.sh` PASS (exit 0). **REFUTED — guard #7a
  weakness** (comment-only mentions satisfy the grep). New finding
  D-031-2.
- **(b2) scrub the comments too** → `check-invariants.sh` FAIL
  (exit 1). Confirms the weakness is the comment-only mentions.

---

## New findings (ADR proposals, logged NOT implemented per FREEZE)

- **D-031-1 (docs)**: annotate `docs/test-logs/029/step3-diagnosis.txt`
  with an erratum header (same discipline as D-027-1's session-025
  erratum) noting the "tbard never became master / BEFORE DRM master
  acquire" claim (lines 12-17) was mechanism-wrong — the DRM acquire
  DID run at service-arm step 3 and released via RAII Drop at the
  step-5 (identify_digitizer) failure, per ADR-041 D1; the
  debugfs-empty observation was the RAII cleanup, not never-acquired.
  Credit acceptance-1's live-verified status (QA v8: six claims
  live-verified). Action: annotate in the next docs commit.
- **D-031-2 (guard strength)**: `scripts/check-invariants.sh` guard #7a
  (`grep -qE 'geometry::is_touchbar_digitizer'
  src/providers/input.rs`) is not scoped to code lines — it matches
  `//` and `///` comments. A regression that replaces all real call
  sites with a local predicate while leaving the doc comments
  untouched would PASS the invariant. The other guards in the same
  script (#1, #2, #5, #6) DO scope to code lines via
  `grep -vE '^[0-9]+:\s*//'`; guard #7 omits this filter. Same class
  as ADR-031/NF-5. ADR proposal: scope guard #7a to code lines (exclude
  `//` and `///`), OR strengthen to require ≥1 real CALL site
  (`is_touchbar_digitizer(` with a non-comment preceding context).
- **D-031-3 (preflight guard)**: the preflight STEP 0e checks
  `strings /usr/bin/tbard | grep -c -- --service` ≥ 1 (ADR-038
  stale-binary guard) but does NOT check `--probe-input`. A stale
  binary predating ADR-041 fails 0d LOUDLY (exit 2 "unknown argument"
  — Audit C), so the failure mode is safe; but a dedicated 0e-sub-check
  `strings /usr/bin/tbard | grep -c -- --probe-input` ≥ 1 would make
  the stale-binary class explicit at 0e rather than surfacing at 0d.
  Flagged in self-assessment-10 C6. ADR proposal: add the
  `--probe-input` strings check to preflight 0e.

All three are DOCS/TOOLING findings (no source semantics changed); all
are logged NOT implemented per FREEZE.

---

## What remains Stage-3/4 acceptance (NOT this session)

Stated explicitly, per the task's requirement:
- **Real privdrop live**: the service-arm first start under the
  interlock — root guard → privdrop target resolution → DRM acquire →
  tb_dims → digitizer identify (now with the structural predicate) →
  backlight → pre-drop fd assembly → `privdrop_to_nobody_with_target`
  → post-drop self-check → render loop. The `--probe-input` live run
  (Audit B) verified the IDENTIFICATION step read-only; the full
  service-arm first start (with the real privdrop) is Stage-3
  acceptance.
- **Render**: the render loop producing frames on the real touchbar
  card (DRM master acquire → dumb buffer → framebuffer → page render →
  dirtyfb). The dry-run smoke (Audit A) could not execute (Hyprland
  holds vkms master); the sim render path is exercised by `cargo test`
  (70 unit pass) but the REAL render on appletbdrm is Stage-3.
- **SIGTERM-from-loop**: clean SIGTERM exit from the render loop
  (ADR-022/025: SIGTERM-during-retry → exit 0; budget exhaustion →
  exit 1). The integration test `test_sigterm_releases_master` passes
  (green), but the real SIGTERM-from-loop under the interlock is
  Stage-3.
- **Backlight write**: the real `SysfsBacklight` brightness write via
  the pre-drop-held fd (post-drop nobody). The fd-open path is in
  `open_backlight_brightness_fd_pre_drop` (main.rs:433); the real
  write is Stage-3.
- **Real seat-tag enumeration**: the seat-touchbar libinput context
  enumerating event7 with `ID_SEAT=seat-touchbar` applied (the rule
  is now installed + triggered — Audit B confirmed the tag is present).
  The probe's ID_SEAT fast path succeeded read-only; the full
  runtime enumeration inside `identify_digitizer` (with the evdev fd
  held pre-drop) is Stage-3.

These are NOT claims of this report; they are the explicit Stage-3/4
acceptance surface that remains after this focused QA.

---

## Final paragraph

**CLEARED FOR MERGE + binary reinstall + Stage-3 re-run (attempt #3).**
All four claims VERIFIED by live re-execution + diff inspection: the
D1 service-arm ordering is accurate (the ADR's line citations match
the `a7a461b` baseline; the ORDER is preserved at HEAD with line
numbers shifted by the probe-input arm; the RAII-reconciliation of
session-029's "never became master" is sound — with the docs
annotation gap filed as D-031-1); the D2 structural predicate is
scale-free + model-invariant (no 32767/127/2170/60 in the predicate
body; STRIP_RATIO_MIN=10; iBridge-association ID_SEAT-OR-sysfs-
ancestry; resolution-aspect absence-tolerant; rejection tests
non-vacuous); the D3/ADR-042 non-trigger is correct (our seat
mechanism == oracle's, citations 899-902/1036/1043-1044 exact; the
69-touchbar-seat.rules is now installed + triggered, so event7 carries
ID_SEAT=seat-touchbar — the non-trigger decision is stronger than at
session-029); the probe + preflight unification is structural (probe
read-only exit 0/1 — Audit B ACCEPTed event7 live; preflight 0d calls
the installed probe; equivalence enforced by check-invariants guard
#7b + the equivalence test; W12 stale-binary FAIL is the expected
reinstall precondition). All repo gates green (fmt, build, clippy -D
warnings, test 74/74, check-invariants, ci-gate, bash -n preflight +
PKGBUILD). Adversarial (a) confirms guard #7b; adversarial (b) REFUTES
guard #7a's strength (comment-only mentions satisfy the grep) → new
finding D-031-2 (guard-strength ADR proposal). Host safety maintained
throughout (Audit D: oracle sole master on card2 at start AND end,
/dev/input 18→18, /etc untouched, no service lifecycle actions). The
dry-run smoke (W13) could not execute (Hyprland holds vkms master —
the v5-5/v6-5 environmental precedent; NOT a regression, NOT an
ADR-041 issue — the sim path does not run the predicate by design).
Three new findings logged NOT implemented per FREEZE: D-031-1
(annotate session-029 evidence, D-027-1 discipline), D-031-2 (scope
check-invariants guard #7a to code lines), D-031-3 (preflight 0e
`--probe-input` strings guard). The branch is CLEARED for merge; the
binary reinstall (`makepkg -si` from this branch's tip) is the
deployment step that resolves W12; the Stage-3 re-run (attempt #3)
is the live acceptance for the real privdrop + render + SIGTERM-from-
loop + backlight write + seat-tag enumeration surface that remains.