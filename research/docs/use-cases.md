the platform's shape is now fixed (pages, widgets, IPC, providers), so the possibility space can be mapped precisely rather than as marketing daydreams. The hardware gives us four primitives, and everything below is a combination of them:

Primitive	Source on this machine	Constraint reality
Paint anything	2170×60 DRM canvas (appletbdrm)	60 px tall — one row, no nesting; animations must be modest
Read touches	HID multitouch digitizer, absolute coords, slot tracking	Tap / long-press / drag / multi-finger swipe; no hover, no pressure reported
Control light	appletb_backlight (deterministic selection per ADR-015)	OLED-ish panel — static UI needs burn-in care (pixel-shift is already in your code via enable_pixel_shift!)
Inject keys	/dev/uinput — the oracle already proves Esc/Fn injection	Your renderer is the Esc key; reliability is a UX feature
Tier 1 — Widget/UX possibilities (all fit the engine's existing widget catalog)
Controls: buttons, toggles, horizontal sliders and dials (the strip is a 1-D world — drag-based rotary dials are the natural "knob"), multi-state keys (Fn/media/compact/page modes like macOS had).
System monitors: CPU/GPU/battery/fan as dials, gauges, or sparkline tickers — your fork already has CPU/GPU/battery widgets; the engine generalizes them.
Timers & focus: pomodoro countdown, world-clock ticker, meeting-remaining indicator.
Macro pad: the Stream Deck pitch — per-page button sets for specific apps (IDE, OBS, DAW, docker/k8s quick actions).
Macro input: mini keyboard pages (emoji picker, clipboard history selector, symbol pad).
Tier 2 — Desktop integration (the IPC clients from Phase 3)
This is where the platform stops being "pretty strip" and becomes ambient hardware:

Hyprland: your compositor exposes an event socket — workspace indicators with tap-to-switch, window-title marquee, scratchpad toggle, layout switcher. On this exact machine, that's a 1:1 fit.
Media: MPRIS listener → auto-switch to a media page on play (roadmap item), lyrics sync (already in your fork's lineage), volume slider.
Notifications: hook mako/dunst → transient toasts on the bar (respecting dim/idle policy).
Dev status: git branch/CI status tickers, build watcher (green/red page), test-runner quick actions.
Password managers: Bitwarden/gopass CLI clients → TOTP countdown widget, "lock vault" button.
Anything with a CLI or socket — the whole point of proto/protocol.md: third parties push widgets without touching kernel code. That's the ecosystem pitch.
Tier 3 — Possibilities unique to this hardware lineage
Auto-brightness from the T1's ALS: per your prior-art.md, the iBridge device includes an ambient-light-sensor HID function (0xff12) in config 2. If it's exposed on your stack (investigate — the ALS driver lineage exists but isn't confirmed in the Seborider bundle), the bar becomes the only display on the machine that dims with real ambient light.
Touch ID lane: t1bridge (0xBOYD, [REPORTED] in prior-art.md) talks to the T1 Secure Enclave over CDC-NCM. Your engine could serve as its UI layer — enrollment prompts, fingerprint-glow feedback on the bar — without owning any of the security plumbing.
Trusted-input path (use with honesty): touches arrive via a path outside the compositor. A PIN/TOTP prompt rendered on the bar is not readable by screen capture of the desktop session — but be precise in any README claim: the daemon is not a TEE, it's a separate attack surface, not a cryptographic boundary.
Focus mode: because you own rendering, you can offer what macOS never did — a page that is just Esc + Fn when you want the machine quiet, or a full "dark + wake on touch" policy (your idle/backlight providers already give you the machinery).
Tier 4 — The web mirror force-multiplies everything
The Phase-3 mirror means every one of the above is also usable from any browser: the bar becomes a Stream Deck you can click with the mouse on the desktop, a remote control from your phone, an accessibility input surface, and — not trivially — a GUI designer with drag-drop page building. No other Touch Bar project (MTMR/BetterTouchTool lineage on macOS included) offers the "bar as service with a web API" model.

The honest no-list
No hover states, no 2-D layouts, no video that you'd actually enjoy (60 px), no per-key haptics (none exist), no simultaneous renderer coexistence (single-writer — your own docs/dangers.md), and pinch-zoom is pointless on a strip. Anything requiring sub-100 ms continuous animation needs the stall-workaround discipline your fork already carries for T2.

Suggested hero set for the GitHub launch
Four screenshots sell the whole thesis: (1) workspace switcher bound to Hyprland, (2) auto-switching media page with lyrics, (3) a macro-pad page, (4) the web mirror clicking that same page from a phone. One "possibilities" doc (docs/use-cases.md) written from this list gives contributors a menu to build against — and the widget/plugin API means they never need to touch DRM, uinput, or your hard-won privilege model to add the next one.
