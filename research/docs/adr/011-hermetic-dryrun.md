# ADR 011: Empty Pages → Typed Error + Hermetic Dry-Run

## Status: Accepted

## Date: 2026-09-25

## Context

The VT-gate attempt (`docs/test-logs/dryrun-smoke.log`) hit a
deterministic, privilege-independent startup panic at `src/main.rs:266:18`:

```
tbard: panic: panicked at src/main.rs:266:18:
index out of bounds: the len is 0 but the index is 0
```

**Root cause** (confirmed by reading the code, not guessing):
`ConfigManager::load()` (`src/config/manager.rs:55-66`) returns
`Ok(TouchbarConfig { pages: vec![], .. })` (line 64) when neither
`/etc/touchbar-engine/config.yaml` nor `/usr/share/touchbar-engine/config.yaml`
exists — both absent on this bench. `main.rs:207-210`'s
`cfg_mgr.load().unwrap_or_else(|e| default_config())` only invokes
`default_config()` on `Err`; because `load()` returns `Ok` (empty pages),
the 2-page `default_config()` is never used. `build_pages(&cfg, width)`
returns an empty `Vec`, `active_page = 0`, and the first redraw panics at
`pages[active_page].layout(...)` (`main.rs:266`).

The same latent indexing bug exists at `main.rs:258`
(`pages[active_page].is_dirty()`), masked by `||` short-circuit when
`needs_redraw` is true on the first iteration — it would panic on a later
iteration if `needs_redraw` were false and `pages` were empty.

The dry-run is **NOT hermetic**: it depends on external config files. The
fix engineer's earlier live smoke passed only because a config file
existed in that environment.

## Decision

### 1. Typed error for zero pages

Add a `ConfigError` enum (in `src/config/mod.rs` or `src/providers/error.rs`)
with a `NoPagesConfigured` variant. `ConfigManager::load()` returns
`Err(ConfigError::NoPagesConfigured)` when the loaded config has zero
pages, instead of `Ok` with an empty vec. `main` propagates this as an
`anyhow::Result` error (logs + exits) — never an index panic.

The fallback path (`load()` finds no config file) also returns
`Err(ConfigError::NoPagesConfigured)` rather than `Ok`-empty, so the
`unwrap_or_else(|e| default_config())` arm in `main` finally fires and
the daemon proceeds with the built-in default — but see §2: in dry-run we
do better.

### 2. Hermetic `--dry-run` with a built-in demo page

`--dry-run` must not depend on external config. In dry-run mode, `main`
synthesizes a deterministic built-in demo page (a couple of buttons +
a slider, sized for 60×2170) and runs the engine against it with ZERO
dependence on `/etc/` or `$HOME`. This makes the smoke test hermetic:
`HOME=$(mktemp -d) cargo run -- --dry-run` always exercises
layout → render → input.

In real mode, the existing config-load path is preserved (with the §1
typed error now guarding the empty-pages case).

### 3. Fix the latent indexing at main.rs:258

Replace `pages[active_page]` indexing in the render loop with `.get()`
and propagate a typed error on out-of-bounds, so the bug class cannot
recur even if a future change re-introduces an empty `pages` vec. This is
the localized fix; ADR-014 bans the whole class via
`clippy::indexing_slicing`.

## Alternatives considered

- **Just make `default_config()` the fallback for empty pages.**
  Rejected as insufficient: it hides the misconfiguration (zero pages is
  a config error worth surfacing) and does not make dry-run hermetic
  (real-mode would still silently fall back when a config file exists but
  has zero pages).
- **Panic on zero pages with a clear message.** Rejected: ADR-006 removes
  panics from startup paths; a typed error that propagates to `main`'s
  log+exit is the established pattern.

## Impact list

- `src/config/manager.rs` — `load()` returns `Err(ConfigError::NoPagesConfigured)`
  on zero pages (both the no-file fallback and the empty-file case).
- `src/config/mod.rs` or `src/providers/error.rs` — `ConfigError` enum
  (or a `HwError`-adjacent variant). Chosen: a small `ConfigError` in
  `src/config/mod.rs` bridged into `anyhow::Error` via the `Error` trait.
- `src/main.rs` — dry-run synthesizes a built-in demo page; real-mode
  preserves the config-load path with the typed error guarding empties;
  `pages[active_page]` indexing converted to `.get()` + typed error at
  the two loop sites (`:258`, `:266`, and the render/hit-test sites that
  follow).

## Regression tests

- `test_zero_pages_is_typed_error_not_panic`: construct a
  `ConfigManager`/`load` path that yields zero pages, assert it returns
  `Err(ConfigError::NoPagesConfigured)` (no panic).
- `test_dry_run_smoke_hermetic`: a test that simulates the dry-run
  page-synthesis path with `HOME` pointed at an empty tempdir, asserts
  the demo page is built and `pages.len() > 0`. (tempfile is already a
  dev-dep.) Marked SIMULATED — it does not start the full daemon (which
  needs vkms master); it exercises the page-construction seam.

## References

- `docs/test-logs/dryrun-smoke.log` — the BUG A panic evidence
- `docs/adr/010-master-acquisition-input.md` — config-at-/etc + ProtectHome
- `docs/adr/006-typed-errors.md` — the typed-error pattern this follows