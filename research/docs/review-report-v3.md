# Pre-Flight Re-Review (v3) — `fix/sim-harness-adr-011-015`

**Reviewer**: QA & reliability engineer (read-only; FREEZE RULE — no code changes)
**Date**: 2026-09-25
**Branch**: `fix/sim-harness-adr-011-015` (HEAD `7f8ab04`), stacked on
`fix/preflight-adr-004-009` (neither merged).
**Baseline**: `docs/review-report-v2.md` (v2) — cleared the 6 v1 FAILs,
blocked only on 2 seat-gated tests needing an active VT.
**Input**: `docs/self-assessment-2.md` (treated as claim, not truth — re-derived).
**Environment this session**: MBP14,2 (T1), kernel `7.2.6-arch2-1`,
Hyprland Wayland session 3 on `seat0`/`tty1` (Active=yes, State=active).
`appletbdrm` 1.2.0 + `hid_multitouch` + `vkms` loaded.
`/dev/dri/card0` (appletbdrm 60×2170), `card1` (i915 eDP 2560×1600),
`card2` (vkms 1024×768, tagged `master-of-seat`, attached to `seat0`,
logind ACL `user:emzmo:rw-`). Reviewer uid=1000 (unprivileged),
passwordless sudo available. **No source code was modified.** Throwaway
violation copies went to `/tmp/opencode/` and were deleted.

---

## TASK 1 — Traceability (per-claim verdict)

| v2 § / claim | ADR | Commit | Verdict | Evidence |
|---|---|---|---|---|
| C1: BUG A (zero pages) → typed error + hermetic dry-run + bound check + hot-reload refuse empty | ADR-011 | `7dd2271` | **VERIFIED** | See C1 below |
| C2: panic hook = one structured entry + backtrace; cleanup chain intact | ADR-012 | `3b646ed` | **VERIFIED** | See C2 below |
| C3: `test_sigterm_releases_master` captures stderr verbatim, classifies in code | ADR-013 | `fb931bf` | **VERIFIED** | See C3 below |
| C4: `#![deny(clippy::indexing_slicing)]` crate root; `#[allow]` narrow + justified | ADR-014 | `71a4d97` | **VERIFIED (with one observation)** | See C4 below |
| C5: backlight selection deterministic; guard excludes main-display | ADR-015 | `3a20dcf` | **VERIFIED** | See C5 below |
| C6: gates green (fmt, clippy -D warnings, 32/32 tests, invariants, ci-gate) | — | — | **VERIFIED** | Task 3 below |
| C7: ADR-010 docs quality (citations, supersession, retry design-only, no privdrop) | ADR-010 | `3a1f3b2` | **VERIFIED (with one citation caveat)** | Task 5 below |

### C1 — ADR-011: BUG A fix — VERIFIED

- `src/config/mod.rs:18-40` defines `ConfigError::{NoPagesConfigured, Parse}`
  with `Display`/`Error` impls.
- `src/config/manager.rs:74-86` `load()` returns
  `Err(ConfigError::NoPagesConfigured.into())` on zero pages — both the
  no-file fallback (`:85`) and the empty-file case (`:78-80`). No `Ok`-empty
  path remains.
- `src/main.rs:220-230` dry-run uses `demo_config()` (deterministic built-in
  demo page: esc+F1+F2+slider+mute, 60×2170); real mode falls back to
  `default_config()` on load error.
- `src/main.rs:234-239` `pages.is_empty()` guard before the loop →
  `anyhow::bail!` (typed error, no panic).
- `src/main.rs:293-299` `active_page >= pages.len()` bound-check EVERY
  iteration → `anyhow::bail!`.
- `src/main.rs:275-277` hot-reload refuses empty vec (`warn!` + keep current).
- `demo_config()` (`src/main.rs:589-630`) is pure literals — NO `HOME`,
  `SystemTime`, `Instant`, `rand` deps (grep confirmed). Deterministic.
- 4 tests: `test_zero_pages_is_typed_error_not_panic`,
  `test_empty_config_file_is_typed_error`,
  `test_dry_run_demo_config_is_hermetic`, `test_default_config_yields_pages`
  — all PASS (Task 3).

### C2 — ADR-012: panic hook diagnostics — VERIFIED

- `src/lifecycle.rs:73-92` `install_panic_hook`: ONE `log::error!` entry
  containing location + message + `std::backtrace::Backtrace::force_capture()`
  (unconditional, ignores `RUST_BACKTRACE`). The old `eprintln!` is gone —
  no duplicated line.
- `run_panic_cleanup()` (`:96-107`) runs the registered closure (socket
  unlink) AFTER the diagnostic log, single-fire via
  `PANIC_CLEANUP_FIRED.compare_exchange`. ADR-007 cleanup chain intact.
