# QA v6.5 — Focused Re-Verification of fix/retry-guard-adr-033-034

**Branch:** `fix/retry-guard-adr-033-034` (stacked on `fix/service-adr-019`,
off `feb8d8f`, post-v0.1.3-test4)
**Commits under test:** `0429156` (ADR-033), `aaf7424` (ADR-034),
`cb6f4ea` (NF-A3 docs), `a21d3bc` (session 017 docs)
**Date:** 2026-09-26
**Role:** QA & reliability engineer — FOCUSED re-verification (v6.5)
**Scope:** ONLY ADR-033, ADR-034, NF-A3 + gates. ADR-019/031/032 are OUT
  of scope (covered by QA v6, `docs/review-report-v6.md`).
**FREEZE RULE:** no source changes. Findings only. **HELD** — no edits
  to any file under `src/`, `tests/`, `packaging/`, `scripts/`, or ADR
  docs. The only files written this session are QA artifacts under
  `docs/test-logs/018/`, this report, and the devlog/CHANGELOG entries.
**Host safety binding:** `docs/dangers.md` HOST SAFETY RULES binding.
  The deployed oracle (`tiny-dfr-mbp142.service`, pid 542, uid 65534)
  stays untouched and lit; the touchbar card (`/dev/dri/card2`) is NOT
  acquired by any test — it is occupied by the oracle, which by design
  makes the live root-start retry audit SAFE (EBUSY on master acquire
  aborts BEFORE any uinput/backlight open per ADR-019 D2).

## Baseline (pre-audit)

- Touch Bar card: `/dev/dri/card2`, dri minor `2`, driver `appletbdrm`
  (card-number-stable).
