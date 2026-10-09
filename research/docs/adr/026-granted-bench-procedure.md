# ADR 026: Granted-Bench Procedure — Reproducible Unprivileged vkms Master

## Status: **CLOSED** (2026-09-26, incident post-mortem) — see "CLOSURE"
  below. The unprivileged granted-bench lane is CLOSED on this machine;
  the procedure is retained for historical/reference value only.

## Date: 2026-09-26

## Context

The bench-grant model (ADR-016 §1) shows `setMaster` succeeds ⟺
(root OR active-seat ACL) AND no current master. The seat-gated tests
(`test_sim_display_acquires_vkms`, `test_sigterm_releases_master`) and
the hermetic smoke require the daemon to acquire vkms master on `card2`.
On this bench, Hyprland (via `aquamarine`) takes master on every DRM
device it opens, including hotplug-added vkms — so if vkms is loaded
after Hyprland started, Hyprland hotplug-opens card2 and the unprivileged
`setMaster` EACCESes despite the seat ACL + active session (session-008
evidence, `docs/review-report-v4.md` T4).

This ADR defines the **granted-bench procedure** — the reproducible steps
that guarantee card2 has NO compositor master so the unprivileged tests
EXECUTE and PASS. It is the operational counterpart to ADR-016's model.
ADR-019 (reserved, service session) covers the production root-start path;
this ADR covers the development/QA bench.

## Decision — granted-bench procedure

The procedure guarantees: vkms is loaded at boot (before Hyprland),
Hyprland is routed away from card2, and the session ACL is active.

1. **Load vkms at boot, before login.** Create
   `/etc/modules-load.d/vkms.conf` containing `vkms`, so the module loads
   during early boot (initramfs/base systemd modules) before any login
   session or compositor starts. This prevents the post-start hotplug
   race where aquamarine opens a newly-appeared card.
   ```sh
   echo vkms | sudo tee /etc/modules-load.d/vkms.conf
   ```

2. **Discover the compositor config file actually loaded.** This bench
   runs a **Noctalia-style** setup with NO `~/.config/hypr/hyprland.conf`
   and NO `/etc/xdg/hypr/hyprland.conf` (proven by `ls` 2026-09-26 — both
   absent). The `env = AQ_DRM_DEVICES,...` line MUST land in the file
   Hyprland actually loads, else it silently does nothing (the 2026-09-26
   environ capture proved `AQ_DRM_DEVICES` was never applied despite the
   prior procedure asserting it). Config discovery:
   ```sh
   # Hyprland's source chain: --config <cmdline> ? $HYPRLAND_CONFIG_FILE
   # ? <executable-dir>/hyprland.conf (when invoked from a wrapper)
   # ? ~/.config/hypr/hyprland.conf ? $XDG_CONFIG_DIRS/hypr/hyprland.conf
   # ? /etc/hyprland.conf. Noctalia wraps Hyprland; its config is
   # ~/.config/noctalia/config.toml, which does NOT source a hyprland.conf.
   # Find the loaded file by inspecting the wrapper + the Hyprland source:
   hyprctl --version                # confirms the compositor
   ls ~/.config/hypr/ /etc/xdg/hypr/ # standard locations (absent here)
   # If a wrapper (e.g. start-hyprland) sets --config or sources a file,
   # edit THAT file. If none exists, create ~/.config/hypr/hyprland.conf
   # (Hyprland falls back to it) and ensure the wrapper does not override.
   ```
   The line must land in the **actually-loaded** file; verify via step 6
   (the environ check that would have caught the silent non-application).

3. **Route Hyprland away from vkms.** In the config file discovered in
   step 2, set `AQ_DRM_DEVICES` (or `WLR_DRM_DEVICES`) to the i915
   by-path device so Hyprland opens only the eDP card, not vkms:
   ```
   env = AQ_DRM_DEVICES,/dev/dri/by-path/pci-0000:00:02.0-card
   ```
   (Verify the by-path symlink for the i915 with
   `ls /dev/dri/by-path/ | grep card`.) `AQ_DRM_DEVICES` applied at
   Hyprland startup does NOT cover post-start hotplug — step 1 ensures
   vkms is already present at startup so the device filter applies to it
   (Hyprland sees vkms, skips it because it is not in the allow-list).

4. **Full log out and back in.** A re-login (or `loginctl terminate-session`
   + re-greetd) restarts Hyprland with the new `AQ_DRM_DEVICES` and the
   already-loaded vkms. The module survives logout (it is a kernel
   module, not session-scoped). Do NOT merely reload Hyprland config —
   `AQ_DRM_DEVICES` is read at backend init, not on config reload.

