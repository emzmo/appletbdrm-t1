# ADR 010: Master Acquisition Input — Proven Privilege Model (docs-only)

## Status: Accepted (docs-only — no code in this ADR)

## Date: 2026-09-25

## Context

The original architecture assumption (ADR 001, README) was "no root,
systemd user unit" for the daemon. **This is disproven on this machine.**
The deployed, lit, proven oracle — `tiny-dfr-mbp142.service` — uses a
**system unit with no `User=`** (root start) and an **internal privdrop
to `nobody`** after acquiring DRM master and opening the privileged fds.
This ADR records the proven recipe from the oracle source + runtime
evidence so the future service ADR can implement it faithfully, and
designs (does not implement) the bounded boot-retry loop.

Evidence this session (`docs/test-logs/004-service-oracle/`):
- `oracle-runtime.txt`: PID 562 runs as `nobody` (privdrop); `fuser
  /dev/dri/card0` shows only PID 562 → **sole DRM master of card0**;
  `/proc/562/fd` shows fd 3 = `/dev/uinput` (write-only, opened pre-drop),
  fd 4 = `/dev/dri/card0`, fd 5 =
  `/sys/.../backlight/appletb_backlight/brightness` (opened pre-drop).
  card1 (i915) held by systemd/logind/Hyprland/Xwayland; card2 (vkms)
  held by systemd/logind/Hyprland.
  **Privilege caveat (ADR-016)**: the `/proc/562/fd` capture required
  root — reading a `nobody` process's fd table needs `CAP_SYS_PTRACE` or
  root. `ls /proc/562/fd/` as uid 1000 → Permission denied; under sudo →
  succeeds. The capture was done with sudo.
- `deployed.service`: the live `/etc/systemd/system/tiny-dfr-mbp142.service`
  (matches `backup_old/tiny-dfr-mbp142/etc/systemd/system/...`).
- `binary-identity.txt`: deployed sha256 `7d25cf8d…`; rebuilt (isolated
  target dir, rustc 1.98.1) sha256 `ca5059c…` — **not byte-identical**
  (builds not reproducible; embedded paths/timestamps differ). Source
  provenance confirmed: `backup_old/tiny-dfr-mbp142` Cargo.toml v0.3.7.

## Proven recipe (oracle source citations)

The oracle's `main` (`backup_old/tiny-dfr-mbp142/src/main.rs`) order:

1. **Acquire DRM master as root.** `main.rs:822-841` calls
   `DrmBackend::open_card()` (`display.rs:180-199`) which iterates
   `/dev/dri/card*` and calls `try_open_card` (`display.rs:67-71`);
   `try_open_card` opens the card and calls
   `card.acquire_master_lock()` at **`display.rs:71`** — while the
   process is still root. Master is held for the daemon's lifetime.
2. **Open uinput + backlight fds pre-drop.** `real_main` (`main.rs:874`)
   opens `/dev/uinput` write-only at **`main.rs:878`**
   (`UInputHandle::new(OpenOptions::new().write(true).open("/dev/uinput"))`)
   and constructs `BacklightManager::new()` at **`main.rs:879`**, which
   opens the brightness file at **`backlight.rs:85`**
   (`.open(bl_path.join("brightness"))`). Both fds are held across the
   drop. `nobody` has no ACLs on `/dev/uinput` or the sysfs backlight
   file, so these MUST be opened before privdrop.
3. **Privdrop to `nobody`.** `main.rs:888-892`:
   `PrivDrop::default().user("nobody").group_list(&["input","video"]).apply()`.
   The process is now `nobody` with `input`+`video` supplementary groups.
4. **Post-drop setup.** uinput ioctls (`set_evbit`/`dev_setup`/`dev_create`,
   `main.rs:922-943`), libinput contexts (`main.rs:899-901`), epoll
   (`main.rs:909-921`) all run as `nobody`. The already-open fds (DRM
   card0, uinput, backlight) continue to work because fd permissions are
   fixed at open time.
