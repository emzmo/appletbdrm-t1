# ADR 017: Assert the `#![deny]` Guard Exists (guard the guard)

## Status: Accepted

## Date: 2026-09-26

## Context

QA review-v3 C4 (`docs/review-report-v3.md:93-118`) observed that
ADR-014's `#![deny(clippy::indexing_slicing)]` lint guard is fragile:
removing the `#![deny]` line makes clippy PASS silently (verified in a
throwaway copy — clippy exit 0 with the deny removed). The `#[allow]`
annotations don't fail without the deny. This is a known limitation of
lint-based guards: there is no separate "the deny must exist" assertion.
ADR-014's own observation recommended a `check-invariants.sh` grep
asserting the `#![deny]` line is present at each required module root.

## Decision

Extend `scripts/check-invariants.sh` to grep each required module root
for the `#![deny(clippy::indexing_slicing)]` line:

- `src/main.rs`
- `src/widgets/mod.rs`, `src/widgets/page.rs`, `src/widgets/button.rs`,
  `src/widgets/slider.rs`
- `src/config/yaml.rs`

If any is missing, the script FAILs with the file path. This guards the
guard: removing the deny line (the fragility QA demonstrated) now fails
the invariant gate, not just clippy.

## Alternatives considered

- **A separate `deny-lint-presence.sh` script.** Rejected: folding into
  the existing `check-invariants.sh` keeps one invariant gate.

## Impact list

- `scripts/check-invariants.sh` — add a grep loop over the required
  module roots asserting the `#![deny(clippy::indexing_slicing)]` line.

## Regression test

The `check-invariants.sh` script IS the regression guard. A throwaway
removal of the deny line (per QA v3's demonstration) would now FAIL the
script.

## References

- `docs/review-report-v3.md:93-118` — the fragility observation
- `docs/adr/014-ban-indexing-slicing.md` — the lint being guarded