- `test_panic_hook_logs_backtrace_and_runs_cleanup` (`:150-183`) registers
  a cleanup closure that sets a `static AtomicBool`, installs the hook,
  triggers a panic via `catch_unwind`, asserts the cleanup flag was set —
  PASS. The cleanup chain runs under the new hook.

### C3 — ADR-013: seat-gated tests tell the truth — VERIFIED

- `src/lifecycle.rs:202-361` `test_sigterm_releases_master` captures child
  stderr verbatim (`stderr(Stdio::piped())`, `:236`; reads via
  `wait_with_output`, `:256-260`). On early exit it classifies in code:
  - **panic at startup** (`stderr.contains("panic at")` ||
    `"index out of bounds"`, `:263`) → `panic!` (REGRESSION) with verbatim stderr.
  - **master EACCES** (`"Permission denied"` || `"EACCES"` || `"master"`,
    `:271-273`) → skip with verbatim stderr.
  - **clean early exit** → skip with verbatim stderr (`:285-290`).
  No guessing.
- `src/providers/sim_display.rs:245-252` `test_sim_display_acquires_vkms`
  skip message renders the full error verbatim (`--- error ---\n{}\n-------------`).
- **Live confirmation**: running the tests as `nobody` (no ACL, no group)
  produced the verbatim EACCES skip:
  ```
  test_sim_display_acquires_vkms: skipped (SimDisplayProvider::acquire failed):
  --- error ---
  Permission denied (os error 13)
  -------------
  ```
  (see `docs/test-logs/005/inv-a-nobody.log`). The classification works.

### C4 — ADR-014: ban indexing class — VERIFIED (with observation)

- `#![deny(clippy::indexing_slicing)]` is at `src/main.rs:19` (the crate
  root) AND at module roots: `src/widgets/mod.rs:8`, `page.rs:4`,
  `button.rs:4`, `slider.rs:7`, `src/config/yaml.rs:4`. The claim "at crate
  root" is correct (main.rs is the crate root for the bin).
- `#[allow(clippy::indexing_slicing)]` sites are narrow + justified:
  - `src/main.rs:304` (redraw block) — comment "active_page < pages.len()
    was checked above; indexing is provably safe" (ADR-014 cited).
  - `src/main.rs:408` (gesture/hit-test) — same justification.
  - `src/main.rs:492` (`dev_name_c[i]`) — "i < dev_name.len() (30) <
    dev_name_c.len() (80) — in bounds".
  - `src/main.rs:727` (test module — legitimate, tests index with known bounds).
  - `src/providers/{drm_backend, sim_display, mock_display}.rs` —
    `data[..len].copy_from_slice(&src[..len])` where
    `len = src.len().min(data.len())` — bounded slicing, justified.
  - `src/ipc/protocol.rs:126`, `src/config/yaml.rs:168` — on `#[cfg(test)]
    mod tests`, legitimate.
- **Observation (non-blocking)**: the lint deny IS the only guard against
  the class regressing. Removing `#![deny(clippy::indexing_slicing)]` from
  `main.rs` makes clippy PASS silently (verified in a throwaway copy —
  clippy exit 0 with the deny removed). The `#[allow]` annotations don't
  fail without the deny. This is a known limitation of lint-based guards:
  there is no separate "the deny must exist" assertion. A future ADR could
  add a `check-invariants.sh` grep asserting the `#![deny]` line is present
  at each required module root (similar to the ADR-009 name-string guard).

### C5 — ADR-015: backlight selection — VERIFIED

- `src/providers/mod.rs:295-330` `select_touchbar_backlight_path(dir)`:
  iterates the backlight dir, **skips** any name matching
  `DISPLAY_BACKLIGHT_NAMES` (`apple-panel-bl, gmux_backlight,
  intel_backlight, acpi_video0`, `:300-305`, `:321-323`) BEFORE checking
  the touchbar name list (`TOUCHBAR_BACKLIGHT_NAMES = appletb_backlight,
  display-pipe, 228600000.dsi.0`, `:296`, `:325-326`). Never
  first-in-sysfs. Belt-and-suspenders guard against conflating the lists.
- `discover_backlight_path()` (`:311-313`) delegates to
  `select_touchbar_backlight_path("/sys/class/backlight/")`.
- 2 tests: `test_select_touchbar_backlight_ignores_intel` (creates
  `intel_backlight` FIRST + `appletb_backlight`, asserts `appletb_backlight`
  is chosen — proves not-first-in-sysfs + guard works),
  `test_select_touchbar_backlight_bails_on_no_match` (only
  `intel_backlight` present → `Err` "No Touch Bar backlight"). Both PASS
  (Task 3). **Both selection AND guard are asserted.**

---

## TASK 2 — Adversarial review of the new code

### Remaining direct indexing on pages/active_page

`grep -nE "pages\[|widgets\[" src/main.rs` (outside `#[allow]` and comments):
- `:305` `pages[active_page].is_dirty()` — under `#[allow]` at `:304`,
  bound-checked at `:293-299`.
