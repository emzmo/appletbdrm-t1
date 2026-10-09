# ADR 031: NF-5 Guard Strength — Catch Bare Numeric Scale Literals in `src/`

## Status: Accepted

## Date: 2026-09-26

## Context

QA v5 finding **NF-5** (`docs/test-logs/014/README.md`, carried forward
from session 013): the ADR-029 grep guard in
`scripts/check-invariants.sh` catches `const SIM_WIDTH`/`SIM_HEIGHT` and
`x/y_transformed(SIM_*)` re-introductions, but NOT a bare numeric scale
literal re-inlined in `src/` scale paths — e.g. `x_transformed(2170u32)`
or `y_transformed(60u32)` (or unsuffixed `2170`/`60`) planted directly in
`poll()`. A future regression that swapped `self.logical_dims` for a bare
literal would pass the existing guard but re-introduce the exact
sim/real divergence ADR-029 closed (sim scale denominators not
Geometry-derived).

The guard must be strengthened to catch the bare-numeric form, scoped to
`src/` (NOT `tests/` — test fixtures legitimately use bare numeric
literals like `2170`/`60` as abs-info maxima and scale targets).

## Decision

### 1. Add a `src/`-scoped grep for bare numeric scale literals in `x_transformed`/`y_transformed` calls

Add a check to `scripts/check-invariants.sh` that greps `src/` (recursively,
excluding comments) for `x_transformed(<numeric>)` or
`y_transformed(<numeric>)` where `<numeric>` is a bare integer literal
(optionally suffixed with `u32`/`u16`/`i32`/etc.). The pattern catches:

- `x_transformed(2170u32)`, `x_transformed(2170)`, `x_transformed(60u32)`, ...
- `y_transformed(60)`, `y_transformed(2170u32)`, ...

It does NOT flag `x_transformed(logical_w)` or
`x_transformed(self.logical_dims.0)` (variable references — the correct
form). The grep is scoped to `src/` so test fixtures in `tests/` and
`src/.../tests` modules that legitimately use bare numerics are NOT
false-positives.

### 2. Demonstrate the guard on a throwaway copy (plant → FAIL)

Before landing the guard, plant a bare numeric literal in a throwaway
copy of `src/providers/sim_input.rs` and run the guard to demonstrate it
FAILS. Then remove the plant and confirm the guard PASSES on clean
`src/`. The demonstration is captured in
`docs/test-logs/015/nf5-guard-demo.log`.

### 3. Scope to `src/` (avoid test-fixture false positives)

The existing ADR-029 guard checks `src/providers/sim_input.rs` for
`const SIM_*` and `x/y_transformed(SIM_*)`. The new guard is broader
(any `src/` file, any bare numeric) but still scoped to `src/` so the
test modules (which live under `src/.../tests` and `tests/`) are
excluded. The grep uses `grep -rE` over `src/` and excludes comment lines.

## Alternatives considered

- **A wider grep over the whole repo.** Rejected: test fixtures in
  `tests/` and `src/.../tests` modules legitimately use bare `2170`/`60`
  as abs-info maxima and scale targets (e.g.
  `SimInputProvider::new_with_range(32767, 127, 2170, 60)` in
  `sim_input.rs` tests). A repo-wide grep would flag those as
  false-positives, making the guard non-vacuous-but-noisy.
- **A clippy lint.** Rejected: there is no built-in clippy lint for
  "numeric literal as function argument" — clippy's
  `clippy::length_zero_to_empty`/etc. do not apply. A custom lint would
  require a `clippy`-dev build, out of scope.
- **Banning all numeric literals in `src/`.** Rejected: many legitimate
  numeric constants exist (thresholds, timeouts, `FRAME_LOG_INTERVAL`).
  The guard targets ONLY the scale-denominator call sites
  (`x_transformed`/`y_transformed`).

## Impact list

- `scripts/check-invariants.sh` — add a `src/`-scoped grep for
  `x/y_transformed(<bare-numeric>)` (section 6, after the existing
  ADR-029 section 5). FAIL on any match outside comments.
- No src/test changes.

## Regression test

The guard is demonstrated on a throwaway copy (plant a literal → FAIL,
remove → PASS) in `docs/test-logs/015/nf5-guard-demo.log`. The guard
runs as part of `scripts/check-invariants.sh` in every CI gate.

## References

- `docs/test-logs/014/README.md` — NF-5 finding
- `docs/adr/029-complete-adr-024-scale-wiring.md` — the ADR-029 guard
  this strengthens
- `scripts/check-invariants.sh` sections 5 (ADR-029) + 6 (ADR-031, new)