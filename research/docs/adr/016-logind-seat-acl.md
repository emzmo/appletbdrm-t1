# ADR 016: Logind Seat-ACL Execution Path + Bench Context (ADR-010 amendment)

## Status: Accepted (amends ADR-010; docs-only)

## Date: 2026-09-26

## Context

QA review-v3 Investigation A (`docs/review-report-v3.md:330-422`)
discovered that the two seat-gated tests (`test_sim_display_acquires_vkms`,
`test_sigterm_releases_master`) PASS **unprivileged** (uid 1000) on this
bench, contradicting the ADR-010 narrative that "an unprivileged shell
CANNOT acquire vkms master here (EACCES on tty3)." The explanation is the
**logind seat-ACL execution path**, which ADR-010 did not document. This
ADR amends ADR-010 with that path + the bench context, and records the
ADR-010 evidence caveat (`/proc/562/fd` capture required root).

## Decision (amendments to ADR-010)

### 1. DRM master acquisition model (bench-grant model, evidence 2026-09-26)

**`setMaster` succeeds ⟺ (root OR active-seat ACL) AND no current master.**

Two conditions are BOTH required:
1. **Privilege**: the caller is root, OR the caller is the active-seat
   user with a logind ACL on the card (`master-of-seat` + `uaccess` tags
   → `getfacl /dev/dri/cardN` shows `user:<uid>:rw-`).
2. **Master-exclusivity**: no process currently holds DRM master on the
   card. The kernel allows exactly one master per card at a time; a
   `setMaster` when another process holds master fails with EACCES (or
   EBUSY under some drivers) even if the caller is privileged.

