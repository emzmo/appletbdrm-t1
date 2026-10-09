# ADR 019: Production Service — `tbard --service` + Privdrop + systemd Unit

## Status: Accepted

## Date: 2026-09-26

## Context

This ADR implements the production service shape that has been reserved as
the gap `018 → 020` since the hygiene stack landed. It is the ADR the
project has been building toward: every prior ADR about typed errors
(006, 011, 018), the exit-code contract (025), SIGTERM-responsive retry
(022), retry cleanup (027), deterministic backlight (015), fail-safe
backlight (008), and the proven privilege recipe (010) feeds into this one.

The deployed oracle — `tiny-dfr-mbp142.service` — is the **proven**
reference artifact on this machine. Its `/etc` unit and udev rule are
**READ-ONLY REFERENCE artifacts** (HOST SAFETY RULES, `docs/dangers.md`):
never modify, never stop, never start. This ADR copies the oracle's
hardening suite **wholesale with amendments** (`docs/test-logs/004-service-oracle/deployed.service`).

Card numbers are UNSTABLE across boots
(`docs/test-logs/010-bench-incident/`). **All** device resolution in the
service path is by driver (`appletbdrm` / `i915` / `faux_driver`), never
by `cardN`. The existing `discover_touchbar_drm()` geometry scan
(`src/providers/mod.rs`) already enumerates `/dev/dri/card*` and accepts
by aspect ratio, so it is card-number-stable by construction.

### Design questions (resolved here)

The brief names five design questions D1–D5. They are resolved in the
Decision section below.

## Decision

### D1 — Service-mode flag: `tbard --service`

`tbard` gains a `--service` flag. The modes are:

| Invocation | Mode | Config path | Privdrop | Default-page fallback on missing config |
|---|---|---|---|---|
| `tbard --dry-run` | dry-run (dev) | none — `demo_config()` | NO | n/a (demo always) |
| `tbard` (bare) | real/dev (no `--service`) | `/etc/touchbar/` then `/usr/share/touchbar/` | NO | NO — `NoPagesConfigured` (ADR-011, dev visibility) |
| `tbard --service` | production | `/etc/touchbar/` then `/usr/share/touchbar/` | YES (root → nobody/nogroup) | YES — a service must NOT crash-loop on a missing config |

**Justification.** A systemd service that crash-loops on a missing config
file is a worse operator experience than a daemon that boots a sane default
and lets the operator drop a config in later. The oracle itself ships a
compiled-in default layout and only reads `/etc` for overrides. We mirror
that: in `--service`, a missing or zero-page config falls back to the
built-in `default_config()` (the same 12-F-key + media fallback already in
`src/main.rs`), **with a loud `warn!` log line** so the operator sees the
fallback. The exit code is 0 (running with default), not 1.

**Reconciliation with ADR-011's `NoPagesConfigured`.** ADR-011 says "zero
pages is a typed error, never `Ok` with an empty vec." That contract is
preserved **at the `ConfigManager::load()` layer** — `load()` still
returns `Err(ConfigError::NoPagesConfigured)`. The divergence is only at
the **caller policy** layer: `--service` mode treats `NoPagesConfigured`
as "use the built-in default and continue," while dev/real-non-service
mode treats it as "fail loudly, exit 1." This is documented explicitly
because it is the one place the service mode diverges from ADR-011's
"surface the misconfiguration" stance — and the divergence is deliberate:
a service's job is to stay up.

**Alternatives considered.**
- *A separate binary (`tbard-service`).* Rejected: two binaries double the
  build/test surface for a one-flag behavioral difference. The flag is
  cheaper and the privdrop path is gated on it.
- *Always privdrop in real mode.* Rejected: a developer running `tbard`
  bare on the bench (no systemd, often not root) would hit an
  `EACCES`/`EPERM` on the privdrop and exit 1 — breaking the existing
  dev workflow. `--service` is the explicit "I am the production unit"
  signal.
