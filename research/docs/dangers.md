# Dangers — touchbar-engine hardware sessions

A consolidated list of operations that can **wedge, freeze, or destroy
state** on the T1 MacBookPro14,2. Read before any session. Each entry has an
evidence pointer and a safe alternative.

## D1 — USB-reset of the iBridge (`05ac:8600`)

**Risk**: destroys `appletbdrm` internal state; the DRM card vanishes and
cannot be recovered without a reboot. Reported in the prior deploy stack.
**Evidence**: `backup_old/README.md` "Hazards" — "Never USB-reset the
iBridge (`usb.core.Device.reset()`, `usbreset`): destroys appletbdrm state,
needs reboot."
**Do not**: `usbreset 05ac:8600`, `python -c "import usb; usb.core.find(idVendor=0x05ac).reset()"`, or any `IOCTL_USBRESET` on the iBridge fd.
**Instead**: use the Tier 2 config-switch recovery in `docs/recovery.md`
(unbind → Config 1 → Config 2 → rebind), or reboot as last resort.

## D2 — Flipping USB configuration while `appletbdrm` is bound

**Risk**: wedges the device into a bad D-state; the driver holds stale pipes
and subsequent transfers hang.
**Evidence**: `backup_old/README.md` "Hazards" — "Never flip configurations
while appletbdrm is bound: wedges the device (D-state). The suspend hook
unbinds first." See also `docs/prior-art.md` §2 (T1 protocol: "stale bulk
pipes that must be cleared at probe").
**Do not**: write to `/sys/bus/usb/devices/1-3/bConfigurationValue` while
`/sys/bus/usb/drivers/appletbdrm/1-3:2.3` exists.
**Instead**: `echo "1-3:2.3" > /sys/bus/usb/drivers/appletbdrm/unbind` and
wait 1 s before any config flip.

## D3 — ACPI `ASOC.SOCW(1)` and any ACPI method call on the T1

**Risk**: hard-freezes the T1 machine (full lockup, no console, no syslog).
**Evidence**: `docs/prior-art.md` §6 (AJ-dev-i60/t1-touchbar) —
"`skip_acpi_power` parameter: bypasses `ASOC.SOCW(1)` ACPI call that
hard-freezes T1 Macs"; `lineage-research.md:150,186`.
**Do not**: use `acpi_call`, `/proc/acpi/acpi_call`, `acpid` rules that
evaluate `\_SB_.ASOC.SOCW`, or any userspace ACPI eval on this hardware.
**Instead**: the daemon and scripts use only DRM/libinput/sysfs/libusb. The
current build has **no ACPI calls** (verified by `grep`, see
`docs/review-report.md` §2.4). Keep it that way.

## D4 — DRM master contention on the laptop eDP panel (`card1`, i915)

**Risk**: taking DRM master on `card1` during discovery can black-blink or
steal scanout from a running compositor (Weston/GNOME/X). On a headless TTY
this is harmless.
**Evidence**: `docs/review-report.md` §2.2 Defect A —
`src/providers/mod.rs:146` `card.acquire_master_lock()` is called on every
probed card, including `card1` (i915).
**Do not**: run the daemon under a live GUI session until the discovery code
is fixed to skip non-geometry-matched cards before acquiring master.
**Instead**: run Stage 3+ from a text TTY (`Ctrl-Alt-F2`) with no compositor
running, or after the fix is made on a branch.

## D5 — No clean shutdown / no SIGTERM handler (current build)

**Risk**: `kill -TERM` does not exit the daemon (the `loop {}` in
`real_main` has no exit condition). `kill -9` works but leaves DRM master
held until the OS reaps the fd, and the framebuffer/dumb-buffer are not
destroyed in order (`DrmProvider` has no `impl Drop`).
**Evidence**: `docs/review-report.md` §2.3 — `src/main.rs:165-323` infinite
loop; §2.5 — no `impl Drop` for `DrmProvider`.
**Do not**: rely on graceful shutdown in this build.
**Instead**: after `kill -TERM`, wait 5 s, then `kill -9` if needed, then
verify `/dev/dri/card0` is still usable. If DRM state is suspect, Tier 2
or Tier 3 of `docs/recovery.md`.

## D6 — Backlight silent-write failure / startup panic

**Risk**: the daemon may believe it set the backlight while the hardware
stayed dark, or may `panic!` at startup if the sysfs brightness file is
unreadable.
**Evidence**: `docs/review-report.md` §2.6 —
`src/providers/backlight.rs:30` panics on missing sysfs file; `:55-63`
silently discards write errors.
**Do not**: assume the bar is lit because the daemon is running.
**Instead**: after starting the daemon, independently verify with
`cat /sys/class/backlight/appletb_backlight/brightness` that the value is
non-zero; if the bar is dark, set it manually (Tier 1 of `docs/recovery.md`).

## D7 — Idle timeout drives the bar to 0 (dark) after 60 s

**Risk**: by design, `SysfsBacklight::update` sets brightness to `0` after
`BRIGHTNESS_OFF_TIMEOUT_MS = 60_000` ms of inactivity. This is a power
feature, not a bug, but it conflicts with a "never dark" expectation and
can be confused with a failure during long observation.
**Evidence**: `src/providers/backlight.rs:14,100-104`.
**Mitigation**: touch the trackpad / press a key within 60 s to reset the
idle timer, or set `adaptive_brightness: false` and a high
`active_brightness` in the config, or (post-fix) disable the off-timeout.

