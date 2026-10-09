# ADR 034: Hard Root Guard on `--service`

## Status: Accepted

## Date: 2026-09-26

## Context

QA v6 finding **NF-A2** (`docs/review-report-v6.md:467-478`,
`docs/test-logs/016/audit-a-unpriv-service.log`): `tbard --service` has
NO hard root guard at entry. The QA v6 spec claimed unprivileged
`--service` → typed "service mode requires root" error, exit 1, no
device touched. The actual code has NO such guard — the only `euid`
check (`src/main.rs:330`, the privdrop-SKIP guard) runs AFTER the DRM
retry loop. So an unprivileged `--service` start:

1. enters the real-mode branch (dry_run=false),
2. scans `/dev/dri/` (read-only geometry scan — succeeds unprivileged
   if the user can read the card nodes),
3. attempts `prov.acquire()` → `open_with_retry` → `try_open_card` →
   `acquire_master_lock()` → **EACCES** (uid 1000 has no DRM master
   right AND the oracle holds master),
4. spins in the retry loop for the full budget (ADR-033: ~90s; pre-
   ADR-033: ~30min per NF-A1),
5. only THEN reaches the privdrop guard at `main.rs:330` which logs a
   `warn!` and SKIPS the privdrop (continue, not fail).

With `Restart=on-failure` (the unit's policy), this would be a
**spin-storm in production**: an unprivileged start (e.g. a misconfigured
unit file missing `User=root`, or an operator running `tbard --service`
manually as a non-root user) spins for the budget, exits 1 (budget
exhaustion per ADR-033), systemd restarts it, spins again, … — the
daemon never tells the operator "you started me wrong." The
`warn!`-and-continue privdrop guard is NOT a substitute for a hard
entry guard — it runs too late (after the retry) and does not exit.

### Root cause from code (cite file:line)

`src/main.rs:330-343` — the only `euid` check in the service path:

```rust
if unsafe { libc::geteuid() } == 0 {
    if let Err(e) = service::privdrop_to_nobody() { ... }
    info!("tbard: service-mode privdrop to nobody/nogroup complete");
} else {
    warn!(
        "tbard: --service requested but euid != 0 (euid={}); \
         SKIPPING privdrop (sim/sandbox structural exercise only; \
         the real drop is validated in QA v6 + Stage 3)",
        unsafe { libc::geteuid() }
    );
}
```

This guard is at `main.rs:330` — AFTER the DRM retry loop (`main.rs:195-222`
pre-ADR-033; `main.rs:195-218` post-ADR-033). It logs `warn!` and
CONTINUES (no `return`, no `exit`). The QA v6 Audit A live evidence
(`docs/test-logs/016/audit-a-unpriv-service.log`) confirmed: the
`warn!` about "euid != 0, SKIPPING privdrop" was NEVER logged in the
unprivileged run — because the retry loop ran first (for ~120s before
the harness SIGTERM) and the privdrop guard was never reached.

## Decision

### 1. Hard root guard at `--service` entry, BEFORE any scanning

At the TOP of the service arm — BEFORE the DRM scan, BEFORE the retry,
BEFORE any device access — check `geteuid()`. If `euid != 0`:

- log ONE `error!` line with the typed error,
- return `Err(ServiceError::ServiceRequiresRoot)` (typed error,
  `Restart=on-failure` compatible),
- `main` returns `Err` → **exit 1** immediately (< 1s),
- NO scanning, NO device access, NO retry.

The guard is a hard fail, not a warn-and-continue. The
warn-and-continue privdrop guard at `main.rs:330` is REMOVED — it is
subsumed by the entry guard (if we reach the privdrop block, we ARE
root, because the entry guard already verified it; the `else` branch
is now unreachable).

### 2. Typed error: `ServiceError::ServiceRequiresRoot`

Add a new `ServiceError` variant:

```rust
pub enum ServiceError {
    PostDropFdCheck { fd: &'static str, detail: String },
    PrivDrop { detail: String },
    /// ADR-034: `--service` mode requires root (euid == 0). An
    /// unprivileged start is a configuration error (e.g. a unit file
    /// missing `User=root`, or an operator running `tbard --service`
    /// manually as a non-root user). The daemon fast-fails with a
    /// typed error + exit 1 BEFORE any scanning or device access —
    /// no spin, no retry, no `Restart=on-failure` spin-storm.
    ServiceRequiresRoot { euid: u32 },
}
```

The `Display` impl produces a greppable, operator-actionable message:
`"service mode requires root (euid=1000); start as root or via the
systemd unit (tbard.service) — exit 1"`.

### 3. Adjudication: partial-privilege scenarios

**Decision: `euid == 0` is required; hard fail otherwise.** No
partial-privilege handling (e.g. `CAP_SYS_ADMIN` without root, or a
setuid binary). Rationale:

- The proven privilege recipe (ADR-010, the oracle) is root-start +
  in-process privdrop to `nobody`/`nogroup`. The fds are opened
  PRE-drop (as root); the drop follows; the post-drop self-check
  verifies the fds. This recipe REQUIRES root at start — `CAP_SYS_ADMIN`
  without root would let the DRM master acquire succeed but the
  `/dev/uinput` open and the sysfs backlight open also need root (or
  group ACLs that `nobody` does not have). A partial-privilege path
  would need a different fd-open strategy (post-drop ACLs) and a
  different self-check — that is a separate ADR's scope, not this one.
- The systemd unit starts as root (no `User=`/`Group=`; the drop is
  in-process). An operator running `tbard --service` manually is
  expected to use `sudo`. A non-root `--service` start is a
  configuration error, not a supported mode.
- Keeping the guard simple (euid==0 required, hard fail otherwise)
  avoids the complexity of capability negotiation and the risk of a
  partial-privilege path that silently limps. The fast-fail is the
  safety property: the daemon tells the operator immediately that they
  started it wrong, rather than spinning.

### 4. The fast-fail is the regression target

The regression test asserts the fast-fail is **fast** (< 1s) and
**typed** (the verbatim error message). The duration assertion is the
key: pre-ADR-034, an unprivileged `--service` spun for ~30min (NF-A1) /
~90s (post-ADR-033); post-ADR-034, it exits in < 1s. The
`Restart=on-failure` spin-storm is impossible because the daemon exits
fast with a typed error — the operator sees the error in the journal
immediately, not after a 90s/30min spin.

## Alternatives considered

- **Warn-and-continue (keep the existing privdrop-SKIP guard).**
  Rejected: it runs AFTER the retry (too late) and continues (not a
  fail). The QA v6 Audit A showed the `warn!` was never even logged in
  the unprivileged run because the retry ran first. A warn-and-continue
  guard at the TOP of the service arm (before the retry) would still
  continue into the retry — the daemon would still spin. The guard
  MUST be a hard fail (exit 1) to prevent the spin.
- **`euid == 0` OR `CAP_SYS_ADMIN`.** Rejected: see the adjudication
  above. The proven recipe is root-start + privdrop; a
  partial-privilege path is a separate ADR's scope. Keeping the guard
  simple avoids silent-limp risk.
- **Move the privdrop guard to the top but keep it warn-and-skip for
  sim/sandbox structural exercise.** Rejected: the sim/sandbox
  structural exercise of the service path is covered by the unit tests
  (post-drop self-check with mocked fds, `resolve_config` policy
  tests) which do NOT need to run the real-mode branch. The real-mode
  `--service` arm is the PRODUCTION path; it must fast-fail on
  misconfiguration, not warn-and-limp. The sim/sandbox note in the
  existing `warn!` message ("sim/sandbox structural exercise only") was
  a sim-time allowance that does not belong in the production path.
- **A CLI-level check in `Options::parse`.** Rejected: `Options::parse`
  runs before signal handlers / panic hook are installed; an `exit(1)`
  there would skip the ADR-007 cleanup chain. The guard belongs in
  `main` after the lifecycle setup, at the top of the service arm.

## Impact list

- `src/service.rs` — add `ServiceError::ServiceRequiresRoot { euid:
  u32 }` variant + `Display` impl.
- `src/main.rs` — at the top of the `else` (real-mode) branch, BEFORE
  the DRM scan/retry, add:
  ```rust
  if opts.service && unsafe { libc::geteuid() } != 0 {
      let e = service::ServiceError::ServiceRequiresRoot {
          euid: unsafe { libc::geteuid() },
      };
      log::error!("tbard: {}", e);
      return Err(e.into());
  }
  ```
  Remove the `else` (warn-and-continue) branch of the privdrop guard
  at `main.rs:330-343` — it is now unreachable (the entry guard
  already verified `euid == 0`).
- `src/service.rs` tests — add a unit test for the
  `ServiceRequiresRoot` `Display` impl (greppable message).
- `tests/exit_code.rs` OR a new integration test — spawn `tbard
  --service` unprivileged, assert exit 1 + verbatim stderr + duration
  < 1s (the fast-fail is the regression target). The existing
  `tests/exit_code.rs` tests `--dry-run`; the `--service` fast-fail is
  a distinct regression target.

## Tests

1. **Unit: `ServiceError::ServiceRequiresRoot` Display.** Construct the
   error, assert the message contains "service mode requires root",
   "euid=", and "exit 1" (greppable + operator-actionable).

2. **Integration: spawn `tbard --service` unprivileged → exit 1 fast,
   verbatim stderr asserted, duration < 1s.** The test spawns the real
   binary (`env!("CARGO_BIN_EXE_tbard")`) with `--service` as the
   current (unprivileged) user. Asserts:
   - exit code is 1 (not 0, not 2),
   - stderr contains the verbatim "service mode requires root" string,
   - duration < 1s (the fast-fail is the regression target; pre-ADR-034
     this would have spun for ~90s post-ADR-033 / ~30min pre-ADR-033).
   The test runs unprivileged (the QA v6 bench is uid 1000); if run as
   root (e.g. under sudo), it skips truthfully — the fast-fail is
   unprivileged-only.

   The real privdrop path (root → nobody) remains QA/Stage-3
   acceptance (unchanged). This test does NOT exercise the real drop;
   it exercises the fast-fail on misconfiguration.

## References

- `docs/review-report-v6.md:467-478` — NF-A2 finding
- `docs/test-logs/016/audit-a-unpriv-service.log` — live evidence
  (unprivileged --service → EACCES → retry → SIGTERM at 120s)
- `docs/adr/019-production-service.md` D2 — the privdrop ordering (the
  entry guard is BEFORE the pre-drop fd opens)
- `docs/adr/025-exit-code.md` — the exit-code contract (exit 1 on
  startup failure → `Restart=on-failure` restarts; the typed error
  makes the failure greppable)
- `docs/adr/010-master-acquisition-input.md` — the proven root-start +
  privdrop recipe (justification for `euid == 0` required)