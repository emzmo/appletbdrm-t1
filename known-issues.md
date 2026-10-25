# Known Issues — appletbdrm-t1

Issues are ordered by severity. Each includes a description,
impact assessment, and proposed strategy for v2.

---

## 🔴 High Priority

### 1. DRM card seat assignment race condition

**Description:**
The udev rule uses `GOTO="seat_end"` for the DRM card, which 
is a no-op across separate udev rule files. The DRM card stays 
on `seat0` (the default seat where Hyprland/Sway runs). The 
digitizer is correctly assigned to `seat1`, but the DRM card 
is not.

The current setup works because of timing: the config switch 
script runs early in boot, and the daemon grabs the DRM card 
before Hyprland fully initializes. But this is a race 
condition, not a deterministic isolation.

We attempted to assign the DRM card to `seat1` explicitly, 
but this crashes the SDDM login greeter on systemd 262.1 due to 
a `io.systemd.Login.CreateSession InvalidParameter` bug. The 
GOTO no-op approach was chosen as a workaround that doesn't 
crash the boot.

**Impact:**
If a compositor (Hyprland, Sway, KDE Wayland) initializes faster 
than the daemon on some hardware or config, it will take DRM 
master on `/dev/dri/card0` and the Touch Bar daemon will fail 
to render. This is intermittent and hardware/config dependent.

**Strategy for v2:**
- Assign the DRM card explicitly to `seat1` in the udev rule 
  (same as the digitizer).
- This cannot be applied on a running system (the T1 chip 
  crashes if USB config is re-negotiated while the DRM driver 
  is bound — documented as risk D2 in the project).
- Safe deployment paths:
  a) Fresh installs: the PKGBUILD installs the rule before 
     first boot — no race possible.
  b) Existing installs: user must edit the rule, reboot, 
     and if the first boot fails, reboot again (the T1 
     enumerates differently after a clean cold boot).
- Document the risk clearly in INSTALL.md.
- Track the systemd 262.1 CreateSession bug upstream; if 
  fixed in a future systemd release, revisit the seat1 
  assignment.

---

### 2. Dead code: async URB path for T1

**Description:**
The driver has two probe paths:
- T1: async URB submission (original code, never worked)
- T1: sync probe (our fix, works)

We patched the probe to use sync for T1, but the async URB 
code path still exists in the source. It is dead code that 
will never execute for T1 but remains readable.

**Impact:**
No runtime impact (the code never runs for T1). But anyone 
reading the driver source will be confused: they see an 
async path and a sync path, and won't know which one is 
active. Maintenance burden: if the async code references 
kernel APIs that change, the compiler will require updates 
to code that never runs.

