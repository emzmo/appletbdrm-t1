# ADR 045: Observability — RUST_LOG=info in the systemd unit

## Status: Accepted

## Date: 2026-09-26

## Context

Session 037 (`docs/test-logs/037/step3-5-start-live-state-hc2.txt` STEP 3)
observed that the running `tbard.service` instance emitted **ZERO**
application log lines in the journal. `env_logger::init()`
(`src/main.rs:133`) with no `RUST_LOG` in the service environment
(`systemctl show tbard.service` → `Environment=` empty at HEAD
`ccd7024`) defaults to the `error` level, so every success-path
`log::info!(...)` line — including the ADR-043 enable-write success
line at `src/providers/backlight.rs:180-185`:

```
tbard: backlight enable-write {} (max {}, active_brightness {})
```

— was SUPPRESSED. stdout/stderr ARE wired to journald
(`/proc/<pid>/fd/{1,2}` → `/run/systemd/journal/stdout`, verified via
`ss` in s037), so the silence is the log-level filter, not a wiring
fault. `log::error!` lines WOULD appear — NONE did, and the daemon
did not restart (`Restart=on-failure` never fired).

This observability gap is what made the s037 dark-bar ambiguity
unresolvable from the journal alone: the defect had to be inferred
from sysfs + debugfs + source analysis (which then mis-read the
source — see ADR-044). ADR-044 V5 closes the code-level question
(the enable-write SUCCEEDED per the `Result=success` + exit 0
evidence + the propagation chain at `src/main.rs:547-553`), but the
journal was blind to the success path that would have confirmed it
directly. ADR-045 fixes the observation gap so the next validation
run is not blind.

## Decision

### 1. `Environment=RUST_LOG=info` in `tbard.service`

Add one line to `packaging/systemd/tbard.service` [Service] section:

```
Environment=RUST_LOG=info
```

This makes the boot sequence + the enable-write line + the ADR-023
frame-counter cadence observable in the journal via
`journalctl -u tbard.service`. The operator can read the boot
sequence (display.acquire, privdrop, post-drop self-check, scanout-
begin enable-write) from the journal instead of `sudo cat
/sys/kernel/debug/dri/<N>/...`, reducing the runbook's debugfs
dependency (OQ-5).

### 2. Level choice — INFO, not DEBUG

`info` is the correct level for a validation/production daemon:

- **The ADR-023 frame-counter cadence was designed for INFO.**
  `docs/adr/023-frame-counter.md` §1 specifies the periodic frame
  log at `info!` "so it appears at the default verbosity; `debug!`
  would hide it in a production `info`-level config." The cadence is
  one `info!` line every `FRAME_LOG_INTERVAL = 100` frames
  (`src/main.rs`, `FRAME_LOG_INTERVAL` constant) — at ~10fps that is
  ~1 line per ~10s, NOT a per-frame flood. ADR-023 §"Alternatives
  considered" explicitly rejects per-frame `debug!` as "too noisy at
  10fps; the periodic summary is the right cadence."
- **The boot sequence emits a handful of INFO lines ONCE at startup.**
  The scanout-begin enable-write success line
  (`src/providers/backlight.rs:180-185`), the post-drop self-check OK
  line (`src/main.rs:475`), the display.acquire + geometry lines
  (`src/main.rs:519-529`), and the DRM scan acceptance
  (`src/providers/mod.rs:170`) are one-shot emissions at boot, not
  per-frame.
- **The adaptive `update()` path is silent on the common case.**
  `src/providers/backlight.rs:222-266` `update()` does NOT log on
  the `current_bl == new_bl` no-op gate (the common idle case); it
  logs only on write FAILURE (at `error!`, always emitted regardless
  of `RUST_LOG`). So the loop-bottom adaptive path adds no INFO
  noise.
- **The error-path lines (ADR-008 fail-safe) are ERROR-level.** They
  are always emitted regardless of `RUST_LOG`, so `info` does not
  change error visibility — it only OPENS the success path.

### 3. No journal-flood risk at INFO

The combination — periodic frame counter at ~1 line/~10s + one-shot
boot sequence + silent adaptive common case + ERROR-level error path
— means `RUST_LOG=info` produces on the order of ~6 lines/s at
steady state (the frame counter dominates), which is well within
journald's capacity and the runbook's greppable-signal intent. There
is no per-frame `info!` emission. ADR-023 §2 explicitly makes
`FRAME_LOG_INTERVAL = 100` a structural constant (not operator-
tunable) so the cadence cannot accidentally become a flood.

### 4. What this would have changed in s037

