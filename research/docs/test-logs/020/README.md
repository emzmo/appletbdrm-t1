# Session 020 — v0.2.0 install + udev migration (W2) + unit verify + preflight

Role: installation/packaging session on the dev machine. v0.2.0 artifacts
deployed to the system. HOST SAFETY RULES (docs/dangers.md) binding with
one controlled exception: this session is AUTHORIZED to write /etc and
/usr packaging paths and to run the install — per the human-approved plan.
Still forbidden: service lifecycle, oracle files/unit, compositor/login
config, reboot.

Master HEAD at session start: `f853a65` (`v0.2.0-1-gf853a65`,
`f853a6534087aa8f15324368fa3e0b4a8baaa293`). Working tree clean.

## Files in this directory

- `install-evidence.log`   — every installed file + path + sha256
- `99-touchbar-seat.rules.removed` — verbatim copy of the removed stale rule
- `udev-migration.log`     — udevadm info / getfacl / udevadm test verbatim
- `systemd-analyze-verify.log` — post-install unit verification (exit 0)
- `preflight-no-go.log`    — interlock-preflight.sh output (NO-GO, oracle active)
- `regression.log`         — tbard --service unprivileged fast-fail + dri clients