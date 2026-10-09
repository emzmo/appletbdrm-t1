# ADR 014: Ban the Indexing Bug Class (`clippy::indexing_slicing`)

## Status: Accepted

## Date: 2026-09-25

## Context

BUG A (`docs/adr/011-hermetic-dryrun.md`) was an index-out-of-bounds
panic at `src/main.rs:266` (`pages[active_page]` with empty `pages`).
ADR-011 fixed the specific instance and added bound checks, but the bug
*class* — direct indexing that can panic on an out-of-bounds — can recur
anywhere a `Vec`/slice is indexed without a prior bound check. The
render loop, widget engine, and page layout all index `Vec`s
(`pages[active_page]`, `widgets[widget_id]`, layer arrays).

The task: "deny `clippy::indexing_slicing` in `src/main.rs` and the
engine/render/widget modules, or convert the hot loop to `.get()` with
typed error propagation. All gates must stay green after the lint lands."

## Decision

### 1. Deny `clippy::indexing_slicing` in the engine/render/widget modules

Add `#![deny(clippy::indexing_slicing)]` (module-level) to:
- `src/main.rs` (the render loop + page indexing),
- `src/widgets/mod.rs`, `src/widgets/page.rs`, `src/widgets/button.rs`,
  `src/widgets/slider.rs` (widget vector indexing),
- `src/config/yaml.rs` (none currently, but guard against future).

Test modules `#[allow]` the lint (tests legitimately index with known
bounds + panic on assertion).

### 2. Convert the offending sites to `.get()` + typed error

Every `vec[i]` the lint flags is converted to `vec.get(i)` with a typed
error propagation (`anyhow::bail!` or an early-return `Result`), so an
out-of-bounds becomes a clean `Err` (logged by `main`), never a panic.
The ADR-011 bound checks in `real_main` already cover `pages[active_page]`;
this ADR sweeps the remaining sites (widget indexing in the gesture/hit-test
path, layer arrays) and makes the lint enforce it permanently.

### 3. Allow list

`#[allow(clippy::indexing_slicing)]` is used only where indexing is
provably safe AND a typed error path would obscure the logic
(e.g. a `slice[0]` immediately after `!slice.is_empty()`). Each allow
gets a one-line justification comment. The default is deny + `.get()`.

## Alternatives considered

- **Convert only the hot loop, no lint.** Rejected: without the lint the
  class recurs in a future edit; the lint makes it CI-enforced.
- **Global `#![deny]` at the crate root.** Rejected: the crate root
  already has `#![allow(dead_code)]` for Phase-2 stubs; a global deny
  would force every test module to allow. Scoped module-level denies are
  precise.

## Impact list

- `src/main.rs` — `#![deny(clippy::indexing_slicing)]` + convert the
  `pages[active_page]` and `pages[active_page].widgets[widget_id]` sites
  to `.get()` + typed error (the gesture/hit-test path).
- `src/widgets/*.rs` — module-level deny; convert any `widgets[i]`/`[0]`
  indexing to `.get()` or add a justified `#[allow]`.
- `src/config/yaml.rs` — module-level deny (defensive; no current sites).
- `scripts/ci-gate.sh` — already runs `clippy -D warnings`, so the deny
  is enforced continuously.

## Regression test

The clippy gate (`scripts/ci-gate.sh`, `-D warnings`) IS the regression
guard: any new `vec[i]` in the denied modules fails CI. No separate unit
test — the lint is the test. The existing `test_dry_run_demo_config_is_hermetic`
(ADR-011) exercises the render loop's page-construction path without panic.

## References

- `docs/adr/011-hermetic-dryrun.md` — the specific BUG A this class contains
- `docs/test-logs/dryrun-smoke.log:133-134` — the index-out-of-bounds panic