- *Config at `/etc/touchbar-engine/` (existing).* Rejected: the existing
  `USER_CFG_PATH = "/etc/touchbar-engine/config.yaml"` predates the
  service design. The service unit uses `ProtectHome=true` and a
  `ConfigurationDirectory=touchbar` style; the cleaner `/etc/touchbar/`
  namespace is adopted. The existing paths are migrated (see Config wiring).

### D2 — Privdrop ordering (root → nobody/nogroup, pre-drop fd open, post-drop self-check)

`--service` mode executes this exact order, mirroring the oracle recipe
(`docs/adr/010-master-acquisition-input.md` §"Proven recipe"):

1. **Resolve the Touch Bar card by driver/geometry.**
   `providers::discover_touchbar_drm()` (`src/providers/mod.rs`) already
   enumerates `/dev/dri/card*` read-only and accepts by aspect ratio —
   card-number-stable. This returns a `PathBuf`.
2. **Acquire DRM master on the matched card** (as root).
   `DrmProvider::acquire()` → `open_with_retry` (ADR-022, SIGTERM-responsive).
3. **Open `/dev/uinput` (write)** for key emission. Held across the drop.
4. **Open the Touch Bar backlight sysfs `brightness` file (write)**
   deterministically (ADR-015: `select_touchbar_backlight_path`, never
   `intel_backlight`). Held across the drop.
5. **Privdrop to `nobody`/`nogroup`** via the existing `privdrop = "0.5.3"`
   crate (`Cargo.toml`, currently unused — session 007 verified it
   builds). The oracle drops to `nobody` + supplementary `input,video`;
   we drop to `nobody`/`nogroup` **without** supplementary groups — the
   pre-drop fds are already open, so `nobody` needs no group ACLs to use
   them. This is stricter than the oracle.
6. **POST-DROP SELF-CHECK.** After the drop, verify every required fd is
   still valid and usable:
   - DRM card fd: `fcntl(F_GETFL)` succeeds.
   - uinput fd: `fcntl(F_GETFL)` succeeds.
   - backlight fd: `fcntl(F_GETFL)` succeeds.
   Any missing/unusable fd → typed error (`ServiceError::PostDropFdCheck`)
   → `log::error!` → **exit 1**. The daemon must NEVER limp on with a
   missing fd (e.g. emit keys into a closed uinput, or run with no
   backlight control). Fail loudly, exactly once, and let systemd's
   `Restart=on-failure` retry the whole sequence.

`--dry-run` and bare `tbard` (dev/real-non-service): **NO privdrop.** The
existing behavior is preserved hermetically (existing tests stay green).

### D3 — Boot race: bounded, SIGTERM-responsive retry with backoff

The config-2 USB switch exposes the Touch Bar DRM card late at boot. The
oracle's answer is an inner 60s `Restart=always` spin
(`docs/adr/010-...md` §"Boot race"). Ours is the ADR-022 machinery:
`DrmProvider::open_with_retry(30, 2s)` is **bounded, SIGTERM-responsive,
with shutdown-aware sleep** (50ms poll increments). `main`'s real-mode
path already calls this loop and treats SIGTERM-during-retry as a clean
exit 0 (ADR-025).

**Expected boot timing.** Worst case 30 × 2s = 60s of bounded retry
before a hard "card never appeared" exit 1. In practice the config-2
switch fires within ~5–10s of `appletbdrm` probe; the daemon acquires
within the first few attempts. This is the same envelope as the oracle
but **bounded** (no unbounded outer `Restart=always` spin on a hard
failure — see D4).

> **CORRECTION (ADR-033, 2026-09-26, NF-A1).** The "30 × 2s = 60s"
> claim above is **REFUTED by QA v6** (`docs/review-report-v6.md:450-465`,
> NF-A1). `main.rs` had an OUTER `for attempt in 1..=30` loop wrapping
> `prov.acquire()` (which is itself `open_with_retry(30, 2s)`), so the
> actual worst-case was 30 × 30 × 2s = **1800s ≈ 30min**, NOT 60s. ADR-033
> removes the outer loop and replaces the count-based retry with a
> single-level wall-clock budget (~90s). See
> `docs/adr/033-flatten-retry-budget.md`. The unit file's
> `StartLimitBurst` is recalibrated from 10 to 3 against the corrected
> ~90s budget (W1 recalibration, ADR-033).

