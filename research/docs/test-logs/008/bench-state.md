# Bench state — session 008 (re-verification)

Date: 2026-09-26T00:58+01:00
Operator/QA: uid=$(id -u)

## Session
- `id -u`: 1000 (emzmo)
- `loginctl session-status 3`: Type=wayland, State=active, Seat=seat0, TTY=tty1
- Hyprland PID 749 is the display server (greetd leader 664)

## DRM cards
- `/dev/dri/card0`: USB (iBridge T1) — TAGS :uaccess:master-of-seat:systemd:seat:
- `/dev/dri/card1`: i915 (iGPU) — TAGS :uaccess:master-of-seat:seat:
- `/dev/dri/card2`: vkms (loaded this session via `sudo modprobe vkms`) — TAGS :seat:uaccess:master-of-seat:

## card2 ACL
`getfacl /dev/dri/card2`:
  user::rw-, user:emzmo:rw-, group::rw- (video), mask::rw-, other::---

## Master holders on card2 (sudo ls /proc/*/fd)
- PID 1 (systemd), PID 501 (systemd-logind), PID 749 (Hyprland)

## Result
- The active seat0 ACL is present (ADR-016 path), BUT Hyprland holds
  card2 master. A dry-run `tbard --dry-run` acquire EACCESes as uid 1000
  and EBUSYes under sudo (master already held).
- This is the ADR-016 bench-change caveat: "if Hyprland holds card2
  without releasing, the unprivileged path EACCESes." Hyprland cannot be
  restarted from inside this Wayland session.
- `AQ_DRM_DEVICES` is unset, so Hyprland attaches to all DRM cards
  including card2.
