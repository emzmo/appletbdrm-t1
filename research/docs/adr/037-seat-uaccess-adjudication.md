# ADR 037: NF-020-A Seat/uaccess Adjudication — Keep the Isolation, Annotate the Dead uaccess Tag

## Status: Accepted (docs-only + udev rule annotation + packaging/README update)

## Date: 2026-09-26

## Context

### NF-020-A (session 020, low severity)

The `uaccess` ACL does **NOT** materialize on the Touch Bar input
device. `getfacl /dev/input/event7` shows `user::rw-` only — no
`user:emzmo:rw-` entry. Root cause (machine-state backed, see
`docs/test-logs/020/udev-migration.log` §H):

- The `69-touchbar-seat.rules` rule sets `ENV{ID_SEAT}="seat-touchbar"`
  on the iBridge input device (VID:PID `05ac:8600`).
- logind's `uaccess` builtin materializes a user ACL for the active
  session's user **on the device's seat**. There is no `seat-touchbar`
  in logind (`loginctl: No seat 'seat-touchbar' known`; only `seat0`
  exists, with the active emzmo session).
- With no active session on `seat-touchbar`, logind has no user to
  materialize an ACL for, so none is set. The `TAG+="uaccess"` is
  present (`udevadm info` shows `TAGS=:uaccess:seat:seat-touchbar:`)
  and the builtin IS scheduled to run (`udevadm test` confirms
  `73-seat-late.rules:16 RUN{builtin}+="uaccess"`), but it no-ops
  because the device's seat has no active session.
- Contrast: the DRM cards on `seat0` (including the iBridge
  `card2`/appletbdrm) DO get `user:emzmo:rw-` materialized.

The 69- rule's two goals CONFLICT on this machine:

- **Goal 1 (libinput seat isolation, ADR 009):** `ID_SEAT=seat-touchbar`
  moves the digitizer OFF `seat0` so the desktop compositor's
  libinput context (Hyprland on `seat0`) CANNOT enumerate it —
  touches on the Touch Bar stay off the desktop cursor. This is the
  isolation that makes the Touch Bar an engine-owned input surface,
  not a second trackpad.
- **Goal 2 (uaccess user ACL, ADR 019 packaging):** `TAG+="uaccess"`
  expects the device to be on the active session's seat so logind
  materializes a user ACL. `ID_SEAT=seat-touchbar` defeats this.

Practical impact today: NONE — the Touch Bar input device is
group-owned by `input` (`group::rw-`), and the production daemon runs
as `nobody` with the digitizer fd opened PRE-DROP by root (ADR 010 +
ADR 036), so neither the user ACL nor the `input` group is on the
production access path. The missing ACL only matters for an
unprivileged non-`input` user opening the device directly, which is
not the production path.

### Why this is docs-only (no code change)

The production access path is ADR 010 + ADR 036: root opens the
digitizer fd PRE-DROP, privdrops to `nobody`, and the held fd is
verified by the post-drop self-check. The `uaccess` ACL is NOT on the
production path — it was a packaging-time attempt to give the
active console user seat-style access for a dev/manual-run path that
is not the production unit. The conflict between goal 1 and goal 2 is
real but it does not block production: goal 1 (isolation) is required
for correctness; goal 2 (uaccess ACL) is not required for the
root-start + privdrop recipe.

The RECOMMENDED resolution is therefore to KEEP the isolation (goal 1)
and annotate/remove the dead `uaccess` tag (goal 2), documenting the
dev-access alternatives. The proven root+privdrop recipe (ADR 010) is
NOT reopened — it is the production path.

## Decision

### D1 — Trade-off table

| Option | libinput seat isolation (Hyprland/libinput on seat0 cannot enumerate the digitizer) | uaccess ACL materializes on the digitizer | Production path (root + privdrop, ADR 010/036) | Dev / manual-run path (unprivileged user opens the device) |
| --- | --- | --- | --- | --- |
| **A: keep `ID_SEAT=seat-touchbar` + keep `TAG+="uaccess"` (status quo)** | YES (digitizer off seat0) | NO (no active session on seat-touchbar → uaccess no-ops) | unaffected (root opens pre-drop) | masked by `input` group membership; no ACL |
| **B: keep `ID_SEAT=seat-touchbar` + REMOVE `TAG+="uaccess"` (RECOMMENDED)** | YES (digitizer off seat0) | n/a (tag removed; no dead tag) | unaffected (root opens pre-drop) | `input` group membership (the long-standing bench lane) or a static ACL (see D3) |
| **C: drop `ID_SEAT=seat-touchbar` (put digitizer on seat0) + keep `TAG+="uaccess"`** | NO (Hyprland/libinput on seat0 CAN enumerate the digitizer — Touch Bar touches move the desktop cursor) | YES (device on seat0, active session user gets an ACL) | unaffected (root opens pre-drop) | uaccess ACL works, but isolation is LOST — Touch Bar touches become desktop pointer events |
| **D: custom `seat-touchbar` logind seat (uaccess materializes on the custom seat)** | YES (digitizer on its own seat) | YES (if a logind session is attached to `seat-touchbar` with an active user) | unaffected (root opens pre-drop) | requires a logind seat + session for `seat-touchbar`; complex, not pursued now (see D3 future alternative) |

### D2 — RECOMMENDED: Option B (keep the isolation; remove/annotate the dead uaccess tag)