## D8 — S3 suspend / resume can drop the iBridge

**Risk**: on resume, the kernel may reset the T1; the DRM card vanishes and
the daemon (if running) hits flush errors. The prior stack has a suspend
hook that unbinds + flips configs + restarts the daemon.
**Evidence**: `backup_old/systemd/touchbar-suspend-hook` (v7) and
`backup_old/README.md` "S3 recovery".
**Do not**: suspend the machine mid-session and expect the daemon to keep
working unaided.
**Instead**: before any planned suspend, stop the daemon (Tier 0). After
resume, re-run Stage 0 capture before resuming any active stage. The
suspend hook from `backup_old/` may be installed **between** sessions, not
during a frozen one.

## D9 — `appletbdrm` flush-stall storm on T1

**Risk**: the T1 DRM protocol has a one-behind ACK and stale-pipe
behaviour; under stress the driver can stall and the userspace backoff
(currently unbounded in stall count) can spin in 32 s sleeps.
**Evidence**: `docs/prior-art.md` §5 (three dialect deviations);
`docs/review-report.md` §2.3 — `record_flush_duration` caps per-flush
cooldown at 32 s but does not cap the number of stalls.
**Do not**: let a stall storm run indefinitely.
**Instead**: if ≥ 10 stall warnings appear in 60 s, abort the stage and
follow `docs/recovery.md` Tier 0 → Tier 2.

## D10 — Editing code during a session (FREEZE RULE violation)

**Risk**: invalidates all evidence, makes root-cause analysis impossible,
and can leave the device in a half-patched state.
**Evidence**: the role's GROUND RULES §1.
**Do not**: `cargo build`, `edit`, `vim`, `git commit`, or any source
change while a session is in progress.
**Instead**: log the finding, stop the session, write an ADR, fix on a
branch, re-review, then resume.

---

# HOST SAFETY RULES

The **FREEZE RULE** (D10) protects the *repo* — it forbids source edits
during a session so evidence stays valid. The rules below protect the
*machine* — they forbid operations that can break the dev machine's
login or compositor regardless of repo state. They were added after the
2026-09-26 bench-lane incident (a diagnostics session staged an
`AQ_DRM_DEVICES` filter via the login chain and broke graphical login;
see `docs/test-logs/010-bench-incident/`).

## D — No login-chain or compositor-config modification on the dev machine

**Risk**: modifying the login chain or compositor configuration on the
dev machine can break graphical login. The 2026-09-26 incident proved
this: an `AQ_DRM_DEVICES` filter staged via `~/.profile`,
`~/.config/environment.d/`, and `~/.config/uwsm/env-hyprland` caused
Hyprland/aquamarine to ABRT (signal 6) at backend init on three
consecutive login attempts, forcing a reboot from the greeter. The prior
session's risk note claimed "worst case: harmless env var" — **refuted**.

**Scope** (treat any of these as login-breaking until proven otherwise):
compositor config (`~/.config/hypr/hyprland.lua`, `hyprland.conf`, any
`hl.env`/`env =` line), greetd config (`/etc/greetd/`, the greeter
command), `~/.profile`, `~/.config/environment.d/`, session/systemd
units (`*.service`, `*.target` in the login/graphical chain), PAM stack,
and any wrapper script in the login chain (e.g. `start-hyprland`).

**Do not**: stage, apply, or "quickly verify" any change to the above on
the dev machine, *even if a prior session's risk note calls it
harmless*. A "just an env var" change is not harmless — it reaches the
compositor at backend init and can abort it.

**Instead**: any change to the login chain or compositor config must
have (a) a **pre-tested revert** (a verified, documented sequence that
restores the prior state without relying on graphical login — e.g. a
text-VT command sequence tested beforehand) AND (b) be **first tested on
a disposable environment** (a VM or a spare machine), not the dev
machine. If neither is available, the change is not made. The unprivileged
granted-bench lane is CLOSED on this machine; the sudo prebuilt-binary
path (ADR-010) is the official bench and requires no login-chain edits.

## D — Machine-state claims require machine-state evidence

**Risk**: a "risk-harmless" or "package installed" or "config applied"
claim that is not backed by machine-state evidence can mislead the next
session into applying a dangerous change. The 2026-09-26 incident was
preceded by a risk note ("worst case: harmless env var") that was not
supported by evidence and was refuted by the breakage. Separately, a
research doc claimed "uwsm 0.27.0-1 installed" which `pacman -Q uwsm`
refutes (uwsm is not installed on this machine).

**Rule**: machine-state claims — "package X is installed", "config Y is
applied", "the compositor reads file Z", "this change is risk-harmless",
"the var reaches process P" — require **machine-state evidence** (the
actual `pacman -Q` / `ls` / `cat` / `/proc/.../environ` / debugfs
output, captured verbatim and cited). Risk notes are themselves claims
and require evidence like any other. A claim with no evidence is marked
UNVERIFIED, not asserted as harmless.

**Instead**: before any change that touches the login chain or
compositor, capture the current machine state verbatim
(`pacman -Q <pkg>`, `ls -la <path>`, `cat <config>`,
`/proc/$(pidof Hyprland)/environ`, `sudo cat /sys/kernel/debug/dri/N/
clients`) into `docs/test-logs/NNN/` and cite it. If the evidence
contradicts the claim, the claim is dropped, not the evidence.