5. **Boot race: pure Restart spin.** `main.rs:825-836` does an internal
   30×2s = 60s retry loop for the late-appearing card (the iBridge USB
   config switch at sysinit flips the device into DRM mode late). The
   unit's `Restart=always` (`deployed.service:9`) is the OUTER backstop:
   if the inner 60s loop exhausts, the process panics
   (`main.rs:839`), systemd restarts it, and it tries again. There is no
   notification-based wait — it is a bounded inner retry + unbounded
   outer restart. The unit comment (`deployed.service:3-4`) says exactly
   this: "The daemon scans /dev/dri itself … Restart=always covers the
   DRM card appearing late."

## Backlight selection (oracle)

`find_backlight` (`backlight.rs:30-44`) matches the sysfs entry name
against `["display-pipe", "228600000.dsi.0", "appletb_backlight"]` — the
**touchbar** backlight, deterministically, NOT first-in-sysfs.
`find_display_backlight` (`backlight.rs:46-62`) matches
`["apple-panel-bl", "gmux_backlight", "intel_backlight", "acpi_video0"]`
for the main display. This machine exposes BOTH `appletb_backlight`
(hid-appletb-bl, touchbar) and `intel_backlight` (main display); the
oracle never confuses them. ADR-015 hardens our equivalent with a test.

## Amendments we need vs the oracle unit

The oracle unit (`deployed.service`) is a strong baseline but needs three
amendments for our engine:

1. **`RestrictAddressFamilies` gains `AF_INET`** — the oracle restricts
   to `AF_UNIX AF_NETLINK` (`deployed.service:20`); our future localhost
   WebSocket (ADR 003 Phase 3) needs `AF_INET` (or `AF_INET AF_INET6`).
   Add it when the WS phase lands; until then keep the oracle's set.
2. **`ProtectHome=true` ⇒ config at `/etc/touchbar/…`** — the oracle
   uses `ProtectHome=true` (`deployed.service:13`), so config cannot live
   under `$HOME` or `/home`. The oracle's config is at
   `/usr/share/tiny-dfr-mbp142/…` + `/etc/…` (see `config.rs`). Our
   `ConfigManager` (`src/config/manager.rs:13-14`) already uses
   `/usr/share/touchbar-engine/config.yaml` + `/etc/touchbar-engine/config.yaml`
   — compatible with `ProtectHome=true`. **BUG A root cause lives here**:
   when neither exists, `load()` returns `Ok` with zero pages
   (`manager.rs:62-65`) instead of `Err`, so the daemon reaches the render
   loop with an empty `pages` vec and panics at `main.rs:266`. ADR-011
   fixes this: zero pages ⇒ typed `ConfigError::NoPagesConfigured`, and
   `--dry-run` synthesizes a built-in demo page (hermetic).
3. **IPC socket at a fixed `/run/touchbar/…` path** — the oracle has no
   IPC. Our `IpcServer::bind` (`src/ipc/server.rs:17-21`) uses
   `$XDG_RUNTIME_DIR/touchbar/engine.sock`, which under a system unit
   (no `User=`, privdrop to `nobody`) is wrong: `nobody` has no
   `$XDG_RUNTIME_DIR`. The future service must use a fixed
   `/run/touchbar/engine.sock` (created by the unit's
   `RuntimeDirectory=touchbar` + ownership to `nobody`). This is an IPC
   phase concern; noted here for the recipe.

## Considered and rejected: `User=nobody` + `AmbientCapabilities=CAP_SYS_ADMIN`

A systemd unit with `User=nobody` and `AmbientCapabilities=CAP_SYS_ADMIN`
would let `nobody` acquire DRM master without root start. **Rejected:**
- `CAP_SYS_ADMIN` is the broadest capability in the kernel (it governs
  far more than DRM master); handing it to `nobody` ambiently is a larger
  attack surface than root-start + immediate privdrop.
- The oracle's root-start + privdrop model is *proven* on this exact
  hardware (14h uptime, lit bar, sole master of card0). Replicating it is
  lower risk than inventing a capability model.
- `drmSetMaster` requires either root or `CAP_SYS_ADMIN`+being the active
  session's DRM master; under a system unit there is no active session
  for `nobody`, so the ambient cap is the only path — and it is the
  broad-cap path we reject.

## Boot race: bounded retry design (NOT implemented here)

The future service's wait-for-card mechanism: **`NoDisplayCandidate`
(ADR-011) + bounded backoff**, NOT the oracle's unbounded outer
`Restart=always` + inner 60s spin.