- `:313` `pages[active_page].layout(...)` — same `#[allow]` block.
- `:324` `pages[active_page].render(...)` — same block.
- `:415, :430` `pages[active_page].widgets[widget_id]` — under `#[allow]`
  at `:408`; `widget_id` from `hit_test` (returns valid index).
- `:747` `pages[0].layout(...)` — in the `#[cfg(test)]` module (allowed).
All direct indexing is either bound-checked the same iteration or in test
code. No unguarded indexing remains.

### demo_config determinism

`demo_config()` (`src/main.rs:589-630`) body is pure string/struct
literals — `vec![PageDef { id: "demo", widgets: vec![WidgetDef::button{...}, ...] }]`.
Grep for `HOME|env::var|SystemTime|Instant::now|random|rand::|thread_rng`
in `demo_config` returns zero matches. No external deps. Hermetic.

### Hot-reload empty-vec path

`src/main.rs:273-282`: `check_reload` → `build_pages` →
`if new_pages.is_empty() { warn!("config reload yielded zero pages;
keeping current layout") } else { pages = new_pages; ... }`. The empty vec
is never assigned to `pages`. Tested indirectly by
`test_zero_pages_is_typed_error_not_panic` (the load path) and the
`pages.is_empty()` guard at `:234`.

### Panic-hook single-entry + cleanup-under-hook

`src/lifecycle.rs:74-91`: one `log::error!` (location + message +
`force_capture` backtrace), then `run_panic_cleanup()`.
`test_panic_hook_logs_backtrace_and_runs_cleanup` asserts the cleanup
closure runs under the new hook — PASS. Single-entry + cleanup intact.

### Stderr capture verbatim

`src/lifecycle.rs:233-260`: `Command::new(...).stderr(Stdio::piped())`,
`wait_with_output()` → `String::from_utf8_lossy(&o.stderr)`. Skip/panic
messages embed `{}` with the stderr in a fenced block. Verified live
(nobody run produced verbatim `Permission denied (os error 13)`).

### deny-lint placement + `#[allow]` audit

All `#![deny]` and `#[allow]` sites listed in C4 above. Every `#[allow]`
has a one-line justification comment citing ADR-014 or the bound proof.
Test modules `#[allow]` on `#[cfg(test)] mod tests` — legitimate.

### Backlight test asserts BOTH selection and guard

`test_select_touchbar_backlight_ignores_intel` creates `intel_backlight`
FIRST (proving not-first-in-sysfs) AND asserts `appletb_backlight` is
chosen (proving the guard excludes the main-display backlight). Both
invariants in one test. `test_select_touchbar_backlight_bails_on_no_match`
asserts the guard alone (only `intel_backlight` → `Err`).

### `check-invariants.sh` adversarial test

Planted `dev.name().contains("iBridge Touchpad")` in a throwaway copy of
`src/providers/input.rs`:
```
85:        if dev.name().contains("iBridge Touchpad") { return true; }
FAIL: src/providers/input.rs uses dev.name()/.name().contains() — the digitizer match must be geometry-only (ADR 009).
85:        if dev.name().contains("iBridge Touchpad") { return true; }
FAIL: src/providers/input.rs contains name-string "iBridge Touchpad" in code (ADR 009 forbids name-string matching).
check-invariants: FAIL
EXIT=1
```
Also confirmed (prior review v2) the udev `ATTR{name}` and missing-VID:PID
violations are caught. Throwaway deleted.

---

## TASK 3 — Gates verbatim

### `cargo fmt --check`
```
========== cargo fmt --check ==========
FMT_EXIT=0
```
**PASS** (exit 0).

### `cargo clippy --all-targets -- -D warnings`
```
========== cargo clippy --all-targets -- -D warnings ==========
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.17s
CLIPPY_EXIT=0
```
**PASS** (exit 0, zero warnings).

