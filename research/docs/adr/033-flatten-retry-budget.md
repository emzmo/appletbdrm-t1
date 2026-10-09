# ADR 033: Flatten the Retry — System-Level Wall-Clock Budget

## Status: Accepted

## Date: 2026-09-26

## Context

QA v6 finding **NF-A1** (`docs/review-report-v6.md:450-465`,
`docs/test-logs/016/audit-a-unpriv-service.log`,
`docs/test-logs/016/audit-c-retry-exhaust.log`): the retry path that
covers the T1 config-2 boot race is **nested**, not single-level, so the
actual worst-case wall-clock is ~30 minutes, NOT the 60 seconds claimed
by ADR-019 D3.

### Root cause from code (cite file:line)

`src/main.rs:198-222` — an OUTER `for attempt in 1..=30` loop calls
`prov.acquire()` each iteration:

```rust
for attempt in 1..=30 {                       // main.rs:198 — OUTER 30 iterations
    if lifecycle::should_shutdown() { ... }
    let mut prov = DrmProvider::new();
    match prov.acquire() {                     // main.rs:206 — calls acquire()
        Ok(()) => { card = Some(prov); break; }
        Err(e) => {
            last_err = e.to_string();
            ...
            std::thread::sleep(Duration::from_secs(2));  // main.rs:219
        }
    }
}
```

`src/providers/drm_backend.rs:340-342` — `DrmProvider::acquire()` is
itself ANOTHER 30×2s loop:

```rust
fn acquire(&mut self) -> anyhow::Result<()> {
    self.open_with_retry(30, std::time::Duration::from_secs(2))
}
```

`open_with_retry` (`drm_backend.rs:221-285`) iterates `1..=max_attempts`
(30) with a `retry_interval` (2s) sleep between attempts. The total
worst-case retry is therefore **30 (outer) × 30 (inner) × 2s = 1800s ≈
30min**, NOT the 60s claimed in ADR-019 D3 (`docs/adr/019-production-service.md:126-131`,
lines 126-131: "Worst case 30 × 2s = 60s of bounded retry").

### Why D3's 60s claim was arithmetically wrong

ADR-019 D3 computed `30 × 2s = 60s` — counting ONLY the INNER
`open_with_retry(30, 2s)`. It did not account for the OUTER loop in
`main.rs` that RESTARTS the inner loop up to 30 times. The outer loop
predates ADR-019 (present at `feb8d8f`, the master base), but ADR-019
D3's "60s bounded retry" claim is **REFUTED by the actual nested
structure** — bounded × bounded = effectively unbounded (1800s, not
60s). The QA v6 live audits (A/C) confirmed this: the inner 30/30
completes at ~60s, then the outer loop restarts the inner loop (Audit C
observed the restart at ~60s; Audit A observed two inner cycles
completing in 120s before the harness SIGTERM interrupted the third).

### Consequence

1. **systemd's `StartLimitIntervalSec=300`/`StartLimitBurst=10`
   rate-limiting is effectively moot.** A single start attempt runs
   ~30min before the daemon's own exit-1 — one attempt outlasts the
   300s window, so `StartLimitBurst=10` would never fire (the window
   expires before the first attempt finishes). With
   `Restart=on-failure` this is a spin-storm in production (one 30-min
   start, restart, another 30-min start, …).

2. **W1's StartLimit calibration was tuned against the wrong duration.**
   The unit file's `StartLimitIntervalSec=300`/`StartLimitBurst=10`/
   `RestartSec=5s` were calibrated for the CLAIMED 60s retry envelope
   (10 restarts × (60s + 5s) ≈ 650s, with the 300s window catching a
   persistent hard failure inside ~5-6 restarts). Under the ACTUAL
   ~30min nested-retry behavior, this calibration is wrong. The unit
   values must be retuned against the CORRECTED budget.

### Evidence the card appears late (boot race is real)

- ADR-019 D3 (`docs/adr/019-production-service.md:126-131`): "the
  config-2 USB switch exposes the Touch Bar DRM card late at boot ...
  the config-2 switch fires within ~5–10s of `appletbdrm` probe."
