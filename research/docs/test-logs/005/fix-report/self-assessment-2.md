# Self-Assessment 2 — fix/sim-harness-adr-011-015

**Session**: 003 (fix engineer), **Date**: 2026-09-25
**Branch**: `fix/sim-harness-adr-011-015`, based on
`fix/preflight-adr-004-009` (NOT merged to main; not rebased on main).
**Purpose**: invariant → status table for the fresh QA re-verification
session. Maps each BUG-class / diagnostic gap / ADR to its fix commit,
evidence, regression test, and status.

## Build/test summary (fix engineer's final run)

- `cargo fmt --check` → exit 0
- `cargo clippy --all-targets -- -D warnings` → exit 0
- `scripts/check-invariants.sh` → PASS
- `scripts/ci-gate.sh` → PASS
- `cargo test` → **32 passed; 0 failed** (25 from adr-004-009 branch + 7 new)

## Invariant → status table

| Item | ADR | Fix commit | Evidence to re-verify | Regression test | Status |
|---|---|---|---|---|---|
| BUG A — empty pages index panic (privilege-independent) | ADR-011 | `7dd2271` | `src/config/manager.rs:55-66` `load()` returns `Err(NoPagesConfigured)` on zero pages; `src/main.rs` dry-run uses `demo_config()` (hermetic); bound-check `active_page` | `test_zero_pages_is_typed_error_not_panic`, `test_empty_config_file_is_typed_error`, `test_dry_run_demo_config_is_hermetic`, `test_default_config_yields_pages` | **PASS** (BUG A fixed; 4 tests green) |
| Latent indexing at main.rs:258 (same class) | ADR-011 + ADR-014 | `7dd2271`/`71a4d97` | bound-check `active_page >= pages.len()` bails before indexing; `#![deny(clippy::indexing_slicing)]` crate-wide | the clippy gate enforces the deny | **PASS** |
| Panic hook discards backtrace + duplicates line | ADR-012 | `3b646ed` | `src/lifecycle.rs` `install_panic_hook`: one `log::error!` with `Backtrace::force_capture()`; no `eprintln!` | `test_panic_hook_logs_backtrace_and_runs_cleanup` (cleanup chain intact) | **PASS** (1 test green) |
| Seat-gated tests guess the cause | ADR-013 | `fb931bf` | `test_sigterm_releases_master` captures child stderr verbatim; classifies panicked/EACCES/clean-exit in code | the rewritten test itself | **PASS** — both tests RAN + PASSED this session |
| Ban the indexing bug class | ADR-014 | `71a4d97` | `#![deny(clippy::indexing_slicing)]` crate-root + widget/config modules; justified `#[allow]` on provably-safe bounded slicing | `cargo clippy -D warnings` in `scripts/ci-gate.sh` | **PASS** (lint enforces) |
| Two-backlight selection hazard | ADR-015 | `3a20dcf` | `select_touchbar_backlight_path()` in `src/providers/mod.rs`; skips main-display names | `test_select_touchbar_backlight_ignores_intel`, `test_select_touchbar_backlight_bails_on_no_match` (SIMULATED) | **PASS** (2 tests green) |
| Oracle provenance + privilege model (docs) | ADR-010 | `3a1f3b2` | `docs/adr/010-master-acquisition-input.md`; `docs/test-logs/004-service-oracle/` (runtime, unit, binary-identity) | (docs-only; no test) | **PASS** (recipe recorded; tbard does NOT privdrop today) |

## Tests that require a privileged / seat-granted environment

| Test | Requirement | This session | Re-verification paths |
|---|---|---|---|
| `test_sim_display_acquires_vkms` | DRM master on a vkms card | **RAN + PASSED** (card2) | (a) graphical session with `AQ_DRM_DEVICES` set to i915 so Hyprland releases card2; (b) prebuilt binary under sudo (production-faithful per ADR-010) |
| `test_sigterm_releases_master` | DRM master on a vkms card (spawns `tbard --dry-run`) | **RAN + PASSED** (card2) | same two paths |
| All other 30 tests | No privilege needed | PASS | `cargo test` in any session |

Both seat-gated tests **passed in this session** (BUG A fixed + this shell
had vkms master access). In other session classes they skip with a
verbatim-stderr message (ADR-013) or `panic!` (REGRESSION) if a startup
panic recurs. The two re-verification paths are documented in
`docs/test-plan.md` "Seat-gated test execution paths".

## Hermetic smoke (no privilege needed)

`HOME=$(mktemp -d) RUST_LOG=info cargo run -- --dry-run` → starts,
acquires vkms master, renders (vkms `dirty_framebuffer` returns `ENOSYS` —
a vkms limitation, not our bug; the render path executes fully), Ctrl+C
clean exit ("shutdown signal received, exiting"), immediate rerun OK
(master released by RAII `Drop`). **Verified live this session.**

## Items explicitly out of scope for this branch (per the task)

- **No hardware testing** — sim harness only (vkms + uinput).
- **No service implementation** — ADR-010 designs the bounded boot-retry
  loop but does NOT implement the systemd unit (separate future ADR).
- **No privdrop implementation** — ADR-010 records the recipe + the
  pre-drop fd checklist + the post-drop self-check requirement; the
  privdrop step itself is a future service ADR. `tbard` does NOT privdrop
  today (confirmed: `grep -rn "privdrop" src/` = 0 matches).
- **No edits under `backup_old/`** — the oracle source is read-only
  reference; no oracle code lands in `src/`.
- **No kernel patches** — kernel-side findings go to a separate lane.