### `cargo test`
```
running 32 tests
test config::yaml::tests::test_parse_settings ... ok
test config::manager::tests::test_empty_config_file_is_typed_error ... ok
test config::yaml::tests::test_parse_minimal_config ... ok
test config::manager::tests::test_zero_pages_is_typed_error_not_panic ... ok
test config::yaml::tests::test_reject_invalid_yaml ... ok
test config::yaml::tests::test_parse_slider ... ok
test config::yaml::tests::test_parse_time_and_battery ... ok
test ipc::protocol::tests::test_roundtrip_error_response ... ok
test ipc::protocol::tests::test_roundtrip_set_pages ... ok
test ipc::protocol::tests::test_roundtrip_update_widget ... ok
test lifecycle::tests::test_signal_handler_sets_flag ... ok
test lifecycle::tests::test_shutdown_flag_round_trip ... ok
test lifecycle::tests::test_panic_hook_logs_backtrace_and_runs_cleanup ... ok
test providers::error::tests::test_hwerror_display_contains_context ... ok
test providers::backlight::tests::test_failsafe_brightness_on_write_failure ... ok
test providers::error::tests::test_hwerror_propagates_through_anyhow ... ok
test providers::input::tests::test_geometry_matches_touchbar_rotated ... ok
test providers::input::tests::test_geometry_rejects_no_absmt ... ok
test providers::input::tests::test_geometry_rejects_trackpad ... ok
test providers::input::tests::test_geometry_tolerance ... ok
test providers::tests::test_aspect_ratio_gate ... ok
test providers::sim_display::tests::test_sim_display_acquires_vkms ... ok
test providers::tests::test_select_touchbar_backlight_bails_on_no_match ... ok
test providers::tests::test_scan_never_promotes_vkms_decoy ... ok
test providers::tests::test_select_touchbar_backlight_ignores_intel ... ok
test tests::test_default_config_yields_pages ... ok
test tests::test_dry_run_demo_config_is_hermetic ... ok
test widgets::page::tests::test_hit_test_basic ... ok
test widgets::page::tests::test_hit_test_y_bounds ... ok
test widgets::page::tests::test_hit_test_stretch ... ok
test providers::sim_input::tests::test_sim_input_creates_uinput_device ... ok
test lifecycle::tests::test_sigterm_releases_master ... ok

test result: ok. 32 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.57s
TEST_EXIT=0
```
**PASS** (32/32). **Reconciliation**: 25 (from adr-004-009 branch) + 7 new
(ADR-011: 4 — `test_zero_pages_is_typed_error_not_panic`,
`test_empty_config_file_is_typed_error`, `test_dry_run_demo_config_is_hermetic`,
`test_default_config_yields_pages`; ADR-012: 1 —
`test_panic_hook_logs_backtrace_and_runs_cleanup`; ADR-015: 2 —
`test_select_touchbar_backlight_ignores_intel`,
`test_select_touchbar_backlight_bails_on_no_match`) = 32. ✅

**Skipped-test count**: `cargo test` reports 0 ignored, but
`--nocapture` reveals `test_sim_display_acquires_vkms` and
`test_sigterm_releases_master` **ran and PASSED** this session (see
Investigation A — unprivileged PASS via logind seat ACL). 0 runtime skips
in this session. The `nobody` run (Investigation A/B) produced 1
verbatim-EACCES skip (`test_sim_display_acquires_vkms`) and 1
binary-not-found skip (`test_sigterm_releases_master`, test-harness path
limitation under `nobody`) — both with truthful messages per ADR-013.

### `scripts/check-invariants.sh`
```
========== scripts/check-invariants.sh ==========
check-invariants: PASS
INVARIANTS_EXIT=0
```
**PASS.**

### `scripts/ci-gate.sh`
```
==> cargo fmt --check
==> cargo clippy --all-targets -- -D warnings
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.16s
==> scripts/check-invariants.sh (ADR 009: zero name-string matching)
check-invariants: PASS
CI gate: PASS
CIGATE_EXIT=0
```
**PASS.**

### Commit hygiene
```
git log --oneline
7f8ab04 docs: self-assessment-2 + session 003 wrap-up + test-plan seat-gated paths
3a20dcf ADR-015: backlight selection (deterministic touchbar, never first-in-sysfs)
71a4d97 ADR-014: ban indexing bug class (clippy::indexing_slicing)
fb931bf ADR-013: seat-gated tests tell the truth (verbatim child stderr, no guessing)
3b646ed ADR-012: panic hook diagnostics (backtrace + single structured entry)
7dd2271 ADR-011: empty pages -> typed error + hermetic dry-run (BUG A fix)
3a1f3b2 ADR-010: master acquisition input (docs-only; proven privilege model)
c8fcb69 baseline: QA re-review v2 evidence + oracle capture (adr-004-009 branch HEAD)
```
- **One commit per ADR** (010-015): each ADR file introduced in its own
  commit (`git log --diff-filter=A -- docs/adr/NNN-*.md`). ✅
- **ADR-before-code ordering**: ADR file mtimes (22:29-22:42) precede
  their commit times (22:42-22:45). ✅
- **Messages reference ADR numbers**: all 6 commits have `ADR-0NN:` in
  the subject. ✅

---

## INVESTIGATION A — Privilege context of the passes

**Hypothesis**: the fix session's shell was privileged (root), making the
seat-gated passes production-faithful per ADR-010 but undocumented.

**My context**: uid=1000 (unprivileged), passwordless sudo available,
Hyprland Wayland session 3 on `seat0`/`tty1` (Active=yes, State=active).

### (a) Unprivileged run — expected EACCES per ADR-010; ACTUAL: PASS