**Strategy for v2:**
- Remove or `#ifdef` out the async URB path for T1.
- Keep it for T2 (where async may still be relevant).
- Or eliminate it entirely if T2 also uses sync probe 
  (needs testing — see issue #6).

---

### 3. Preamble drain necessity unverified

**Description:**
Fix 1 (16-byte preamble drain in `read_response`) was 
applied but the probe succeeded WITHOUT it ever activating. 
The probe passed on the first `GINF` read with 
`actual_size == size`, meaning no preamble was present.

Hypothesis: `usb_clear_halt()` (Fix 3) drained stale data 
from the pipes, including any pending preamble. Or: the T1 
only sends preambles during sustained rendering, not during 
the initial probe sequence.

**Impact:**
No runtime impact (the drain loop is harmless if never 
triggered). But we don't know if preambles appear later 
during `flush_damage` (frame rendering). If they do and the 
drain loop has a bug, rendering could fail silently.

**Strategy for v2:**
- Add a conditional log (behind a debug flag) in the drain 
  loop that fires if the drain ever activates.
- After 100 sessions without activation, consider removing 
  the drain for the probe path (keep it for flush_damage 
  where it may still be needed).
- Do NOT remove until confirmed unnecessary.

---

### 4. Hardcoded USB device path

> **Status: RESOLVED** — The current `ibridge-config-switch.sh` 
> uses dynamic discovery by VID:PID (`05ac:8600`), not a 
> hardcoded path. This issue is documented for historical 
> context and to prevent regression.

**Description:**
An earlier version of `ibridge-config-switch.sh` wrote to a 
hardcoded sysfs path:
```
/sys/bus/usb/devices/1-3/bConfigurationValue
```

The `1-3` path is the USB topology on a specific machine 
(MBP14,2). On another MacBook, the iBridge chip may enumerate 
at a different USB port (e.g. `1-4`, `2-1`).

The current script resolves this dynamically:
```bash
for dev in /sys/bus/usb/devices/*/idVendor; do
    if [ "$(cat "$dev" 2>/dev/null)" = "05ac" ] && \
       [ "$(cat "$(dirname "$dev")/idProduct" 2>/dev/null)" = "8600" ]; then
        BRIDGE="$(dirname "$dev")"
        break
    fi
done
```

**Impact:**
Resolved — no longer applies. The dynamic discovery survives 
USB bus renumbering across reboots and different hardware.

**Strategy for v2:**
- Keep the dynamic discovery approach.
- Add a fallback: if the iBridge is not found, log clearly 
  and exit with non-zero (already implemented).
- Consider adding a retry loop in case the device appears 
  late during boot (see issue #5).

---

## 🟡 Medium Priority

### 5. No error recovery in config switch script

**Description:**
The config switch script waits 25 seconds for the DRM card
to appear. If it doesn't, it exits with `exit 1` and gives
up. No retry, no fallback.

**Impact:**
On a slow cold boot (disk I/O heavy, low temperature,
peripheral init delay), the T1 might take more than 25s
to fully enumerate. The user gets no Touch Bar until the
next reboot, with no indication of what happened.

**Strategy for v2:**

- Implement retry with exponential backoff: 25s, 50s, 100s.
- Or: don't fail the service, just log a warning and let
  the daemon retry on its own (the daemon already has
  `Restart=always`).
- At minimum: log the failure to journald with a clear
  message, not just a silent `exit 1`.

### 6. T2 support unverified

**Description:**
The driver has `mac_type` guards (`MAC_TYPE_T1` vs
`MAC_TYPE_T2`) throughout. The T1 fixes (preamble drain,
one-behind ACK, stale pipe clearing) are gated on
`mac_type == MAC_TYPE_T1`. The T2 path assumes no
preamble and direct ACK.

But no T2 machine has ever been tested with this driver.
The T2 code path is theoretical.

**Impact:**
If a T2 user installs this package, it might work, might
crash, or might have subtle rendering bugs. We don't know.

**Strategy for v2:**

- Find a T2 MacBook owner in the community to test.
- Or: add a clear warning in the README that T2 is
  untested.
- If T2 testing reveals issues, gate the T2 path the same
  way we gated T1 (with conditionals).

### 7. No automated tests

**Description:**
There are no tests. Every change is verified manually by
rebooting and checking dmesg, sysfs, and the Touch Bar
display. There's no way to verify a change doesn't break
something without a full reboot cycle.

**Impact:**
Regression risk: a future change to the driver could break
probe, or rendering, or touch input, and the developer
won't know until a user reports it.

**Strategy for v2:**

- Add a basic test script (`test.sh`) that verifies:
  - The module compiles (`make modules`)
  - The probe passes (`dmesg | grep "Touch Bar initialized"`)
  - The DRM card exists (`ls /sys/class/drm/card*/device/driver`)
  - The backlight responds (`echo 128 > .../brightness && cat .../brightness`)
  - The sysfs nodes exist
- This doesn't need to be CI/CD ready, just a script a
  developer can run after changes.

## 🟢 Low Priority

### 8. Backlight: internal HID vs external patch

**Description:**
We handle T1 backlight internally via HID Feature Reports on
Interface 6. Seborider's approach uses a separate patched
driver (`hid-appletb-bl`) that adds the T1 ID to the
backlight driver table.

Both approaches work. Ours is more self-contained (no
external dependency) but more complex code inside
`appletbdrm.c`.

**Impact:**
No runtime impact. But the internal approach adds code
complexity to the DRM driver that isn't strictly display-
related. If the HID interface handling breaks in a
kernel update, the DRM driver breaks too.

**Strategy for v2:**

- Evaluate: does Seborider's `hid-appletb-bl` patch work
  on our hardware? If yes, we could simplify `appletbdrm.c`
  by removing the internal backlight code and depending
  on the external patch.
- If our approach is more robust (which it may be —
  Seborider's is a separate module that could also race),
  keep it but document why.
- Low priority: if it works, don't touch it.

---

## Summary

| # | Issue | Severity | Effort | v2? |
|---|-------|----------|--------|-----|
| 1 | Seat race condition | High | Low (rule change + docs) | Yes |
| 2 | Dead async code | High | Low (#ifdef or remove) | Yes |
| 3 | Preamble drain unverified | High | Low (add debug log) | Maybe |
| 4 | Hardcoded USB path | High | — | **RESOLVED** |
| 5 | No error recovery | Medium | Low (retry logic) | Yes |
| 6 | T2 unverified | Medium | Low (docs or find tester) | Maybe |
| 7 | No tests | Medium | Medium (script) | Maybe |
| 8 | Backlight approach | Low | High (refactor) | No |

---

*Last updated: 2026-10-25*
*Found during: post-v1 audit before AUR publication*