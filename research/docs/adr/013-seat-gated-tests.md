# ADR 013: Seat-Gated Tests Tell the Truth — Verbatim Child Stderr

## Status: Accepted

## Date: 2026-09-25

## Context

The VT-gate attempt (`docs/test-logs/vt-tests.log:146`) showed
`test_sigterm_releases_master` skip with a GUESSED cause:

```
test_sigterm_releases_master: skipped (daemon exited before SIGTERM —
likely could not acquire DRM master in this environment)
```

The guess was wrong: the dryrun smoke log (`dryrun-smoke.log:133-136`)
shows the daemon had actually **panicked at startup** (BUG A,
index-out-of-bounds), not failed with EACCES on master. The test could
not distinguish the two because it did not capture the child's stderr —
it only observed that the child had exited before SIGTERM and inferred a
cause in prose.

The task requirement: "Skip/fail messages must embed the child's stderr
verbatim. No guessing." Seat-gated tests must distinguish, in code:
- **child panicked at startup** (e.g. BUG A, or any other panic) —
  distinct from
- **master EACCES** (privilege/seat denied) — distinct from
- **clean early exit** (e.g. `--help`, or a normal shutdown).

## Decision

### 1. Capture the spawned child's stderr verbatim

`test_sigterm_releases_master` spawns `tbard --dry-run` with
`stderr(Stdio::piped())` and reads the full stderr buffer when the child
exits early. The skip/fail message embeds that buffer verbatim (in a
fenced block) so the operator sees exactly what the daemon said — no
inference.

### 2. Distinguish the three cases in code

When the child exits before SIGTERM, inspect the captured stderr + exit
status to classify:

- **Panicked at startup**: stderr contains `"panic at"` (the ADR-012 hook
  format) OR the exit status is a signal/abort. → `panic!` the test
  (REGRESSION — a startup panic is a code bug, not a seat issue). Embed
  the stderr.
- **Master EACCES**: stderr contains `"Permission denied"` /
  `"EACCES"` / the SimDisplay acquire error message. → skip with the
  verbatim stderr (this is the seat/privilege case the task documents).
- **Clean early exit**: exit success with no panic/EACCES markers. →
  skip with the verbatim stderr (unexpected but not a regression).

This replaces the single guessed skip message with three
evidence-grounded outcomes.

### 3. Apply the same verbatim-stderr pattern to `test_sim_display_acquires_vkms`

`test_sim_display_acquires_vkms` already distinguishes "no vkms card"
from "acquire failed" but its skip message for the acquire failure is a
bare `Err` display. Keep its structure but ensure the error (which may
carry `HwError::DrmMaster` with the OS errno) is rendered fully. No
behavior change — it already does not guess.

## Alternatives considered

- **Keep the guess, add a "see logs" pointer.** Rejected: the guess is
  the defect; the test must tell the truth from its own observation.
- **Parse exit codes only.** Rejected: a panic under `catch_unwind`
  exits 0 (the `main` logs + returns), so exit code alone cannot
  distinguish panic from clean exit — stderr content is required.

## Impact list

- `src/lifecycle.rs` — `test_sigterm_releases_master` rewritten:
  capture stderr, classify on early exit, embed verbatim in
  skip/panic messages.
- `src/providers/sim_display.rs` — `test_sim_display_acquires_vkms`:
  ensure the skip message renders the full `HwError` (already does;
  minor message tweak for consistency).
- No production-code change.

## Regression test

The rewritten `test_sigterm_releases_master` IS the regression guard: in
a session with BUG A present it would now `panic!` (REGRESSION) with the
verbatim index-out-of-bounds stderr instead of skipping with a wrong
guess. With BUG A fixed (ADR-011) and no master access, it skips with the
verbatim EACCES stderr. With master access (active VT), it runs the
full SIGTERM → master-release assertion.

## References

- `docs/test-logs/vt-tests.log:146` — the guessed skip message
- `docs/test-logs/dryrun-smoke.log:133-136` — the actual panic the guess missed
- `docs/adr/012-panic-hook-diagnostics.md` — the `"panic at"` hook format
  this test now greps for