**Hyprland takes master on every DRM device it opens**, including
hotplug-added vkms. `aquamarine` (Hyprland's backend) hotplug-opens a
DRM card that appears after Hyprland started — so if vkms is modprobed
AFTER Hyprland started, Hyprland opens card2 and takes master, and a
later unprivileged `setMaster` EACCESes despite the seat ACL + active
session. This is **master-exclusivity, not a privilege rule**: the seat
ACL is granted (`user:emzmo:rw-`), the session is active, but Hyprland's
master lease blocks the acquire.

This model explains the observed matrix (factual correction
2026-09-26 — do NOT retro-fit the model to rows whose mechanism is
unverifiable):
- **Session 007 / QA v3 PASS — mechanism UNVERIFIED**. The prior text
  credited "AQ_DRM_DEVICES→i915" as the mechanism. This is **PROVEN
  FALSE** by the 2026-09-26 environ capture: `grep -a AQ_DRM /proc/$(pidof
  Hyprland)/environ` returns nothing, and no `hyprland.conf` exists on
  this bench (the compositor is a Noctalia-style setup with no
  `~/.config/hypr/hyprland.conf` — see ADR-026's config-discovery step).
  No bench-state capture exists for session 007 (no `docs/test-logs/NNN/
  bench-state.md` for that run), so the mechanism that made the
  unprivileged `setMaster` succeed is an **open question** — it may have
  been a transient vkms-not-yet-opened-by-Hyprland window, a different
  Hyprland/aquamarine version, or a now-changed udev/logind state. The
  PASS is real (the QA v3 log records it); the *explanation* is not.
- **QA v4 / session 008 EACCES (unprivileged) + EBUSY (root)** —
  **SUPPORTED by direct evidence**. `sudo cat /sys/kernel/debug/dri/2/
  clients` (2026-09-26) shows a `Hyprland` row with `master y` on dev 2
  (card2), and a `systemd-logind` row with `master y`. Hyprland holds
  master → unprivileged `setMaster` EACCES (no exclusivity) and root
  `setMaster` EBUSY (exclusivity blocks root too). vkms was modprobed
  AFTER Hyprland started → aquamarine hotplug-opened card2.
- **tty3 EACCES** — mechanism consistent with the model (Hyprland on tty1
  holds master; tty3 idle → no ACL + Hyprland holds master → EACCES) but
  no debugfs capture exists for that session; treat as
  model-consistent, not directly proven.

The 2026-09-26 debugfs capture is the canonical evidence:
```
$ sudo cat /sys/kernel/debug/dri/2/clients
         command  tgid dev master a   uid  ...
  systemd-logind   500   2   y    y     0  ...
        Hyprland  3005   2   y    y  1000  ...
        Hyprland  3005   2   n    n  1000  ...
```
`Hyprland` row `master y` on dev 2 = Hyprland holds DRM master on card2.

### 2. Third execution path: logind seat ACL (refined by the model)

ADR-010 documented two privilege paths: (a) root-start + privdrop
(production), (b) `User=nobody` + `CAP_SYS_ADMIN` (rejected). There is a
**third path** that the bench tests exercise — the logind seat-ACL path
— **but only when no compositor holds master on the card**:

- vkms `card2` is tagged `master-of-seat` + `seat` + `uaccess`
  (`udevadm info /sys/class/drm/card2` → `TAGS=:master-of-seat:seat:uaccess:`).
- `loginctl seat-status seat0` lists `card2` with `[MASTER] drm:card2`.
- Session 3 (emzmo) is `Active=yes`, `State=active` on `seat0`.
- `getfacl /dev/dri/card2` shows `user:emzmo:rw-` — logind granted the
  active session user an ACL on the card.
- **AND** no compositor (Hyprland/aquamarine) currently holds master on
  card2 (see §1 — Hyprland hotplug-opens vkms if it appears after
  startup).

**Result**: an unprivileged user in the **active** `seat0` session can
acquire vkms master WITHOUT sudo **iff no compositor holds master on the
card**. The ADR-010 EACCES narrative is **context-dependent**: true when
a compositor holds master OR the session is idle; false when the
compositor has released the card (e.g. `AQ_DRM_DEVICES` pointed at i915
AND vkms loaded before Hyprland's hotplug scan, or Hyprland restarted
after `AQ_DRM_DEVICES` was applied). ADR-010 is corrected accordingly.

### 2. Bench context recording

Every test run that exercises DRM master should record (per
`docs/test-logs/006/bench-state.md`):
- `id -u` (uid),
- `loginctl session-status` `Active=` / `State=` for the current session,
- `getfacl /dev/dri/card2` (ACL presence),
- `udevadm info /sys/class/drm/card2` (tags),
- `AQ_DRM_DEVICES` status (env + Hyprland config).

**Bench-change caveat (refined by the bench-grant model)**: the earlier
EACCES (tty3, idle) vs the session-007 PASS (active seat0, no compositor
on card2) vs the session-008 EACCES (vkms hotplug-added after Hyprland →
Hyprland holds master) are all **bench-state changes, not code changes**.
The determining factor is whether a compositor holds master on card2,
which depends on (a) whether vkms was loaded before Hyprland's hotplug
scan and (b) whether `AQ_DRM_DEVICES` routes Hyprland away from card2.
Record `fuser /dev/dri/card2` (is Hyprland holding it?) + the above
state per run. The granted-bench procedure that guarantees a reproducible
unprivileged-pass state is in **ADR-026**.

### 3. ADR-010 evidence caveat

ADR-010's `/proc/562/fd` evidence (`docs/test-logs/004-service-oracle/oracle-runtime.txt`)
was captured with **root privilege** — reading a `nobody` process's fd
table requires `CAP_SYS_PTRACE` or root. `ls /proc/562/fd/` as uid 1000
→ Permission denied; under sudo → succeeds. ADR-010 is amended to note
this (one paragraph in its evidence section).

### 4. udev `uaccess` tag ordering finding (evidence 2026-09-26)

`/dev/input/event4` (the Touch Bar digitizer) carries
`TAGS=:uaccess:seat-touchbar:` (`udevadm info /dev/input/event4`), but
`getfacl /dev/input/event4` shows **no user ACL** — only `user::rw-` and
`group::rw-` (group `input`). The `uaccess` TAG did **not** materialize
an ACL. Suspected cause: our `99-touchbar-seat.rules` adds `TAG+="uaccess"`
at rule number 99, **after** systemd's `/usr/lib/udev/rules.d/70-uaccess.rules`
ran `IMPORT{builtin}="uaccess"` (which is the builtin that converts an
existing `uaccess` TAG into a user ACL at the active session). At number
70 the TAG was not yet present (our rule runs at 99), so the builtin
no-ops; at number 99 we add the TAG but the builtin has already passed.
This is masked on this bench by the user being in group `992(input)` (so
`group::rw-` grants access regardless of the missing ACL). Fix planned
for the ADR-019 packaging session: rename the rule to
`69-touchbar-seat.rules` (so the `uaccess` TAG is present before the
70-uaccess builtin runs) OR append `IMPORT{builtin}="uaccess"` after the
`TAG+="uaccess"` line in our rule. **Docs only — no rule change this
session.**

## Impact list

- `docs/adr/010-master-acquisition-input.md` — amended: add the logind
  seat-ACL path as a third execution path; correct the EACCES narrative
  as context-dependent; add the `/proc/562/fd` privilege caveat.
- `docs/test-logs/006/bench-state.md` — referenced as the bench-context
  template.
- No code change.

## References

- `docs/review-report-v3.md:330-422` — Investigation A (the discovery)
- `docs/review-report-v4.md` — T4 live re-verification (the session-008
  EACCES that refined the model: Hyprland hotplug-holds card2 master)
- `docs/test-logs/005/inv-a-systemic-explanation.log` — the evidence
- `docs/test-logs/006/bench-state.md` — bench context template
- `docs/test-logs/008/bench-state.md` — session-008 bench state (Hyprland
  holds card2; `fuser` evidence)
- `docs/adr/026-granted-bench-procedure.md` — the reproducible
  granted-bench procedure (load vkms at boot + AQ_DRM_DEVICES + re-login)

---

## Incident entry — 2026-09-26 login breakage (bench-lane closure)

**2026-09-26**: the unprivileged granted-bench lane this ADR's §1 model
underpins is **CLOSED** on this machine after a second compositor-chain
incident. The bench-grant model (§1) remains valid as a *model*; the
*procedure* to stage the granted state (ADR-026) is no longer pursued on
this machine.

### What happened

The prior diagnostics session staged `AQ_DRM_DEVICES` (set to only the
i915 card node) via three login-chain files (`~/.profile`,
`~/.config/environment.d/aq-devices.conf`, `~/.config/uwsm/env-hyprland`)
to realize ADR-026's procedure. On the next logout/login (boot -2,
2026-09-26 09:03), Hyprland **ABRT'd (signal 6) at ~1 s after session
start** on three consecutive login attempts, forcing the user to reboot
from the greeter. The session died instantly each time — the
"session-13/15/17 started → Hyprland ABRT → session removed" pattern is
in `journalctl -b -2` (09:03:30–09:03:49). Removing `~/.profile` and
`~/.config/environment.d/aq-devices.conf` restored login on boot 0; the
third file (`~/.config/uwsm/env-hyprland`) is inert (uwsm not installed).

### Task-2 root-cause status (with journal citations)

Full analysis: `docs/test-logs/010-bench-incident/root-cause-from-logs.md`.
Summary:

- **H1 (AQ_DRM_DEVICES → Hyprland/aquamarine backend-init failure at
  session start → session dies instantly → login breaks): CONFIRMED
  (mechanism).** Hyprland ABRT'd within ~1 s of `Started Session N` on
  three attempts (boot -2:
  `systemd-coredump[13049]: Process 13030 (Hyprland) … signal 6/ABRT`
  at 09:03:31; `systemd-coredump[13234]: Process 13215 (Hyprland) …
  signal 6/ABRT` at 09:03:36; session-17 scope deactivated same second
  at 09:03:49). Pre-incident boots -4/-3 had no Hyprland ABRTs.
  Removing the injection fixed login (boot 0). **Evidentiary gap**: the
  exact ABRT text/backtrace is NOT in the journal (Hyprland logs nothing
  to journald before aborting) and `coredumpctl info Hyprland` returns
  "No coredumps found" (cores rotated/purged) — the precise assertion
  site is UNKNOWN.
- **H2 (~/.profile sourcing broke a different step of the greetd/sh
  session prefix): REFUTED.** The wayland session reached `Started
  Session N` on each attempt; the dying process was specifically
  Hyprland (named in the coredump line), not the session worker or a
  shell. greetd's `source_profile: true` is the long-standing path
  (boots -4/-3 used it and Hyprland launched fine).
- **H3 (environment.d / systemd-user-manager interplay): REFUTED as
  primary cause; UNKNOWN as a contributing factor (no positive
  evidence).** The first ABRT (09:03:31) preceded the user-manager
  teardown (09:03:47); Hyprland is launched by greetd into the session
  scope, not by the user manager, so `environment.d` is not in
  greetd→Hyprland's env chain.

**Terminal root-cause status**: mechanism CONFIRMED (Hyprland ABRT at
backend-init latency with the staged `AQ_DRM_DEVICES` active; removing
it fixed login); exact abort site UNKNOWN (no backtrace available).
Reproduction to recover the backtrace belongs on a disposable VM/spare
machine, NOT this dev machine.

### Impact on this ADR

- §1 (the bench-grant model) stands — it is the *model*, confirmed by
  the session-008 debugfs evidence (Hyprland master y on card2). The
  2026-09-26 incident does not contradict the model; it shows that the
  *procedure* to reach the granted state is dangerous on this machine.
- §2 (the logind seat-ACL execution path) stands as a path that exists
  *in principle* but is **not** to be exercised via login-chain staging
  on this machine. The sudo path (ADR-010) is the official bench.
- The "AQ_DRM_DEVICES → i915" mechanism credited for the session-007
  PASS in §1 remains **UNVERIFIED** (as before); the 2026-09-26 incident
  adds no new evidence about session-007's mechanism.
- See ADR-026's CLOSURE for the lane-closure statement and the retained
  reference material.