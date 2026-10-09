# Exit-Code Audit (ADR-018 risk) — BLOCKER for the service session

Date: 2026-09-26T01:00+01:00
uid: 1000, session: wayland/seat0 active

## Hypothesis (from the review prompt)

ADR-018 converted three `panic!`s in `main`'s startup paths to
`log::error!` + `return`. Because `fn main()` returns `()` (not
`Result`), a `return` from `main` exits with code **0**. A future
`Restart=always` systemd service (ADR-019, reserved) would treat exit 0
as success — converting a startup FAILURE into a silent restart loop
with no alarm.

## Code evidence

`src/main.rs` — `fn main()` (line 96) returns `()`:

```rust
fn main() {
    ...
    if let Err(e) = display.acquire() {
        log::error!("tbard: dry-run SimDisplay acquire failed: {}", e);
        return;            // line 126 → exit 0
    }
    ...
    Err(e) => {
        log::error!("tbard: dry-run SimInput init failed: {}", e);
        return;            // line 133 → exit 0
    }
    ...
    if lifecycle::should_shutdown() { return; }   // line 157 → exit 0 (clean)
    ...
    None => {
        log::error!("tbard: Touch Bar card never appeared: {}", last_err);
        return;            // line 182 → exit 0  (STARTUP FAILURE)
    }
    ...
    Err(e) => {
        log::error!("tbard: backlight init failed: {}", e);
        return;            // line 201 → exit 0  (STARTUP FAILURE)
    }
    ...
    Ok(Err(e)) => log::error!("tbard: engine returned error: {:#}", e),  // line 145/209 → exit 0
    Err(_) => log::error!("tbard: engine panicked"),                     // line 146/210 → exit 0
}
```

The only `std::process::exit` calls are `exit(0)` for `--help` (line 73)
and `exit(2)` for a bad argument (line 78). Every ADR-018-converted
startup-failure path falls through to `main` returning `()` → exit 0.

## Live evidence (sim harness)

Binary: `target/debug/tbard` (rebuilt this session, 00:57).

```
$ HOME=$(mktemp -d) RUST_LOG=info ./target/debug/tbard --dry-run
[INFO  tbard] tbard: Touch Bar engine starting (mode: dry-run)
[ERROR tbard] tbard: dry-run SimDisplay acquire failed: Permission denied (os error 13)
$ echo $?
0
```

A startup FAILURE (EACCES on vkms master acquire) exits **0**.

Control:
```
$ HOME=$(mktemp -d) RUST_LOG=info ./target/debug/tbard --bogus-arg; echo $?
2
```
Bad-arg path correctly exits 2 (pre-ADR-018 logic, unchanged).

## Verdict

**ADR-018's own claim is REFUTED.** The ADR text states: "No behavior
change — the daemon still exits non-zero on a startup failure; it just
does so via `log::error!` + return instead of `panic!` + unwind." This
is false: `panic!` + unwind through `catch_unwind` would have returned
an `Err` to `main`'s `match result` (also logged, also exit 0 — the
PRE-ADR-018 code already exited 0 on a caught panic). The conversion did
NOT introduce a non-zero exit; it removed the panic-hook/backtrace
diagnostic for these paths and left the exit code at 0.

This is a **pre-existing** latent bug (the `Ok(Err(e))`/`Err(_)` matches
at 145/146/209/210 also exit 0), surfaced/re-confirtable by ADR-018's
conversion. It is a **BLOCKER for the service session**: a
`Restart=always` unit would spin on a "successful" exit 0 with no
failure signal. A `Type=notify`/`Restart=on-failure` unit needs a
non-zero exit on startup failure.

## Fix pointer (ADR for the NEXT session — do NOT fix in this freeze)

`fn main()` should return `Result<(), E>` (or call
`std::process::exit(1)` on the startup-failure paths), so a typed
startup failure exits non-zero. The clean-shutdown SIGTERM path (line
157, `should_shutdown` during retry) may legitimately exit 0, but the
acquire/backlight/card-never-appeared failures (126, 133, 182, 201) and
the `Ok(Err(_))`/`Err(_)` engine-failure matches (145, 146, 209, 210)
must exit non-zero. Suggest ADR-024 (or fold into ADR-019 service
session) covering: `main` returns a typed `Result`, startup failures
exit 1, SIGTERM-clean exit 0, panic-caught exit 1 (distinct from
SIGTERM-clean). Pair with a sim test that asserts `$? != 0` on an
injected acquire failure.