```
uid=1000 session=3 - emzmo (1000) context=wayland/seat0/tty1 (Active=yes)
cargo test -- --nocapture test_sim_display_acquires_vkms test_sigterm_releases_master
ok: SimDisplay on vkms /dev/dri/card2 (60×2170)
test providers::sim_display::tests::test_sim_display_acquires_vkms ... ok
ok: second master acquisition on /dev/dri/card2 succeeded → SIGTERM released master
test lifecycle::tests::test_sigterm_releases_master ... ok
test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```
(`docs/test-logs/005/inv-a-unpriv.log`)

**Both tests PASSED unprivileged.** This contradicts the ADR-010 narrative
that "an unprivileged shell CANNOT acquire vkms master here (EACCES on
tty3)". I did NOT stop and celebrate — I investigated the systemic change.

### Systemic explanation: logind seat ACL grants master to the active session user

`docs/test-logs/005/inv-a-systemic-explanation.log` captures the full
evidence:
- vkms `card2` is tagged `master-of-seat` + `seat` + `uaccess`
  (`udevadm info /sys/class/drm/card2` → `TAGS=:master-of-seat:seat:uaccess:`).
- `loginctl seat-status seat0` lists `card2` with `[MASTER] drm:card2`.
- Session 3 (emzmo) is `Active=yes`, `State=active` on `seat0`.
- `getfacl /dev/dri/card2` shows `user:emzmo:rw-` — logind granted the
  active session user an ACL on the card.
- Hyprland (PID 746) holds master on `card2`, BUT the active seat0 user
  can acquire/steal master via logind's seat master-of-seat coordination
  (the kernel allows the active seat user to take master).

**Conclusion**: the tests pass unprivileged on this bench because vkms is
a **seat device** and logind grants the **active** session user master
access. The ADR-010 narrative ("unprivileged EACCES on tty3") was true for
the prior review's context (tty3 was idle, not the active seat0 session)
but is **NOT a general property** — it depends on which session is
`Active` on `seat0`. The fix session's tests passed for the SAME reason
mine do now: active seat0 session + logind ACL, **NOT undocumented root
privilege**. The fix session's `self-assessment-2.md` says "this shell had
vkms master access on card2" but does not explain WHY — the explanation is
the logind seat ACL, which I have now captured.

### (b) Privileged run (sudo) — also PASS (confirms ADR-010 path)

```
sudo -n cargo test -- --nocapture test_sim_display_acquires_vkms test_sigterm_releases_master
ok: SimDisplay on vkms /dev/dri/card2 (60×2170)
ok: second master acquisition on /dev/dri/card2 succeeded → SIGTERM released master
test result: ok. 2 passed; 0 failed
```
(`docs/test-logs/005/inv-a-sudo.log`)

Both paths (unprivileged-via-ACL and privileged-via-sudo) PASS. The ADR-010
production-faithful path (root acquire) works, AND the active-seat-user
path works.

### (c) `nobody` run — EACCES, verbatim per ADR-013

Running the prebuilt test binary as `nobody` (no ACL, no group):
```
test_sim_display_acquires_vkms: skipped (SimDisplayProvider::acquire failed):
--- error ---
Permission denied (os error 13)
-------------
test lifecycle::tests::test_sim_display_acquires_vkms ... ok
```
(`docs/test-logs/005/inv-a-nobody.log`). The ADR-013 verbatim-stderr
classification fires correctly for the EACCES case. (`test_sigterm_releases_master`
skipped with "tbard binary not found next to the test binary" — a
test-harness path limitation under `nobody`, not an ADR-013 classification
failure; the `test_sim_display_acquires_vkms` EACCES classification is
the proof.)

### Investigation A conclusion

**The fix session's "READY" claim is reproducible without privilege on
this bench.** The passes were NOT the result of undocumented root
privilege — they were the result of the active seat0 session + logind ACL,
which I have now documented (the fix session did not document this
mechanism). The ADR-010 EACCES narrative is context-dependent (true on
idle tty3, false on active seat0) and should be amended to note the
logind seat-ACL path as a third execution path. **No blocker.** New
finding: ADR-010 should be amended to document the logind seat-ACL path
and the fix session's actual uid/active-session context (ADR proposal
below).

---

## INVESTIGATION B — EACCES semantics in the daemon (residual inconsistency)

**Hypothesis**: the user's unprivileged smoke logs showed the old binary
reaching the render loop (panic at `main.rs:266`) in sessions where
unprivileged master acquire EACCESes. The report's "two distinct failure
modes" narrative does not fully account for this — maybe
`SimDisplayProvider` warn-and-continues on EACCES, making the daemon
appear to run while never flipping (ADR-008 failure family).

### What does `SimDisplayProvider` do when `drmSetMaster` fails?

`src/providers/sim_display.rs:118-153` `acquire()`:
```rust
card.acquire_master_lock()?;   // line 136 — ? propagates
...
Ok(())
```
`acquire_master_lock()` uses `?` — on EACCES it returns
`Err(io::Error EACCES)` up. `acquire()` does NOT warn-and-continue. It
fail-fasts with a typed error.