5. **Verify card2 has NO compositor master.** The **canonical** check is
   the debugfs `clients` file (shows the `master` column per process):
   ```sh
   sudo cat /sys/kernel/debug/dri/2/clients
   # EXPECTED: NO Hyprland row with master y. systemd-logind may show
   # master y (see caveat below). A Hyprland row with master y = FAIL.
   ```
   `fuser -v /dev/dri/card2` is a **quick SUFFICIENT check only** — it
   shows open fds, NOT master status. An empty `fuser` (no Hyprland fd)
   is sufficient to prove Hyprland does not hold master (no fd → no
   master), but a non-empty `fuser` does NOT prove Hyprland holds master
   (it may hold a non-master fd). Always confirm with debugfs `clients`
   before declaring the bench granted. 2026-09-26 debugfs capture:
   ```
   $ sudo cat /sys/kernel/debug/dri/2/clients
           command  tgid dev master a   uid
     systemd-logind   500   2   y    y     0
           Hyprland  3005   2   y    y  1000   <-- FAIL: Hyprland master
   ```

6. **Post-verification: confirm `AQ_DRM_DEVICES` is actually in the
   Hyprland process environ.** This is the check that would have caught
   the silent non-application in session 007/v3:
   ```sh
   sudo grep -a AQ_DRM_DEVICES /proc/$(pidof Hyprland)/environ | tr '\0' '\n'
   # EXPECTED: AQ_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card
   # If empty, the config line did not land in the loaded file — redo step 2.
   ```

7. **Run the unprivileged tests.** With the above verified:
   ```sh
   cargo build --bin tbard   # test_sigterm_releases_master spawns this
   cargo test -- --nocapture test_sim_display_acquires_vkms test_sigterm_releases_master
   ```
   Both should EXECUTE and PASS (no skip), acquiring + releasing vkms
   master via the active-seat ACL with no compositor competing.

8. **Fallbacks (VT / sudo) per ADR-010.** If the granted-bench procedure
   cannot be applied (e.g. cannot edit the loaded config or reboot), fall
   back to:
   - a clean text VT (`Ctrl-Alt-F2`, log in) where no compositor holds
     seat0 master — but tty3 EACCES was exclusivity, not a privilege rule,
     so the VT must NOT have a compositor holding card2 (vkms loaded at
     boot still applies);
   - sudo (root) — but root EACCESes/EBUSYes too if Hyprland holds master
     (exclusivity blocks root as well). Sudo works ONLY on a VT where
     Hyprland is not running, OR after stopping Hyprland.

   The granted-bench procedure (steps 1-7) is the ONLY path that works
   **without disrupting the running graphical session**, because it makes
   Hyprland release card2 by configuration rather than by stopping the
   compositor.

### logind caveat

`/sys/kernel/debug/dri/N/clients` may show a `systemd-logind` row with
`master y` on card2 (the 2026-09-26 capture shows it). logind holds a
master lease on seat devices for seat-master coordination; this is
**normal** and does NOT block the active-seat user's `setMaster` (logind
yields master to the active session's acquirer). If, however, the tests
still EACCES after Hyprland is excluded (no Hyprland row with master y,
only systemd-logind), **capture the debugfs `clients` verbatim**, fall
back to the sudo path (ADR-010, production-faithful), and **STOP** — the
bench is timeboxed. Do not attempt further udev/logind surgery in a
verification session; file the anomaly and let a fix session investigate.

## Why each step is necessary (tied to the model)

- **Step 1 (boot-load vkms)**: if vkms is modprobed after Hyprland starts,
  aquamarine hotplug-opens it and takes master (session-008 evidence).
  Boot-loading makes vkms visible at Hyprland startup so step 3's filter
  can exclude it.
- **Step 2 (config discovery)**: the 2026-09-26 environ capture proved
  `AQ_DRM_DEVICES` was never applied (no `hyprland.conf` on this bench).
  Editing a non-loaded file silently does nothing. This step finds the
  file Hyprland actually loads (cmdline `--config` → `$HYPRLAND_CONFIG_FILE`
  → executable-dir → `~/.config/hypr/` → `$XDG_CONFIG_DIRS` → `/etc/`).
- **Step 3 (`AQ_DRM_DEVICES`)**: without it, Hyprland opens every DRM
  card including vkms. With it, Hyprland opens only the i915, leaving
  card2 master-free.
- **Step 4 (re-login)**: `AQ_DRM_DEVICES` is read at backend init, not
  on config reload. A full session restart is required.
- **Step 5 (debugfs `clients` verify)**: the model says
  master-exclusivity is the deciding factor; `debugfs dri/N/clients` is
  the canonical observation of who holds master (the `master` column).
  `fuser` is a quick sufficient-only proxy (empty fuser ⇒ no master, but
  non-empty fuser ⇏ master). This catches a failed procedure before
  running the tests.
- **Step 6 (environ verify)**: confirms the config line reached the
  process. This is the check that would have caught the session-007
  silent non-application.
- **Step 7**: the tests spawn `target/debug/tbard` which must be freshly
  built — `cargo test` does NOT rebuild the main bin (QA v4 noted this;
  the `cargo build --bin tbard` prerequisite / ci-gate fix is tracked in
  **ADR-028**).

## Alternatives considered

