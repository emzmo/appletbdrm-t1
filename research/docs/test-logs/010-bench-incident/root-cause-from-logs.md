# Root Cause from Previous-Boot Logs — Bench-Lane Incident (2026-09-26)

Read-only analysis of `journalctl` for the boot(s) spanning the failed
login attempt. Zero system impact (journal reads only). No reproduction
attempted, none proposed — reproduction, if ever wanted, belongs on a
disposable VM/spare machine, not this dev machine.

---

## 1. Boot inventory — `journalctl --list-boots` (tail)

```
IDX BOOT ID                          FIRST ENTRY                  LAST ENTRY
 -7 016763f557e942938a89964ec69aec74 Mon 2026-09-21 23:26:39 WEST Tue 2026-09-22 00:00:24 WEST
 -6 f4ea46bdaee24b6fa20372121e6c918a Wed 2026-09-23 18:34:44 WEST Wed 2026-09-23 23:10:13 WEST
 -5 d74fb32818864196962ba27ab44e2ad1 Thu 2026-09-24 15:37:16 WEST Fri 2026-09-25 00:06:15 WEST
 -4 c988f392fa15483fb1cb241e5eca9199 Fri 2026-09-25 08:05:20 WEST Sat 2026-09-26 00:42:44 WEST
 -3 34a9b686a1504985bc843e23333ec6ab Sat 2026-09-26 00:43:13 WEST Sat 2026-09-26 01:20:36 WEST
 -2 38653e0627204f43b19f448ae0d58da6 Sat 2026-09-26 01:20:58 WEST Sat 2026-09-26 09:04:04 WEST
 -1 fefe95a4ea004ecfaa39a6152a3c5327 Sat 2026-09-26 09:24:13 WEST Sat 2026-09-26 09:32:13 WEST
  0 817bfc806df64ce9a95f54dbbba737e7 Sat 2026-09-26 09:32:45 WEST Sat 2026-09-26 09:44:03 WEST
```

### Boot selection

- **Boot -2** (Sat 01:20:58 → 09:04:04) — **the incident boot**. Spans
  the failed login attempts and the user's reboot to escape. This is the
  primary evidence boot.
- **Boot -1** (Sat 09:24:13 → 09:32:13) — the first recovery boot (after
  the user rebooted from the greeter at 09:04:03 on boot -2). Short; the
  user was still removing the staged files / verifying.
- **Boot 0** (Sat 09:32:45 → now) — the current restored boot; login
  works. Captured in `recovery-verification.md`.
- **Boots -4 / -3** — pre-incident; Hyprland sessions ran normally (no
  ABRT). Used to confirm the breakage is *new* in boot -2, not a
  pre-existing condition.

The staged login-chain files (`~/.profile`, 
`~/.config/environment.d/aq-devices.conf`, `~/.config/uwsm/env-hyprland`)
were created during the prior diagnostics session, which ran inside boot
-2's working Hyprland session (session 10, started 01:21:14 on boot -2)
and/or the boot -3 session. The incident manifested when the user logged
out of session 10 and tried to log back in — the re-login re-sourced the
staged files and Hyprland ABRT'd.

---

## 2. Incident sequence — boot -2, 09:03:23 → 09:04:03 (verbatim journal lines)

The user logged out of the prior working Hyprland session (session 10)
at 09:03:23, then attempted to log back in. greetd → cosmic-greeter came
up, the user authenticated, and greetd launched Hyprland for the new
wayland session. Hyprland **ABRT'd (signal 6) within ~1 second of session
start**, three times in a row, after which the user gave up and rebooted
from the greeter.