With `RUST_LOG=info` in place, the s037 STEP 3 journal would have
shown the `tbard: backlight enable-write 128 (max 255,
active_brightness 128)` INFO line at scanout-begin. That single line
would have collapsed the ambiguity: the write fired (confirming
ADR-043's override is live in the binary), and the dark bar would
have been attributable to post-write decay (s039 S2 timing) +
observation timing, NOT a missing write. The s037 source-analysis
mis-read would not have been prompted, because the journal evidence
would have pointed the other way. This is the runbook's single most
impactful observability fix.

## Verification

`systemd-analyze verify packaging/systemd/tbard.service` → exit 0,
no warnings (systemd 262 / 262-1-arch). The unit is syntactically
valid and the new `Environment=` directive is accepted. Recorded
honestly: the verify is a static syntax/reference check, not a
runtime behavior test (no service lifecycle actions in this session
per the rules).

## Alternatives considered

- **`RUST_LOG=debug`.** Rejected: would surface per-frame render
  details and libinput event traces, flooding the journal at 10fps.
  ADR-023 explicitly chose INFO for the periodic cadence and
  rejected per-frame DEBUG. The validation runbook needs the boot
  sequence + the enable-write line + the frame counter, all at INFO.
- **`RUST_LOG=tbard=info`.** Considered: a tbard-specific filter
  would suppress INFO from dependencies (drm, input, privdrop). But
  the daemon's own `log::info!` lines are all under the `tbard:`
  prefix already (the code uses `log::info!("tbard: ...")`), and the
  dependencies do not emit meaningful INFO lines on the success path.
  The simpler `RUST_LOG=info` is chosen for the validation runbook's
  clarity; a future ADR may tighten the filter if a dependency
  becomes noisy.
- **`RUST_LOG=warn`.** Rejected: would suppress the ADR-023 frame
  counter and the enable-write success line — the two lines the
  runbook most needs. The error path is already at ERROR (always
  emitted), so `warn` adds nothing over the default `error` for
  failure visibility, and it loses the success-path observability
  this ADR is chartered to add.
- **No change (keep the default `error` level).** Rejected: this is
  the s037 status quo that made the run observationally blind. The
  whole point of ADR-045 is to open the success path.

## Impact list

- `packaging/systemd/tbard.service` — add `Environment=RUST_LOG=info`
  to the [Service] section (with the ADR-045 justification comment).
- `docs/adr/045-observability-rust-log-info.md` — this file (new).
- `CHANGELOG.md` — `[Unreleased — ADR-045 observability]` subsection.
- `devlog.md` — session 040 entry (ADR-045 section).

No `src/` change (the log statements already exist at `info!` in the
code; this ADR only sets the environment variable that lets them be
emitted).

## NOTE for merge

The UNIT (`/usr/lib/systemd/system/tbard.service`) MUST be
reinstalled from `packaging/systemd/tbard.service` after merge for
`RUST_LOG=info` to take effect on the next `systemctl start`. The
BINARY (`/usr/bin/tbard`) is unchanged by this ADR (the ADR-044
guard-hardening test is in the test module, not the binary; the
`info!` log statements are already in the binary at `ccd7024`). The
reinstall is a `sudo install -m 0644 packaging/systemd/tbard.service
/usr/lib/systemd/system/tbard.service` + `systemctl daemon-reload`,
NOT a binary rebuild. ADR-038's process rule (verify behavioral
identity before + after install) applies to the unit file's
`Environment=` line: post-install, `systemctl show tbard.service |
grep -- RUST_LOG` must show `RUST_LOG=info`.

## References

- `src/main.rs:133` — `env_logger::init()` (the log-level filter
  point; defaults to `error` with no `RUST_LOG`).
- `src/providers/backlight.rs:180-185` — the ADR-043 enable-write
  success line at `info!` (the single most important diagnostic for
  acceptance item 9, suppressed in s037).
- `src/main.rs:475` — post-drop fd self-check OK at `info!`.
- `src/main.rs:519-529` — display.acquire + geometry INFO lines.
- `docs/adr/023-frame-counter.md` §1, §2 — the frame-counter cadence
  is `info!` every `FRAME_LOG_INTERVAL = 100` frames (not per-frame;
  designed for INFO; no flood).
- `docs/adr/025-exit-code.md` — `Restart=on-failure` maps exit 1 →
  `Result=failed`; the ERROR-level lines are always emitted
  regardless of `RUST_LOG`.
- `docs/test-logs/037/step3-5-start-live-state-hc2.txt` STEP 3 — the
  zero-application-log-lines observation that motivated this ADR.
- `docs/adr/044-backlight-provider-dispatch-audit.md` V5 — the
  corrected dark-bar explanation (successful write + decay +
  observation timing) that this ADR's INFO line would have confirmed
  directly in the journal.