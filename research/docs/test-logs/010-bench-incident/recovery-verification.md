# Recovery Verification — Bench-Lane Incident (2026-09-26)

Read-only capture session. Captured verbatim from the running machine on
2026-09-26 after the user removed the two staged login-chain files
(`~/.profile` and `~/.config/environment.d/aq-devices.conf`) that broke
graphical login. This file is DATA; it records the closed-lane baseline.

The third staged file `~/.config/uwsm/env-hyprland` was **not** removed by
the user and still contains the `AQ_DRM_DEVICES` export (see §1.3). It is
**inert on this machine** because `uwsm` is not installed
(`pacman -Q uwsm` → "package not found") and the login path is
greetd → cosmic-greeter → Hyprland (no uwsm in the chain). It is noted
here as a harmless cleanup candidate; per the session rules it was NOT
deleted.

---

## 1. Login-chain baseline

### 1.1 `ls -la ~/.profile ~/.config/environment.d/`

```
ls: cannot access '/home/emzmo/.profile': No such file or directory
/home/emzmo/.config/environment.d/:
total 8
drwxr-xr-x  2 emzmo emzmo 4096 Sep 26 09:23 .
drwxr-xr-x 35 emzmo emzmo 4096 Sep 26 08:58 ..
```

`~/.profile` is absent (removed by the user — restored login).
`~/.config/environment.d/` exists but is **empty** (the staged
`aq-devices.conf` was removed by the user — restored login).

### 1.2 Inert orphan `~/.config/uwsm/env-hyprland`

```
$ ls -la ~/.config/uwsm/env-hyprland
-rw-r--r-- 1 emzmo emzmo 61 Sep 26 08:49 /home/emzmo/.config/uwsm/env-hyprland

$ cat ~/.config/uwsm/env-hyprland
export AQ_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card
```

This file was staged by the prior diagnostics session and **was not
removed by the user**. It is the third login-chain file from that session
(in addition to `~/.profile` and `~/.config/environment.d/aq-devices.conf`).
It is **inert on this machine** because:

```
$ pacman -Q uwsm
error: package 'uwsm' was not found
```

uwsm is not installed, so nothing sources `~/.config/uwsm/env-hyprland`.
The active login chain is greetd → cosmic-greeter (cosmic-comp) → Hyprland
(journal boot 0, §3). The Hyprland environ confirms no `AQ_` var reached
the compositor (§2.3).

**Status**: harmless cleanup candidate. **NOT deleted** per session rules
(read-only; the user decides). Its presence does not affect login because
nothing reads it.

### 1.3 Package versions (context for the inert-ness)

```
$ pacman -Q uwsm        → error: package 'uwsm' was not found
$ pacman -Q aquamarine  → aquamarine 0.15.1-1
$ pacman -Q hyprland    → hyprland 0.56.2-3
```

The research doc `docs/research/hyprland-aq-devices.md` §3 claims
"this bench runs Hyprland under uwsm (`uwsm 0.27.0-1` on Arch `extra`)".
That claim is **REFUTED** by `pacman -Q uwsm` — see the correction entry
appended to that doc this session.

---

## 2. Session health

### 2.1 `hyprctl monitors`