### What does `main` do with that error?

`src/main.rs:117-122`:
```rust
if opts.dry_run {
    let mut display = SimDisplayProvider::new();
    if let Err(e) = display.acquire() {
        panic!("tbard: dry-run SimDisplay acquire failed: {}", e);
    }
```
`main` **panics** on the `Err`. This panic is at `main.rs:121`, OUTSIDE
the `catch_unwind` at `:131` — so the panic hook runs (logs backtrace +
socket unlink) and then the process unwinds/exits. **Fail-fast.** The
daemon does NOT reach the render loop when master acquire fails.

### Live confirmation

Running `tbard --dry-run` as `nobody` (EACCES on master):
```
[ERROR tbard::lifecycle] tbard: panic at src/main.rs:121:13: panicked at src/main.rs:121:13:
    tbard: dry-run SimDisplay acquire failed: Permission denied (os error 13)
    backtrace: ...
```
(`docs/test-logs/005/inv-b-nobody-dryrun.log`). The daemon panicked at
`main.rs:121` (the dry-run acquire guard) with the verbatim EACCES — it
never reached the render loop. No frames produced. No silent false
negative.

### Reconciling the user's old smoke

The user's old smoke showed "panic at main.rs:266" (the index-out-of-bounds
BUG A). That was NOT an EACCES case — it was BUG A (empty pages), where
master acquire SUCCEEDED but `pages` was empty so the render loop
index-panicked. The "two distinct failure modes" narrative is correct:
- BUG A (empty pages) → master acquire succeeds → render loop → index
  panic at `:266`. **Fixed by ADR-011.**
- EACCES (no master) → master acquire fails → `panic!` at `:121` → never
  reaches render loop. **Fail-fast, always was.**

There is no warn-and-continue path. The ADR-008 failure family
(silent-false-negative) does NOT apply to the EACCES case.

### Investigation B conclusion

**Hypothesis REFUTED.** `SimDisplayProvider` fail-fasts on EACCES
(`?` propagation + `panic!` in `main`). The daemon never reaches the
render loop when master acquire fails. The old "panic at main.rs:266"
was BUG A (empty pages with master acquired), now fixed by ADR-011. No
new ADR needed for warn-and-continue — that hazard does not exist.

**One minor observation (non-blocking, for a future cleanup ADR)**: the
dry-run acquire path uses `panic!` (`main.rs:121, 125`) rather than the
ADR-006 typed-error propagation pattern. This is outside the ADR-006
hardware-provider modules (which have `#![deny(clippy::panic)]`), so clippy
allows it, but for consistency the dry-run branch could return a typed
`HwError` and let `main` log+exit without `panic!`. Not a blocker — the
panic hook + `catch_unwind` (for the `real_main` call) handle it cleanly,
and the `:121` panic is outside `catch_unwind` but the hook still logs
the backtrace before the process exits. ADR proposal below.

---

## TASK 4 — Hermetic smoke, LIVE

`docs/test-logs/005/t4-smoke-run1.log` + `t4-smoke-run2.log` +
`t4-smoke-sudo.log`. uid=1000 (unprivileged, active seat0 session).

### Run 1 — 20s unprivileged smoke
```
HOME=/tmp/tmp.a4HTlmEBB7 RUST_LOG=tbard=debug timeout --signal=SIGTERM 20 ./target/debug/tbard --dry-run
[INFO  tbard] tbard: Touch Bar engine starting (mode: dry-run)
[INFO  tbard::providers::sim_display] tbard: dry-run SimDisplay on vkms /dev/dri/card2 (60×2170)
[INFO  tbard] tbard: Touch Bar display 60x2170
[WARN  tbard] tbard: display flush error: Function not implemented (os error 38)
[INFO  tbard] tbard: shutdown signal received, exiting
```
- Daemon started, acquired vkms master, reached the render loop (60×2170
  display info logged). Frames rendered to the dumb buffer.
- `display flush error: Function not implemented (os error 38)` — vkms
  does not implement `dirty_framebuffer` (ENOSYS). The render path
  executed fully (layout + cairo paint + dumb-buffer copy); only the
  damage ioctl fails on vkms. Non-fatal warning; the real `appletbdrm`
  path supports `dirty_framebuffer`. Not a regression.
- SIGTERM (from `timeout`) → "shutdown signal received, exiting" → clean
  loop break. Exit 124 is `timeout`'s own code; the daemon logged clean
  exit. No panic/backtrace.
- Synthetic touch: the SimInput uinput device was created
  (`test_sim_input_creates_uinput_device` PASS this session,
  `/dev/input/event18`); no touch was injected in the smoke (the
  harness injects via the write side, not done here), but the read path
  is exercised.

