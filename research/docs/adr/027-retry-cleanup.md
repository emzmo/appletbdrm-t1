# ADR 027: Retry Cleanup Assertion (partial-resource release)

## Status: Accepted

## Date: 2026-09-26

## Context

QA review-v4 (`docs/review-report-v4.md:388-390`) observed that
`test_retry_aborts_on_shutdown` (`src/providers/drm_backend.rs:451-488`)
injects a closure that always returns `Err(EBUSY)` — it never allocates a
card/db/fb, so the ADR-022 claim "releasing any partial resources" is
**vacuously true**: there is nothing to release. The test does not assert
a partially-allocated state is released on shutdown.

## Decision

### 1. Inject a closure that allocates on a later call, then fails

Add a test that injects a closure which **succeeds on the first call**
(allocating a card/db/fb into the `DrmProvider`) and **fails on the
second call** (simulating a card that appears, is opened, then a re-open
after a transient failure fails while the first allocation is still
held). Then set the shutdown flag and assert the retry loop aborts AND
the `DrmProvider`'s `Drop` releases the partial allocation (the `card`
field is `Some` → `Drop` runs `release()` → `release_master_lock()`).

Wait — `open_with_retry_injectable` stores the successful allocation
into `self` and `return Ok(())` on success, so the retry loop EXITS on
the first success. The "allocate then fail on a later call" scenario
does not arise in a single `open_with_retry_injectable` call (it returns
on the first `Ok`). The partial-resource concern is about a closure that
partially allocates INSIDE one call then returns `Err` (e.g. opens the
card fd, takes master, but fails at `create_dumb_buffer` — the card fd +
master are held but the closure returns `Err`, leaking the fd/master
because `open_with_retry_injectable` never stored them in `self`).

The real `try_open_card` does NOT leak in this case — it uses `?`
propagation, and on `Err` the `Card` (with the fd + master) is dropped
via Rust's drop glue (releasing master + closing the fd). The test
should verify this: inject a closure that opens a real vkms card +
acquires master + then returns `Err` (simulating a dumb-buffer failure),
then assert a SECOND acquisition of master on the same card succeeds
(the first master was released by the closure's drop glue).

### 2. The test

`test_retry_partial_alloc_releases_master_on_failure`: inject a closure
that (a) opens the vkms card read+write, (b) acquires master, (c)
returns `Err` (simulating a post-master failure). The closure's `Card`
is dropped on `Err`, releasing master. Then the test opens the same
vkms card and asserts `acquire_master_lock()` succeeds (proving the
partial master was released). This is the partial-resource release
assertion. Requires vkms + master access; skips gracefully otherwise.

## Alternatives considered

- **Mock the allocation with a fake `Card`.** Rejected: `Card` wraps a
  real `std::fs::File` + the `drm` crate traits; a fake would not
  exercise the real `release_master_lock` drop path. The vkms-backed
  test exercises the real DRM master release.

## Impact list

- `src/providers/drm_backend.rs` tests — add
  `test_retry_partial_alloc_releases_master_on_failure`.

## Regression test

`test_retry_partial_alloc_releases_master_on_failure` — described above.
Skips if no vkms card or master cannot be acquired (graceful skip per
the ADR-013 pattern; embeds the verbatim error).

## References

- `docs/review-report-v4.md:388-390` — the vacuously-true observation
- `docs/adr/022-sigterm-retry.md` — the "releasing any partial resources"
  claim this test now asserts