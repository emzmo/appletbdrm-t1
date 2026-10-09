# ADR 006: Typed Errors on Hardware Paths — No `unwrap`/`expect`/`panic`

## Status: Accepted

## Date: 2026-09-25

## Context

Pre-flight review §2.3 (`docs/review-report.md`) found many
`unwrap()`/`expect()`/`panic!()` calls directly on hardware paths: DRM
`display_info`, uinput open/ioctls/writes, sysfs backlight reads, and
fontconfig FFI. A single `write` failure on the uinput path killed the
daemon; a missing sysfs brightness file panicked at startup; a damaged
cairo surface panicked the render loop. The review also flagged that
`panic::catch_unwind` swallowed panics silently with no cleanup.

The task requires: a typed error enum with context (device, ioctl), full
propagation, and clippy lints so `unwrap`/`expect`/`panic` **cannot
return** on hardware paths.

## Root cause

The code used `anyhow::Result` for fallible operations but defaulted to
`.unwrap()`/`.expect()` at hardware boundaries "for brevity," with no
distinction between "programmer bug" (warranted panic) and "hardware
transient" (warranted propagation). There was no typed error carrying
device/ioctl context, so error logs were strings without structure, and
the lint configuration did not forbid the foot-gun.

## Decision

### 1. Typed error enum (`src/providers/error.rs`)

Introduce a `HwError` enum carrying structured context (device path,
ioctl/sysfs attribute, OS errno) for every hardware failure category:

```rust
pub enum HwError {
    DrmOpen   { path: PathBuf, source: io::Error },
    DrmMaster { path: PathBuf, source: io::Error },
    DrmIoctl  { path: PathBuf, ioctl: &'static str, source: io::Error },
    DrmFlush  { path: PathBuf, source: io::Error },
    SysfsRead { path: PathBuf, attr: String, source: io::Error },
    SysfsWrite{ path: PathBuf, attr: String, source: io::Error },
    Uinput    { op: &'static str, source: io::Error },
    UinputWrite { source: io::Error },
    Ffi       { func: &'static str, detail: String },
    Backlight { detail: String },
    NotFound  { what: &'static str },
}
```

`HwError` implements `std::error::Error` + `Display` (rich, structured
messages) and `From<io::Error>` is **not** blanket-implemented (to force
call sites to attach device/ioctl context). A `From<HwError> for
anyhow::Error` bridge lets the typed errors propagate through the
existing `anyhow::Result` return types without rewriting every signature.

### 2. Propagate on hardware paths

Replace every `unwrap()`/`expect()`/`panic!()` on DRM, uinput, sysfs,
and FFI paths with `?` (returning `Result<_, HwError>` or `anyhow::Result`):
- `src/main.rs` uinput setup + `emit_keys` writes → propagate.
- `src/providers/backlight.rs` `read_attr` panic → `Result`; silent write
  → propagate and surface (ties into ADR 008 fail-safe).
- `src/providers/drm_backend.rs` / `sim_display.rs` → already return
  `Result`; audit for residual unwraps.
- `src/fonts.rs` FFI `CString::new(...).unwrap()` /
  `CStr::to_str().unwrap()` → propagate as `HwError::Ffi`.

Render-path cairo `unwrap()`s (`Context::new`, `paint`, `surface.data`)
are **not** hardware paths; they are left as-is for now (cairo allocation
failures are OOM, a different failure class). They are tracked for a
future render-resilience ADR. This keeps the change scoped to the ADR's
hardware invariant.

### 3. Clippy lints forbidding return on hardware paths

Add module-level clippy denies in the hardware modules so the foot-gun
cannot return:

```rust
// src/providers/backlight.rs, drm_backend.rs, sim_display.rs, sim_input.rs,
// src/providers/input.rs, src/fonts.rs
#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
```

`#[allow(...)]` is used sparingly and only where a panic is genuinely
unreachable (e.g. a `CString` from a static literal) with a justifying
comment. Test modules use `#[allow(clippy::unwrap_used)]` because tests
 legitimately panic on assertion failure.

The crate root does **not** deny globally (the bin `main` and test code
still use `unwrap`/`expect`/`panic` for programmer-error exits); the deny
is scoped to the hardware-provider modules where the invariant applies.

### 4. `main` shutdown on propagated errors

Hardware errors that previously panicked now return `Err` up to `main`.
`real_main` returns `anyhow::Result<()>`; on `Err` it logs the structured
error and breaks the loop cleanly so the lifecycle ADR (007) RAII guards
run. The infinite loop gains an exit-on-error path. (The signal-handler
exit is ADR 007; this ADR only ensures errors propagate instead of
panicking.)

## Alternatives considered

- **Global `#![deny(clippy::unwrap_used)]` at the crate root.** Rejected:
  it would force rewriting every test and the `main` entry's intentional
  `panic!` for "card never appeared" (which is a legitimate fail-fast).
  Scoped denies target the invariant precisely.
- **Keep `anyhow` everywhere, no typed enum.** Rejected: the task requires
  a typed error enum with device/ioctl context, and structured errors make
  the recovery/diagnosis path in ADR 007 + the upstream Seborider issue
  triage far easier than string-matching.
- **`thiserror` derive macro.** Rejected for scope: one enum with manual
  `Display`/`Error` impls avoids a new dependency and keeps the change
  minimal.

## Impact list

- `src/providers/error.rs` — new: `HwError` enum + `Display`/`Error` +
  `From<HwError> for anyhow::Error`.
- `src/providers/mod.rs` — declare `pub mod error;`.
- `src/providers/backlight.rs` — `read_attr` → `Result`; `set_backlight_file`
  → `Result`; module-level clippy denies.
- `src/providers/drm_backend.rs`, `sim_display.rs`, `sim_input.rs`,
  `input.rs` — module-level clippy denies; residual unwraps converted to
  `?` with context.
- `src/fonts.rs` — FFI unwraps → `Result`; SAFETY context (ties to ADR
  007's unsafe justification, but the unwrap removal is this ADR).
- `src/main.rs` — `emit_keys` + uinput setup propagate; `real_main`
  returns `Result` and exits the loop on error.
- No public trait signature changes (still `anyhow::Result`).

## Regression test

`src/providers/error.rs` tests: `test_hwerror_display_contains_context`
asserts each variant's `Display` string includes the device path / ioctl
name (the structured context the review asked for).
`test_hwerror_propagates_through_anyhow` asserts a `HwError` returned from
a fallible fn propagates through `anyhow::Result` without panic.

The clippy gate (`scripts/ci-gate.sh`, `-D warnings`) enforces the
module-level denies continuously — any new `unwrap`/`expect`/`panic` in
a hardware module fails CI.

## References

- `docs/review-report.md` §2.3 (the FAIL being fixed)
- `docs/review-report.md` §2.5 (FFI unwraps overlap with ADR 007)