```
Sep 26 09:03:23 phobos greetd[11139]: pam_unix(login:session): session closed for user emzmo
Sep 26 09:03:23 phobos systemd[1]: session-10.scope: Deactivated successfully.
Sep 26 09:03:23 phobos systemd-logind[500]: Removed session 10.
... (cosmic-greeter comes back up as session 11) ...
Sep 26 09:03:30 phobos greetd[12971]: pam_unix(login:session): session opened for user emzmo(uid=1000) by emzmo(uid=0)
Sep 26 09:03:30 phobos systemd-logind[500]: New session '13' of user 'emzmo' with class 'user' and type 'wayland'.
Sep 26 09:03:30 phobos systemd[1]: Started Session 13 of User emzmo.
Sep 26 09:03:31 phobos systemd-coredump[13049]: Process 13030 (Hyprland) of user 1000 terminated abnormally with signal 6/ABRT, processing...
Sep 26 09:03:31 phobos greetd[12971]: pam_unix(login:session): session closed for user emzmo
Sep 26 09:03:31 phobos systemd[1]: session-13.scope: Deactivated successfully.
Sep 26 09:03:31 phobos systemd-logind[500]: Removed session 13.
... (cosmic-greeter session 14) ...
Sep 26 09:03:36 phobos greetd[13156]: pam_unix(login:session): session opened for user emzmo(uid=1000) by emzmo(uid=0)
Sep 26 09:03:36 phobos systemd-logind[500]: New session '15' of user 'emzmo' with class 'user' and type 'wayland'.
Sep 26 09:03:36 phobos systemd[1]: Started Session 15 of User emzmo.
Sep 26 09:03:36 phobos systemd-coredump[13234]: Process 13215 (Hyprland) of user 1000 terminated abnormally with signal 6/ABRT, processing...
Sep 26 09:03:37 phobos greetd[13156]: pam_unix(login:session): session closed for user emzmo
Sep 26 09:03:37 phobos systemd[1]: session-15.scope: Deactivated successfully.
Sep 26 09:03:37 phobos systemd-logind[500]: Removed session 15.
... (cosmic-greeter session 16) ...
Sep 26 09:03:49 phobos greetd[13341]: pam_unix(login:session): session opened for user emzmo(uid=1000) by emzmo(uid=0)
Sep 26 09:03:49 phobos systemd-logind[500]: New session '17' of user 'emzmo' with class 'user' and type 'wayland'.
Sep 26 09:03:49 phobos systemd[1]: Started Session 17 of User emzmo.
Sep 26 09:03:49 phobos greetd[13341]: pam_unix(login:session): session closed for user emzmo
Sep 26 09:03:49 phobos systemd[1]: session-17.scope: Deactivated successfully.
Sep 26 09:03:49 phobos systemd-logind[500]: Removed session 17.
... (cosmic-greeter session 19; user gives up) ...
Sep 26 09:04:03 phobos systemd-logind[500]: reboot requested from client PID 13504 ('cosmic-greeter') (unit session-19.scope)...
Sep 26 09:04:03 phobos greetd[574]: error: check_children: greeter exited without creating a session
```

Summary of the three Hyprland launches:

| attempt | session | Hyprland PID | outcome | latency |
|---|---|---|---|---|
| 1 | 13 | 13030 | ABRT signal 6 | ~1 s after `Started Session 13` |
| 2 | 15 | 13215 | ABRT signal 6 | ~0 s (same timestamp) |
| 3 | 17 | (no coredump line) | session-17 scope deactivated same second | ~0 s |

The only Hyprland-related lines in the entire boot -2 journal are the two
coredump lines:

```
Sep 26 09:03:31 phobos systemd-coredump[13049]: Process 13030 (Hyprland) of user 1000 terminated abnormally with signal 6/ABRT, processing...
Sep 26 09:03:36 phobos systemd-coredump[13234]: Process 13215 (Hyprland) of user 1000 terminated abnormally with signal 6/ABRT, processing...
```

**No aquamarine/Hyprland stdout/stderr reached the journal** — Hyprland
logs nothing to journald before ABRT'ing, so the *specific* ABRT message
(textual reason) is not in the journal. `coredumpctl info Hyprland` returns
"No coredumps found" — the cores were processed by systemd-coredump at
the time but are no longer retrievable (rotated/purged), so **no
backtrace is available**.

