# Self-Assessment 3 — fix/hygiene-adr-016-023

**Session**: 007 (fix engineer), **Date**: 2026-09-26
**Branch**: `fix/hygiene-adr-016-023`, off `master` (`v0.1.2-test3`).
**ADR 019 RESERVED** for the future service session — NOT used/renumbered.
**No hardware testing** — sim harness only (vkms + uinput).

## Build/test summary (fix engineer's final run)

- `cargo fmt --check` → exit 0
- `cargo clippy --all-targets -- -D warnings` → exit 0
- `scripts/check-invariants.sh` → PASS (incl. new ADR-017 deny-guard)
- `scripts/ci-gate.sh` → PASS
- `cargo test` → **39 passed; 0 failed** (32 baseline + 7 new)

## Invariant → status table

| Finding / Item | ADR | Fix commit | Evidence to re-verify | Regression test | Status |
|---|---|---|---|---|---|
| S1-F1 coordinate-space mismatch + no widget-ID log (HARD BLOCKER) | ADR-020 | `d22c8a6` | `src/geometry.rs` `Geometry` (three-space model); `real_main` feeds logical dims to `layout` + `apply_paint_matrix`; tap path `info!` logs page/widget/logical (x,y)/gesture | `test_geometry_swaps_framebuffer_to_logical`, `test_geometry_already_landscape_stays`, `test_pixel_probe_paint_matrix_in_bounds` (FAILED pre-fix, now PASSES), `test_hit_test_round_trip_logical_space` (4 widgets) | **PASS** (4 tests; pre-fix pixel-probe demonstrated off-canvas paint) |
| S1-F2 no frame counter | ADR-023 | `b457f42` | `real_main` `frame_counter`/`dirty_flushes`/`last_flush_result`; `info!` every `FRAME_LOG_INTERVAL=100` frames | `test_frame_log_interval_constant` | **PASS** (1 test) |
| S1-F3 hot-reload storm | ADR-021 | `2af9513` | `arm_watch` dropped `IN_ONESHOT` (persistent); `check_reload` drains queue + debounces; no per-iteration re-arm | `test_one_write_one_reload` (one write ⇒ one reload; quiescent ⇒ zero) | **PASS** (1 test, verified live) |
| S2-F1 SIGTERM not honored during retry | ADR-022 | `075bae3` | `open_with_retry_injectable` checks `should_shutdown` each iter + `shutdown_aware_sleep`; `main` outer retry honors shutdown + graceful return | `test_retry_aborts_on_shutdown` (injected EBUSY + shutdown ⇒ aborts < 2s, took 0.10s) | **PASS** (1 test) |
| S2-F2 unprivileged card0 EACCES | — | — | (no code change — expected per ADR-010) | — | **N/A** (no change) |
| QA-016 logind seat-ACL path + ADR-010 caveat | ADR-016 | `00a1689` | `docs/adr/016-logind-seat-acl.md`; ADR-010 amended (logind path + `/proc/562/fd` root caveat) | (docs-only) | **PASS** |
| QA-017 assert the `#![deny]` guard exists | ADR-017 | `00a1689` | `scripts/check-invariants.sh` greps required module roots for `#![deny(clippy::indexing_slicing)]` | the script itself (throwaway removal FAILs) | **PASS** |
| QA-018 dry-run `panic!`s → typed error | ADR-018 | `00a1689` | `src/main.rs` `:124/:128/:192` `panic!` → `log::error!` + `return` | existing ADR-013 + dry-run smoke (behavior unchanged) | **PASS** |

## Tests requiring a privileged / seat-granted environment

| Test | Requirement | This session | Re-verification paths |
|---|---|---|---|
| `test_sim_display_acquires_vkms` | DRM master on vkms | ran + PASS in prior sessions (active seat0 ACL per ADR-016) | (a) active seat0 session (logind ACL); (b) sudo (ADR-010 root path) |
| `test_sigterm_releases_master` | DRM master on vkms (spawns `tbard --dry-run`) | ran + PASS in prior sessions | same two paths |
| All other 37 tests | No privilege needed | PASS | `cargo test` in any session |

Both seat-gated tests passed unprivileged in the prior session via the
logind seat ACL (ADR-016 documents this mechanism). They are NOT
re-exercised in this session (no hardware/sim runtime verification was
performed — code-only + unit tests). The two re-verification paths are
documented in `docs/test-plan.md` "Seat-gated test execution paths".

## Pre-fix pixel-probe demonstration (recorded in devlog)

A worktree at `v0.1.2-test3` with only the pixel-probe test added →
FAILED: "predicted device (30,1000) should be red (R=0xFF); got
0x00000000. On the broken tree the translate uses the long dim so the
paint is off-canvas." The paint landed at device-x ≈ 2110..2170 (out of
fb width 60). Worktree removed; test+fix landed in one commit (ADR-020).

## Items explicitly out of scope (per the task)

- **No hardware testing** — sim harness only.
- **No service implementation** — ADR-010's bounded boot-retry is
  design-only; ADR-019 reserved for the future service session.
- **No edits under `backup_old/`** — oracle source read-only.
- **ADR 019 NOT used/renumbered.**