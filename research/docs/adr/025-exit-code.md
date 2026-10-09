# ADR 025: Exit-Code Contract (startup failures exit non-zero)

## Status: Accepted

## Date: 2026-09-26

## Context

QA review-v4 Exit-Code Audit (`docs/review-report-v4.md:232-265`,
`docs/test-logs/008/exit-code-audit.md`) is a **BLOCKER for the service
session**: `fn main()` (`src/main.rs:96`) returns `()`, so every
ADR-018-converted startup-failure path (`log::error!` + `return` at lines
126, 133, 182, 201) and the engine-`Err`/panic matches (145, 146, 209,
210) exit **0**. Live-confirmed: `HOME=$(mktemp -d) tbard --dry-run` →
EACCES → exit 0. A future `Restart=always` systemd service (ADR-019)
would treat exit 0 as success and spin silently on a startup failure.

The SIGTERM-clean exit (line 157) SHOULD stay 0 (it is a clean shutdown,
not a failure). The distinction: startup failures + engine errors must
exit non-zero; a clean SIGTERM exit must exit 0.

## Decision

### 1. `fn main()` returns `Result<(), Box<dyn std::error::Error>>`

Convert `fn main()` to return `Result<(), Box<dyn std::error::Error>>`.
Rust's runtime treats `Err` from `main` as exit code 1 (with an error
message); `Ok(())` as exit 0. This makes the exit-code contract automatic:
- Startup-failure paths return `Err(...)` (exit 1).
- The clean SIGTERM-during-retry path returns `Ok(())` (exit 0).
- The engine-`Err`/panic matches return `Err(...)` (exit 1).

`Box<dyn std::error::Error>` is used (not `anyhow::Error`) because
`anyhow::Error` does not implement `std::error::Error` (it's not
`Send + Sync` compatible with the `Termination` trait's `Box<dyn Error>`);
the startup errors are converted via `.into()`.

### 2. Map each exit path

| Path | Line (pre-fix) | Exit code | Return |
|---|---|---|---|
| `--help` / bad arg | 73/78 | 0 / 2 | unchanged (`process::exit`) |
| dry-run SimDisplay acquire fail | 126 | **1** | `Err(...)` |
| dry-run SimInput init fail | 133 | **1** | `Err(...)` |
| SIGTERM during card-open retry | 157 | **0** | `Ok(())` (clean) |
| card never appeared | 182 | **1** | `Err(...)` |
| backlight init fail | 201 | **1** | `Err(...)` |
| engine `Ok(Err(e))` | 145/209 | **1** | `Err(...)` |
| engine panic (`Err(_)`) | 146/210 | **1** | `Err(...)` |
| engine `Ok(Ok(()))` | 144/208 | **0** | `Ok(())` |

### 3. Sim test asserting non-zero exit

A unit test cannot directly assert a process exit code (it runs
in-process). Instead, add a small integration test that spawns
`target/debug/tbard --dry-run` with `HOME` pointed at an empty tempdir
(guaranteed EACCES on vkms master in a non-granted bench), waits for
exit, and asserts the exit code is non-zero. This is the live equivalent
of the QA v4 audit. Skips if the binary is not found or does not fail
(no EACCES in a granted bench).

## Alternatives considered

- **`std::process::exit(1)` at each failure site.** Rejected: less
  idiomatic than `Result`-from-`main`; skips `Drop` glue for locals still
  in scope at the `process::exit` call (though the startup paths have
  few locals). `Result`-from-`main` is the Rust convention.
- **Keep `()` + `exit(1)` only on the no-card path.** Rejected: the
  audit showed ALL startup failures exit 0; partial fix leaves the
  spin-silent hazard on the other paths.

## Impact list

- `src/main.rs` — `fn main()` signature →
  `Result<(), Box<dyn std::error::Error>>`; each startup-failure
  `return` → `return Err(...);`; engine-`Err`/panic matches →
  `return Err(...);`; SIGTERM-clean + `Ok(Ok(()))` → `Ok(())`.
- `tests/exit_code.rs` (or a `#[test]` in main) — integration test
  spawning the binary + asserting non-zero exit on a forced failure.

## Regression test

`tests/exit_code.rs`: `test_startup_failure_exits_nonzero` — spawns
`target/debug/tbard --dry-run` with `HOME=$(tempdir)` (forces config
fallback → demo_config → SimDisplay acquire; in a non-granted bench this
EACCESes), waits, asserts `!exit.success()` (non-zero). Skips if the
binary is not found or the exit is 0 with no EACCES (granted bench where
acquire succeeds — the test cannot force a failure there).

## References

- `docs/review-report-v4.md:232-265` — the Exit-Code Audit (BLOCKER)
- `docs/test-logs/008/exit-code-audit.md` — the live evidence (exit 0)
- `docs/adr/018-dryrun-typed-error.md` — the conversion that preserved
  the latent exit-0 bug