### Pre-incident boots confirm the breakage is new

Boot -4 (Sep 25) and boot -3 (Sep 26 00:43) had normally-running Hyprland
sessions with no ABRT:

```
# boot -4
Sep 25 08:05:37 ... New session '3' of user 'emzmo' ... type 'wayland'.
Sep 25 08:05:37 ... Started Session 3 of User emzmo.
Sep 25 20:31:53 ... Started Session 5 of User emzmo.
Sep 25 20:38:41 ... Started Session 6 of User emzmo.
Sep 25 20:38:51 ... Started Session 7 of User emzmo.
(no Hyprland ABRT lines anywhere in boot -4)

# boot -3
Sep 26 00:43:23 ... New session '3' of user 'emzmo' ... type 'wayland'.
Sep 26 00:43:23 ... Started Session 3 of User emzmo.
Sep 26 01:20:26 ... New session '7' of user 'emzmo' ... type 'wayland'.
Sep 26 01:20:26 ... Started Session 7 of User emzmo.
(no Hyprland ABRT lines anywhere in boot -3)
```

So Hyprland launched fine on boots -4 and -3. The ABRT first appears on
boot -2, immediately after the staged login-chain files were in place and
the user logged out + back in.

---

## 3. Hypothesis verdicts

### H1 — `AQ_DRM_DEVICES=only-the-i915-card-node` made Hyprland/aquamarine fail backend init at session start → session died instantly → login broke.

**CONFIRMED (mechanism) — with one evidentiary gap.**

Evidence FOR:
- Hyprland ABRT'd (signal 6, an assertion/abort not a segfault) within
  ~1 second of session start on three consecutive login attempts (boot
  -2, §2). The latency is consistent with a backend-init failure:
  aquamarine's `CDRMBackend::attempt()` → `scanGPUs()` runs at compositor
  startup, before any output is configured.
