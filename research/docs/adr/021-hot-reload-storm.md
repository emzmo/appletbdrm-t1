# ADR 021: Hot-Reload Storm — Drain + Debounce (S1-F3)

## Status: Accepted

## Date: 2026-09-26

## Context

Stage 1 finding **S1-F3** (`docs/test-logs/006/stage1/SUMMARY.md:121-146`):
after the first successful config reload, the daemon enters a tight loop
emitting `config reloaded` + `display flush error: ENOSYS` every iteration
(~hundreds of times per second) until SIGTERM. The hot-reload is unusable
in practice.

### Root cause (re-derived from code)

`src/config/manager.rs:51-67` `arm_watch` uses
`AddWatchFlags::IN_ONESHOT` (`:54`), so the watch fires once and is
removed. `check_reload` (`:89-118`):
- `:90-92`: if `self.watch.is_none()` (after a reload cleared it), re-arm
  and `return None` — this re-arm happens EVERY iteration after the first
  reload because `:110-111` sets `self.watch = None` then `arm_watch()`.
- `:94-117`: `read_events` reads pending events; if any match the watch,
  `changed=true`, `self.watch = None`, `arm_watch()`, return `Some(load())`.

The storm mechanism: after an atomic config replace (`mv new tmp.yaml
/etc/.../config.yaml`), the inotify queue contains MULTIPLE events
(IN_MOVED_TO + IN_CLOSE_WRITE, possibly IN_IGNORED for the old inode).
`read_events` (`:94`) reads a buffer's worth; the first call consumes
some, sets `changed=true`, re-arms, returns `Some(load())`. The re-armed
watch on the new inode + undrained stale events in the queue cause the
NEXT `check_reload` to immediately see events again → `changed=true` →
reload → repeat. The queue is never fully drained (a single
`read_events` does not loop until EAGAIN), and the `IN_ONESHOT` re-arm
every iteration keeps re-triggering.

Additionally, there is no debounce: a legitimate editor save (which may
write multiple times) or a tool that writes+rename produces a burst of
events that should coalesce into ONE reload, not N.

## Decision

### 1. Drain the inotify queue (read until EAGAIN)

After detecting a change, loop `read_events` until it returns `EAGAIN`,
discarding additional events. This clears stale events from the atomic
replace so the next `check_reload` sees an empty queue.

### 2. Stop per-iteration re-arming; use a persistent watch + debounce

Drop `IN_ONESHOT` — keep a persistent watch on the config path. Track
`last_reload: Instant`. On a change event, if `last_reload.elapsed() <
DEBOUNCE`, skip (the burst is coalescing). Otherwise reload and update
`last_reload`. This means:
- The watch is armed ONCE (in `new`/`arm_watch`), not re-armed every
  iteration.
- A burst of events from one save coalesces into one reload.
- No `self.watch = None` + re-arm dance that re-triggers.

A small debounce constant (default ~200ms) is injected as a field so the
regression test can use a short value. `DEBOUNCE` is not a tunable for
operators — it's a structural coalescing window.

### 3. Document the debounce

The ADR + a doc comment record: a single config write may produce a burst
of inotify events (IN_CLOSE_WRITE + IN_MOVED_TO for an atomic replace);
the debounce window coalesces them into exactly one reload. A second,
distinct write after the debounce window produces a second reload.

## Alternatives considered

- **Keep `IN_ONESHOT`, just drain.** Rejected: the per-iteration re-arm
  is itself part of the storm (re-arming on the new inode can generate a
  fresh event). A persistent watch + debounce is the stable fix.
- **polling (stat every N ms).** Rejected: inotify is already wired; the
  fix is to use it correctly.

## Impact list

- `src/config/manager.rs` — `arm_watch` drops `IN_ONESHOT`; `check_reload`
  drains the queue (loop until EAGAIN) + applies a debounce window against
  `last_reload: Instant`; no per-iteration re-arm. A `debounce:
  Duration` field (default constant) is added for test injection.
- No behavior change for a single reload (still works); the storm is gone.

## Regression test

`src/config/manager.rs` tests: `test_one_write_one_reload` — write the
config once, call `check_reload` (drives the inotify read), assert
exactly ONE `Some(Ok)` reload; then a quiescent window (no further
writes) ⇒ subsequent `check_reload` calls return `None` (ZERO reloads).
The test injects a short debounce constant. Uses `tempfile` (already a
dev-dep) + a real inotify watch on a tempdir config file.

## References

- `docs/test-logs/006/stage1/SUMMARY.md:121-146` — S1-F3
- `docs/test-logs/006/stage1/run5-hotreload-ok.log` — the storm evidence