> **ANNOTATION (ADR-035, 2026-09-26, NF-A4).** The ADR-033 flattening
> applies to **`DrmProvider::acquire()`**, which is called by BOTH the
> `--service` arm AND the bare dev/real-non-service arm (the `else`
> real arm at `main.rs`). Consequently a bare `tbard` (no `--service`)
> run against a missing or occupied Touch Bar card now waits the same
> ~90s `RETRY_BUDGET` before the typed "card never appeared: budget
> 90s exhausted" exit 1 — previously this was the nested ~30min case
> (NF-A1), and pre-ADR-019 it was unbounded. This is intended behavior
> (a single bounded budget is strictly better than nested/unbounded),
> but it was not called out here. See
> `docs/adr/035-dev-mode-retry-budget-annotation.md`. This annotation
> does not change D3's decision; it documents a consequence of
> ADR-033 that D3 did not surface.

### D4 — Unit policy: `tbard.service`, `WantedBy=multi-user.target`, `Restart=on-failure`

**Unit file name: `tbard.service`.** MUST NOT collide with the oracle's
`tiny-dfr-mbp142.service`. The name `tbard.service` matches the binary
and is unambiguous in `journalctl -u tbard`.

**`WantedBy=multi-user.target`** (boot before login — first-mover). The
oracle uses `After=systemd-logind.service systemd-user-sessions.service`
and `WantedBy=multi-user.target`-equivalent timing; per oracle evidence
(`docs/test-logs/004-service-oracle/`), starting before any user session
means **we** are the first DRM master claimant on the Touch Bar card, so
we do not race a compositor for it. The Touch Bar card is not a compositor
target anyway (compositors take the eDP/i915 card), but first-mover avoids
any transient.

**`Restart=on-failure` + `RestartSec=5s`** (NOT the oracle's blind
`Restart=always`). ADR-025's exit-code contract makes `on-failure`
meaningful: exit 0 (clean SIGTERM, or running-with-default) does **not**
restart; exit 1 (startup failure, post-drop self-check fail, panic via
`catch_unwind`) **does** restart. This is strictly better than the
oracle's `Restart=always`, which would restart even on a clean
`systemctl stop`-driven SIGTERM exit 0 — a tight spin if an operator
stops the unit while a restart is queued. `RestartSec=5s` bounds the
restart rate so a hard failure (e.g. backlight device gone) does not
spin the CPU. `StartLimitBurst`/`StartLimitIntervalSec` are set so a
persistent hard failure stops retrying after a window (the operator sees
a `failed` unit, not an infinite spin).

**Hardening suite: oracle wholesale + amendments.** The oracle unit
(`docs/test-logs/004-service-oracle/deployed.service`) hardens with:
`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=true`,
`PrivateTmp=true`, `PrivateIPC=true`, `ProtectKernelTunables=true`,
`ProtectKernelModules=true`, `ProtectKernelLogs=true`,
`ProtectControlGroups=strict`, `RestrictAddressFamilies=AF_UNIX AF_NETLINK`,
`RestrictNamespaces=true`, `RestrictSUIDSGID=true`. We copy all of these
verbatim, plus the amendments from ADR-010:
- **`RestrictAddressFamilies=AF_UNIX AF_NETLINK AF_INET`** — add `AF_INET`
  for the future localhost WebSocket (ADR-003 Phase 3). This is documented
  here; **no IPC code is implemented in this ADR** (the socket-dir plan
  below is Phase-3 design only).
- **`ProtectHome=true` ⇒ config at `/etc/touchbar/`** (D1). No config
  under `$HOME` or `/home` is read in service mode.