- The prior diagnostics session staged `AQ_DRM_DEVICES` to *only* the
  i915 card node (`/dev/dri/by-path/pci-0000:00:02.0-card`), via three
  login-chain files. On boot -2 that env var would have reached Hyprland
  at session start (greetd's config has `source_profile: true`; the
  staged `~/.profile` and `~/.config/environment.d/aq-devices.conf` are
  both in greetd/PAM's sourcing chain).
- Boot -2 is the *only* boot with Hyprland ABRTs; boots -4/-3 (before
  staging) had normal Hyprland. The breakage is temporally coincident
  with the staged files being present at re-login.
- The recovery (boot 0) removed `~/.profile` and
  `~/.config/environment.d/aq-devices.conf`; the surviving
  `~/.config/uwsm/env-hyprland` is inert (uwsm not installed, §1.2 of
  recovery-verification.md); on boot 0 Hyprland launches cleanly with no
  `AQ_` in its environ. Removing the active injection fixed login —
  consistent with the injection being the cause.

Evidentiary gap:
- The **specific ABRT text/backtrace is NOT in the journal** (Hyprland
  emits no journald output before aborting) and the **cores are gone**
  (`coredumpctl info Hyprland` → "No coredumps found"). So the exact
  assertion that fired cannot be cited. We can confirm Hyprland ABRT'd
  at backend-init latency with the staged env var present, and that
  removing the env var fixed it — but we cannot cite the precise
  aquamarine error string.

Why "only the i915 card node" specifically would abort: aquamarine's
`scanGPUs` canonicalizes each `AQ_DRM_DEVICES` entry and matches it
against the enumerated DRM cards (DRM.cpp:202-244, see
`docs/research/hyprland-aq-devices.md` §4.1). A filter that excludes
vkms is the *intended* use. The abort is therefore more likely a
*downstream* consequence of the filter (e.g. Hyprland/aquamarine hitting
an unexpected state when its device set is restricted on this
multi-card bench: appletbdrm card + i915 card + vkms, with the Touch Bar
and vkms both filtered out) than a parse failure of the var itself. The
prior hyprland.lua parse failure (the *first* compositor-chain incident,
already recorded) is a separate failure mode — this incident is a
runtime abort, not a config parse error. **The exact abort site is
UNKNOWN absent the core.**

### H2 — `~/.profile` sourcing broke a different step of the greetd/sh session prefix.

**REFUTED.**

- greetd's config on boot -2 shows `source_profile: true` and `service:
  "login"`. greetd sources `~/.profile` via PAM/shell as part of starting
  the user session — this is the normal, long-standing path on this
  machine (boots -4/-3 also used greetd with `source_profile: true` and
  Hyprland launched fine). The *sourcing* mechanism itself is not new.
- The staged `~/.profile` contained a single `export AQ_DRM_DEVICES=…`
  line. It did not contain shell syntax errors, did not `exit`, did not
  redefine PATH or break the shell — it set one env var. There is no
  journal evidence of a shell/session-prefix failure (no `p_unix` auth
  failure, no shell error, no "session leader exited" before Hyprland
  started). On all three attempts the wayland session *did* start
  (`New session ... type 'wayland'`, `Started Session …`), and the
  process that died was specifically **Hyprland** (PID named in the
  coredump line), not the greetd session worker or a shell.
- The failure point is the compositor process, not the session prefix.
  H2 is refuted by the coredump identifying Hyprland as the dying
  process and by the session successfully reaching the "Started Session"
  stage before Hyprland ABRT'd.

### H3 — `environment.d` / systemd-user-manager interplay.

**REFUTED (as the primary cause); UNKNOWN (as a contributing factor).**

- `~/.config/environment.d/aq-devices.conf` is read by the systemd **user
  manager** (`user@1000.service`), not by greetd's session shell. On
  boot -2 the user manager (session 4 / session 18) was already running
  from the prior logged-in session and was torn down *during* the
  incident window (09:03:47 `user@1000.service: Deactivated
  successfully`, 09:03:59 again). The `environment.d` file would have
  been read when the user manager *next* started — but Hyprland is
  launched by greetd directly into the session scope, not by the user
  manager, so `environment.d` is not in greetd→Hyprland's env chain.
- The three Hyprland ABRTs all happened *before* the user manager was
  torn down (first ABRT at 09:03:31; user manager deactivated at
  09:03:47). So whatever `environment.d` was doing, Hyprland had already
  ABRT'd independently.
- The var that reached Hyprland came from greetd's `source_profile: true`
  sourcing `~/.profile` (H1's path), not from `environment.d`. There is
  no evidence the user-manager interplay caused the abort. Marking H3
  REFUTED as the primary cause; UNKNOWN only as a hypothetical
  contributing factor for which there is no positive evidence.

---

## 4. Terminal root-cause status

**Root cause (mechanism): CONFIRMED — Hyprland ABRT'd (signal 6) at
~1 s after session start on boot -2, three consecutive attempts, with
the staged `AQ_DRM_DEVICES` injection active in the greetd→Hyprland env
chain; removing the injection (deleting `~/.profile` and
`~/.config/environment.d/aq-devices.conf`) restored login on boot 0.**

**Exact abort site / assertion text: UNKNOWN — the journal has no
Hyprland/aquamarine stderr before the ABRT, and `coredumpctl info
Hyprland` returns no cores (rotated/purged). The backtrace is not
available. Reproduction to recover the backtrace belongs on a disposable
VM/spare machine, NOT this dev machine — the bench lane is closed.**

**Hypothesis scores**: H1 CONFIRMED (mechanism; exact abort site
unknown), H2 REFUTED, H3 REFUTED (primary) / UNKNOWN (contributing, no
positive evidence).

The prior diagnostics session's risk note ("worst case: harmless env
var") is **REFUTED by this incident**: an `AQ_DRM_DEVICES` filter
applied via the login chain on this multi-card bench can abort
Hyprland/aquamarine at backend init and break graphical login. See
`docs/dangers.md` HOST SAFETY RULES (added this session).