- **Stop Hyprland, run tests, restart Hyprland.** Rejected: disrupts the
  graphical session (and the user's workflow). The granted-bench
  procedure keeps Hyprland running on the i915 while vkms is master-free.
- **Use a different vkms card that Hyprland never opens.** Rejected:
  there is only one vkms card; Hyprland opens all DRM cards unless
  filtered.
- **Run the tests under sudo on a VT.** Works but is the production-faithful
  path (ADR-010), not the unprivileged development path. Documented as a
  fallback.

## Impact list

- `docs/adr/016-logind-seat-acl.md` — amended with the bench-grant model
  (§1) and a reference to this ADR.
- No code change. No service implementation (ADR-019 reserved).

## References

- `docs/adr/016-logind-seat-acl.md` §1 — the bench-grant model this
  procedure operationalizes (and §4 — the udev `uaccess` ordering finding)
- `docs/review-report-v4.md` T4 — the session-008 EACCES (Hyprland
  hotplug-holds card2) that motivated this procedure
- `docs/test-logs/008/bench-state.md` — session-008 bench state evidence
- `docs/adr/010-master-acquisition-input.md` — the root-start production
  path (fallback)
- `docs/adr/028-*.md` — (planned) test-integrity: stale-binary hazard +
  `cargo build --bin tbard` ci-gate prerequisite
- 2026-09-26 debugfs capture (this session): `sudo cat
  /sys/kernel/debug/dri/2/clients` shows `Hyprland master y` on dev 2 —
  the canonical master-exclusivity evidence
- 2026-09-26 environ capture (this session): `grep -a AQ_DRM
  /proc/$(pidof Hyprland)/environ` = empty; `~/.config/hypr/hyprland.conf`
  + `/etc/xdg/hypr/hyprland.conf` absent — the config-discovery motivation

---

## CLOSURE — unprivileged granted bench CLOSED (2026-09-26 incident post-mortem)

**The unprivileged granted-bench lane is CLOSED on this machine.** Two
compositor-chain incidents have now occurred while attempting to stage
it; the lane is closed without a runtime re-confirmation, and runtime
re-confirmation is explicitly **NOT** to be performed on this machine in
any future session.

### Incident history (two compositor-chain breakages)

1. **hyprland.lua parse failure** (first incident, recorded separately):
   the legacy hyprlang line `env = AQ_DRM_DEVICES,…` was added to
   `~/.config/hypr/hyprland.lua`, which is a Lua config — the line is a
   syntax error in Lua and broke Hyprland config parse.
2. **Login breakage (2026-09-26, this incident)**: the prior diagnostics
   session staged `AQ_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card`
   via three login-chain files (`~/.profile`,
   `~/.config/environment.d/aq-devices.conf`,
   `~/.config/uwsm/env-hyprland`). On the next logout/login, Hyprland
   ABRT'd (signal 6) at ~1 s after session start on three consecutive
   attempts (boot -2, 09:03:31 / 09:03:36 / 09:03:49), forcing the user
   to reboot from the greeter. Removing `~/.profile` and
   `~/.config/environment.d/aq-devices.conf` restored login on boot 0.
   The third file (`~/.config/uwsm/env-hyprland`) was left in place and
   is **inert** because `uwsm` is not installed on this machine
   (`pacman -Q uwsm` → "package not found"); the active login chain is
   greetd → cosmic-greeter → Hyprland, with no uwsm in the chain. Full
   evidence: `docs/test-logs/010-bench-incident/recovery-verification.md`
   and `docs/test-logs/010-bench-incident/root-cause-from-logs.md`.

The prior diagnostics session's risk note ("worst case: harmless env
var") is **REFUTED** by the 2026-09-26 incident — an `AQ_DRM_DEVICES`
filter applied via the login chain on this multi-card bench can abort
Hyprland/aquamarine at backend init and break graphical login. See
`docs/dangers.md` HOST SAFETY RULES (added this session).

### Official bench for seat-gated tests

The **sudo path (prebuilt binaries, production-faithful per ADR-010)** is
the official bench for `test_sim_display_acquires_vkms` and
`test_sigterm_releases_master`. ADR-010's root-start + privdrop model is
the production-faithful execution path and does not require any
login-chain or compositor-config modification on the dev machine. The
granted-bench procedure in this ADR (steps 1–8) is **not** to be
re-attempted on this machine.

### Runtime re-confirmation explicitly NOT performed

The granted-bench procedure has **never** been successfully run end-to-end
on this machine (the session-007 PASS was real but its mechanism is
UNVERIFIED — see ADR-016 §1; the session-008 re-attempt EACCES'd because
Hyprland hotplug-held card2; the 2026-09-26 attempt to stage the
procedure broke login). Runtime re-confirmation is explicitly **NOT** to
be performed on this machine. The lane is closed **without** it. If
reproduction is ever wanted, it belongs on a disposable VM or spare
machine — never on this dev machine.

### What is retained from this ADR

The technical content (the bench-grant model, the `AQ_DRM_DEVICES`
semantics, the debugfs `clients` master-exclusivity check, the
driver-based card mapping) remains valid reference material. The
debugfs master check and the driver-based card mapping are reused by
the Stage-3 interlock diagnostic tooling
(`scripts/bench/verify-granted-bench.sh`, untracked — see recommendation
in the incident report). The *procedure* (editing the login chain to
apply the filter) is what is closed, not the underlying model.