### Run 2 — immediate rerun (no stale state)
```
[INFO  tbard] tbard: Touch Bar engine starting (mode: dry-run)
[INFO  tbard::providers::sim_display] tbard: dry-run SimDisplay on vkms /dev/dri/card2 (60×2170)
[INFO  tbard] tbard: Touch Bar display 60x2170
[WARN  tbard] tbard: display flush error: Function not implemented (os error 38)
[INFO  tbard] tbard: shutdown signal received, exiting
```
Immediate rerun OK — master was released by RAII `Drop` on the first
exit (no EACCES/EBUSY on the second acquire). Confirms ADR-007 master
release works.

### Run 3 — sudo smoke (privileged path)
```
sudo -n env HOME=… RUST_LOG=tbard=debug timeout --signal=SIGTERM 8 ./target/debug/tbard --dry-run
[INFO  tbard] tbard: Touch Bar engine starting (mode: dry-run)
[INFO  tbard] tbard: dry-run SimDisplay on vkms /dev/dri/card2 (60×2170)
[INFO  tbard] tbard: Touch Bar display 60x2170
[WARN  tbard] tbard: display flush error: Function not implemented (os error 38)
[INFO  tbard] tbard: shutdown signal received, exiting
```
Identical behavior under sudo (root). Both privilege paths work.

---

## TASK 5 — ADR-010 quality

| Requirement | Verdict | Evidence |
|---|---|---|
| Oracle recipe with citations (unit file, fuser, /proc fd) | **VERIFIED** | `docs/adr/010-master-acquisition-input.md:33-69` cites `deployed.service:9,13,20`, `main.rs:822-943`, `display.rs:67-71`, `backlight.rs:30-44,85`, `oracle-runtime.txt` (fuser + /proc/562/fd). 7 references to `deployed.service`, 1 to `fuser`. |
| Pre-drop fd checklist | **VERIFIED** | `:148-164` "Pre-drop fd checklist" lists DRM card fd, `/dev/uinput`, `appletb_backlight/brightness` with the rationale (nobody has no ACLs). Post-drop self-check requirement documented. |
| Amendments (AF_INET, /etc/touchbar, /run/touchbar) | **VERIFIED** | `:86-109` three amendments: `RestrictAddressFamilies` + `AF_INET` for WS Phase 3; `ProtectHome=true` ⇒ config at `/etc/touchbar-engine/` (compatible); IPC socket at `/run/touchbar/engine.sock` via `RuntimeDirectory=touchbar`. |
| Supersession of "no root" | **VERIFIED** | `:9-10` "The original architecture assumption (ADR 001, README) was 'no root, systemd user unit'. This is disproven on this machine."; `:184` references ADR-001 as "now-superseded". |
| Rejected CAP_SYS_ADMIN alternative | **VERIFIED** | `:111-124` "Considered and rejected" section with 3 reasons (broad-cap attack surface, oracle proven, no active session for nobody). |
| Boot-retry marked DESIGN ONLY | **VERIFIED** | `:126` "Boot race: bounded retry design (NOT implemented here)"; `:145` "Do not implement the service here — this is design-only for the future service ADR." |
| "tbard does not privdrop today" grep-confirmed | **VERIFIED** | `:166-173` "No. `grep -rn "privdrop\|PrivDrop\|nobody" src/` returns zero matches." I re-ran the grep: 0 matches in `src/`. `privdrop = "0.5.3"` in `Cargo.toml:22` is an unused dependency. |
| `/proc/562/fd` evidence with privilege caveat | **PARTIAL (caveat missing)** | `:19-23` cites `/proc/562/fd` fd-by-fd but does NOT explicitly note that reading `/proc/562/fd` of a `nobody` process required root privilege. I confirmed: `ls /proc/562/fd/` as uid 1000 → Permission denied; under sudo → succeeds. The fix session's `oracle-runtime.txt` capture was done with root/sudo, but ADR-010 does not state this. **Citation caveat gap (non-blocking).** |

---

## TASK 6 — Archive + devlog

- `docs/test-logs/005/fix-report/self-assessment-2.md` (the fix engineer's
  claim, archived as data) and `self-assessment-1.md` (prior fix session).
- `docs/test-logs/005/inv-a-unpriv.log`, `inv-a-sudo.log`, `inv-a-nobody.log`,
  `inv-a-nobody-sigterm.log`, `inv-a-systemic-explanation.log`
  (Investigation A evidence).
- `docs/test-logs/005/inv-b-nobody-dryrun.log` (Investigation B evidence).
- `docs/test-logs/005/t4-smoke-run1.log`, `t4-smoke-run2.log`,
  `t4-smoke-sudo.log` (Task 4 hermetic smoke).
- Devlog entry appended (every result annotated with uid + session type).

---

## New findings → ADR proposals for the next fix session (logged, NOT implemented)