- The oracle's `Restart=always` spin (`docs/adr/010-master-acquisition-input.md`
  §"Boot race") is evidence the card appears late — the oracle retries
  until the card appears. The boot race is real; the retry is needed.
  The bug is the NESTING (bounded × bounded), not the retry itself.

## Decision

### 1. Retry budgets are SYSTEM-LEVEL, never per-layer

A retry budget is a single total wall-clock cap that covers the entire
boot-race retry, enforced at ONE level. No layer may wrap another
bounded retry — bounded × bounded = effectively unbounded. The
system-level budget is the single source of truth for "how long do we
wait for the card before declaring a persistent failure."

### 2. Remove the outer loop; single-level bounded retry with ONE wall-clock budget

**Remove the outer `for attempt in 1..=30` loop in `src/main.rs:198-222`
entirely.** Replace it with a single `prov.acquire()` call. The retry
lives ONLY inside `DrmProvider::acquire()` → `open_with_retry`, now
budgeted by **total elapsed wall-clock** (not a count × interval
product).

**New `open_with_retry` signature** (replaces the count-based one):
```rust
pub fn open_with_retry(&mut self, budget: Duration, retry_interval: Duration)
    -> anyhow::Result<()>
```

- `budget` — the total wall-clock budget (e.g. 90s). The retry bails
  when `Instant::now()` exceeds the deadline (`start + budget`).
- `retry_interval` — the sleep between attempts (e.g. 2s), unchanged.
  The existing `shutdown_aware_sleep` (50ms poll) is preserved so
  SIGTERM wakes the loop within ~50ms.

**`DrmProvider::acquire()`** calls
`self.open_with_retry(BUDGET, RETRY_INTERVAL)` with module-level
constants:
```rust
/// ADR-033: system-level wall-clock budget for the boot-race retry.
/// Covers the config-2 USB switch exposing the Touch Bar card late at
/// boot (ADR-019 D3: typically ~5-10s; budget is generous for slow
/// probes). The 30-min nested-retry case (NF-A1) is impossible by
/// construction — there is no outer loop.
const RETRY_BUDGET: std::time::Duration = std::time::Duration::from_secs(90);
const RETRY_INTERVAL: std::time::Duration = std::time::Duration::from_secs(2);
```

**Recommended budget: ~90s.** Rationale:
- The config-2 switch fires within ~5-10s (ADR-019 D3); 90s gives a
  ~9-18x safety margin for slow probes / cold boots.
- 90s is well under systemd's `StartLimitIntervalSec=300` so a single
  start attempt finishes well within the rate-limit window (the
  StartLimit can actually fire now — see W1 recalibration below).
- 90s is short enough that a persistent hard failure (card never
  appears) is surfaced to the operator in ~90s, not ~30min.

### 3. SIGTERM-responsive (ADR-022 machinery preserved)

The per-iteration `lifecycle::should_shutdown()` check at the top of
`open_with_retry` is preserved (ADR-022). The `shutdown_aware_sleep`
(50ms poll) is preserved. On SIGTERM mid-retry, the loop bails with the
distinct "aborted by shutdown signal" error. `main.rs` checks
`should_shutdown()` after `acquire()` returns `Err`:
- `should_shutdown()` → `return Ok(())` (ADR-025: clean SIGTERM →
  exit 0, `Restart=on-failure` does NOT restart).
- otherwise → `return Err(...)` (ADR-025: persistent failure → exit 1,
  `Restart=on-failure` restarts).

### 4. Per-attempt logging with remaining budget

Each retry iteration logs (at `warn!`) the attempt number, the elapsed
time, and the remaining budget — so the operator can see the boot race
progressing. The existing "every 10th attempt" heuristic is replaced
with a budget-relative cadence (log every ~10s of elapsed time, so the
operator sees ~9 log lines over a 90s budget rather than every 20s).

### 5. Layering contract (documented)

- **Internal retry (`open_with_retry`)** = transient unavailability
  (the Touch Bar card appearing late at boot due to the config-2 USB
  switch). Bounded by the system-level wall-clock budget (~90s),
  SIGTERM-responsive. On exhaustion → typed error → exit 1.
- **systemd `Restart=on-failure`** = persistent failure (the card
  never appears, or a post-drop self-check fails, or a panic). The
  daemon exits 1; systemd restarts it (rate-limited by
  `StartLimitBurst`/`StartLimitIntervalSec`). After the burst window,
  systemd marks the unit `failed` and stops retrying.

