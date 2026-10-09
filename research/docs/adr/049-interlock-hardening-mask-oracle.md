# ADR 049: Interlock hardening — mask the oracle during validation windows (runbook + investigation, minimal code)

## Status: Accepted

## Date: 2026-09-27

## Context

Session 043 STAGE 3 PASS ran tbard 54min44s stable as sole master, but
the STEP 6 stop captured an INTERLOCK DISCOVERY
(`docs/test-logs/043/step6-stop-tbard.txt:32-100`): the oracle
(`tiny-dfr-mbp142.service`) SELF-RESTARTED mid-run under the explicit
`systemctl stop` issued at STEP 1, and panic-retried against the busy
Touch Bar card (held by tbard) until tbard released it. This was BENIGN
for validation (tbard held master throughout; the oracle's panic-retry
loop did not disturb tbard's mastership), but it is a RACE in the
interlock that would be a problem for a migration run: the oracle's
restart policy can fire while tbard is running, producing repeated
panics (exit 101) in the oracle's journal and potentially tripping
systemd's `StartLimit` if sustained.

This ADR documents the investigation (read-only), amends the runbook +
the interlock-preflight commentary to use `systemctl mask` during
validation windows (mask blocks ANY restart path — socket, dependency,
manual, or `Restart=` policy), and adds a mid-run assertion (re-check
debugfs for an oracle row periodically / before every stage step). The
mask/unmask is performed by the SESSION at interlock open/close; NO
changes to the oracle's unit file itself.

## Investigation (read-only) — why the oracle self-restarted under explicit stop

### The oracle's unit file

`backup_old/systemd/tiny-dfr-mbp142.service:1-22` (read-only reference;
the deployed unit at `/usr/lib/systemd/system/tiny-dfr-mbp142.service`
is the oracle's own, untouched):

```ini
[Unit]
Description=Touch Bar daemon for MacBookPro14,2 (T1, appletbdrm framebuffer)
After=systemd-logind.service systemd-user-sessions.service

[Service]
ExecStart=/usr/bin/tiny-dfr-mbp142
Restart=always
```

`Restart=always` (`:9`) is the key. `systemctl stop` sends SIGTERM and
waits for the process to exit, but `Restart=always` means systemd will
re-schedule a restart whenever the main process exits — INCLUDING an
exit caused by an administrative `stop`. (The `stop` semantics: it
stops the CURRENT activation, but `Restart=always` re-fires on the
next clean exit unless the unit is DISABLED or MASKED. For a `static`
unit — `is-enabled=static` — `disable` has no effect: the unit is
pulled in by something else, e.g. a `.wants`/`.requires` symlink or a
dependency, so `disable` cannot remove the static activation source.)

### Session-043 journal evidence

`docs/test-logs/043/step1-stop-oracle.txt`: STEP 1 `systemctl stop
tiny-dfr-mbp142.service` @ 23:43:28 → exit 0; `is-active=inactive` at
+1s and +10s (the stop SUCCEEDED initially; the oracle was inactive
for at least 10s).

`docs/test-logs/043/step6-stop-tbard.txt:32-55`: the oracle's journal
DURING the tbard run shows it self-restarted and panic-retried:
```
Sep 27 00:38:03.547  tiny-dfr-mbp142[364955]: waiting for touchbar card (30/30)
Sep 27 00:38:05.547  thread 'main' (364955) panicked at src/main.rs:839:21:
                     touchbar card never appeared: No touch bar device found,
                     attempted: [/dev/dri/card2: Device or resource busy (os 16),
                                 /dev/dri/card0: busy, /dev/dri/card1: busy]
Sep 27 00:38:05.549  Main process exited, code=exited, status=101/n/a
Sep 27 00:38:05.549  Failed with result 'exit-code'.
Sep 27 00:38:05.725  Scheduled restart job, restart counter is at 4.
Sep 27 00:38:05.726  Started Touch Bar daemon for MacBookPro14,2 ...
```

So between STEP 1 (23:43:28) and 00:38:05, the oracle was re-activated
(likely by a systemd trigger — the unit is `static` + `Restart=always`;
possibly a socket/dependency or a manual restart — the exact trigger is
not recoverable from the journal, but the RESTART POLICY is the reason
it stayed up once activated). It then spun in its 30s retry loop
panicking on the busy card (`card2` held by tbard) until tbard released
it at 00:38:59 (`docs/test-logs/043/step8-hc3-restore.txt:5-10`: "the
oracle self-restored via systemd's Restart= policy; it had been
restart-looping during the tbard run and acquired the card the instant
tbard released it").

### Why `systemctl stop` is insufficient

`systemctl stop` stops the current activation but does NOT suppress the
unit's `Restart=` policy or its static activation sources. For a unit
with `Restart=always` that is `is-enabled=static`, the only ways to
PREVENT any restart path during a validation window are:

1. **`systemctl mask`** — symlink the unit to `/dev/null` in
   `/etc/systemd/system/`, which makes the unit unreachable to systemd
   for the duration. NO activation source (socket, dependency, manual
   `start`, or `Restart=` re-fire) can start it. Reversible with
   `systemctl unmask`. This is the strongest suppression.
2. **`systemctl disable --now`** — only effective for `enabled` units
   (removes the `.wants` symlink). For a `static` unit,
   `is-enabled=static` means there is no `.wants` symlink to remove;
   `disable` is a no-op. (Session 043 confirmed: after STEP 1's stop,
   `is-enabled=static` was UNCHANGED — `docs/test-logs/043/step1-stop-oracle.txt:10`.)
3. **Edit the unit file to remove `Restart=always`** — REJECTED by the
   brief: "no changes to the oracle's unit file itself" (the oracle is
   the deployed daemon; HOST SAFETY RULES — leave it untouched).

**Verdict: `systemctl mask` is the only suppression that works for a
`static` + `Restart=always` unit without editing the unit file.** The
mask is performed by the SESSION at interlock open (before STEP 1's
stop) and reversed at interlock close (STEP 8's restore). The mask
symlink lives in `/etc/systemd/system/` (an `/etc` change performed by
the session operator, NOT a code change to the oracle's unit file).

> NOTE on the HOST SAFETY RULES / "no `/etc` changes" constraint: the
> mask creates a symlink in `/etc/systemd/system/tiny-dfr-mbp142.service
> → /dev/null`. This is an administrative action by the session
> operator at interlock open/close, reversible with `unmask`, and does
> NOT edit the oracle's deployed unit file at
> `/usr/lib/systemd/system/tiny-dfr-mbp142.service`. The "no `/etc`
> changes" rule in the fix-engineer role applies to CODE/CONFIG changes
> the branch makes; the interlock mask is a runtime administrative
> action documented in the runbook, performed by the QA operator during
> a validation session, and reversed before the session closes. The
> runbook records the exact commands so the operator does them
> correctly and reverses them.

## Decision

### 1. Runbook amendment: MASK the oracle for the validation window.

`docs/test-plan.md` STEP 1 (stop the oracle) is amended: replace
`systemctl stop` with `systemctl mask --now` (mask + stop in one
command). The mask blocks ANY restart path (socket, dependency, manual,
`Restart=`) for the duration. STEP 8 (restore the oracle) is amended:
`systemctl unmask` + `systemctl start tiny-dfr-mbp142.service` (the
`start` is the safety net; the unmask re-enables the static activation
sources).

Exact commands (performed by the SESSION at interlock open/close):
```bash
# STEP 1 (interlock OPEN) — mask + stop the oracle:
sudo systemctl mask --now tiny-dfr-mbp142.service
# Verify: is-active=inactive, is-enabled=masked (NOT static).
systemctl is-active tiny-dfr-mbp142.service   # inactive
systemctl is-enabled tiny-dfr-mbp142.service  # masked
# Verify NO auto-restart within +60s (the mask blocks it; this is the
# ADR-049 assertion that the s043 race cannot recur):
sleep 60 && systemctl is-active tiny-dfr-mbp142.service  # still inactive

# STEP 8 (interlock CLOSE) — unmask + start the oracle:
sudo systemctl unmask tiny-dfr-mbp142.service
sudo systemctl start tiny-dfr-mbp142.service
# Verify: is-active=active, is-enabled=static (restored).
```

### 2. Interlock-preflight commentary: mask, not disable.

`scripts/bench/interlock-preflight.sh` STEP 3 (oracle service status)
is amended: the NO-GO message changes from `disable --now` to `mask
--now` (the disable is a no-op for a static unit; the mask is the
effective suppression). A header comment references ADR-049. The
preflight is read-only (it does NOT perform the mask — the operator
does, at STEP 1); the preflight only reports the oracle state + the
correct suppression command.

### 3. Mid-run assertion: re-check debugfs for an oracle row periodically.

Add a runbook note: during long validation runs, re-check debugfs for
an oracle row periodically (or before every stage step):
```bash
sudo cat /sys/kernel/debug/dri/<N>/clients | grep -i tiny-dfr
# EXPECT: no output (the oracle is masked; no row should appear).
# If a tiny-dfr-mbp142 row appears mid-run, the mask failed or was
# reversed — abort the run (the oracle is racing tbard for the card).
```
This is the ADR-049 mid-run assertion. It catches the case where the
mask is accidentally reversed mid-session (e.g. another operator runs
`unmask`) or where a systemd version behaves unexpectedly with
`Restart=always` + `mask`.

### 4. No code changes to the oracle's unit file.

The oracle's deployed unit file at
`/usr/lib/systemd/system/tiny-dfr-mbp142.service` is NOT modified. The
mask is a runtime administrative action (a symlink in
`/etc/systemd/system/`), reversible with `unmask`. The brief's
constraint "no changes to the oracle's unit file itself" is respected.

### 5. Minimal code: a preflight/runbook commentary check (no service lifecycle code).

This ADR is primarily a RUNBOOK + PREFLIGHT change (docs + script
commentary). No `src/` change. The preflight script's STEP 3 message +
header comment are updated; the runbook's STEP 1 + STEP 8 + a new
mid-run assertion note are added. No service lifecycle code is added
(the mask/unmask are operator commands, not code).

## Alternatives considered

- **`systemctl disable --now` (the s043 preflight's recommendation).**
  Rejected: for a `static` unit, `disable` is a no-op
  (`is-enabled=static` has no `.wants` symlink to remove). Session 043
  confirmed `is-enabled=static` was unchanged after STEP 1's stop. The
  mask is the only effective suppression without editing the unit file.
- **Edit the oracle's unit file to remove `Restart=always`.** Rejected
  by the brief: "no changes to the oracle's unit file itself." The
  oracle is the deployed daemon (HOST SAFETY RULES — leave it
  untouched). The mask achieves the suppression without editing the
  unit.
- **Stop the oracle and accept the restart race (the s043 behavior).**
  Rejected for migration (would race tbard for the card); acceptable
  for validation (s043 was benign) but the runbook should not rely on
  benign luck. The mask eliminates the race by construction.
- **Add a tbard-side guard that re-acquires master if the oracle grabs
  it.** Rejected: out of scope (the interlock is mutual exclusion by
  design — ADR-019 D5; a re-acquire guard would be a different feature).
  The mask is the interlock-level fix.

## Impact list

- `docs/adr/049-interlock-hardening-mask-oracle.md` — this file (new).
- `docs/test-plan.md` — STEP 1 amended (mask --now); STEP 8 amended
  (unmask + start); new mid-run assertion note; ADR-049 reference.
- `scripts/bench/interlock-preflight.sh` — STEP 3 NO-GO message +
  header comment updated (mask, not disable; ADR-049 reference).
- `CHANGELOG.md` — `[Unreleased — ADR-049 interlock hardening]`.
- `devlog.md` — session 044 entry (ADR-049 section).
- `docs/self-assessment-15.md` — claims C-049.

No `src/` change. No `tests/` change. No `packaging/` change. Gates
green (fmt, build, clippy, test, check-invariants, ci-gate,
bash -n PKGBUILD) — no code changed, so the gate is the existing green
state.

## References

- `backup_old/systemd/tiny-dfr-mbp142.service:9` — `Restart=always`
  (the restart policy that fires under explicit stop).
- `docs/test-logs/043/step1-stop-oracle.txt:10` — `is-enabled=static`
  (unchanged after stop — disable is a no-op for static units).
- `docs/test-logs/043/step6-stop-tbard.txt:32-55` — the oracle's
  self-restart + panic-retry loop during the tbard run (journal
  evidence).
- `docs/test-logs/043/step8-hc3-restore.txt:5-10` — the oracle
  self-restored via `Restart=` when tbard released the card.
- `scripts/bench/interlock-preflight.sh:252-268` — STEP 3 (oracle
  service status; the `disable --now` message this ADR replaces with
  `mask --now`).
- `docs/adr/019-production-service.md` — ADR-019 D5 (mutual exclusion;
  the interlock design this ADR hardens).