- **Keep `ID_SEAT=seat-touchbar`.** The isolation is required for
  correctness: without it, Hyprland's libinput context on `seat0`
  enumerates the Touch Bar digitizer and Touch Bar touches move the
  desktop cursor — the Touch Bar stops being an engine-owned input
  surface. This is the ADR 009 design intent and must not be
  sacrificed for a uaccess ACL that is not on the production path.
- **Remove the `TAG+="uaccess"` line from the rule** (or annotate it
  as dead with a comment explaining NF-020-A). A dead tag that no-ops
  is worse than no tag: it implies an ACL that never materializes,
  which is exactly the W2 "event4 evidence closed" false closure it
  caused. Removing it makes the rule honest: the rule does ONE thing
  (seat assignment for isolation), and access is via the root+privdrop
  recipe (production) or the `input` group / a static ACL (dev).
- **Do NOT reopen the proven root+privdrop recipe.** ADR 010 is the
  production access path; ADR 036 closes the digitizer-fd pre-drop
  gap. The uaccess ACL is a dev/manual-run convenience, not a
  production requirement.

This ADR adopts the **annotate** form (keep the line, add a comment
explaining it is dead under NF-020-A and why we keep it annotated
rather than removed): the line is a useful marker for a future
custom-seat logind session (option D) that could make it live again,
and removing it would make the rule shorter but lose the trace of the
trade-off. The comment makes the dead-tag status explicit so it is
not mistaken for a working ACL again.

### D3 — Dev-access alternatives (documented; not reopened)

For a developer running `tbard` bare (non-service, no privdrop) who
needs to open the Touch Bar digitizer without root:

1. **`input` group membership** (the long-standing bench lane). The
   device is group-owned by `input` (`group::rw-`); a user in `input`
   can open it. This is how the bench has worked all along and is the
   default dev path. Drawback: group membership grants access to ALL
   input devices, not just the digitizer.
2. **Static ACL** (`setfacl -m u:<uid>:rw /dev/input/eventN`). Works
   but does not survive a replug/reboot without a udev rule to
   re-apply it. Acceptable for a fixed bench, not for a portable
   setup.
3. **Custom-seat logind session (considered / future alternative).**
   Define `seat-touchbar` as a real logind seat (`loginctl seat
   seat-touchbar`) and attach a session to it with the active user.
   Then the `uaccess` builtin WOULD materialize an ACL for that
   session's user on `seat-touchbar`'s devices. This makes option D
   live. NOT pursued now: it requires logind seat configuration +
   keeping a session active on a seat with no display/keyboard, which
   is fragile and out of scope for the deploy-hardening suite. Listed
   as a considered/future alternative so the trade-off table's option
   D is not lost.

### D4 — packaging/README.md update

Update `packaging/README.md` to document:

- The `uaccess` tag in `69-touchbar-seat.rules` is **dead** under
  NF-020-A (annotated in the rule). The ACL does not materialize
  because `ID_SEAT=seat-touchbar` moves the device off the active
  session's seat, and there is no `seat-touchbar` in logind.
- The production access path is root-start + privdrop (ADR 010 +
  ADR 036): root opens the digitizer fd PRE-DROP, privdrops to
  `nobody`, and the held fd is verified post-drop. The `uaccess` ACL
  is NOT on the production path.
- Dev-access alternatives: `input` group membership (default),
  static ACL (fixed bench), custom-seat logind session (future).

## Alternatives considered

- **Option C (drop the isolation to make uaccess work).** Rejected:
  losing the seat isolation makes the Touch Bar digitizer a
  compositor-visible device — Touch Bar touches move the desktop
  cursor. This breaks the ADR 009 design intent (the Touch Bar is an
  engine-owned input surface) and is a correctness regression.
- **Option D (custom-seat logind session).** Considered / future. It
  would make both goals work, but it requires logind seat + session
  configuration for a seat with no display/keyboard, which is fragile
  and out of scope for the deploy-hardening suite. Listed in D3.
- **Reopen the root+privdrop recipe.** Explicitly NOT done. ADR 010
  is the proven production path; ADR 036 closes the digitizer-fd
  pre-drop gap. The uaccess ACL is a dev convenience, not a
  production requirement.

## Impact list

- `packaging/udev/69-touchbar-seat.rules` — annotate the
  `TAG+="uaccess"` line as dead under NF-020-A (comment explaining
  why; keep the line as a marker for the future custom-seat option).
- `packaging/README.md` — document the dead uaccess tag + the
  production access path (root+privdrop) + the dev-access alternatives.
- `docs/adr/037-seat-uaccess-adjudication.md` — this ADR.
- `CHANGELOG.md` / `devlog.md` — session 021.

## References

- `docs/test-logs/020/udev-migration.log` §H (NF-020-A root cause:
  no `seat-touchbar` in logind; uaccess no-ops)
- `docs/test-logs/020/regression.log` (the missing ACL on event7)
- `docs/adr/009-digitizer-geometry.md` (seat isolation design intent)
- `docs/adr/010-master-acquisition-input.md` (root+privdrop recipe)
- `docs/adr/019-production-service.md` (D2 — pre-drop fd contract)
- `docs/adr/036-digitizer-fd-pre-drop.md` (digitizer fd pre-drop)
- `packaging/udev/69-touchbar-seat.rules` (the rule)
- `packaging/README.md` (the packaging doc)