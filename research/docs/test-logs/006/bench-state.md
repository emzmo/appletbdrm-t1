# Bench-state capture — Session 006 (feeds ADR-016)

Captured: 2026-09-25T23:30:01+01:00
Branch: fix/sim-harness-adr-011-015 @ 7f8ab04

## id -u / id
```
uid=1000(emzmo) gid=1000(emzmo) groups=1000(emzmo),963(gamemode),992(input),998(wheel)
```

## Session type (graphical/VT)
```
XDG_SESSION_TYPE=wayland
XDG_SESSION_CLASS=
XDG_SESSION_ID=3
XDG_SEAT=seat0
WAYLAND_DISPLAY=wayland-1
DISPLAY=:1
```

## loginctl session-status 3
```
3 - emzmo (1000)
  Since: Fri 2026-09-25 08:05:37 WEST; 15h ago
  State: active
 Leader: 660 (greetd)
   Seat: seat0; vc1
    TTY: tty1
 Remote: no
Service: login
   Type: wayland
  Class: user
Desktop: Hyprland
   Idle: no
   Unit: session-3.scope
         ├─  660 /usr/bin/greetd --session-worker 12
         ├─  729 /usr/bin/start-hyprland
         ├─  746 Hyprland --watchdog-fd 4
         ├─  785 noctalia
         ├─  790 Xwayland :1 -rootless -core -listenfd 56 -listenfd 57 -displayfd 103 -wm 100
         ├─ 1009 kitty
         ├─ 1041 /usr/bin/kitten __atexit__
         ├─ 2008 kitty
         ├─ 2014 /usr/bin/kitten __atexit__
         ├─14218 /usr/lib/firefox/firefox
         ├─14223 /usr/lib/firefox/crashhelper 14218 9 /tmp/ 11 20260915231823
         ├─14297 /usr/lib/firefox/firefox -contentproc -ipcHandle 0 -signalPipe 1 -initialChannelId {ac110430-5e15-4246-aa20-b2120734ccd3} -parentPid 14218 -greomni /usr/lib/firefox/omni.ja -appomni /usr/lib/firefox/browser/omni.ja -appDir /usr/lib/firefox/browser 1 forkserver
```

## sudo fuser -v /dev/dri/card0 card1 card2
```
                     USER        PID ACCESS COMMAND
/dev/dri/card0:      nobody      562 F.... tiny-dfr-mbp142
/dev/dri/card1:      root          1 F.... systemd
                     root        497 F.... systemd-logind
                     emzmo       746 F.... Hyprland
                     emzmo       790 F.... Xwayland
/dev/dri/card2:      root          1 F.... systemd
                     root        497 F.... systemd-logind
                     emzmo       746 F.... Hyprland
```

## AQ_DRM_DEVICES applied in hyprland.conf?
```
grep_exit=1 (1/2 = NOT set; 0 = set, shown above)
AQ_DRM_DEVICES in shell env = <unset>
Hyprland PID 746 environ AQ_DRM/WLR_DRM:
  (none)
```

## Kernel version
```
7.2.6-arch2-1
Linux phobos 7.2.6-arch2-1 #1 SMP PREEMPT_DYNAMIC Mon, 14 Sep 2026 22:41:30 +0000 x86_64 GNU/Linux
```
