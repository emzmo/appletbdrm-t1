# ADR 018: Dry-Run `panic!`s → Typed Error Propagation

## Status: Accepted

## Date: 2026-09-26

## Context

QA review-v3 Investigation B (`docs/review-report-v3.md:497-505`)
observed that the dry-run acquire path (`src/main.rs:121,125`) uses
`panic!` for `SimDisplayProvider::acquire` / `SimInputProvider::new`
failures, outside the ADR-006 `#![deny(clippy::panic)]` hardware-provider
modules. The current panic hook handles it cleanly, so this is cosmetic
consistency, not a correctness bug — but the ADR-006 typed-error pattern
is the established convention, and `panic!` in `main` bypasses the
graceful-exit path (the `:121` panic is outside `catch_unwind`).

## Decision

Convert the three remaining `panic!`s in `main`'s startup paths to
`log::error!` + `return` (graceful exit, typed failure, no panic):
- `src/main.rs:124` dry-run `SimDisplayProvider::acquire` failure.
- `src/main.rs:128` dry-run `SimInputProvider::new` failure.
- `src/main.rs:192` real-mode `SysfsBacklight::new` failure.

The errors are already typed (`HwError`-carrying `anyhow::Error` from
the providers); `main` logs the structured error and returns. No
behavior change — the daemon still exits non-zero on a startup failure;
it just does so via `log::error!` + return instead of `panic!` + unwind.
The panic hook is no longer exercised for these paths (it remains for
genuine panics elsewhere).

## Alternatives considered

- **Leave the `panic!`s (the hook handles them).** Rejected: consistency
  with ADR-006's typed-error pattern + the graceful-exit path is
  cleaner; the `:121` panic being outside `catch_unwind` means the
  `real_main` `catch_unwind` doesn't cover it.

## Impact list

- `src/main.rs` — three `panic!`s → `log::error!` + `return`.

## Regression test

No new test — the existing ADR-013 `test_sigterm_releases_master` + the
dry-run smoke exercise these paths; the behavior (exit on failure) is
unchanged. The `check-invariants.sh` ADR-017 guard does not cover `main`
(the crate root is not a hardware-provider module), so no lint change.

## References

- `docs/review-report-v3.md:497-505` — the observation
- `docs/adr/006-typed-errors.md` — the typed-error pattern