The two layers are complementary: the internal retry handles transient
boot-race latency; systemd handles persistent failure across restarts.
Neither layer wraps the other.

## W1 RECALIBRATION — retune the unit file against the CORRECTED budget

The current unit file (`packaging/systemd/tbard.service`) has
`StartLimitIntervalSec=300` / `StartLimitBurst=10` / `RestartSec=5s`,
calibrated for the CLAIMED 60s retry envelope. Under the CORRECTED ~90s
budget, one start attempt runs at most ~90s before the daemon's exit-1.
Retuning:

**Design math** (with `RestartSec=5s`, internal budget 90s):
- One restart cycle = 90s (budget) + 5s (RestartSec) = 95s.
- `StartLimitBurst=3` / `StartLimitIntervalSec=300`:
  - t=0: start 1 (runs 90s, exits 1)
  - t=95: start 2 (runs 90s, exits 1)
  - t=190: start 3 (runs 90s, exits 1)
  - t=285: start 4 → BLOCKED (3 starts in 285s < 300s window; the 4th
    exceeds `StartLimitBurst=3`).
- **3 restart attempts** in the 300s window, then systemd marks the
  unit `failed` and stops retrying. A persistent hard failure (card
  never appears) is surfaced to the operator in ~285s (not spinning
  forever, not ~30min per attempt).

**Changes to `packaging/systemd/tbard.service`:**
- `StartLimitBurst=10` → `StartLimitBurst=3` (was calibrated for the
  wrong 60s envelope; 3 × 95s = 285s fits the 300s window, 4th is
  blocked).
- `StartLimitIntervalSec=300` — UNCHANGED (still 300s; the 95s cycle
  fits 3 restarts in the window).
- `RestartSec=5s` — UNCHANGED (bounds the restart rate; 5s between
  attempts is reasonable for a hardware probe race).
- Comment block updated to cite the CORRECTED ~90s budget (was
  "30x2s = 60s") and the recalibrated StartLimit math.

