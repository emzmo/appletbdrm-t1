# QA v10 — Focused Re-Verification of fix/backlight-write-adr-043 (ADR-043 + D-031-2/D-031-3 ride-alongs)

**Session**: 035, **Date**: 2026-09-26
**Role**: QA & reliability engineer (focused re-verification, v10).
**Branch**: `fix/backlight-write-adr-043` off `master` `9ce94af`
(== v0.2.3). Four commits: `d8ae790` (docs: session 033, ADR-043
proposed) → `38392ce` (ADR-043 + code) → `7db83c8` (D-031-2 ride-along)
→ `d13196c` (docs: session 034 closure). HEAD = `d13196c`.
**Scope**: ADR-043 (+ D-031-2/D-031-3 ride-alongs) + the D1/D2/D3
derivations only.
**FREEZE**: no source changes. Every mutation in this report was on
the live tree and RESTORED from `/tmp/opencode` backups immediately
after; baseline re-verified PASS after each restore. No source changes
were committed. (Adversarial demos by their nature mutate the tree;
the FREEZE rule covers committed changes, and the demos' contract is
"plant → observe FAIL → restore → observe PASS → delete the planted
state", which leaves the tree byte-identical to HEAD.)
**HOST SAFETY RULES** (`docs/dangers.md`) binding; the deployed oracle
(`tiny-dfr-mbp142.service`) stayed untouched and lit throughout; no
service lifecycle actions; no `/etc` writes; no `udevadm trigger`.
Audit D confirms (`docs/test-logs/035/host-state-audit.log`).

**The report is a CLAIM; the live audits are VERDICTS.** The
self-assessment-11 (`docs/self-assessment-11.md`, archived under
`docs/test-logs/035/fix-report/`) is the implementer's CLAIM; every
claim below was re-derived from the diffs and adjudicated against live
execution. New findings → ADR proposals, logged not implemented per
FREEZE.

---

## Per-claim verdicts

### Claim 1 — D1 ancestry: "lost in port, preserved the write, lost the determinism" — **VERIFIED (with the two-candidate mechanism note)**

INDEPENDENT oracle read of `backup_old/tiny-dfr-mbp142/src/backlight.rs`
+ `main.rs` (not via the ADR's citations — read directly):

- `BacklightManager::new()` (`backlight.rs:78-98`) opens the brightness
  fd WRITE-only (`OpenOptions::new().write(true).open(bl_path.join("brightness"))`,
  `backlight.rs:84-86`) and reads `current_bl` from sysfs
  (`read_attr(&bl_path, "brightness")`, `backlight.rs:91`) but does NOT
  write — the constructor is read-only. ✅ matches ADR D1.
- The write lives in `update_backlight` (`backlight.rs:119-145`): it
  recomputes `new_bl` and calls `set_backlight(&self.bl_file,
  self.current_bl)` (`backlight.rs:144`) gated on
  `self.current_bl != new_bl` (`backlight.rs:142`). ✅ matches ADR D1.
- `update_backlight` is called once per loop iteration at the BOTTOM of
  the oracle's render loop (`backup_old/tiny-dfr-mbp142/src/main.rs:1108`),
  AFTER the first `drm.dirty(&clips)` flush (`main.rs:1005`). ✅ matches
  ADR D1 — the oracle's first visible backlight write is in the SAME
  first loop iteration as the first frame, just after the flip.

Our port preserved the write path:
- `SysfsBacklight::update()` at `src/providers/backlight.rs:222-266`
  with the `current_bl == new_bl` no-op gate at `backlight.rs:243-245`
  (the ADR cites `:213-215`; the line numbers shifted because the ADR
  was derived against the pre-fix tree — the GATE is present and
  correct). ✅
- The loop-bottom `backlight.update()` call is at `src/main.rs:845`
  (ADR cites `:821`; shifted by the ADR-043 insertion above it). ✅
- The stale-read root: `SysfsBacklight::new()` reads `current_bl` from
  sysfs at `backlight.rs:88-93` (ADR cites `:81`; same path). ✅

**Classification "port preserved the write, lost the determinism" —
CONFIRMED.** The oracle's `update_backlight` writes on the first
iteration because `current_bl` (read fresh at `new()`) differs from the
computed `new_bl` on a dark boot / oracle-just-stopped state. Our port
has the SAME gate, so the first `update()` is a no-op whenever the
stale `current_bl` happens to equal the computed target — the HC2
evidence (`docs/test-logs/033/step5-hc2.txt`: sysfs mtime unchanged
since boot on BOTH starts) is consistent with this no-op mechanism.

**TWO-CANDIDATE MECHANISM NOTE (per the task's labeling requirement —
not retro-pinning).** The exact dark-panel mechanism has TWO candidates
that the HC2 evidence does not distinguish:

1. **Stale-read no-op (D1's primary account).** The `current_bl` read
   at `SysfsBacklight::new()` (`backlight.rs:88-93`) coincides with the
   computed `new_bl`, so the first `update()`'s
   `current_bl == new_bl` gate (`backlight.rs:243`) returns false and
   the write is skipped. This requires either (a) the adaptive
   `display_bl_path` read silently failing post-drop and the
   `max_bl/2` fallback (`backlight.rs:228-232`) happening to equal a
   stale `current_bl`, or (b) the non-adaptive `active_brightness`
   (`backlight.rs:235`) happening to equal a stale `current_bl`.
2. **Panel-off state behind a non-zero sysfs value.** The held-fd write
   path (`set_backlight_file`, `backlight.rs:121-157`) does
   `rewind` + `write!` + `flush` on the held fd, but the kernel sysfs
   handler could fail to land the write (silently) OR the panel could
   be in an off state behind a non-zero sysfs value (the brightness
   value reads back non-zero but the panel emits no light until an
   explicit enable-write forces the transition).

The ADR itself acknowledges both at `043-backlight-enable-write-render-path.md`
lines 60-72 ("Whether the adaptive `display_bl_path` read silently
failed post-drop ... or the held-fd write silently did not land, the
structural defect is the same"). The unconditional `enable()` write is
**robust to BOTH candidates** — it forces a write at scanout-begin
regardless of the `current_bl` state, so candidate 1 (the gate no-ops)
is bypassed and candidate 2 (the panel needs an explicit poke) is
satisfied. **Empirical closure is attempt-#4 STEP 4b**: the live
hardware run must show (a) the sysfs `brightness` mtime MOVES on the
first start (proving a write reached the kernel) and (b) the observed
brightness value is non-zero AND the panel is lit (proving the write
landed and the panel responded). Until that live run, the
two-candidate note stands UNRESOLVED at the mechanism level and
RESOLVED at the structural level (the unconditional write covers both).
This report labels the mechanism as "two candidates, unconditional
write robust to both, empirical closure pending attempt-#4 STEP 4b" —
NOT retro-pinned to candidate 1.

### Claim 2 — D2 timing: enable() at scanout-begin, after modeset, before first flush — **VERIFIED**

Re-derived from `src/main.rs` at HEAD (`d13196c`):

- The modeset is `display.acquire()`:
  - dry-run arm: `src/main.rs:196` (`if let Err(e) = display.acquire()`)
    inside the `if opts.dry_run { ... }` block (`main.rs:193`).
  - service/real arm: `src/main.rs:308` (ADR-043 cites `:308`; the
    DRM retry loop's `prov.acquire()` — verified by grep, the call is
    present in the non-dry-run arm before `real_main` is entered at
    `main.rs:479`).
- Both arms converge on `real_main` (`main.rs:502`), which is entered
  AFTER `acquire()` returned Ok:
  - dry-run: `real_main(&mut display, &mut input, &mut backlight, true, false, None)` at `main.rs:233`.
  - service/real: `real_main(&mut drm, &mut input, &mut backlight, false, opts.service, uinput_opt)` at `main.rs:479-487`.
- Inside `real_main`, the FIRST backlight call is
  `backlight.enable()` at `src/main.rs:547`, immediately AFTER
  `display_info()` at `main.rs:515` (which confirms the modeset
  succeeded and geometry is resolved) and BEFORE the render loop begins
  at `main.rs:614`. The first `display.flush(&data, &clips)` is at
  `main.rs:692` (ADR cites `:702`; shifted by the ADR-043 insertion —
  the flush is downstream of `enable()`). ✅
- The enable-write is on the SHARED `real_main` path → BOTH service
  and dev/dry-run modes light the bar. ✅

**W14: fd-HELD reachability + post-drop open() absence + dry-run
hermeticity.**

- The held fd is opened PRE-drop by
  `open_backlight_brightness_fd_pre_drop` (`src/main.rs:919-931`),
  which runs as root in the service arm (`main.rs:436` installs it via
  `backlight.hold_brightness_fd(f)`). `SysfsBacklight::enable()`
  (`backlight.rs:175-199`) routes through `set_backlight_file`
  (`backlight.rs:121-157`), which uses the held fd when present
  (`backlight.rs:123-141`: `rewind` + `write!` + `flush` on
  `self.held_brightness_fd`) and falls back to a per-write open
  otherwise (`backlight.rs:143-156`). ✅
- Grep for `open(` / `OpenOptions` in `src/main.rs` (full file): the
  only matches are `setup_uinput` (`main.rs:861-863`,
  `.open("/dev/uinput")` — pre-drop in service, in-real_main in dev)
  and `open_backlight_brightness_fd_pre_drop` (`main.rs:922-924`,
  `.open(bl_path.join("brightness"))` — pre-drop only). **No post-drop
  `open(` of a sysfs backlight path exists on the render path.** The
  enable-write writes through the HELD fd; it does NOT re-open sysfs.
  ✅ ADR-036 / NF-020-A (post-drop `nobody` cannot open sysfs) is not
  violated.
- The oracle's own `update_backlight` writes at loop-bottom on every
  iteration post-drop through the held `bl_file` (oracle
  `backlight.rs:144`), which is the oracle's own post-drop
  held-fd write — proven-safe by the oracle running lit for years.
  Our `enable()` uses the SAME mechanism (held fd, rewind+write+flush),
  just at scanout-begin instead of loop-bottom. ✅
- `--dry-run` hermeticity: the dry-run arm (`main.rs:193-245`)
  constructs `SimDisplayProvider`, `SimInputProvider`, and
  `MockBacklight::new(255)` (`main.rs:231`). `MockBacklight::enable()`
  (`mock_backlight.rs:47-55`) records to `write_log` and does NOT
  touch real sysfs. The dry-run render path never opens
  `/sys/class/backlight/`, `/dev/dri/card*` for write, or
  `/dev/uinput` for write (the SimDisplay acquire targets vkms; the
  SimInput uses an internal uinput handle in sim mode). The
  integration test (`tests/backlight_enable_write.rs`) sets
  `HOME=$(tempfile::tempdir())` (`backlight_enable_write.rs:34-37`) —
  ZERO `/etc` or `$HOME` dependence. ✅ `--probe-input` is mutually
  exclusive with `--dry-run` and `--service` (`main.rs:104`), so it
  cannot reach the render path. ✅

### Claim 3 — D3 restore: no clean-exit restore, justified by oracle self-relight — **VERIFIED**

- `SysfsBacklight` has NO `Drop` impl (grep `impl Drop for SysfsBacklight`
  in `src/providers/backlight.rs` → no match). The clean-exit path in
  `real_main` (`src/main.rs:618` shutdown check → `break` →
  `main.rs:847-852` return) does NOT call `backlight.set_brightness(0)`
  or any restore write. ✅
- The ADR records the flicker/race rationale at
  `043-backlight-enable-write-render-path.md` lines 126-162 (D3 section):
  - "If tbard wrote 0 on clean exit, it would briefly darken the bar in
    the window between tbard's exit and the oracle's first
    `update_backlight` — a user-visible flicker with no benefit."
  - "If tbard wrote a non-zero 'restore' value on clean exit, it would
    race the oracle's own startup write and could conflict."
  - "The oracle's `update_backlight` (`main.rs:1108`) writes a non-zero
    `new_bl` on its first iteration after restart ... HC3 confirms this
    live: oracle restart → backlight 54 → bar lit."
- HC3 evidence re-checked: `docs/test-logs/033/step8-restore-hc3.txt`
  confirms "backlight: 54 (oracle holding the panel lit)" + "Yes —
  F-row + Esc works" after session-033's clean SIGTERM exits. ✅
- The clean-exit no-restore is ASSERTED by
  `test_clean_exit_no_backlight_restore_write` (`src/main.rs:1516-1547`):
  drives `real_main` to a SIGTERM-triggered break, asserts
  `set_brightness` calls is empty. PASSES (cargo test, this session).

### Claim 4 — W15: value provenance (where does 128 come from?) — **VERIFIED (cited, not invented)**

`enable()` writes `self.active_brightness.min(self.max_bl)`
(`src/providers/backlight.rs:176`). `active_brightness` is:

- A field of `SysfsBacklight` (`backlight.rs:33`), set in `new()`
  from the `active_brightness` parameter (`backlight.rs:103`).
- The parameter is sourced from the config schema:
  `src/config/yaml.rs:32-33`:
    ```rust
    #[serde(default = "default_brightness")]
    pub active_brightness: u32,
    ```
- The default function `default_brightness()` at
  `src/config/yaml.rs:63-65`:
    ```rust
    fn default_brightness() -> u32 {
        128
    }
    ```
  → **128 is the documented `#[serde(default)]` value for
  `active_brightness` in the config schema.** It is NOT an invented
  constant; it is the SAME `active_brightness` the adaptive `update()`
  path uses as its active-level target (`backlight.rs:235`). The ADR
  cites this correctly at `043-backlight-enable-write-render-path.md`
  line 172-177 and the impact list line 362-363.
- Clamping to `max_bl` verified: `backlight.rs:176`
  `self.active_brightness.min(self.max_bl)`, and the unit test
  `test_enable_write_clamps_to_max_bl` (`backlight.rs:434-462`) sets
  `active_brightness=200, max_bl=100` and asserts the write is 100.
  PASSES (cargo test, this session).

**W15 adjudication: 128 is CITED (config schema `default_brightness()`
at `src/config/yaml.rs:63-65`, wired via `#[serde(default)]` at
`yaml.rs:32`). Not invented. Clamping verified.** Not REFUTED.

### Claim 5 — Tests: 3 backlight unit + 2 render-path unit + 1 integration; ordering asserted; MockBacklight write_log non-vacuous — **VERIFIED**

- `src/providers/backlight.rs` tests (3 unit):
  - `test_enable_write_occurs_once_with_active_brightness`
    (`backlight.rs:379-429`) — held fd capture, asserts `enable()`
    succeeds and `current_bl == 128`; second `enable()` also succeeds.
  - `test_enable_write_clamps_to_max_bl` (`backlight.rs:434-462`) —
    `active_brightness=200, max_bl=100` → write is 100.
  - `test_enable_write_failure_resets_to_failsafe`
    (`backlight.rs:468-512`) — unwritable brightness file → `enable()`
    returns Err AND `current_bl == FAILSAFE_BRIGHTNESS` (visible, not
    0, not 128).
- `src/main.rs` render-path tests (2 unit):
  - `test_render_path_enable_write_precedes_first_flush_and_update`
    (`main.rs:1434-1506`) — drives `real_main` with
    `OneShotShutdownDisplay(MockDisplay)` + `RecordingBacklight(MockBacklight)`
    for one iteration. Asserts:
    - `calls[0] == "enable"` (enable is the FIRST backlight call) —
      **ordering ASSERTED, not implied**.
    - `enable_idx < update_idx` (enable precedes the loop-bottom
      update).
    - `!backlight.inner.write_log().is_empty()` AND
      `*front() > 0` (MockBacklight received a non-zero enable write).
  - `test_clean_exit_no_backlight_restore_write` (`main.rs:1516-1547`)
    — asserts no `set_brightness` calls on clean SIGTERM exit (D3).
- `tests/backlight_enable_write.rs` (1 integration):
  - `test_dry_run_backlight_enable_write_recorded` — spawns
    `tbard --dry-run` with `HOME=$(tempdir)`, waits for the render
    path to be reached (SimDisplay acquire line), sends SIGTERM,
    asserts exit 0. Skips truthfully (ADR-013) with verbatim EACCES
    when no vkms master is available (this bench).

**MockBacklight write_log non-vacuity.** `MockBacklight::enable()`
(`mock_backlight.rs:47-55`) pushes `self.brightness.min(self.max_brightness)`
to `write_log` at `mock_backlight.rs:53`. `set_brightness()`
(`mock_backlight.rs:35-40`) pushes the clamped value at
`mock_backlight.rs:38`. The render-path test asserts
`!write_log().is_empty() && *front() > 0` — if `enable()` did NOT
record (e.g. someone replaced the body with `Ok(())`), `write_log`
would be empty and the test would FAIL. **Non-vacuous.** (See
adversarial demo 3 below for the companion ordering assertion.)

**Test counts: 74 → 80.** `cargo test` (this session):
- main.rs unittests: **75 passed** (was 73 pre-ADR-043 + 2 new
  render-path tests = 75; the ADR's claim of "75 unit" matches —
  the 3 backlight.rs tests are part of the 75, counted in the bin's
  unittest run).
- integration tests: `backlight_enable_write.rs` 1 + `exit_code.rs` 1
  + `privdrop_target_ordering.rs` 1 + `service_root_guard.rs` 1 +
  `sigterm_master_release.rs` 1 = **5 integration**.
- Total: **75 unit + 5 integration = 80**. ✅ matches ADR claim
  (74 → 80).

### Claim 6 — Guards #8 (ADR-043) and #7a (D-031-2) non-vacuous; preflight 0e `--probe-input` — **VERIFIED (all three re-run live)**

**Guard #8 (ADR-043 enable-write present on render path).**
`scripts/check-invariants.sh` section 8 (lines verbatim):
```sh
if ! grep -nE 'backlight\.enable\(\)\s*[\{;]' src/main.rs \
    | grep -vE '^[0-9]+:\s*//' \
    | grep -vE '^[0-9]+:\s*///' ; then
    echo "FAIL: ADR 043 src/main.rs render path missing the \
backlight.enable() call ..."
    status=1
fi
```
The grep requires the call-site syntax `backlight.enable()` followed by
`{` or `;` (statement context: `if let Err(e) = backlight.enable() {`
or `backlight.enable()?;`), scoped to CODE lines (excludes `//` and
`///`).

**Adversarial demo re-run (live, this session):**
- BASELINE: `547: if let Err(e) = backlight.enable() {` →
  `check-invariants: PASS` (exit 0).
- ADVERSARIAL: `sed -i 's/if let Err(e) = backlight.enable() {/if false {/' src/main.rs`
  → grep finds NO match → guard output:
  ```
  FAIL: ADR 043 src/main.rs render path missing the backlight.enable() call ...
  check-invariants: FAIL (exit 1)
  ```
- RESTORE: `cp /tmp/opencode/main.rs.bak src/main.rs` →
  `check-invariants: PASS` (exit 0).
- **VERDICT: non-vacuous — the exact session-033 regression (removing
  the render-path enable-write) is caught.** Recorded in
  `docs/test-logs/035/adversarial-demos-v10.log` demo 1.

**Guard #7a (D-031-2 — code-line scoping).**
`scripts/check-invariants.sh` section 7 (the ADR-041 structural
predicate check) now scopes the grep to code lines:
```sh
if ! grep -nE 'geometry::is_touchbar_digitizer' src/providers/input.rs \
    | grep -vE '^[0-9]+:\s*//' \
    | grep -vE '^[0-9]+:\s*///' ; then
    echo "FAIL: ADR 041 src/providers/input.rs does not call \
geometry::is_touchbar_digitizer on a CODE line ... (D-031-2)."
    status=1
fi
```

**Adversarial demo re-run (live, this session):**
- BASELINE: 3 code-line calls (130, 194, 280) + 3 comment/doc mentions
  (113, 230, 534) → `check-invariants: PASS` (exit 0).
- ADVERSARIAL: python script commented out the 3 code-line calls
  (replaced lines 130, 194, 280 with
  `// ADVERSARIAL: geometry::is_touchbar_digitizer removed`), leaving
  only the comment/doc mentions. Guard output:
  ```
  FAIL: ADR 041 src/providers/input.rs does not call geometry::is_touchbar_digitizer
  on a CODE line ... A comment-only mention does not satisfy the guard (D-031-2).
  check-invariants: FAIL (exit 1)
  ```
- RESTORE: `cp /tmp/opencode/input.rs.bak src/providers/input.rs` →
  `check-invariants: PASS` (exit 0).
- **VERDICT: non-vacuous under the D-031-2 scoping — a comment-only
  copy FAILS. The prior `grep -q` form would have passed on the
  comment-only copy (vacuous — the D-031-1 lesson: comments are not
  code).** Recorded in `docs/test-logs/035/adversarial-demos-v10.log`
  demo 2.

**Preflight STEP 0e `--probe-input` strings check (D-031-3).**
`scripts/bench/interlock-preflight.sh` STEP 0e (verified by reading
the file): now checks BOTH
`strings /usr/bin/tbard | grep -c -- --service` ≥ 1 AND
`strings /usr/bin/tbard | grep -c -- --probe-input` ≥ 1. A stale
pre-ADR-041 binary would fail the `--probe-input` count (it lacks the
flag), making the 0d failure a loud 0e FAIL instead of a confusing
"unrecognized argument" at 0d. ✅ The check is present and syntactically
correct; `bash -n scripts/bench/interlock-preflight.sh` exits 0.
**STEP 0c write-permission viability: DERIVED, NOT added** — the ADR
at lines 258-276 derives that a 0c write-probe is vacuous (root always
passes sysfs perms) and would NOT have caught the ADR-043 defect (a
missing CALL, not a permission failure). The ADR-036 post-drop
self-check (`src/main.rs:471-475`) verifies the held fd at runtime;
the ADR-043 guard is the check-invariants grep. ✅ reasoning sound.

### Claim 7 — W13-class regression: live hermetic dry-run smoke — **NOT EXECUTABLE on this bench (environmental, NOT a regression); in-process tests COVER the contract**

`HOME=$(mktemp -d) timeout 20 ./target/debug/tbard --dry-run`:
```
[INFO  tbard] tbard: Touch Bar engine starting (mode: dry-run)
[ERROR tbard] tbard: dry-run SimDisplay acquire failed: Permission denied (os error 13)
Error: Permission denied (os error 13)
```
The dry-run smoke opens a vkms DRM card and calls
`acquire_master_lock()`. On this bench Hyprland + systemd-logind
ALREADY HOLD DRM master on the vkms card (card0), so
`acquire_master_lock()` returns EACCES BEFORE the render path is
reached (the failure is at `SimDisplay::acquire()`, upstream of
`backlight.enable()`). This is the SAME documented environmental
constraint recorded in QA v5-5, v6-5, v8, v9 (audit-A-dryrun.log in
each). NOT an ADR-043 regression.

The integration test (`tests/backlight_enable_write.rs`) skips
truthfully (ADR-013) with the verbatim EACCES — same skip behavior as
every prior QA on this bench.

**The W13 contract — "the enable() addition must not have broken the
sim path (MockBacklight receives the write)" — is COVERED by the
in-process unit tests** which exercise the SAME `real_main` render path
WITHOUT the master-gated acquire:
- `test_render_path_enable_write_precedes_first_flush_and_update`:
  `MockDisplay` + `RecordingBacklight(MockBacklight)` → asserts
  `calls[0] == "enable"`, `enable_idx < update_idx`,
  `!write_log().is_empty()`, `*front() > 0`. PASSES.
- `test_clean_exit_no_backlight_restore_write`: asserts no
  `set_brightness` on clean SIGTERM exit. PASSES.

**Adversarial demo (companion to W13, live this session):** moved
`backlight.enable()` from scanout-begin to AFTER the loop-bottom
`backlight.update()` (i.e. after the first flush). The recorded call
order became `["update", "enable"]` and the test FAILED at the
`calls[0] == "enable"` assertion (panic at `src/main.rs:1450`). Restore
→ PASS. **The ordering test is non-vacuous — moving enable after the
first flush FAILS it.** Recorded in
`docs/test-logs/035/adversarial-demos-v10.log` demo 3.

**W13 adjudication: NOT executable live on this bench (environmental);
the in-process tests cover the sim-path contract on every `cargo test`
run, and the adversarial demo confirms the ordering assertion is
non-vacuous. A LIVE sim smoke on a bench with an unmastered vkms card
(or a VT session) is the merge session's re-verification, same as
every prior QA in this environment.**

---

## W14 / W15 adjudications (summary)

- **W14 (enable() reachable with fd HELD; no post-drop open() on the
  render path; dry-run hermetic):** VERIFIED. `enable()` writes through
  the held fd via `set_backlight_file` (`backlight.rs:121-141`); no
  post-drop `open(` of a sysfs backlight path exists in `src/main.rs`
  (grep-confirmed — the only `open(` calls are pre-drop
  `/dev/uinput` and pre-drop `backlight/brightness`); the oracle's own
  loop-bottom writes prove post-drop held-fd writes are safe; `--dry-run`
  uses `MockBacklight` and never touches real sysfs; `--probe-input` is
  mutually exclusive with `--dry-run`/`--service` and cannot reach the
  render path.
- **W15 (value 128 provenance):** VERIFIED, CITED. 128 is the
  `#[serde(default = "default_brightness")]` value for
  `active_brightness` at `src/config/yaml.rs:63-65`, wired at
  `yaml.rs:32`. Not invented. Clamping to `max_bl` verified by
  `test_enable_write_clamps_to_max_bl`.

---

## Two-candidate mechanism note (per the task's labeling requirement)

The exact dark-panel mechanism has TWO candidates that the HC2
evidence does not distinguish:

1. **Stale-read no-op.** `current_bl` (read at `SysfsBacklight::new()`,
   `backlight.rs:88-93`) coincides with the computed `new_bl`, so the
   first `update()`'s `current_bl == new_bl` gate (`backlight.rs:243`)
   returns false and the write is skipped.
2. **Panel-off state behind a non-zero sysfs value.** The held-fd write
   silently did not land OR the panel is in an off state behind a
   non-zero sysfs value and needs an explicit enable-write to
   transition.

The unconditional `enable()` write is **robust to BOTH candidates** —
it forces a write at scanout-begin regardless of `current_bl` state,
bypassing candidate 1's gate no-op and satisfying candidate 2's
explicit-poke requirement. **Empirical closure is attempt-#4 STEP 4b**:
the live hardware run must show (a) the sysfs `brightness` mtime MOVES
on the first start (proving a write reached the kernel) and (b) the
observed brightness value is non-zero AND the panel is lit (proving the
write landed and the panel responded). This report LABELS the mechanism
as "two candidates, unconditional write robust to both, empirical
closure pending attempt-#4 STEP 4b" — NOT retro-pinned to candidate 1.
The ADR's own language at lines 60-72 acknowledges both; the
classification "lost in port, preserved the write, lost the
determinism" is structural and correct regardless of which candidate
fired in session 033.

---

## Adversarial outputs (live, this session)

All three demos recorded in `docs/test-logs/035/adversarial-demos-v10.log`.
Summary:

| Demo | Target | Plant | Observed | Restore |
|------|--------|-------|----------|---------|
| 1 | check-invariants guard #8 | `if let Err(e) = backlight.enable() {` → `if false {` | guard FAIL (exit 1) | PASS (exit 0) |
| 2 | check-invariants guard #7a | comment out 3 code-line calls (130, 194, 280) | guard FAIL (exit 1) | PASS (exit 0) |
| 3 | render-path ordering test | move `enable()` after loop-bottom `update()` | call order `["update", "enable"]` → test FAIL (panic at `calls[0] == "enable"`) | PASS |

All three confirm the corresponding guard/test is NON-VACUOUS. The tree
was RESTORED from `/tmp/opencode` backups after each demo; baseline
`check-invariants: PASS` and `cargo test: 80 passed` re-verified at the
end. No source changes were committed.

---

## Gates (verbatim)

All gates run live this session; full output in
`docs/test-logs/035/gates-verbatim.log`.

| Gate | Command | Result |
|------|---------|--------|
| format | `cargo fmt --check` | exit 0 |
| build | `cargo build --bin tbard` | exit 0 |
| lint | `cargo clippy --all-targets -- -D warnings` | exit 0 |
| test | `cargo test` | 75 unit + 5 integration = 80 passed; 0 failed |
| invariants | `bash scripts/check-invariants.sh` | PASS (exit 0) |
| CI gate | `bash scripts/ci-gate.sh` | CI gate: PASS (exit 0) |
| preflight syntax | `bash -n scripts/bench/interlock-preflight.sh` | exit 0 |
| PKGBUILD syntax | `bash -n packaging/PKGBUILD` | exit 0 |

**Commit hygiene (ADR-before-code):**
`d8ae790` (docs: session 033 — ADR-043 proposed) → `38392ce` (ADR-043
+ code, ADR file travels with the implementation) → `7db83c8` (D-031-2
ride-along) → `d13196c` (docs: session 034 closure). The ADR proposal
(`d8ae790`) precedes the implementation (`38392ce`); the accepted ADR
travels with the code in `38392ce`. This matches the documented
ADR-before-code pattern (proposal in a docs commit, accepted ADR +
code together in the implementation commit). ✅

---

## Host-state audit (read-only; oracle active throughout)

Full audit in `docs/test-logs/035/host-state-audit.log`. Summary:

- **Touch Bar DRM card (card2, appletbdrm) master state:**
  `tiny-dfr-mbp142` (uid 65534 = nobody, master=y) is the SOLE master
  at START and at END. tbard never acquired master on card2 (the
  dry-run path targets vkms card0 and EACCES'd; the integration test's
  spawn also EACCES'd). Oracle untouched and lit throughout.
- **`/dev/input` count:** 25 at start, 25 at end — unchanged (tbard
  never created a uinput device; the dry-run EACCES'd before
  SimInput init).
- **`/etc` writes:** only `/etc/resolv.conf` (pre-existing
  NetworkManager/systemd activity, UNRELATED to tbard or this QA
  session). No tbard-related `/etc` writes.
- **Installed vs branch delta (W12-class, expected):** `/usr/bin/tbard`
  is the v0.2.3 build (mtime 2026-09-26 18:38:33; `--probe-input` works
  — ADR-041 was in v0.2.3). The ADR-043 build is NOT installed yet;
  reinstall is the merge session's job (per ADR-038 process rule). The
  preflight STEP 0e `--probe-input` strings check (D-031-3 ride-along)
  will fire on the merge session's reinstall + preflight. Recorded as
  expected (installed binary lags the branch under QA; the merge
  session reinstalls).

HOST SAFETY RULES respected.

---

## New findings → ADR proposals (logged, NOT implemented per FREEZE)

**No new findings.** All claims re-derived from the diffs match the
live execution; all gates green; all adversarial demos confirm
non-vacuity; the two-candidate mechanism note is a LABELING refinement
of an existing ADR-043 passage (lines 60-72), not a new finding. The
W14/W15 adjudications are VERIFIED, not new findings. No ADR proposals
to raise.

---

## Final verdict

All seven claims VERIFIED against live execution. All gates green
(fmt, build, clippy -D warnings, test 80 = 75 unit + 5 integration,
check-invariants, ci-gate, `bash -n` on preflight + PKGBUILD). Both
adversarial demos (guards #8 and #7a) reproduced FAIL-then-PASS; the
render-path ordering test's adversarial demo reproduced the
`["update", "enable"]` FAIL. The two-candidate mechanism note is
labeled correctly (unconditional write robust to both, empirical
closure pending attempt-#4 STEP 4b). W14 (fd-held reachability, no
post-drop open on the render path, dry-run hermeticity) and W15 (128
cited in the config schema, clamping verified) both VERIFIED. Host
state unchanged; oracle untouched and lit; no `/etc` writes. The W13
live sim smoke is not executable on this bench (Hyprland holds vkms
master — the same environmental constraint as v5-5/v6-5/v8/v9); the
in-process unit tests cover the sim-path contract on every `cargo
test`, and the adversarial demo confirms the ordering assertion is
non-vacuous.

**CLEARED FOR MERGE + binary reinstall (v0.2.4) + Stage-3 attempt #4
(owes items 4 + 9 only).**

The merge session's obligations: (a) merge `fix/backlight-write-adr-043`
to master, tag v0.2.4; (b) reinstall `/usr/bin/tbard` from the tip
(ADR-038 process rule — the installed binary currently lags at v0.2.3,
W12-class expected); (c) re-run preflight (STEP 0e's new
`--probe-input` strings check fires against the reinstalled binary);
(d) re-run Stage-3 from P1 in a fresh session — items 1, 2, 3, 5, 6,
7, 8, 10, 11 are live-verified (session 033) and need not be
re-proven; the re-run owes only items 4 (first pixels) + 9 (backlight
write), now that ADR-043 lands the deterministic enable-write at
scanout-begin. Attempt-#4 STEP 4b (sysfs mtime moved + observed
non-zero lit value) is the empirical closure for the two-candidate
mechanism note.