Design (for the future service ADR, not this ADR's code):
- The engine returns a typed `NoDisplayCandidate` error
  (`ConfigError`/`HwError` family, ADR-011) when no Touch Bar card is
  found.
- The service wrapper (a small `main` retry loop or systemd
  `ExecStartPre`/`Restart`-on-failure with `StartLimitBurst`) retries
  with **bounded exponential backoff**: e.g. 2s, 2s, 4s, 8s, …, capped at
  30s, max ~5 min total, then exits with a distinct code so systemd can
  distinguish "card not here yet" (restart) from "hard failure" (stop).
  Every retry is logged with the verdict list from `scan_all_cards`
  (ADR-004) so the boot sequence is observable.
- This replaces the oracle's `panic!` at `main.rs:839` (which under
  `Restart=always` is a tight unbounded retry) with a bounded, logged
  loop. **Do not implement the service here** — this is design-only for
  the future service ADR.

## Pre-drop fd checklist + post-drop self-check

**Pre-drop fd checklist** (the fds that MUST be opened as root before
privdrop, because `nobody` has no ACLs on them):
1. DRM card fd (`open` + `acquire_master_lock`) — `/dev/dri/cardN`.
2. `/dev/uinput` (write) — for key emission.
3. Touch Bar backlight sysfs `brightness` file (write) —
   `/sys/.../backlight/appletb_backlight/brightness`.

**Post-drop self-check requirement** (for the future service): after
`PrivDrop::apply()`, the daemon MUST assert each required fd is still
valid (e.g. a no-op `fcntl(F_GETFL)` or a probe write) and **fail loudly**
(log `error!` + exit with a distinct code) if any is missing. This
catches a regression where a fd open moves post-drop by mistake (the
`nobody` open would fail silently or with EACCES, and the daemon would
run degraded). The self-check is a one-time startup assertion, not a
per-loop check.

## Answer from current code: does `tbard` privdrop today?

**No.** `grep -rn "privdrop\|PrivDrop\|nobody" src/` returns zero matches.
`privdrop = "0.5.6"` is listed in `Cargo.toml` but is an **unused
dependency** — the current `tbard` runs as whatever user started it
(typically the user, in dry-run; root in a future system unit). There is
no privilege-drop path in `src/` today. The future service ADR must add
the privdrop step (after the pre-drop fd opens) per the recipe above.

## References

- `docs/test-logs/004-service-oracle/oracle-runtime.txt` — runtime evidence
- `docs/test-logs/004-service-oracle/deployed.service` — live unit
- `docs/test-logs/004-service-oracle/binary-identity.txt` — build identity
- `backup_old/tiny-dfr-mbp142/src/main.rs:822-943` — the recipe (read-only)
- `backup_old/tiny-dfr-mbp142/src/display.rs:67-71,180-199` — master acquire
- `backup_old/tiny-dfr-mbp142/src/backlight.rs:30-44,85` — backlight select
- `docs/review-report-v2.md` Adjudication A — seat-gated test blocker
- `docs/adr/001-architecture.md` — the original (now-superseded) "no root" assumption

## Amendment (ADR-016) — logind seat-ACL execution path + bench-grant model

ADR-016 amends this ADR with a **third execution path** (in addition to
root-start+privdrop and the rejected CAP_SYS_ADMIN): an unprivileged user
in the **active** `seat0` session can acquire DRM master on a
`master-of-seat`+`uaccess`-tagged card (e.g. vkms `card2`) via logind's
seat-master coordination — **but only when no compositor currently holds
master on the card**. The bench-grant model (ADR-016 §1, evidence
2026-09-26): `setMaster` succeeds ⟺ (root OR active-seat ACL) AND no
current master. Hyprland takes master on every DRM device it opens,
including hotplug-added vkms, so the EACCES observed in session 008 is
master-exclusivity (Hyprland holds card2), not a privilege rule. The
"unprivileged EACCES" narrative above is **context-dependent**: true
when a compositor holds master OR the session is idle; false when the
compositor has released the card. The reproducible granted-bench
procedure is in **ADR-026**. See `docs/adr/016-logind-seat-acl.md` +
`docs/test-logs/005/inv-a-systemic-explanation.log` +
`docs/review-report-v4.md` T4.