**Socket-dir plan (Phase-3 design only, NOT implemented here).** The
future IPC socket will live at `/run/touchbar/engine.sock`, created by
the unit's `RuntimeDirectory=touchbar` (which systemd creates as root
and chowns to the `User=`/`Group=` — but we have no `User=`, we privdrop
internally, so the unit will chown the runtime dir to `nobody:nogroup`).
Post-drop `nobody` owns `/run/touchbar/` and can bind the socket. This is
design-only; no IPC code lands in this ADR.

### D5 — Single-writer mutual exclusion (docs)

Exactly one touchbar daemon may own the card. The packaging README states
this explicitly: **ours (`tbard.service`) and the oracle
(`tiny-dfr-mbp142.service`) are mutually exclusive.** There is no silent
coexistence path — both would attempt DRM master on the same card and one
would `EACCES`/`EBUSY`. The migration procedure is:

1. `sudo systemctl disable --now tiny-dfr-mbp142.service` (stop + disable
   the oracle).
2. `sudo systemctl enable tbard.service` (enable ours; do NOT start yet).
3. **Reboot**, OR `sudo systemctl start tbard.service` manually.

The operator MUST NOT run both enabled. The interlock preflight tool
(`scripts/bench/interlock-preflight.sh`, D-implementation) checks the
oracle's status as part of its GO/NO-GO verdict.

## Implementation scope

- **`packaging/systemd/tbard.service`** — the unit, validated with
  `systemd-analyze verify` (output captured in
  `docs/test-logs/015/systemd-analyze-verify.log`). NOT enabled, NOT
  started, NOT installed to `/etc`.
- **`packaging/udev/`** — fix the uaccess ordering bug. The existing
  `99-touchbar-seat.rules` tags `uaccess` AFTER systemd's `70-uaccess.rules`
  ran, so no user ACL materialized (`docs/test-logs/008/`; masked on bench
  by the `input` group). **Rename to `69-touchbar-seat.rules`** so the
  `TAG+="uaccess"` lands before `70-uaccess.rules` processes it. The
  alternative (append `IMPORT{builtin}="uaccess"` after tagging) is
  heavier and re-runs the builtin; renaming is the minimal, proven fix
  and matches the upstream convention (rules that tag `uaccess` are
  numbered `< 70`). Justification cites the `event4` evidence in
  `docs/test-logs/008/`.
- **`packaging/PKGBUILD`** (Arch — the bench distro): builds `tbard`,
  installs the unit + udev rule + example `/etc/touchbar/config.yaml`.
  Syntax-validated with `bash -n`. NOT built/installed on this machine.
- **`scripts/bench/interlock-preflight.sh`**: the Stage-3 preflight tool.
  Driver-resolved card mapping (`appletbdrm` / `i915` / `faux_driver`),
  debugfs master state, oracle service status, Esc-remap reminder, and a
  single GO/NO-GO verdict. Extends the existing
  `scripts/bench/verify-granted-bench.sh` pattern.
- **Config wiring**: service mode reads `/etc/touchbar/` then
  `/usr/share/touchbar/` (new paths), with `default_config()` fallback on
  missing/zero-page config. Dev/dry-run behavior is unchanged and
  hermetic. The config-path resolution is overridable for tests so the
  unit tests do not touch `/etc`.
- **Tests (no root required)**:
  - config-path resolution (service vs dev, overridable for tests),
  - default-page fallback logic in service mode (missing config →
    `default_config()`, zero-page config → `default_config()`, with a
    loud `warn!`),
  - post-drop self-check logic with mocked fds (a missing fd → typed
    `ServiceError::PostDropFdCheck`),
  - retry integration (existing ADR-022 machinery — unchanged).
- **Docs**: this ADR; `packaging/README.md` (install, mutual exclusion,
  migration); `docs/recovery.md` gains our-service stop/start;
  `docs/test-plan.md` Stage-3 acceptance gains "step 1 = first real start
  of `tbard.service` under interlock."

### What is NOT validated in this session (explicit)