```
Monitor eDP-1 (ID 0):
	2560x1600@60.00100 at 0x0
	description: Apple Computer Inc Color LCD
	make: Apple Computer Inc
	model: Color LCD
	physical size (mm): 290x180
	serial: 
	active workspace: 1 (1)
	special workspace: 0 ()
	reserved: 0 34 0 0
	scale: 1.6
	transform: 0
	focused: yes
	dpmsStatus: 1
	vrr: false
	solitary: 0
	solitaryBlockedBy: windowed mode,missing candidate
	activelyTearing: false
	tearingBlockedBy: next frame is not torn,user settings,missing candidate
	directScanoutTo: 0
	directScanoutBlockedBy: user settings,missing candidate
	disabled: false
	currentFormat: XRGB8888
	mirrorOf: none
	availableModes: 2560x1600@60.00Hz 
	colorManagementPreset: srgb
	sdrBrightness: 1
	sdrSaturation: 1
	sdrMinLuminance: 0.2
	sdrMaxLuminance: 80
	hardwareCursorsInUse: true

Monitor Virtual-1 (ID 1):
	1024x768@60.00400 at 1600x0
	description: 
	make: 
	model: 
	physical size (mm): 0x0
	serial: 
	active workspace: 2 (2)
	special workspace: 0 ()
	reserved: 0 34 0 0
	scale: 2
	transform: 0
	focused: no
	dpmsStatus: 1
	vrr: false
	solitary: 0
	solitaryBlockedBy: windowed mode,missing candidate
	activelyTearing: false
	tearingBlockedBy: next frame is not torn,user settings,missing candidate
	directScanoutTo: 0
	directScanoutBlockedBy: user settings,missing candidate
	disabled: false
	currentFormat: XRGB8888
	mirrorOf: none
	availableModes: 1024x768@60.00Hz 4096x2160@60.00Hz 4096x2160@59.94Hz 2560x1600@59.99Hz 2560x1600@59.97Hz 1920x1440@60.00Hz 1856x1392@59.99Hz 1792x1344@60.00Hz 2048x1152@60.00Hz 1920x1200@59.88Hz 1920x1200@59.95Hz 1920x1080@60.00Hz 1600x1200@60.00Hz 1680x1050@59.95Hz 1680x1050@59.88Hz 1400x1050@59.98Hz 1400x1050@59.95Hz 1600x900@60.00Hz 1280x1024@60.02Hz 1440x900@59.89Hz 1440x900@59.90Hz 1280x960@60.00Hz 1366x768@59.79Hz 1366x768@60.00Hz 1360x768@60.02Hz 1280x800@59.81Hz 1280x800@59.91Hz 1280x768@59.87Hz 1280x768@59.99Hz 1280x720@60.00Hz 800x600@60.32Hz 800x600@56.25Hz 848x480@60.00Hz 640x480@59.94Hz 
	colorManagementPreset: srgb
	sdrBrightness: 1
	sdrSaturation: 1
	sdrMinLuminance: 0.2
	sdrMaxLuminance: 80
	hardwareCursorsInUse: true
```

eDP-1 (the i915 eDP panel) is **present, focused, 2560×1600@60, dpms on** —
graphical session is healthy. Virtual-1 is the vkms output (1024×768).

### 2.2 `loginctl list-sessions`

```
SESSION  UID USER  SEAT  LEADER CLASS   TTY  IDLE SINCE
      7 1000 emzmo seat0 1591   user    tty1 no   -
      8 1000 emzmo -     1653   manager -    no   -

2 sessions listed.
```

Session 7 detail (`loginctl show-session 7`, abridged):

```
Id=7
User=1000
Name=emzmo
Timestamp=Sat 2026-09-26 09:37:41 WEST
VTNr=1
Seat=seat0
TTY=tty1
Service=login            # PAM service name used by greetd (config: service: "login")
Desktop=Hyprland
Type=wayland
Class=user
Active=yes
State=active
```

Session 8 is the systemd user manager (`Class=manager`, `Service=systemd-user`).

### 2.3 Hyprland process environ — `AQ_` check (expect empty)

```
$ sudo cat /proc/$(pidof Hyprland)/environ | tr '\0' '\n' | grep -i AQ_
(empty — no output)
```

**CONFIRMED empty** — no `AQ_DRM_DEVICES` reached the Hyprland process on
the current boot. This is the expected restored state: the staged env-var
injection is gone from the live compositor, so Hyprland opens all DRM
cards unfiltered (the normal unfiltered state).

---

## 3. Bench baseline — DRM card mapping + vkms clients

### 3.1 `ls -l /sys/class/drm/card*/device/driver` (re-map cardN by driver)

```
lrwxrwxrwx 1 root root 0 Sep 26 09:44 /sys/class/drm/card0/device/driver -> ../../../bus/faux/drivers/faux_driver
lrwxrwxrwx 1 root root 0 Sep 26 09:32 /sys/class/drm/card1/device/driver -> ../../../bus/pci/drivers/i915
lrwxrwxrwx 1 root root 0 Sep 26 09:44 /sys/class/drm/card2/device/driver -> ../../../../../../bus/usb/drivers/appletbdrm
```

