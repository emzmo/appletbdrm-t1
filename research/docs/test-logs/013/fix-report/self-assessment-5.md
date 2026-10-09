# Self-Assessment 5 — fix/complete-adr-029-030 (complete ADR-024 + ADR-028)

**Session**: 012, **Date**: 2026-09-26
**Branch**: `fix/complete-adr-029-030`, stacked on
`fix/hygiene-adr-016-023` (the single branch carrying ADR-016..028 per
QA v5's T0; QA v5 artifacts committed to the parent as `cf7c713`).
**ADR 019 RESERVED** (service session — not used/renumbered).
**Bench-grant lane CLOSED** (ADR-026; HOST SAFETY RULES in
`docs/dangers.md`) — no login-chain/compositor-config work.
**No hardware testing** — sim harness only.

## Build/test summary (fix engineer's final run)

- `cargo fmt --check` → exit 0
- `cargo build --bin tbard` → exit 0 (ADR-028 ci-gate step)
- `cargo clippy --all-targets -- -D warnings` → exit 0
- `scripts/check-invariants.sh` → PASS (incl. new ADR-029 guard)
- `scripts/ci-gate.sh` → PASS
- `cargo test` → **40 unit + 2 integration = 42 passed; 0 failed**

## Invariant → status table

| Finding / Item | ADR | Fix commit | Evidence to re-verify | Regression test | Status |
|---|---|---|---|---|---|
| QA v5 NF-1: sim scale denominators not Geometry-derived (sim_input.rs hardcoded 2170/60) | ADR-029 | `9ea6f89` | `src/providers/sim_input.rs`: no `SIM_WIDTH`/`SIM_HEIGHT` constants; `logical_dims` field; `poll()` uses `self.logical_dims`; `main.rs` dry-run path builds `Geometry` from `SimDisplayProvider::display_info()` and passes logical dims | `check-invariants.sh` grep guard (fails if `const SIM_(WIDTH\|HEIGHT)` or `x/y_transformed(SIM_*)` re-introduced) | **PASS** (grep-verified clean; guard non-vacuous) |
| QA v5 NF-2: real-range scale test vacuous in execution (SKIP-pass 100%) | ADR-029 | `9ea6f89` | `SimInputProvider::new_with_range` sets `EV_KEY`/`BTN_TOUCH`; `inject_touch_down` emits `BTN_TOUCH=1`; test uses retry-poll loop + HARD FAIL on no event | `test_sim_input_scales_real_abs_range_to_logical` — **live PASS with all sub-assertions executed**: mid-range 16383/63 → (1084.93, 29.53); edges-lo 0/0 → (0, 0); edges-hi 32767/127 → (2169.93, 59.53); widget-tap raw (16383,63) → logical (1084.93,29.53) → hit_test widget_id=1; non-vacuity guard (32767≠2170, 127≠60) | **PASS** (non-vacuous in execution; test CAN fail) |
| QA v5 NF-3 / W1: ADR-028 CARGO_BIN_EXE migration partial (zero tests used the macro; stale-binary false-pass outside ci-gate) | ADR-030 | `2046d13` | `tests/sigterm_master_release.rs` + `tests/exit_code.rs` use `env!("CARGO_BIN_EXE_tbard")`; no `current_exe()` calls remain (grep-verified); `test_sigterm_releases_master` moved to `tests/` | Adversarial `rm -f target/debug/tbard` → `cargo test` rebuilds the bin; spawn-based tests RUN (no false-pass). `exit_code`: "ok: startup failure exited non-zero (code=Some(1))"; `sigterm_master_release`: truthful EACCES skip (verbatim stderr) | **PASS** (structural closure; adversarial check documented) |

## Root-cause statements

### ADR-029 — libinput delivery link (the ADR-024 vacuous-skip root cause)

The existing `SimInputProvider::new_with_range`
(`sim_input.rs:89-146` pre-fix) did NOT set `EV_KEY`/`BTN_TOUCH` on the
uinput device. libinput classifies a device as a touch device (and
emits `TouchEvent`s for it) when the device advertises `BTN_TOUCH`
(`input_linux::Key::ButtonTouch`) OR the udev `ID_INPUT_TOUCHSCREEN=1`
property is set. The udevadm capture
(`docs/test-logs/012/dbg-harness1-full-trace.log`) shows the uinput
device has NO `ID_INPUT_TOUCHSCREEN` property (only `SUBSYSTEM=input`),
so `BTN_TOUCH` is the determining classification signal. Without it,
libinput sees the `ABS_MT_*` axes but never creates a touch device —
the injected events are dropped at device-classification time, never
reaching `Event::Touch`. The QA v5 skip message guessed "timing/device
issue" — **refuted by the four-variant harness**
(`docs/test-logs/012/dbg-harness2-isolate.log`):

| Variant | BTN_TOUCH? | suspend+resume? | Touch delivered? |
|---|---|---|---|
| A (existing SimInputProvider) | no | no | no |
| B | no | yes | no |
| C | yes | no | YES (x=1084.9, y=29.5) |
| D | yes | yes | YES (x=1084.9, y=29.5) |

`BTN_TOUCH` is the determining factor; `suspend()`/`resume()` is NOT
required. The real appletbdrm digitizer advertises `BTN_TOUCH` (oracle
`backup_old/tiny-dfr-mbp142`), so the sim's omission was a divergence
from both the real device and the libinput touch-device contract. The
fix advertises `BTN_TOUCH` + emits it in `inject_touch_down`; the test
now reliably receives the `TouchEvent` and asserts the transform.

### ADR-029 — why sim scale denominators were hardcoded

ADR-024 wired `input.rs` (real) to `self.tb_dims` but left
`sim_input.rs` using `SIM_WIDTH`/`SIM_HEIGHT` constants because the sim
constructor did not accept logical dims — there was no plumbing to
carry `Geometry` into the sim provider. Fix by construction: added the
plumbing (`logical_dims` field + constructor args); `main`'s dry-run
path derives the dims from `Geometry` built off
`SimDisplayProvider::display_info()`, mirroring the real path.

### ADR-030 — the stale-binary hazard (structural closure)

`env!("CARGO_BIN_EXE_tbard")` is a compile-time macro that references
the bin target by name, so Cargo tracks the bin as a dependency of the
test crate: `cargo test` rebuilds the bin whenever it is stale, BEFORE
the test runs. The `current_exe()` approach did not create this
dependency; the test binary and the `tbard` binary were built
independently, so a stale/absent `tbard` was invisible to the test
harness (the test just skipped → "ok" false-pass). Adversarial
self-check (`docs/test-logs/012/adr-030-adversarial-rm-tbard.log`):
`rm -f target/debug/tbard` → `cargo test --no-run` rebuilds the bin
(present again after `--no-run`) → `cargo test` runs the spawn-based
tests against the fresh binary (no false-pass).

## Test count reconciliation (from 42 baseline)

- Baseline (session 011): 41 unit + 1 integration = 42.
- ADR-029: +0 net unit (rewrote `test_sim_input_scales_real_abs_range_to_logical`;
  already counted) = 41 unit + 1 integration.
- ADR-030: -1 unit (`test_sigterm_releases_master` moved OUT of
  `src/lifecycle.rs`), +1 integration (new
  `tests/sigterm_master_release.rs`) = 40 unit + 2 integration.
- **Total: 40 unit + 2 integration = 42** (same total; the spawn-based
  test is now correctly an integration test).

## Tests requiring a privileged / seat-granted environment

| Test | Requirement | This session | Note |
|---|---|---|---|
| `test_sim_display_acquires_vkms` | DRM master on vkms | skips (bench not granted) | ADR-026 CLOSED lane; sudo prebuilt-binary path per ADR-010 |
| `test_sigterm_releases_master` | DRM master on vkms (spawns tbard) | truthful EACCES skip (verbatim stderr) | NOW an integration test (`tests/sigterm_master_release.rs`); ADR-013 class |
| `test_retry_partial_alloc_releases_master_on_failure` | DRM master on vkms | skips (bench not granted) | ADR-027; same |
| `test_sim_input_scales_real_abs_range_to_logical` | `/dev/uinput` + libinput | **RAN + PASS** (all sub-assertions executed) | ADR-029; non-vacuous in execution (was vacuous) |
| `test_sim_input_creates_uinput_device` | `/dev/uinput` | **RAN + PASS** | uinput only |
| `test_startup_failure_exits_nonzero` | spawn `tbard --dry-run` (EACCES in non-granted bench) | **RAN + PASS** (exit 1 on EACCES) | ADR-025/030; uses `CARGO_BIN_EXE_tbard` |
| All other tests | No privilege needed | PASS | — |

The bench-grant lane is CLOSED (ADR-026; HOST SAFETY RULES). The 3
master-gated tests skip truthfully with verbatim errors in this bench
state. The sudo prebuilt-binary path (ADR-010) is the official bench for
those tests — re-run there on a clean VT (no compositor) per ADR-026.

## Granted-environment execution path (human's VT run)

Per ADR-026 (granted-VT procedure — CLOSED on THIS machine, but the
procedure applies to a clean VT / disposable VM):

1. `cargo test --no-run` (as the user) — builds the test binaries + the
   `tbard` bin (as a test dependency via `CARGO_BIN_EXE_tbard`).
2. `sudo ./target/debug/deps/<test-binary> --nocapture` — run each
   prebuilt test binary under root on the clean VT.

Exact prebuilt binary names (hash-suffixed, from `target/debug/deps/`):
- `target/debug/deps/exit_code-d565d17a8b2d77e9`
- `target/debug/deps/sigterm_master_release-732e5141a06bf9cc`
- `target/debug/deps/tbard-024090071b748d61` (unit-test binary; also
  carries the master-gated `test_sim_display_acquires_vkms` and
  `test_retry_partial_alloc_releases_master_on_failure`)

## Adversarial rm-tbard observation (regression closure)

`docs/test-logs/012/adr-030-adversarial-rm-tbard.log` (verbatim):

```
--- step 1: rm -f target/debug/tbard ---
ls: cannot access 'target/debug/tbard': No such file or directory

--- step 2: cargo test --no-run (shows the bin is rebuilt as a test dep) ---
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.11s
  Executable unittests src/main.rs (target/debug/deps/tbard-024090071b748d61)
  Executable tests/exit_code.rs (target/debug/deps/exit_code-d565d17a8b2d77e9)
  Executable tests/sigterm_master_release.rs (target/debug/deps/sigterm_master_release-732e5141a06bf9cc)

--- step 3: bin present after --no-run ---
-rwxr-xr-x 2 emzmo emzmo 45169848 Sep 26 10:52 target/debug/tbard

--- step 4: cargo test (tests run against the rebuilt bin, no false-pass) ---
test result: ok. 40 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
test test_startup_failure_exits_nonzero ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
test test_sigterm_releases_master ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out

VERDICT: with CARGO_BIN_EXE_tbard, cargo test rebuilds the bin as a
test dependency. The spawn-based tests RUN against the fresh binary
instead of skipping (no false-pass). The ADR-028 stale-binary hazard
is closed structurally.
```

## Items explicitly out of scope (per the task / rules)

- **No hardware testing** — sim harness only.
- **No service implementation** — ADR-019 reserved.
- **No login-chain/compositor-config work** — bench-grant lane CLOSED.
- **ADR-019 NOT used/renumbered.**
- **No new features** — ADR-029/030 complete existing ADRs.
- **Stray 2170 constants outside ADR-024's scope** (ESC_THRESHOLD,
  main.rs fallback, slider.rs) are pre-existing and out of ADR-029's
  scope (per QA v5's B.2 note); left documented-but-out-of-scope to
  avoid scope creep / new features.