**`systemd-analyze verify` re-run:** recorded HONESTLY in
`docs/test-logs/017/systemd-analyze-verify.log`. The exit code is **1**
with the message `tbard.service: Command /usr/bin/tbard is not
executable: No such file or directory` — this is EXPECTED (the binary
is NOT installed on this machine per HOST SAFETY RULES: no install, no
service lifecycle). The unit has NO SYNTAX errors; the only diagnostic
is the missing binary path. (This corrects the session-015 log's
"exit 0" claim — see NF-A3 / ADR-033's docs companion.)

## Alternatives considered

- **Keep the outer loop but cap the total wall-clock.** Rejected: a
  wall-clock cap on the outer loop still wraps the inner bounded retry
  (bounded × bounded). The nesting is the root cause; removing it is
  the clean fix. Keeping the outer loop with a cap would require
  coordinating two budgets (outer wall-clock + inner count) — more
  complex and the inner count becomes meaningless once the outer
  wall-clock governs.
- **Remove the inner retry, keep the outer loop with a wall-clock
  budget.** Rejected: the ADR-022 SIGTERM-responsive machinery lives
  inside `open_with_retry` (shutdown-aware sleep, injectable open for
  the unit test). Moving the retry to `main.rs` would require
  duplicating that machinery or making `main.rs` call the injectable
  variant (exposing `Card`/`Mode`/`DumbBuffer`/`framebuffer::Handle`
  to `main.rs`, which currently only sees `DrmProvider`). Keeping the
  retry inside `DrmProvider::acquire()` preserves the encapsulation and
  the ADR-022 test surface.
- **Make `DrmProvider::acquire` not retry when called from the outer
  loop (pass a flag).** Rejected: the flag is a layering smell — the
  caller should not need to know whether the callee retries. The
  system-level budget belongs IN the retry function, not split across
  two layers.
- **A longer budget (e.g. 300s).** Rejected: 300s would make a
  persistent hard failure take 5min per attempt before the daemon
  exits 1 — too slow for operator visibility. 90s is generous for the
  boot race (~9-18x the typical config-2 appearance time) and short
  enough that `StartLimitBurst=3` catches a persistent failure in
  ~285s.

## Impact list

- `src/main.rs:195-231` — remove the outer `for attempt in 1..=30`
  loop; replace with a single `prov.acquire()` call. After `Err`,
  check `should_shutdown()` to distinguish SIGTERM (→ `Ok(())`, exit 0)
  from budget exhaustion (→ `Err`, exit 1). The no-card error message
  is updated to cite the budget, not "30 attempts".
- `src/providers/drm_backend.rs` — `open_with_retry` and
  `open_with_retry_injectable` change from `(max_attempts: u32,
  retry_interval: Duration)` to `(budget: Duration, retry_interval:
  Duration)`. The loop tracks a deadline (`Instant::now() + budget`)
  and bails when exceeded. Per-attempt logging with elapsed/remaining
  budget. `DrmProvider::acquire()` calls with `RETRY_BUDGET = 90s` /
  `RETRY_INTERVAL = 2s` (module-level constants).
- `src/providers/drm_backend.rs` tests — `test_retry_aborts_on_shutdown`
  updated to the new signature (budget instead of max_attempts). The
  shutdown-aborts-in-<2s assertion still holds (the shutdown flag is
  set at 50ms; the loop checks it at the top of each iteration +
  shutdown-aware sleep).
- `packaging/systemd/tbard.service` — `StartLimitBurst=10` → `3`;
  comment block updated with the corrected budget + recalibrated math.
- `docs/adr/019-production-service.md` — D3 amended with a correction
  note (annotate, do not rewrite): the "30×2s = 60s" claim is refuted
  by NF-A1; the corrected budget is ~90s (ADR-033).
- **`docs/adr/035-dev-mode-retry-budget-annotation.md` (NF-A4
  closure, 2026-09-26)** — annotate, do not rewrite: because
  `DrmProvider::acquire()` is shared by the `--service` arm AND the
  bare dev/real-non-service arm, ADR-033's ~90s `RETRY_BUDGET` also
  bounds the bare/dev-mode retry on a missing or occupied card
  (previously the nested ~30min case). Intended behavior, previously
  undocumented. No code change.
- No new Cargo dependencies.

## Tests (injectable open, existing ADR-022 pattern)

1. **Persistent failure → total duration ≈ budget (boundedness
   assertion).** Inject a closure that always returns `Err(EBUSY)`.
   Call `open_with_retry_injectable(Duration::from_secs(2),
   Duration::from_millis(100), always_ebusy)`. Assert: returns `Err`,
   elapsed < budget + slack (2s + 1s = 3s). **The 30-min case must be
   impossible** — there is no outer loop, so the wall-clock is bounded
   by the budget by construction. This is the boundedness regression
   guard.

2. **SIGTERM mid-retry → prompt clean exit.** The existing
   `test_retry_aborts_on_shutdown` (updated to the new signature)
   covers this: inject persistent EBUSY, set the shutdown flag at 50ms,
   assert the retry returns the shutdown error in < 2s (not the full
   budget).

3. **Retry-exhaust → typed error, exit 1 (Restart=on-failure
   compatible).** Inject persistent EBUSY, let the budget exhaust.
   Assert: returns `Err`, the error message says the card never
   appeared / budget exhausted (NOT "aborted by shutdown"). This is
   the `Restart=on-failure`-compatible exit-1 path — the daemon exits
   1 on budget exhaustion, systemd restarts it.

## References

- `docs/review-report-v6.md:450-465` — NF-A1 finding
- `docs/test-logs/016/audit-a-unpriv-service.log` — live evidence
  (inner 30/30 completes, outer restarts it)
- `docs/test-logs/016/audit-c-retry-exhaust.log` — live evidence
  (inner 30/30 at ~60s, outer restarts)
- `docs/adr/019-production-service.md:126-131` — the refuted D3 claim
- `docs/adr/022-sigterm-retry.md` — the SIGTERM-responsive retry
  machinery (preserved)
- `docs/adr/025-exit-code.md` — the exit-code contract (SIGTERM → 0;
  startup failure → 1)
- `docs/adr/010-master-acquisition-input.md` — the oracle's boot-race
  `Restart=always` spin (evidence the card appears late)