Driver-based card mapping on the current boot:

| cardN | driver | what |
|---|---|---|
| card0 | `faux_driver` | **vkms** (the `faux_driver`/vkms platform device) |
| card1 | `i915` | eDP panel (0000:00:02.0) |
| card2 | `appletbdrm` | Touch Bar (1-3:2.3) |

**Card numbers are NOT stable across boots** (boot -2 had card0=appletbdrm,
card1=i915, card2=vkms). The driver-based mapping in
`scripts/bench/verify-granted-bench.sh` is the correct way to locate vkms
— never trust the cardN number. This is the closed-lane baseline mapping.

### 3.2 vkms clients — `sudo cat /sys/kernel/debug/dri/0/clients`

(vkms is minor 0 on this boot — `ls /sys/kernel/debug/dri/` shows
`0 -> vkms`.)

```
             command  tgid dev master a   uid      magic                                                             name                   id
      systemd-logind   476   0   y    y     0          0                                                          <unset>                   43
            Hyprland  1678   0   y    y  1000          0                                                          <unset>                   51
            Hyprland  1678   0   n    n  1000          0                                                          <unset>                   57
```

**Hyprland holds DRM master (`master y`) on the vkms card** (dev 0, tgid
1678). This is the **EXPECTED normal unfiltered state** now that
`AQ_DRM_DEVICES` is no longer applied: Hyprland/aquamarine opens every
DRM card including vkms and takes master on it. This is exactly the
"compositor holds master" condition that makes the unprivileged
`setMaster` EACCES — i.e. the bench is **NOT granted**, by design, on
this closed lane.

This is the **closed-lane baseline**, not a problem. The unprivileged
granted-bench lane is CLOSED on this machine; the sudo prebuilt-binary
path (ADR-010) is the official bench for seat-gated tests. No further
attempt to clear Hyprland off vkms will be made on this machine.

### 3.3 i915 clients — `sudo cat /sys/kernel/debug/dri/1/clients` (context)

```
             command  tgid dev master a   uid      magic                                                             name                   id
            Hyprland  1678 128   n    n  1000          0                                                          <unset>                   44
      systemd-logind   476   1   y    y     0          0                                                          <unset>                   45
            Hyprland  1678 128   n    n  1000          0                                                          <unset>                   46
            Hyprland  1678   1   y    y  1000          0                                                          <unset>                   48
            Hyprland  1678 128   n    n  1000          0                                                          <unset>                   50
            Xwayland  1725 128   n    n  1000          0                                                          <unset>                   55
            Hyprland  1678   1   n    n  1000          0                                                          <unset>                   56
            noctalia  1720 128   n    n  1000          0                                                          <unset>                   58
               kitty  1928 128   n    n  1000          0                                                          <unset>                   59
               kitty  2066 128   n    n  1000          0                                                          <unset>                   60
             python3  2048 128   n    n  1000          0                                                          <unset>                   61
             python3  2048 128   n    n  1000          0                                                          <unset>                   62
```

Hyprland is master on the i915 (dev 1) as expected; Xwayland, noctalia,
kitty, and python3 hold render-node (dev 128) fds. Normal healthy
graphical session.

---

## 4. Login-manager state (context for §1.2)

```
$ systemctl is-enabled greetd            → disabled
$ systemctl is-enabled cosmic-greeter    → enabled
$ systemctl is-enabled getty@tty1        → enabled
$ systemctl is-enabled display-manager   → alias
```

`display-manager.service` is an alias; `greetd.service` is **disabled** as
a standalone unit but is pulled in transitively by cosmic-greeter
(journal boot 0 shows greetd running as the greeter daemon under
cosmic-greeter). The active chain on boot 0 was:

```
greetd (vt 1, service "login") → cosmic-greeter-start → cosmic-comp (greeter)
  → [user auth] → greetd launches Hyprland (PAM service "login", Desktop=Hyprland, Type=wayland)
```

No `uwsm` anywhere in the chain — confirming the
`~/.config/uwsm/env-hyprland` file is inert.