1. **ADR-016 (proposed): logind seat-ACL execution path + session-context
   recording.** ADR-010 should be amended (or a new ADR written) to:
   (a) document the logind seat-ACL path as a THIRD execution path for
   seat-gated tests (active seat0 session + `master-of-seat` tag +
   `uaccess` ACL → unprivileged master acquire works, no sudo needed);
   (b) record the fix session's actual uid + `Active` session state in
   the devlog (the fix session said "this shell had vkms master access"
   but not WHY — it was the active seat0 ACL, not root);
   (c) correct the ADR-010 EACCES narrative to note it is
   context-dependent (true on idle tty, false on active seat0).
   Evidence: `docs/test-logs/005/inv-a-systemic-explanation.log`.

2. **ADR-017 (proposed): assert the `#![deny]` line is present.** ADR-014's
   lint guard is fragile — removing `#![deny(clippy::indexing_slicing)]`
   makes clippy PASS silently (verified in a throwaway copy). Add a
   `check-invariants.sh` grep asserting the `#![deny(clippy::indexing_slicing)]`
   line is present at each required module root (`src/main.rs`,
   `src/widgets/{mod,page,button,slider}.rs`, `src/config/yaml.rs`),
   similar to the ADR-009 name-string guard. Non-blocking.

3. **ADR-018 (proposed, minor): typed error for dry-run acquire path.**
   `src/main.rs:121,125` uses `panic!` for `SimDisplayProvider::acquire`
   / `SimInputProvider::new` failures in the dry-run branch, outside the
   ADR-006 `#![deny(clippy::panic)]` modules. For consistency with the
   ADR-006 typed-error pattern, convert these to `HwError` propagation +
   `main` log+exit (no `panic!`). The current panic hook handles it
   cleanly, so this is cosmetic consistency, not a correctness bug.
   Non-blocking.

4. **ADR-010 citation caveat (non-blocking)**: ADR-010 should note that
   the `/proc/562/fd` evidence in `oracle-runtime.txt` was captured with
   root privilege (reading a `nobody` process's fd table requires
   `CAP_SYS_PTRACE` or root). Add one line to ADR-010's evidence section.

---

## Verdict

**CLEARED FOR MERGE + Stage 1.** All 7 claims are VERIFIED by
re-derivation from the diffs and live execution (not trusting
`self-assessment-2.md`): BUG A is fixed (zero pages → typed
`ConfigError::NoPagesConfigured`, hermetic `demo_config()`, bound-checked
`active_page` every iteration, hot-reload refuses empty vec — 4 tests
green); the panic hook now emits one structured entry with a forced
backtrace and the ADR-007 cleanup chain still runs under it (1 test
green); `test_sigterm_releases_master` captures child stderr verbatim and
classifies panicked/EACCES/clean-exit in code (verified live — the
`nobody` run produced a verbatim `Permission denied (os error 13)` skip
per ADR-013); `#![deny(clippy::indexing_slicing)]` is at the crate root
and widget/config modules with narrow justified `#[allow]`s;
backlight selection is deterministic and the guard excludes
`intel_backlight`/`acpi_video0` (2 tests assert both selection + guard);
ADR-010 is docs-only with full citations, explicit "no root" supersession,
rejected CAP_SYS_ADMIN, and design-only retry. Gates are green verbatim
(fmt exit 0, clippy -D warnings exit 0, 32/32 tests, check-invariants
PASS, ci-gate PASS) and commit hygiene is clean (one commit per ADR,
ADR-before-code, messages reference ADR numbers). **Investigation A**
resolved the privilege-context concern: both seat-gated tests PASS
**unprivileged** (uid 1000) on this bench because vkms is a seat device
and logind grants the active seat0 session user an ACL + master capability
— the fix session's passes were NOT undocumented root privilege, and I
documented the mechanism the fix session omitted; both tests also PASS
under sudo (the ADR-010 production path). **Investigation B** refuted the
warn-and-continue hypothesis: `SimDisplayProvider` fail-fasts on EACCES
(`?` + `panic!` in `main`), the daemon never reaches the render loop when
master acquire fails, and the old "panic at main.rs:266" was BUG A (empty
pages with master acquired), now fixed — no silent-false-negative hazard
exists. The hermetic smoke (Task 4) ran live unprivileged: daemon started,
acquired vkms master, rendered to the dumb buffer (vkms `dirty_framebuffer`
ENOSYS is a vkms limitation, not our bug), exited cleanly on SIGTERM, and
immediate rerun succeeded (master released by RAII Drop). Four non-blocking
ADR proposals are logged for the next fix session (ADR-016 logind path
documentation, ADR-017 assert-the-deny guard, ADR-018 typed-error for
dry-run acquire, ADR-010 /proc privilege caveat) — none block merge or
Stage 1. **Merge `fix/sim-harness-adr-011-015` (and its base
`fix/preflight-adr-004-009`) and proceed to Stage 1.**