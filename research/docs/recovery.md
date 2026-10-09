# Recovery Procedure — touchbar-engine hardware sessions

**Use when**: an abort criterion trips, the daemon panics, the Touch Bar
behaves unexpectedly, or the laptop panel is disturbed during a session.
**Golden rule**: capture first, stop second, **never patch on the air**
(FREEZE RULE). Recovery is about making the machine safe, not fixing code.

## Tier 0 — Stop the daemon (always first)

```bash
# Find the daemon
pgrep -af tbard
# Graceful stop (current build has no SIGTERM handler, so this may not exit)
kill -TERM <pid>
# Wait 5 s; if still alive, force
sleep 5; pgrep tbard && kill -9 <pid>
```

If the daemon was started under systemd (ADR 019 `tbard.service`):
```bash
sudo systemctl stop tbard.service
sudo systemctl status tbard.service --no-pager | tee docs/test-logs/NNN/recovery-status.log
```
If you need to restart it after recovering:
```bash
sudo systemctl start tbard.service
```
**Mutual exclusion (ADR 019 D5)**: `tbard.service` and the oracle
`tiny-dfr-mbp142.service` are mutually exclusive — exactly one may own
the Touch Bar DRM card. If you stop ours to recover, re-enable + start
the oracle to restore the lit bar:
```bash
sudo systemctl enable --now tiny-dfr-mbp142.service
```
The preflight tool (`scripts/bench/interlock-preflight.sh`) checks the
oracle's status as part of its GO/NO-GO verdict before starting ours.

After stopping, verify the Touch Bar is not left in a wedged state:
```bash
ls /sys/class/drm/card0-*/status   # should still read "connected"
cat /sys/bus/usb/devices/1-3/bConfigurationValue  # should still be 2
```

## Tier 1 — Backlight to a known-safe visible state

If the bar is dark and you want it visible for diagnostics (fail-safe ON):
```bash
# Discover the max
cat /sys/class/backlight/appletb_backlight/max_brightness
# Set to a mid value so the bar is visibly ON
echo 128 | sudo tee /sys/class/backlight/appletb_backlight/brightness
```
Do **not** write `0` unless you intend the bar to be dark.

## Tier 2 — Restore USB config / touchbar-activate

If `bConfigurationValue` reads `1` (the iBridge dropped out of Config 2)
or `/dev/dri/card0` disappeared:

> ⚠️ **Never flip configurations while `appletbdrm` is bound** — it wedges
> the device (D-state). See `docs/dangers.md`. Always unbind first.

```bash
IB=/sys/bus/usb/devices/1-3

# 1. Stop the daemon (Tier 0) and unbind the DRM driver
echo "1-3:2.3" | sudo tee /sys/bus/usb/drivers/appletbdrm/unbind 2>/dev/null
sleep 1

# 2. Drop to Config 1, then back to Config 2
echo 0 | sudo tee $IB/bConfigurationValue
sleep 2
echo 2 | sudo tee $IB/bConfigurationValue
sleep 3

# 3. Re-bind if the driver did not auto-attach
ls /sys/bus/usb/drivers/appletbdrm/1-3:2.3 2>/dev/null || \
  echo "1-3:2.3" | sudo tee /sys/bus/usb/drivers/appletbdrm/bind 2>/dev/null

# 4. Verify
cat $IB/bConfigurationValue          # expect 2
ls /dev/dri/card*                    # expect card0 to be back
cat /sys/class/drm/card0-*/status    # expect connected
```

If the macOS wake sequence replay (`touchbar-activate`) is needed because the
T1 is in a cold state that Config 2 alone does not recover, use the script in
`backup_old/systemd/` only **between** sessions (not during a frozen
session). Document the invocation in the devlog.

## Tier 3 — Unload modules (only if the DRM/USB stack is wedged)

```bash
sudo systemctl stop tbard.service 2>/dev/null
sudo systemctl stop tiny-dfr-mbp142.service 2>/dev/null
sudo modprobe -r appletbdrm
sudo modprobe -r hid_multitouch          # only if it was loaded for the Touch Bar
# Do NOT unload applespi (that takes the keyboard/trackpad down)
# Re-load
sudo modprobe appletbdrm
sudo modprobe hid_multitouch
```

Verify `lsmod | grep appletbdrm` and `ls /dev/dri/card0` afterwards.

## Tier 4 — Reboot (last resort)

Use only if Tiers 0–3 did not recover the device **and** the Touch Bar is
unresponsive or the laptop panel is wedged. A reboot will re-run the
sysinit stack (`ibridge-switcher` / `touchbar-t1-setup`) and re-probe.

```bash
sudo systemctl reboot
```

After reboot, re-run Stage 0 environment capture before any further stage.

## What recovery must NEVER do

- ❌ Do not run `usbreset` on the iBridge (`05ac:8600`) — destroys
  `appletbdrm` state, forces a reboot. (See `backup_old/README.md` "Hazards"
  and `docs/dangers.md`.)
- ❌ Do not flip `bConfigurationValue` while `appletbdrm` is bound.
- ❌ Do not issue ACPI calls (`ASOC.SOCW(1)`, `/proc/acpi/...`) — T1
  hard-freeze risk. (See `docs/dangers.md`.)
- ❌ Do not edit code during a session.
- ❌ Do not `kill -9` as a first action — try `kill -TERM` first and give
  the kernel 5 s to release DRM master and close fds.

## Evidence to capture before recovering

Whenever you move past Tier 0, capture first:
```bash
SESS=docs/test-logs/NNN
journalctl -b -0 -k --since "10 min ago" | tee $SESS/recovery-journalctl.log
dmesg -T | tail -300 | tee $SESS/recovery-dmesg.log
lsusb -v -d 05ac:8600 2>/dev/null | tee $SESS/recovery-lsusb.log
cat /sys/class/drm/card0-*/status 2>/dev/null | tee $SESS/recovery-drm-status.log
cat /sys/bus/usb/devices/1-3/bConfigurationValue 2>/dev/null | tee $SESS/recovery-usbcfg.log
pgrep -af tbard | tee $SESS/recovery-pgrep.log
```