The real privdrop path is **not** exercised here (no root, no service
lifecycle, no real Touch Bar card). It is validated in two later stages:
- **QA v6 (sudo)** — run the prebuilt binary under `sudo tbard --service`
  on the bench to exercise the root → nobody drop + post-drop self-check
  against the real `/dev/uinput` and `appletb_backlight` (no real Touch
  Bar card needed if the bench's USB is in config-1; the self-check runs
  against whatever fds the pre-drop opens).
- **Stage 3 (real card0 under the interlock)** — the unit's first real
  start IS Stage 3, under the interlock preflight. This is the
  acceptance criterion.

## Alternatives considered (cross-cutting)

- **`User=nobody` + `AmbientCapabilities=CAP_SYS_ADMIN`** instead of
  root-start + privdrop. Rejected in ADR-010: `CAP_SYS_ADMIN` is the
  broadest capability; the root-start + immediate privdrop model is
  *proven* on this exact hardware. This ADR inherits that rejection.
- **`ExecStartPre` for the card wait.** Rejected: the bounded retry is
  already in-process (ADR-022) and SIGTERM-responsive. An `ExecStartPre`
  would duplicate the retry logic outside the daemon, where it cannot
  share the shutdown flag.
- **`Type=notify` + sd_notify.** Rejected for scope: would require a
  `systemd` crate dependency and `READY=1` signaling. `Type=simple` +
  `Restart=on-failure` is sufficient and matches the oracle.

## Impact list

- `src/main.rs` — `Options` gains `service: bool`; a new `--service` arm;
  the real-mode path is refactored into a `service_main` that does the
  D2 ordering + post-drop self-check; dev/dry-run paths unchanged.
- `src/config/manager.rs` — config paths become `/etc/touchbar/` +
  `/usr/share/touchbar/`; a `for_service()` / overridable-paths constructor
  for tests.
- `src/providers/error.rs` (or a new `src/service.rs`) — `ServiceError`
  enum with `PostDropFdCheck` variant.
- `packaging/systemd/tbard.service` — new.
- `packaging/udev/69-touchbar-seat.rules` — renamed from
  `99-touchbar-seat.rules` (uaccess ordering fix).
- `packaging/PKGBUILD` — new.
- `packaging/README.md` — new (install, mutual exclusion, migration).
- `scripts/bench/interlock-preflight.sh` — new.
- `docs/recovery.md` — our-service stop/start.
- `docs/test-plan.md` — Stage-3 acceptance wording.
- No new Cargo dependencies (`privdrop` is already in `Cargo.toml`).

## Regression tests

- `test_service_mode_default_page_fallback`: service mode with no config
  → `default_config()` is used (non-empty pages), exit 0 path. No `NoPagesConfigured`
  propagates to a crash-loop.
- `test_dev_mode_no_pages_is_typed_error`: bare `tbard` (non-service) with
  no config → `NoPagesConfigured` (ADR-011 contract preserved in dev).
- `test_config_paths_service_vs_dev`: service paths resolve to
  `/etc/touchbar/` + `/usr/share/touchbar/`; dev paths resolve to the
  same (the divergence is the fallback policy, not the paths).
- `test_post_drop_self_check_missing_fd`: mocked fd set missing the
  uinput fd → `ServiceError::PostDropFdCheck` (exit 1, not limp).
- The existing ADR-022 retry test stays green (no change to retry logic).

## References

- `docs/adr/010-master-acquisition-input.md` — the proven privilege recipe
- `docs/adr/011-hermetic-dryrun.md` — `NoPagesConfigured` (reconciled in D1)
- `docs/adr/022-sigterm-retry.md` — the bounded retry (D3)
- `docs/adr/025-exit-code.md` — the exit-code contract (D4 `Restart=on-failure`)
- `docs/adr/015-backlight-selection.md` — deterministic backlight (D2)
- `docs/adr/008-backlight-failsafe.md` — fail-safe ON (D2)
- `docs/test-logs/004-service-oracle/deployed.service` — the hardening suite source
- `docs/test-logs/008/` — the uaccess ordering bug evidence
- `docs/test-logs/010-bench-incident/` — card-number instability
- `docs/dangers.md` — HOST SAFETY RULES (oracle read-only)