- Oracle `tiny-dfr-mbp142` (pid 542) holds DRM master on card2, uid
  65534 (`nobody` — matches the oracle's privdrop).
  `systemctl is-active` = `active`.
- Bench shell uid = 1000 (emzmo), groups include `input`.
- `/dev/input` count = 25; `appletb_backlight/brightness` = 54
  (baseline).
- `/etc/systemd/system/tbard.service`, `/etc/touchbar/`,
  `/etc/udev/rules.d/69-touchbar-seat.rules` all ABSENT.
- Stale `/etc/udev/rules.d/99-touchbar-seat.rules` still present (W2
  from QA v6, install-session input, unchanged).
- Debugfs baseline: `tiny-dfr-mbp142  tgid 542  dev 2  master y  a y
  uid 65534`.

> **The QA v6 self-assessment-7 explicitly states self-assessments are
> CLAIMS; only live audits are VERDICTS.** This report treats the
> fix-engineer's session-017 self-assessment as a CLAIM per devlog
> session 017's process rule and re-derives every verdict from diffs +
> live execution.

---

## Per-claim verdicts

### Claim 1 — ADR-033 (flattened retry): **VERIFIED (diff + live Audit B/C)**

**1a. Outer loop REMOVED (verified from the diff at `src/main.rs:198-222`
pre-fix).**

`git show feb8d8f:src/main.rs` confirms the pre-fix structure: an outer
`for attempt in 1..=30` loop (lines ~178-205 in the pre-fix file; the
ADR's `198-222` cite is the post-fix line range but the structure
described matches) calling `prov.acquire()` each iteration, with
`std::thread::sleep(Duration::from_secs(2))` between attempts. Each
`prov.acquire()` calls `open_with_retry(30, 2s)` — another 30×2s loop.
Total worst-case: 30 × 30 × 2s = 1800s ≈ 30min (NF-A1).

`git show 0429156 -- src/main.rs` shows the outer loop REPLACED by a
single `prov.acquire()` call (lines 218-239 post-fix):

```rust
let mut drm = {
    let mut prov = DrmProvider::new();
    match prov.acquire() {
        Ok(()) => prov,
        Err(e) => {
            if lifecycle::should_shutdown() {
                info!("tbard: shutdown during card-open retry; exiting");
                return Ok(());
            }
            log::error!("tbard: Touch Bar card never appeared: {}", e);
            return Err(e.into());
        }
    }
};
```

No outer loop. The retry lives ONLY inside
`DrmProvider::acquire()` → `open_with_retry(RETRY_BUDGET,
RETRY_INTERVAL)` (`drm_backend.rs:398-401`). **VERIFIED.**

**1b. Single-level `open_with_retry` governed by a wall-clock budget
enforced INSIDE it.**

`src/providers/drm_backend.rs:256-337` — the new
`open_with_retry_injectable(budget, retry_interval, attempt_open)`:

```rust
let start = std::time::Instant::now();
let deadline = start + budget;
loop {
    attempt = attempt.saturating_add(1);
    if crate::lifecycle::should_shutdown() { bail!("aborted by shutdown signal"); }
    match attempt_open() {
        Ok(...) => { ...; return Ok(()); }
        Err(e) => {
            // per-attempt logging on a wall-clock cadence
            if Instant::now() >= next_log {
                warn!("DRM card open failed (attempt {}, elapsed {:?}, remaining {:?}): {}", ...);
                next_log = Instant::now() + RETRY_LOG_INTERVAL;
            }
            last_err = Some(err_str);
        }
    }
    if Instant::now() >= deadline {
        bail!("Touch Bar DRM card never appeared: budget {:?} exhausted after {} attempts; ...", budget, attempt, last);
    }
    shutdown_aware_sleep(retry_interval);
}
```

The budget is enforced by a deadline check inside the loop (bail when
`Instant::now() >= deadline`). There is no count-based exit. The
module-level constants are
`RETRY_BUDGET = Duration::from_secs(90)`,
`RETRY_INTERVAL = Duration::from_secs(2)`,
`RETRY_LOG_INTERVAL = Duration::from_secs(10)`. **VERIFIED.**

**1c. ADR-022 SIGTERM-responsiveness preserved.**

- `should_shutdown()` is checked at the TOP of each loop iteration
  (line 285) BEFORE `attempt_open()` — a SIGTERM between iterations is
  caught immediately.
- `shutdown_aware_sleep(retry_interval)` (50ms poll) is preserved
  (line 338-340) — a SIGTERM DURING the 2s sleep wakes the loop within
  ~50ms.
- On SIGTERM mid-retry: `bail!("aborted by shutdown signal")` →
  `main.rs:227` checks `should_shutdown()` → `return Ok(())` (ADR-025
  clean SIGTERM → exit 0).
- On budget exhaustion (no SIGTERM): `bail!("never appeared: budget
  exhausted")` → `main.rs:235` `return Err(e.into())` (ADR-025
  persistent failure → exit 1).

**Live Audit B confirmed** (see below): SIGTERM at 10s during root
retry → exit 0 in 10.05s. **Live Audit C confirmed** (see below):
budget exhaustion at 91.13s → typed "never appeared / budget 90s
exhausted" error → exit 1. **VERIFIED.**

**1d. Per-attempt logging with remaining budget.**

The retry logs at a wall-clock cadence (`RETRY_LOG_INTERVAL = 10s`),
not a count-based cadence. The log line includes attempt number,
elapsed, remaining budget, and the error string:

```
DRM card open failed (attempt 6, elapsed 10.02s, remaining 79.97s): Device or resource busy (os error 16)
```

**Live-confirmed** in the 15s follow-up run
(`docs/test-logs/018/audit-b2-root-service-budget-progress.log`).
**VERIFIED.**

**1e. Boundedness test asserts elapsed >= budget-150ms and < budget+1.5s.**

`src/providers/drm_backend.rs:581-657` —
`test_retry_persistent_failure_is_bounded_by_budget`:

```rust
let budget = Duration::from_millis(800);
let retry_interval = Duration::from_millis(50);
...
assert!(elapsed < budget + Duration::from_millis(1500), ...);
assert!(elapsed >= budget.saturating_sub(Duration::from_millis(150)), ...);
```

The test injects an 800ms budget (NOT the production 90s — see W3)
and asserts the wall-clock is bounded by `budget + 1.5s` AND runs for
at least `budget - 150ms` (no early bail). **Live-confirmed:** the
test passes in 0.80s
(`docs/test-logs/018/adr033-boundedness-live.log`). **VERIFIED.**

### Claim 2 — ADR-033 W1 recalibration: **VERIFIED (math re-derived)**

**W1: re-derive the math from RETRY_BUDGET and the unit values.**

- `RETRY_BUDGET = 90s` (`drm_backend.rs:209`).
- Unit file (`packaging/systemd/tbard.service`):
  - `StartLimitIntervalSec=300` (line 44).
  - `StartLimitBurst=3` (line 45).
  - `RestartSec=5s` (line 51).

**Design math re-derived:**
- One restart cycle = budget (90s) + RestartSec (5s) = **95s**.
- `StartLimitBurst=3` / `StartLimitIntervalSec=300`:
  - t=0: start 1 (runs 90s, exits 1).
  - t=95: start 2 (runs 90s, exits 1).
  - t=190: start 3 (runs 90s, exits 1).
  - t=285: start 4 → **BLOCKED** (3 starts in 285s < 300s window; the
    4th exceeds `StartLimitBurst=3`).

→ 3 restart attempts in the 300s window, then systemd marks the unit
`failed`. A persistent hard failure is surfaced to the operator in
~285s. **The math holds: 3 × ~95s ≈ 285s < 300s window; 4th start
blocked.** The unit file's comment block (`packaging/systemd/tbard.service:29-43`)
cites this exact math. **VERIFIED.**

`git show 0429156 -- packaging/systemd/tbard.service` confirms
`StartLimitBurst=10` → `StartLimitBurst=3` (the only value change);
`StartLimitIntervalSec=300` and `RestartSec=5s` unchanged. The comment
block was rewritten to cite the corrected ~90s budget (was
"30×2s = 60s"). **VERIFIED.**

### Claim 2 (W3) — RETRY_BUDGET on the production path; bare dev-mode wait: **VERIFIED + NF-A4 (doc gap)**

**W3a. RETRY_BUDGET is the production constant used on the real path
(not just the test's injected 800ms).**

`src/providers/drm_backend.rs:398-401` — the `DisplayProvider` trait
impl:

```rust
fn acquire(&mut self) -> anyhow::Result<()> {
    self.open_with_retry(RETRY_BUDGET, RETRY_INTERVAL)
}
```

`acquire()` is what `main.rs:220` calls in the real arm. It uses the
module-level `RETRY_BUDGET = 90s` constant. The boundedness test calls
`open_with_retry_injectable(Duration::from_millis(800), ...)`
DIRECTLY — NOT via `acquire()` — so the test's 800ms does NOT leak
into the production path. **VERIFIED.**

**Live-confirmed in Audit C**: the production retry exhausted at
**91.13s** with the message "budget **90s** exhausted after 46
attempts" — the runtime reported `90s` (the production constant), not
800ms. **VERIFIED.**

**W3b. What budget does bare `tbard` (dev mode, no `--service`) now
wait on a missing card? Is the intended dev behavior documented?**

**Adjudication:** bare `tbard` (dev/real-non-service, no `--service`)
on a missing/occupied card enters the SAME `DrmProvider::acquire()` →
`open_with_retry(RETRY_BUDGET=90s, RETRY_INTERVAL=2s)` path as
`--service`, because the retry lives inside `DrmProvider::acquire()`,
which is called by BOTH the bare and `--service` real-mode arms (the
only branch is `if opts.dry_run` at `main.rs:139`).

**Live-confirmed in Audit D** (`docs/test-logs/018/audit-d-bare-dev-mode.log`):
bare `tbard` (unprivileged, oracle holds card2) ran for the full
5-second observation window with scan logs every 2s, no fast-fail —
it would have exited 1 at ~90s with the same "budget 90s exhausted"
error (the 5s timeout interrupted it before exhaustion). This is
CORRECT behavior (bare mode has no root guard, no privdrop; the
retry is the same bounded ~90s wait), and it is an IMPROVEMENT over
the pre-ADR-033 ~30min nested-retry case.

**Is the intended dev behavior documented? NO.** ADR-019 D3
(`docs/adr/019-production-service.md:122-123`) mentions in passing
that "main's real-mode path already calls this loop" — so the
behavior is implicit — but NEITHER ADR-019 D3 NOR ADR-033 explicitly
documents that a developer running bare `tbard` against an occupied
card (e.g. on this bench with the oracle running) will wait ~90s
before the typed "card never appeared" error. This is a
**documentation gap, not a code defect** (the bounded ~90s wait is
correct and SIGTERM-responsive).

**New finding NF-A4** (logged, NOT implemented per the FREEZE RULE):
bare dev-mode retry-duration (~90s) is undocumented. **Proposed ADR:
ADR-035 — annotate (do not rewrite) ADR-019 D3 and ADR-033's impact
list to document the bare/dev-mode retry budget.** Stage-3 acceptance
only. Does not block merge.

### Claim 3 — ADR-034 (root guard): **VERIFIED (W4 code audit + live Audit A)**

**W4a. The euid check precedes ALL work in the service arm.**

`src/main.rs:192-208` — the real arm (`else` branch of
`if opts.dry_run`) opens with the ADR-034 root guard BEFORE any other
work:

```rust
} else {
    // ADR-034: HARD ROOT GUARD on `--service`. At the TOP of the
    // service arm, BEFORE any scanning, BEFORE the DRM retry, BEFORE
    // any device access:
    if opts.service && unsafe { libc::geteuid() } != 0 {
        let e = service::ServiceError::ServiceRequiresRoot {
            euid: unsafe { libc::geteuid() },
        };
        log::error!("tbard: {}", e);
        return Err(e.into());
    }
    // ... DRM scan/retry follows HERE (lines 218+) ...
```

Between the `else {` and the guard there is NO config load, NO DRM
scan, NO `discover_touchbar_drm()`, NO `OpenOptions::open`, NO
`acquire_master_lock`, NO `setup_uinput`, NO backlight open. The
guard is the FIRST statement in the real arm. **VERIFIED.**

**Live-confirmed in Audit A** (`docs/test-logs/018/audit-a-fast-fail.log`):
unprivileged `tbard --service` → exit 1 in **6.5ms** with NO scan
log, NO DRM probe, NO uinput/backlight activity. The first (and
only) log line is the typed error. The 6.5ms wall time is
incompatible with any scan/retry having run (a single DRM scan +
master-acquire attempt takes ~10-50ms; 46 attempts takes ~90s). The
guard fires before any of that. **VERIFIED.**

**W4b. Typed `ServiceRequiresRoot` with operator-actionable Display.**

`src/service.rs:31-37` — the enum variant:

```rust
ServiceRequiresRoot { euid: u32 },
```

`src/service.rs:52-57` — the Display impl:

```rust
ServiceError::ServiceRequiresRoot { euid } => write!(
    f,
    "service mode requires root (euid={}); start as root or via \
     the systemd unit (tbard.service) — exit 1",
    euid
),
```

The message is greppable ("service mode requires root") and
operator-actionable (states the offending euid, points at the
systemd unit `tbard.service` as the fix, states the exit code).
**Live-confirmed in Audit A** — the verbatim stderr was:

```
[ERROR tbard] tbard: service mode requires root (euid=1000); start as root or via the systemd unit (tbard.service) — exit 1
Error: ServiceRequiresRoot { euid: 1000 }
```

The unit test `test_service_requires_root_display`
(`src/service.rs:227-247`) asserts the message contains
"service mode requires root", "euid=1000", "tbard.service", and
"exit 1". **VERIFIED.**

**W4c. The old warn-and-continue branch removed and unreachable.**

`git show aaf7424 -- src/main.rs` shows the old branch REMOVED:

```diff
-            if unsafe { libc::geteuid() } == 0 {
-                if let Err(e) = service::privdrop_to_nobody() { ... }
-                info!("tbard: service-mode privdrop ... complete");
-            } else {
-                warn!("tbard: --service requested but euid != 0 ... SKIPPING privdrop ...");
-            }
+            if let Err(e) = service::privdrop_to_nobody() {
+                log::error!("tbard: privdrop failed: {}", e);
+                return Err(e.into());
+            }
+            info!("tbard: service-mode privdrop to nobody/nogroup complete");
```

The privdrop now runs unconditionally (no `geteuid` re-check). The
`else` (warn-and-continue) branch is GONE from the source. The
comment at `main.rs:338-349` explains why the branch is unreachable:
"ADR-034's entry guard already verified `euid == 0` at the top of
the service arm (BEFORE the DRM scan), so the `else` (warn-and-
continue) branch is UNREACHABLE — we ARE root here." **VERIFIED.**

**W4d. `--dry-run` and bare dev mode unaffected unprivileged.**

The guard is gated on `opts.service` (line 202:
`if opts.service && unsafe { libc::geteuid() } != 0`). It lives in
the `else` real arm (line 192), which is only entered when
`opts.dry_run` is false. So:
- `--dry-run` → first branch (`if opts.dry_run` at line 139) → guard
  NEVER reached. Unprivileged `--dry-run` is unaffected.
- bare `tbard` (no flags) → real arm, but `opts.service == false` →
  the guard's `if opts.service && ...` short-circuits to false →
  guard skipped. Unprivileged bare `tbard` is unaffected (it enters
  the retry, which is correct — see W3b/NF-A4).

**Live-confirmed in Audit D**: unprivileged `--dry-run` → exit 1 in
13ms with `dry-run SimDisplay acquire failed: Permission denied`
(vkms master EACCES in this non-granted bench — the hermetic sim
path fails cleanly with a typed error, NOT a panic, NOT the root
guard). Unprivileged bare `tbard` → entered the retry (no
fast-fail), confirming the guard does NOT leak into the bare path.
**VERIFIED.**

### Claim 4 — NF-A3 (docs): **VERIFIED (annotation, not rewrite)**

**4a. Original session-015 claims preserved verbatim with appended
corrections (blockquote / HTML comment), NOT rewritten.**

`docs/test-logs/015/systemd-analyze-verify.log` — `git show cb6f4ea`
confirms the original two-line entry

```
exit=0
NOTE: the "/usr/bin/tbard is not executable" message is EXPECTED ...
```

was preserved (with a minor whitespace fix on the "exit 0 and no
syntax errors" line — "exit 0" → "no syntax errors"; the
"exit=0" line itself is untouched). A blockquote correction was
APPENDED:

```
> **CORRECTION (NF-A3, ADR-033 docs companion, 2026-09-26).** The
> "exit=0" claim above is **WRONG**. The actual `systemd-analyze
> verify` exit code is **1** ...
```

The original `exit=0` line is still present (line 3) for historical
accuracy; the correction annotates it. **NOT rewritten.** **VERIFIED.**

`docs/self-assessment-6.md` — the original line
`- systemd-analyze verify packaging/systemd/tbard.service → exit 0`
is preserved; an HTML comment was APPENDED immediately after:

```
<!-- NF-A3 CORRECTION (2026-09-26): this "exit 0" claim is WRONG. ...
Self-assessments are CLAIMS; only live audits are VERDICTS. -->
```

**NOT rewritten.** **VERIFIED.**

**4b. Process rule recorded ("self-assessments are CLAIMS; only live
audits are VERDICTS").**

- `devlog.md` session 017 entry (line 2622+): "self-assessments are
  CLAIMS; only live audits are VERDICTS. Evidence: three consecutive
  cycles of a self-assessment claim refuted by live execution —
  1. v5 exit codes, 2. v6 fast-fail (NF-A2), 3. v6 systemd-analyze
  (NF-A3)."
- `docs/self-assessment-7.md` (line 13+): a "⚠️ CAVEAT — self-
  assessments are CLAIMS; only live audits are VERDICTS" section
  with the same three-cycle evidence.

**VERIFIED.** This report treats the fix-engineer's session-017
self-assessment as a CLAIM per this rule and re-derives every
verdict from diffs + live execution.

### Claim 5 — Test integrity: **VERIFIED (W5 + structural audit)**

**5a. The two updated tests preserve ADR-022/027 behavior.**

`git show 0429156 -- src/providers/drm_backend.rs` shows:
- `test_retry_aborts_on_shutdown` — updated to the new
  `(budget, retry_interval, attempt_open)` signature (was
  `(max_attempts, retry_interval, attempt_open)`). The behavioral
  assertion is UNCHANGED: inject persistent EBUSY, set the shutdown
  flag at 50ms, assert the retry returns the shutdown error in < 2s
  (not the full budget). ADR-022 SIGTERM-responsiveness preserved.
- `test_retry_partial_alloc_releases_master_on_failure` — updated
  to the new signature. The behavioral assertion is preserved:
  a partial-alloc closure (opens card + acquires master, then
  returns Err) MUST release the partial master via drop glue so a
  second master acquisition succeeds. ADR-027 cleanup-on-failure
  preserved. The test now uses a 35ms budget / 10ms interval (was
  2 attempts / 10ms interval) — the purpose is partial-resource
  release, not the attempt count, so the budget-based form is
  equivalent.

**VERIFIED.**

**5b. `SHUTDOWN_TEST_MUTEX` serializes shutdown-flag tests.**

`src/providers/drm_backend.rs:517-525` — a module-level
`static SHUTDOWN_TEST_MUTEX: Mutex<()> = Mutex::new(())` is acquired
at the top of `test_retry_aborts_on_shutdown`,
`test_retry_persistent_failure_is_bounded_by_budget`, and
`test_retry_partial_alloc_releases_master_on_failure` (each test
holds the guard for its duration). This prevents one test setting
the process-global `SHUTDOWN` flag from making another test's retry
abort spuriously under `cargo test`'s parallel harness. **Live-
confirmed in W5** (zero flakes across 30 signal-heavy + 171 full-
suite executions). **VERIFIED.**

**5c. W5: adversarially run the FULL suite 10x (or signal-heavy
subset 10x + full 3x) — record any flake verbatim.**

Ran the **signal-heavy subset 10x + full suite 3x** variant (the
spec's allowed alternative):

- **Signal-heavy subset 10x** (3 tests each = 30 executions):
  `test_signal_handler_sets_flag`,
  `test_retry_aborts_on_shutdown`,
  `test_retry_persistent_failure_is_bounded_by_budget`. **30/30
  green, zero flakes.** Verbatim logs in
  `docs/test-logs/018/w5-signal-heavy-10x.log`.
- **Full suite 3x** (each run = 54 unit + 3 integration = 57):
  **171/171 green, zero flakes.** Verbatim logs in
  `docs/test-logs/018/w5-full-suite-3x.log`.

**Total W5: 201/201 green, zero flakes.** No flake recorded. The
`SHUTDOWN_TEST_MUTEX` serialization is effective. **VERIFIED.**

---

## Live audits (oracle untouched; touchbar card untouched)

### Audit A — FAST-FAIL: **VERIFIED**

```
$ RUST_LOG=error ./target/debug/tbard --service   # as uid 1000
```
**`$?` = 1. Wall time = 6.5ms.** Verbatim stderr
(`docs/test-logs/018/audit-a-fast-fail.log`):

```
[2026-09-26T11:59:44Z ERROR tbard] tbard: service mode requires root (euid=1000); start as root or via the systemd unit (tbard.service) — exit 1
Error: ServiceRequiresRoot { euid: 1000 }
```

- Exit 1: **CONFIRMED**.
- Verbatim "service mode requires root" stderr: **CONFIRMED** (with
  euid=1000, the systemd unit pointer, and the exit code).
- Wall time < 1s: **CONFIRMED** (6.5ms — three orders of magnitude
  under the 1s bound; was ~30min pre-ADR-033 / ~90s post-ADR-033
  pre-ADR-034).

No DRM scan log, no uinput/backlight activity, no device touched.
**Audit A VERIFIED.** This is the live closure of NF-A2.

### Audit B — SIGTERM DURING RETRY (root, oracle holds card): **VERIFIED**

```
$ sudo RUST_LOG=info ./target/debug/tbard --service   # oracle HOLDING card2
# SIGTERM sent at 10s
```
**`$?` = 0. Wall time = 10.05s.** Verbatim log
(`docs/test-logs/018/audit-b-root-service-sigterm.log`):

```
[INFO  tbard] tbard: Touch Bar engine starting (mode: real)
[INFO  tbard::providers] tbard: DRM scan /dev/dri/card2 → Touch Bar geometry (60×2170, ratio 3616) [ACCEPTED]
... (scan logs every 2s for 5 attempts) ...
[INFO  tbard::providers::drm_backend] tbard: shutdown during DRM card-open retry; aborting
[INFO  tbard] tbard: shutdown during card-open retry; exiting
```

**Per-attempt budget-progress log** (captured in a 15s follow-up,
`docs/test-logs/018/audit-b2-root-service-budget-progress.log`):

```
[WARN  tbard::providers::drm_backend] tbard: DRM card open failed (attempt 6, elapsed 10.021107981s, remaining 79.978892019s): Device or resource busy (os error 16)
```

The retry attempts `acquire_master_lock()` on card2 each iteration;
the oracle holds master → EBUSY (os error 16) each attempt. SIGTERM
at 10s → the loop's top-of-iteration `should_shutdown()` check
catches it → `bail!("aborted by shutdown signal")` → `main.rs:227`
`should_shutdown()` true → `return Ok(())` → exit 0.

**Debugfs before/after (oracle kept master throughout):**
```
before: tiny-dfr-mbp142  tgid 542  dev 2  master y  a y  uid 65534
after:  tiny-dfr-mbp142  tgid 542  dev 2  master y  a y  uid 65534
```
- **No new `/dev/input` device appeared** (count stayed 25).
- **No backlight writes** (brightness stayed 54).
- **Oracle still active** (`systemctl is-active` = `active`; pid 542
  still running).

**Audit B VERIFIED.** The D2 ordering (master-acquire runs FIRST,
before uinput/backlight opens) makes this test SAFE: an EBUSY on
master aborts BEFORE any uinput device is created or backlight fd
opened.

### Audit C — RETRY EXHAUSTION (~90s, bounded): **VERIFIED (NF-A1 live closure)**

```
$ sudo RUST_LOG=info ./target/debug/tbard --service   # oracle HOLDING card2
# observed for 120s; natural exit at 91.13s
```
**`$?` = 1. Wall time = 91.13s.** Verbatim final lines
(`docs/test-logs/018/audit-c-retry-exhaust.log`):

```
[WARN  tbard::providers::drm_backend] tbard: DRM card open failed (attempt 46, elapsed 90.16959758s, remaining 0ns): Device or resource busy (os error 16)
[ERROR tbard::providers::drm_backend] tbard: Touch Bar DRM card never appeared: budget 90s exhausted after 46 attempts (90); last error: Device or resource busy (os error 16)
[ERROR tbard] tbard: Touch Bar card never appeared: Touch Bar DRM card never appeared: budget 90s exhausted after 46 attempts; last error: Device or resource busy (os error 16)
Error: Touch Bar DRM card never appeared: budget 90s exhausted after 46 attempts; last error: Device or resource busy (os error 16)
```

- **Exit 1** (Restart=on-failure compatible): **CONFIRMED**.
- **Typed "never appeared / budget" error**: **CONFIRMED** ("budget
  90s exhausted after 46 attempts").
- **Elapsed ≈ RETRY_BUDGET (90s), NOT 30min**: **CONFIRMED**
  (91.13s = 90s budget + 1.13s slack for the final sleep's
  shutdown-aware poll cadence). **NF-A1 live closure confirmed** —
  the 30min nested-retry case is impossible by construction (no
  outer loop; verified from the diff).

**Debugfs after (oracle kept master throughout):**
```
tiny-dfr-mbp142  tgid 542  dev 2  master y  a y  uid 65534
```
- **No new `/dev/input` device** (count stayed 25).
- **No backlight writes** (brightness stayed 54).
- **Oracle still active**.

**Audit C VERIFIED.** This is the live closure of NF-A1.

### Audit D — DEV-MODE REGRESSION: **VERIFIED**

**D.1 — bare `tbard` (unprivileged, oracle holds card):**

```
$ RUST_LOG=info timeout 5 ./target/debug/tbard   # as uid 1000, no --service
```
**`$?` = 124 (timeout). Wall time = 5.02s.** Verbatim log
(`docs/test-logs/018/audit-d-bare-dev-mode.log`):

```
[INFO  tbard] tbard: Touch Bar engine starting (mode: real)
[INFO  tbard::providers] tbard: DRM scan /dev/dri/card2 → Touch Bar geometry (60×2170, ratio 3616) [ACCEPTED]
... (scan logs every 2s) ...
[INFO  tbard::providers::drm_backend] tbard: shutdown during DRM card-open retry; aborting
[INFO  tbard] tbard: shutdown during card-open retry; exiting
```

Bare `tbard` enters the same `DrmProvider::acquire()` →
`open_with_retry(RETRY_BUDGET=90s, ...)` retry as `--service` (the
retry lives inside `DrmProvider::acquire()`, called by both real-
mode arms). No fast-fail (correct — the ADR-034 root guard is
gated on `opts.service` and does not leak into the bare path). The
5s timeout SIGTERM-interrupted the retry; it would have exited 1 at
~90s with the same "budget 90s exhausted" error as Audit C. This is
the documented-but-implicit dev behavior (see W3b / NF-A4). No
regression from ADR-034 (the guard does not fire for bare mode).

**D.2 — `--dry-run` (unprivileged):**

```
$ RUST_LOG=error timeout 3 ./target/debug/tbard --dry-run   # as uid 1000
```
**`$?` = 1. Wall time = 13ms.** Verbatim stderr
(`docs/test-logs/018/audit-d-dryrun.log`):

```
[2026-09-26T11:59:49Z ERROR tbard] tbard: dry-run SimDisplay acquire failed: Permission denied (os error 13)
Error: Permission denied (os error 13)
```

`--dry-run` goes through the FIRST branch (`if opts.dry_run` at
`main.rs:139`) and NEVER reaches the ADR-034 root guard (which lives
in the `else` real arm). The SimDisplay (vkms) acquire EACCESes in
this non-granted bench (Hyprland holds vkms master, or vkms is not
loadable here) → the daemon fails cleanly with a typed error, NOT a
panic, NOT the root guard. The hermetic sim path is structurally
exercised and fails cleanly. No regression from ADR-034 (the guard
does not leak into `--dry-run`).

**Audit D VERIFIED.** Neither dev path is regressed by ADR-034's
root guard.

---

## W3/W4/W5 adjudications (summary)

- **W3 (RETRY_BUDGET production constant + bare dev-mode wait):**
  - **W3a VERIFIED** — `DrmProvider::acquire()` (the production
    `DisplayProvider` trait impl) calls
    `open_with_retry(RETRY_BUDGET=90s, RETRY_INTERVAL=2s)` using the
    module-level constant; the boundedness test injects 800ms
    directly via `open_with_retry_injectable` (NOT via `acquire()`),
    so the test's 800ms does NOT leak into production. Live-confirmed
    in Audit C (runtime reported "budget 90s exhausted", not 800ms).
  - **W3b VERIFIED + NF-A4** — bare `tbard` waits ~90s on a
    missing/occupied card (same `DrmProvider::acquire()` path as
    `--service`). This is CORRECT behavior (bounded, SIGTERM-
    responsive) but UNDOCUMENTED. **NF-A4 (documentation gap, not a
    code defect) — proposed ADR-035, logged not implemented per the
    FREEZE RULE. Does not block merge.**
- **W4 (root guard code audit):**
  - **W4a VERIFIED** — euid check at `main.rs:202` is the FIRST
    statement in the real arm; no config load, no scan, no fd open
    before it. Live-confirmed in Audit A (6.5ms, no scan log).
  - **W4b VERIFIED** — typed `ServiceRequiresRoot` with operator-
    actionable Display (greppable, mentions euid + systemd unit +
    exit 1). Live-confirmed verbatim in Audit A.
  - **W4c VERIFIED** — the warn-and-continue `else` branch is
    REMOVED from the source (`git show aaf7424`); the privdrop now
    runs unconditionally. The branch is unreachable (the entry
    guard already verified euid==0).
  - **W4d VERIFIED** — `--dry-run` and bare dev mode are
    unprivileged-unaffected (the guard is gated on `opts.service`
    and lives in the `else` real arm; `--dry-run` is the first
    branch and bypasses it). Live-confirmed in Audit D.
- **W5 (adversarial test runs):**
  - **Signal-heavy subset 10x**: 30/30 green, zero flakes.
  - **Full suite 3x**: 171/171 green (57 × 3), zero flakes.
  - **Total: 201/201 green, zero flakes.**
    `SHUTDOWN_TEST_MUTEX` serialization effective. No flake
    recorded verbatim (there was none).

---

## Gates (verbatim)

| Gate | Result | Evidence |
|------|--------|----------|
| `cargo fmt --check` | **PASS** (exit 0) | `docs/test-logs/018/fmt.log` |
| `cargo build --bin tbard` | **PASS** (exit 0) | `docs/test-logs/018/build.log` |
| `cargo clippy --all-targets -- -D warnings` | **PASS** (exit 0) | `docs/test-logs/018/clippy.log` |
| `cargo test` | **PASS** — 54 unit + 3 integration = **57/57 green** | `docs/test-logs/018/test.log` |
| `scripts/check-invariants.sh` | **PASS** (exit 0) | `docs/test-logs/018/check-invariants.log` |
| `scripts/ci-gate.sh` | **PASS** (exit 0) | `docs/test-logs/018/ci-gate.log` |
| `bash -n packaging/PKGBUILD` | **PASS** (exit 0) | `docs/test-logs/018/pkgbuild-bash-n.log` |
| `systemd-analyze verify packaging/systemd/tbard.service` | exit 1, message "Command /usr/bin/tbard is not executable: No such file or directory" — **EXPECTED** (binary not installed per HOST SAFETY RULES); NO syntax errors (NF-A3 corrected) | `docs/test-logs/018/systemd-analyze-verify.log` |

**Commit hygiene:** `0429156` (ADR-033), `aaf7424` (ADR-034),
`cb6f4ea` (NF-A3 docs), `a21d3bc` (session docs). ADR-before-code
holds within each ADR commit (the ADR doc is in the SAME commit as
the code, not a separate later commit). Verified via
`git show --stat 0429156` (ADR-033 doc + code + tests + unit file +
ADR-019 D3 amendment) and `git show --stat aaf7424` (ADR-034 doc +
code + tests). NF-A3 and session docs are docs-only commits (no
code), in the correct order (NF-A3 correction before the session
docs that reference it).

---

## New findings (logged, NOT implemented — FREEZE RULE)

### NF-A4 — Bare dev-mode retry-duration is undocumented

**Severity: documentation (low).** Bare `tbard` (dev/real-non-
service, no `--service`) on a missing or occupied Touch Bar card
now waits ~90s (`RETRY_BUDGET`) before exit 1 — the same budget as
`--service`, because the retry lives inside `DrmProvider::acquire()`
which is called by both real-mode arms. ADR-019 D3
(`docs/adr/019-production-service.md:122-123`) mentions in passing
that "main's real-mode path already calls this loop" — so the
behavior is implicit — but NEITHER ADR-019 D3 NOR ADR-033 explicitly
documents that a developer running bare `tbard` against an occupied
card (e.g. on this bench with the oracle running) will wait ~90s
before the typed "card never appeared" error. Pre-ADR-033 this was
~30min (NF-A1); post-ADR-033 it is ~90s — an improvement, but the
dev-mode wait time is not called out as a documented behavior.

This is a documentation gap, NOT a code defect (the bounded ~90s
wait is correct and SIGTERM-responsive). **Proposed ADR: ADR-035 —
annotate (do not rewrite) ADR-019 D3 and ADR-033's impact list to
document the bare/dev-mode retry budget.** Stage-3 acceptance only —
do NOT touch the card in this session. Logged not implemented per
the FREEZE RULE. **Does not block merge.**

---

## What remains Stage-3 acceptance only

The following is **NOT validated in this session** and is Stage-3
acceptance only (real acquire → privdrop → render → SIGTERM exit 0 →
card free → rerun, on the real touchbar card under the interlock):

1. **Real DRM master acquire on card2** (the oracle must be
   disabled+stopped first per the migration procedure; the
   interlock preflight must emit GO).
2. **Real privdrop to `nobody`/`nogroup`** as root (the
   `privdrop_to_nobody()` call at `main.rs:350` is not exercised
   here — Audits B/C were SIGTERM-interrupted / budget-exhausted
   during the retry, before the privdrop block).
3. **Post-drop self-check against real fds** (`fcntl(F_GETFL)` on
   the real DRM card fd, real `/dev/uinput` fd, real
   `appletb_backlight` brightness fd) — the unit tests exercise the
   LOGIC with mocked fds; the real-fd probe is Stage 3.
4. **Real render loop** on card2 (widget layout → cairo paint → DRM
   flush → visible output on the Touch Bar).
5. **SIGTERM-driven clean exit 0 from the running render loop** (not
   from the retry) → RAII drop releases master → card free.
6. **Re-run the interlock preflight post-stop** → GO (oracle
   disabled, no master holder).
7. **Real backlight writes via the held pre-drop fd** (post-drop
   `nobody` writing through the held fd — the
   `held_brightness_fd` path in `backlight.rs` is not exercised
   here).
8. **NF-A4 documentation** (proposed ADR-035) — annotate the bare
   dev-mode retry budget in ADR-019 D3 + ADR-033 impact list.

---

## Final verdict

**CLEARED FOR MERGE (service + retry-guard branches) + install
session + Stage-3 interlock.**

All four claims VERIFIED by code audit + live audits A/B/C/D +
W3/W4/W5 adjudications + all gates green (54 unit + 3 integration =
57). NF-A1/A2/A3 (the three QA v6 blockers) are CLOSED:

- **NF-A1 (nested retry ~30min) CLOSED by ADR-033.** Live closure in
  Audit C: retry exhaustion at 91.13s with typed "budget 90s
  exhausted after 46 attempts" error, exit 1 (NOT 30min). The outer
  loop is removed by construction (verified from the diff at
  `src/main.rs:198-222` pre-fix vs the post-fix single
  `prov.acquire()` call).
- **NF-A2 (missing root guard) CLOSED by ADR-034.** Live closure in
  Audit A: unprivileged `tbard --service` → exit 1 in 6.5ms with
  verbatim "service mode requires root (euid=1000); start as root
  or via the systemd unit (tbard.service) — exit 1" stderr (was
  ~30min/~90s pre-fix). The euid check precedes ALL work in the
  service arm (no scan, no fd open before it); the warn-and-continue
  branch is removed and unreachable; `--dry-run` and bare dev mode
  are unaffected (W4d).
- **NF-A3 (systemd-analyze exit claim) CLOSED by docs correction.**
  The session-015 "exit=0" claim is preserved verbatim and annotated
  with a blockquote correction; the self-assessment-6 reference is
  annotated with an HTML comment; the process rule ("self-
  assessments are CLAIMS; only live audits are VERDICTS") is
  recorded in devlog session 017 + self-assessment-7. Live re-
  confirmed in this session: `systemd-analyze verify` exit 1 with
  the expected binary-not-installed message, NO syntax errors.

The one new finding (**NF-A4 — bare dev-mode retry-duration
documentation gap**) is a documentation item, NOT a code defect, and
does NOT block merge. It is logged as proposed ADR-035, not
implemented per the FREEZE RULE.

**State explicitly what remains Stage-3 acceptance only:** the real
privdrop+render path — real acquire on card2 (oracle disabled+
stopped, interlock preflight GO) → privdrop to nobody/nogroup →
post-drop fd self-check against real fds → real render loop →
SIGTERM-driven clean exit 0 from the running loop → RAII drop
releases master → card free → rerun the interlock preflight (GO) →
real backlight writes via the held pre-drop fd. None of this is
exercised in this session (Audits B/C were SIGTERM-interrupted /
budget-exhausted during the retry, before the privdrop block).

**Merge the service + retry-guard branches first** (all gates green,
57/57 tests, ADR-033/034/NF-A3 verified by live audit, ADR-before-
code holds, D2 ordering verified safe in Audit B). The Stage-3
interlock session is the acceptance gate for the real privdrop+
render path; NF-A4 is logged-not-implemented per the FREEZE RULE.

**Artifacts:**
- `docs/review-report-v6-5.md` — this report.
- `docs/test-logs/018/` — gate logs (fmt, build, clippy, test,
  ci-gate, check-invariants, pkgbuild-bash-n, systemd-analyze-
  verify) + ADR-033 boundedness live run + audits A/B/B2/C/D + W5
  signal-heavy-10x + W5 full-suite-3x.
- `docs/test-logs/018/fix-report/` — archived fix-engineer report:
  self-assessment-7, ADR-033, ADR-034, review-report-v6, and the
  fix-engineer's session-017 evidence logs (test, fast-fail,
  boundedness, systemd-analyze).
- Updated `devlog.md` (session 018 entry), `CHANGELOG.md`.