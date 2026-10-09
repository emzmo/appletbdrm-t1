# ADR 023: Frame Counter (S1-F2)

## Status: Accepted

## Date: 2026-09-26

## Context

Stage 1 finding **S1-F2** (`docs/test-logs/006/stage1/SUMMARY.md:108-119`):
the render loop has no explicit frame counter or periodic heartbeat log.
"Frame counter advancing" can only be inferred indirectly from the count
of `display flush error: ENOSYS` warnings. This is adequate for a sim
smoke but would not surface a **stalled render loop** (zero new frames) in
a long run unless an operator counts warnings. For endurance (Stage 7) a
structured periodic log is needed to detect a silent stall and feed the
future flush-stall cap.

## Decision

### 1. Structured periodic frame log every N frames

The render loop maintains a `frame_counter: u64` incremented each time a
frame is rendered (each redraw pass). Every `FRAME_LOG_INTERVAL` frames
(constant, default 100), emit a structured `info!` log:

```
tbard: frame stats: frames=N uptime=Ts dirty_flushes=M last_flush=<Ok|Err(detail)>
```

- `frames`: total frames rendered since startup.
- `uptime`: seconds since `real_main` start.
- `dirty_flushes`: count of successful `display.flush` calls (the
  vkms-ENOSYS case is counted as a flush attempt; `last_flush` records the
  result).
- `last_flush`: the result of the most recent flush (`Ok` or `Err(...)`
  truncated).

This makes a stall observable: if `frames` stops advancing between two
periodic logs, the loop is stuck. The log is `info!` so it appears at the
default verbosity; `debug!` would hide it in a production `info`-level
config.

### 2. Constant N, not a tunable

`FRAME_LOG_INTERVAL = 100` is a structural constant (like the ADR-021
debounce). It is not an operator tunable — it is the cadence at which the
endurance log fires. A future ADR may make it tunable if needed.

### 3. Feeds Stage 7 + future flush-stall cap

The `dirty_flushes` + `last_flush` fields give Stage 7 endurance a
greppable signal. A future flush-stall-cap ADR can use the same counter
to bound total stalls.

## Alternatives considered

- **Per-frame `debug!` log.** Rejected: too noisy at 10fps; the periodic
  summary is the right cadence.
- **A separate heartbeat thread.** Rejected: the render loop is the
  producer of frames; a heartbeat thread cannot observe a render stall
  without shared state. The periodic log is emitted from the render loop.

## Impact list

- `src/main.rs` — `frame_counter: u64` + `dirty_flushes: u64` +
  `last_flush_result: String` in `real_main`; increment per redraw; emit
  the periodic `info!` every `FRAME_LOG_INTERVAL` frames.
- A `FRAME_LOG_INTERVAL` constant.

## Regression test

`src/main.rs` tests: `test_frame_log_interval_constant` asserts the
constant is > 0 and reasonable (e.g. 100). The periodic log itself is
exercised by the hermetic smoke (the dry-run produces frames); no
separate unit test for the log emission (it's an `info!` line, not a
return value).

## References

- `docs/test-logs/006/stage1/SUMMARY.md:108-119` — S1-F2
- `docs/adr/014-ban-indexing-slicing.md` — the frame counter must not
  introduce new indexing (it doesn't)