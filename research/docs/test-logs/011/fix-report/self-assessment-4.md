# Self-Assessment 4 — fix/hygiene-adr-016-023 (resume: ADR-024/025/027/028)

**Session**: 007 resume, **Date**: 2026-09-26
**Branch**: `fix/hygiene-adr-016-023`, off `master` (`v0.1.2-test3`).
**ADR 019 RESERVED** (service session — not used/renumbered).
**Bench-grant lane CLOSED** (ADR-026; HOST SAFETY RULES in
`docs/dangers.md`) — no login-chain/compositor-config work.
**No hardware testing** — sim harness only.

## Build/test summary (fix engineer's final run)

- `cargo fmt --check` → exit 0
- `cargo build --bin tbard` → exit 0 (ADR-028 ci-gate step)
- `cargo clippy --all-targets -- -D warnings` → exit 0
- `scripts/check-invariants.sh` → PASS
- `scripts/ci-gate.sh` → PASS
- `cargo test` → **41 unit + 1 integration = 42 passed; 0 failed**

## Invariant → status table

| Finding / Item | ADR | Fix commit | Evidence to re-verify | Regression test | Status |
|---|---|---|---|---|---|
| QA v4 Investigation C: scale target hardcoded + sim/real divergence | ADR-024 | `f18b82a` | `src/providers/input.rs` `poll` uses `self.tb_dims` (was hardcoded 2170/60); `SimInputProvider::new_with_range` for real-range test | `test_sim_input_scales_real_abs_range_to_logical` (abs_max 32767/127 → logical ≈1085/30) | **PASS** (1 test; skips if no uinput) |
| QA v4 Exit-Code Audit BLOCKER: startup failures exit 0 | ADR-025 | `41ab94d` | `fn main()` → `Result<(), Box<dyn Error>>`; startup failures `Err` (exit 1); clean SIGTERM `Ok` (exit 0) | `test_startup_failure_exits_nonzero` (integration; spawns tbard, asserts non-zero — **verified live: exit 1**) | **PASS** (1 integration test; BLOCKER fixed) |
| QA v4: ADR-022 test vacuously true (never allocates) | ADR-027 | `cc58081` | `test_retry_partial_alloc_releases_master_on_failure`: closure acquires master then Err → drop glue releases → 2nd acquire succeeds | the test itself (skips if bench not granted) | **PASS** (1 test; skips in non-granted bench — logic correct for granted bench) |
| QA v4: stale-binary fragility (cargo test doesn't rebuild tbard) | ADR-028 | `5f6a77c` | `scripts/ci-gate.sh` runs `cargo build --bin tbard` before tests | the ci-gate itself (fresh binary guaranteed) | **PASS** (ci-gate step) |

## Test count reconciliation

- Baseline (session 007 first half): 39 unit + 0 integration = 39.
- ADR-024: +1 unit (`test_sim_input_scales_real_abs_range_to_logical`) = 40.
- ADR-025: +1 integration (`test_startup_failure_exits_nonzero`) = 40 unit + 1 integration.
- ADR-027: +1 unit (`test_retry_partial_alloc_releases_master_on_failure`) = 41 unit + 1 integration.
- ADR-028: +0 tests (ci-gate step only) = 41 unit + 1 integration = **42 total**.

## Tests requiring a privileged / seat-granted environment

| Test | Requirement | This session | Note |
|---|---|---|---|
| `test_sim_display_acquires_vkms` | DRM master on vkms | skips (bench not granted) | ADR-026 procedure (CLOSED lane); sudo fallback per ADR-010 |
| `test_sigterm_releases_master` | DRM master on vkms (spawns tbard) | skips (bench not granted) | same |
| `test_retry_partial_alloc_releases_master_on_failure` | DRM master on vkms | skips (bench not granted) | ADR-027; same |
| `test_sim_input_scales_real_abs_range_to_logical` | `/dev/uinput` + libinput | **ran + PASS** (uinput only, no master) | exercises the real 32767→2170 scale |
| `test_sim_input_creates_uinput_device` | `/dev/uinput` | **ran + PASS** | uinput only |
| `test_startup_failure_exits_nonzero` | spawn `tbard --dry-run` (EACCES in non-granted bench) | **ran + PASS** (exit 1 on EACCES) | the exit-code contract assertion |
| All other tests | No privilege needed | PASS | — |

The bench-grant lane is CLOSED (ADR-026; HOST SAFETY RULES). The 3
master-gated tests skip gracefully with verbatim errors in this bench
state. The sudo prebuilt-binary path (ADR-010) is the official bench for
those tests — re-run there.

## Items explicitly out of scope (per the task)

- **No hardware testing** — sim harness only.
- **No service implementation** — ADR-019 reserved.
- **No login-chain/compositor-config work** — bench-grant lane CLOSED
  (HOST SAFETY RULES, `docs/dangers.md`).
- **ADR 019 NOT used/renumbered.**