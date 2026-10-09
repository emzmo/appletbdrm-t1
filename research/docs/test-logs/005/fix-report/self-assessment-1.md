# Self-Assessment — fix/preflight-adr-004-009

**Session**: 001 (fix engineer), **Date**: 2026-09-25
**Branch**: `fix/preflight-adr-004-009`
**Purpose**: invariant → status table for the fresh QA session to re-verify
before re-running the pre-flight review and advancing to Stage 1.

Each row maps a review FAIL (`docs/review-report.md`) to the ADR that
fixes it, the evidence to re-verify, and the regression test that guards
it. "Status" is the fix engineer's self-assessment pending QA
confirmation.

| Review § | Invariant | ADR | Fix commit | Evidence to re-verify | Regression test | Status |
|---|---|---|---|---|---|---|
| §1.1 | `cargo fmt --check` exit 0 | (W1, no ADR) | `be4e6f9` | `cargo fmt --check`; `scripts/ci-gate.sh` | `scripts/ci-gate.sh` fmt step | **PASS** (fmt exit 0) |
| §1.2 | `cargo clippy --all-targets -- -D warnings` exit 0 | (W1) | `be4e6f9` + ADR-006 denies | `scripts/ci-gate.sh` clippy step | `scripts/ci-gate.sh` clippy step | **PASS** (clippy exit 0) |
| §2.1 | Geometry-only discovery; ZERO name-string deps (code + udev); MBP14,2 immunity | ADR-009 | `6af6034` | `scripts/check-invariants.sh`; `src/providers/input.rs` `is_digitizer` (no `dev.name()`); `packaging/udev/99-touchbar-seat.rules` (VID:PID, no `ATTR{name}`) | `test_geometry_*` (4 tests) + `check-invariants.sh` | **PASS** (invariants PASS; 4 geometry tests green) |
| §2.2 | Single-writer; only matched card opened for write/master; never eDP during scan | ADR-004 | `646e165` | `src/providers/mod.rs` `scan_card_readonly` (O_RDONLY, no `acquire_master_lock`); `try_open_card` master-once | `test_scan_never_promotes_vkms_decoy` (vkms decoy rejected — **verified live** on card2) + `test_aspect_ratio_gate` | **PASS** (vkms decoy rejected by ratio; scan read-only by construction) |
| §2.3 | All I/O bounded; no infinite loop; no unwrap/expect/panic on hw paths | ADR-006 + ADR-007 | `136cf96` + `9679275` | `src/providers/*.rs` `#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)]`; `real_main` returns `Result`; loop checks `lifecycle::should_shutdown()` | clippy gate enforces denies; `test_hwerror_*` (2 tests); `test_signal_handler_sets_flag` (live) | **PASS** (denies enforced; errors propagate; signal breaks loop). **Note**: cairo render-path `unwrap()`s (OOM class) remain by ADR-006 scope — QA to confirm acceptance. |
| §2.4 | No ACPI calls anywhere | (was PASS) | — | unchanged | (review §2.4 already PASS) | **PASS** (unchanged) |
| §2.5 | `unsafe` justified; error paths release resources (DRM master, sockets) | ADR-007 (+ ADR-006 NULL checks) | `9679275` + `136cf96` | `impl Drop for DrmProvider` (explicit `release_master_lock`); SAFETY comments in `src/fonts.rs`; panic hook in `src/lifecycle.rs` | `test_sigterm_releases_master` (skips in non-session shell — QA to run on a VT session) | **PASS** (RAII + Drop + SAFETY + panic hook). **Note**: SIGTERM master-release test skips without DRM master access; QA should re-run on an active VT. |
| §2.6 | Backlight fail-safe ON (visible), never dark-from-failure | ADR-008 | `a6780c3` | `src/providers/backlight.rs` `FAILSAFE_BRIGHTNESS`; write-failure resets `current_bl` + `error` log; `new` no panic | `test_failsafe_brightness_on_write_failure` (**verified live** — write fail → current_bl=1, not 200) | **PASS** (fail-safe-ON enforced) |
| §2.7 | `--dry-run` exists; IPC 0600; WS N/A | ADR-005 | `8868391` | `tbard --dry-run` (vkms + uinput sim providers); `src/ipc/server.rs` 0600 (deferred wiring, ADR-005) | `test_sim_input_creates_uinput_device` (**verified live**); `test_sim_display_acquires_vkms` (skips w/o master) | **PASS** (dry-run wired; IPC deferred per ADR). **Note**: SimDisplay master acquire skips in non-session shell; QA to run on a VT session. |

## Build/test summary (fix engineer's final run)

- `cargo fmt --check` → exit 0
- `cargo clippy --all-targets -- -D warnings` → exit 0
- `scripts/check-invariants.sh` → PASS
- `cargo test` → **25 passed; 0 failed**
- `scripts/ci-gate.sh` → PASS (fmt + clippy + invariants)

## Items QA should re-verify on a real session (not hardware — just a VT)

1. **`test_sigterm_releases_master`** — skips in a non-session shell
   (cannot acquire DRM master). On an active VT (or with `CAP_SYS_ADMIN`),
   it spawns `tbard --dry-run`, sends SIGTERM, and asserts a second master
   acquisition succeeds. This is the ADR-007 lifecycle regression.
2. **`test_sim_display_acquires_vkms`** — same master-permission skip.
   On a VT it acquires master on vkms and verifies the 60×2170 dumb buffer.
3. **`tbard --dry-run` smoke test** — on a VT, the daemon should start,
   render to vkms, and exit cleanly on SIGTERM (master released). In this
   shell it fails at SimDisplay acquire (Permission denied) — expected.

## Items explicitly out of scope for this branch (per the task)

- **No hardware testing** — a separate QA session does that.
- **No uinput injection on the real digitizer** — SimInput creates its own
  uinput device; the real digitizer is never touched.
- **No kernel patches** — kernel-side findings (hid_multitouch
  `hid_field_extract` warning) go to a separate Seborider upstream lane.
- **IpcServer full wiring** — deferred to the IPC phase (ADR-005
  justification); the dead code stays compiled, serde tests stay green.