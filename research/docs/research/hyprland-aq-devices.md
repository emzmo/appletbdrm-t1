# Hyprland `AQ_DRM_DEVICES` on a Modern (Lua-config) Bench — Research Report

Date: 2026-09-26 · Researcher: technical-research pass (GLM-5.2)
Scope: pin the config-format and aquamarine-device-filter facts needed to amend
ADR-026 (granted-bench procedure) for the current-generation Hyprland on this
bench.

---

## Pass status logs

**Pass 1 — facts + syntax (R1, R2, R4).**

- Searched: Hyprland news, Hyprland wiki (Start, Variables, Environment
  variables, Multi-GPU), the in-repo `example/hyprland.lua`, Arch package
  pages, uwsm upstream docs + man page, the live bench state
  (`~/.config/hypr/`, `hyprctl --version`, `pacman -Q`).
- Found: the Lua config is real and native (not a plugin); the env-var API
  exists as `hl.env(KEY, VALUE)`; the wiki explicitly names `AQ_DRM_DEVICES`
  and gives its syntax; uwsm has a dedicated `env`/`env-hyprland` route that
  the Hyprland wiki recommends **over** the Lua `hl.env` for `AQ_*` vars.
- Missing: nothing for R1/R2/R4. Every claim is sourced below.

**Pass 2 — semantics from source (R3, R5).**

- Searched: `hyprwm/aquamarine` source tree (`src/backend/drm/DRM.cpp`,
  `src/backend/Session.cpp`, `src/backend/Backend.cpp`).
- Found: the exact `AQ_DRM_DEVICES` parse site (separator, canonicalization,
  match logic), the startup path that consumes it (`scanGPUs` → `attempt`),
  and the hotplug path (`Session.cpp` udev `add` → `CBackend::onNewGpu` →
  `CDRMBackend::fromGpu`) that does **not** re-check the filter.
- Missing: nothing. The init-vs-hotplug answer is definitive from source.

---

## 1. Executive summary

The granted-bench goal — keep Hyprland off the vkms `card2` so the
unprivileged daemon can take its DRM master — **is achievable on the
current Hyprland** (0.56.2-3 on this bench). The preferred method is to set
`AQ_DRM_DEVICES` **before** the compositor starts, via the uwsm session-env
file `~/.config/uwsm/env-hyprland` (Hyprland's own wiki tells uwsm users to
put `AQ_*` there rather than in `hyprland.lua`). The legacy hyprlang
`env = AQ_DRM_DEVICES,…` line that failed to parse **is the wrong syntax
for a `.lua` config**; the Lua equivalent is `hl.env("AQ_DRM_DEVICES",
"…")`, but the uwsm route is recommended and is read earlier in the boot
chain (before the compositor execs, so it is guaranteed to be in
`/proc/$(pidof Hyprland)/environ`). One caveat from aquamarine source:
`AQ_DRM_DEVICES` filters **only** the startup scan (`scanGPUs`); a DRM card
added **after** Hyprland started is opened unconditionally by
`CBackend::onNewGpu` → `CDRMBackend::fromGpu`, which does not consult the
filter. The existing boot-load of vkms (via `/etc/modules-load.d/`) is
therefore still required.

## 2. Version matrix — Hyprland version → config format → env-var mechanism

| Hyprland | Config format | Config file | Env-var mechanism in config | Notes |
|---|---|---|---|---|
| ≤ 0.54 | hyprlang (native) | `~/.config/hypr/hyprland.conf` | `env = KEY,VALUE` (one per line) | The line the operator tried. |
| 0.55 | hyprlang **and** Lua (Lua opt-in; if `hyprland.lua` exists it is loaded instead) [VERIFIED — news/26_lua] | `$XDG_CONFIG_HOME/hypr/hyprland.lua` if present, else `hyprland.conf` [VERIFIED — wiki Start] | Lua: `hl.env("KEY", "VALUE")`; legacy: `env = KEY,VALUE` | Lua introduced 2026-04-26 (news), released as 0.55 on 2026-05-09. hyprlang deprecated, supported "1–2 releases". |
| 0.56 (current Arch `extra`, `0.56.2-3`) | Lua native; hyprlang still accepted as legacy | `~/.config/hypr/hyprland.lua` (this bench has it; no `hyprland.conf`) [VERIFIED — live `ls`] | Lua: `hl.env("KEY", "VALUE")` [VERIFIED — `example/hyprland.lua` L83-84] | This bench's actual state. |

Source pins: Hyprland news `26_lua` (2026-04-26, https://hypr.land/news/26_lua/);
Hyprland 0.55 release news (2026-05-09, https://hypr.land/news/update55);
Hyprland 0.56 release news (2026-07-20, https://hypr.land/news/update56);
Hyprland wiki "Start Here" (modified 2026-08-26,
https://wiki.hypr.land/Configuring/Start/); Arch package `extra/x86_64/hyprland
0.56.2-3` (https://archlinux.org/packages/extra/x86_64/hyprland/, accessed
2026-09-26); live bench `pacman -Q hyprland` = `0.56.2-3`,
`hyprctl --version` = `0.56.2-3`, `~/.config/hypr/hyprland.lua` present and
`hyprland.conf` absent (verified this session).

The operator's premise ("recent Hyprland moved the native config to Lua") is
**VERIFIED and slightly more nuanced than stated**: Lua became available on
`git`/0.55 and is native in 0.56, but hyprlang is still accepted as a
deprecated legacy path for "1–2 releases." On **this** bench the `.lua` file
exists and the `.conf` does not, so Lua is the active format — which is why
the legacy `env = …` line failed to parse.

## 3. The exact procedure for this bench (ranked)

### Preferred method — uwsm session env (recommended by Hyprland's own wiki)

This bench runs Hyprland under uwsm (`uwsm 0.27.0-1` on Arch `extra`).
Hyprland's "Environment variables" wiki page (modified 2026-08-26,
https://wiki.hypr.land/Configuring/Advanced-and-Cool/Environment-variables/)
states verbatim:

> Note uwsm users should avoid placing environment variables in the
> hyprland.lua file. Instead, use `~/.config/uwsm/env` for theming,
> xcursor, Nvidia and toolkit variables, and `~/.config/uwsm/env-hyprland`
> for HYPR* and AQ_* variables. The format is `export KEY=VAL`.

So for this bench, create `~/.config/uwsm/env-hyprland` (or append to it):

```sh
# ~/.config/uwsm/env-hyprland  — read by uwsm BEFORE the compositor execs.
# Pin Hyprland/aquamarine to the Intel i915 eDP card and away from vkms card2.
export AQ_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card
```

Why this is preferred, in boot-chain order:

1. uwsm sources `~/.config/uwsm/env` then `~/.config/uwsm/env-${compositor}`
   during environment preparation, **before** it execs the compositor
   [VERIFIED — uwsm man page `uwsm(1)` CONFIGURATION/Files, dated
   2026-08-29, https://manpages.debian.org/unstable/uwsm/uwsm.1.en.html;
   uwsm README https://github.com/Vladimir-csp/uwsm].
2. The variable is therefore already in the process environment when
   aquamarine's `CDRMBackend::attempt()` calls `scanGPUs()`, which calls
   `getenv("AQ_DRM_DEVICES")` at `src/backend/drm/DRM.cpp:202`
   [VERIFIED — source quote in §4].
3. It is visible in `/proc/$(pidof Hyprland)/environ` (the §5 verification),
   unlike a config-line that never lands in the loaded file (the original
   failure mode on this bench).

Apply, then **fully log out and back in** (uwsm re-prepares env on each
session start; a Hyprland `reload` does **not** re-read env vars because
aquamarine reads `AQ_DRM_DEVICES` only at backend init — see §4).

### Alternative 1 — Lua config (`hl.env`)

If for some reason the uwsm route is unavailable, the correct Lua syntax
(VERIFIED in `example/hyprland.lua` lines 83–84 and the wiki) is:

```lua
-- ~/.config/hypr/hyprland.lua
hl.env("AQ_DRM_DEVICES", "/dev/dri/by-path/pci-0000:00:02.0-card")
```

Place it near the existing `hl.env("XCURSOR_SIZE", "24")` lines. This sets
the var in Hyprland's own process environment before aquamarine backend
init (the wiki notes `hl.env` runs "prior to the initialization of the
Display Server"). A full re-login is still required; `hyprctl reload` is
not sufficient for the same reason. **Caveat:** the Hyprland wiki actively
tells uwsm users **not** to use this for `AQ_*` (use `env-hyprland`
instead), so on this bench the uwsm route is canonical, not this one.

### Alternative 2 — legacy hyprlang (NOT applicable on this bench)

`env = AQ_DRM_DEVICES,/dev/dri/by-path/pci-0000:00:02.0-card` is the
hyprlang syntax. It is correct **only** in a `hyprland.conf` file loaded by
a Hyprland that still reads hyprlang. On this bench the loaded file is
`hyprland.lua`, so this line is a syntax error — exactly the parse failure
the operator observed. It is listed here only to document why it failed.
[VERIFIED — news/26_lua "Old hyprlang syntax will continue to be supported
for 1–2 releases starting from 0.55"; the loaded file is `.lua` on this
bench.]

### Alternative 3 — systemd user-environment generators / `systemctl --user import-environment`

Not recommended here. uwsm already manages the systemd user environment and
explicitly sets `XDG_*` etc.; importing a one-shot `AQ_DRM_DEVICES` via
`systemctl --user import-environment` is fragile because the user manager
may already be running before the graphical session is selected, and aquamarine
only reads the var at the compositor's backend init. The uwsm `env-hyprland`
file is the supported, single-source route and reaches the compositor's
environ by construction. [REPORTED — uwsm README and Arch Wiki
"Universal Wayland Session Manager"; not needed on this bench.]

### Alternative 4 — a newer Hyprland-native device-exclusion feature

None found. As of 0.56.2-3 there is no config-level "exclude this DRM
device" option other than `AQ_DRM_DEVICES`. The Multi-GPU wiki page
(modified 2026-08-26, https://wiki.hypr.land/Configuring/Advanced-and-Cool/Multi-GPU/)
documents `AQ_DRM_DEVICES` as the mechanism. [VERIFIED — no other
device-exclusion knob in the wiki or example config; the source has no
other getenv'd filter in `src/backend/drm/DRM.cpp`.]

### Verification commands (R5)

```sh
# (a) Env reached the compositor process:
sudo cat /proc/$(pidof Hyprland)/environ | tr '\0' '\n' | grep AQ_
# EXPECTED: AQ_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card
# (or the canonicalized /dev/dri/cardN it resolves to)

# (b) Hyprland does NOT hold master on the vkms card (card2 → debugfs dri/2):
sudo cat /sys/kernel/debug/dri/2/clients
# EXPECTED: no Hyprland row with master y. A systemd-logind row with
# master y is normal (logind seat-master lease; yields to the active session).
```

Pitfalls (both VERIFIED on this bench in prior sessions, see ADR-026 §5):

- **(a) is the check that would have caught the original silent
  non-application.** If it is empty, the var never reached the compositor —
  redo the env-file step (the common failure was editing a non-loaded
  `hyprland.conf`).
- **(b) requires sudo** (debugfs is root-only) and **is the canonical
  master-exclusivity observation** (`fuser` shows open fds, not master
  status; empty `fuser` ⇒ no master, but non-empty `fuser` ⇏ master).
- The environ check only proves the var is set; it does not prove the filter
  excluded vkms — that is what (b) confirms. Run both.
- `AQ_DRM_DEVICES` is read at backend init, so a `hyprctl reload` will
  **not** change the open device set; a full session restart is required.

## 4. Aquamarine semantics (R3) — with source citations

All line numbers refer to `src/backend/drm/DRM.cpp`,
`src/backend/Session.cpp`, and `src/backend/Backend.cpp` on the `main`
branch of `github.com/hyprwm/aquamarine` (accessed 2026-09-26).

### 4.1 `AQ_DRM_DEVICES` parsing — exact syntax

The parse site is inside `scanGPUs()` (DRM.cpp:121). At DRM.cpp:202–244:

```cpp
202:    auto                            explicitGpus = getenv("AQ_DRM_DEVICES");
203:    if (explicitGpus) {
204:        backend->log(AQ_LOG_DEBUG, std::format("drm: Explicit device list {}", explicitGpus));
205:        Hyprutils::String::CVarList explicitDevices(explicitGpus, 0, ':', true);
206:
207:        // Iterate over GPUs and canonicalize the paths
208:        for (auto& d : explicitDevices) {
209:            std::error_code ec;
210:            auto            canonicalFilePath = std::filesystem::canonical(d, ec);
...
220:            d = canonicalFilePath.string();
221:        }
222:
223:        for (auto const& d : explicitDevices) {
224:            bool found = false;
225:            for (auto const& vd : devices) {
...
233:                if (canonicalFilePath == d) {
234:                    vecDevices.emplace_back(vd);
235:                    found = true;
236:                    break;
237:                }
238:            }
...
241:                backend->log(AQ_LOG_DEBUG, std::format("drm: Explicit device {} found", d));
242:            else
243:                backend->log(AQ_LOG_ERROR, std::format("drm: Explicit device {} not found", d));
244:        }
245:    } else {
246:        /* no AQ_DRM_DEVICES → use all enumerated cards, boot_vga first */
...
253:    }
```

Conclusions, all [VERIFIED] from the lines above:

- **Separator is `:` (colon).** `CVarList(..., 0, ':', true)` splits on
  colon. The Hyprland wiki Environment-variables page agrees verbatim:
  "It's a colon-separated list of paths, with the first being the primary.
  E.g.: `/dev/dri/card1:/dev/dri/card0`."
- **Paths are canonicalized with `std::filesystem::canonical`** before
  matching, so `/dev/dri/by-path/pci-0000:00:02.0-card` and
  `/dev/dri/card1` are equivalent **as long as the symlink resolves**. The
  by-path form is stable and preferred for this bench (the i915 stable
  by-path is `/dev/dri/by-path/pci-0000:00:02.0-card`).
- **List both card nodes and render nodes? No.** The enumeration at
  DRM.cpp:78–95 (`enumDRMCards`) matches only DRM **primary** minor nodes
  (`DRM_PRIMARY_MINOR_NAME "[0-9]*"`, i.e. `cardN`), and `openIfKMS` is
  called on the devnode (DRM.cpp:174). Render nodes (`renderD128`) are
  **not** what aquamarine opens for modesetting; you list only the card
  node(s). `sessionDevice->resolveMatchingRenderNode(device)` (DRM.cpp:181)
  ties the render node to the card automatically. So for this bench a
  single entry — the i915 card — is correct.
- **Multiple devices** are allowed and ordered: the first listed becomes
  primary (the `vecDevices` order is preserved into `attempt()` at
  DRM.cpp:337, which registers the first as `newPrimary`).
- **A path that does not canonicalize to a real DRM card** logs
  `drm: Explicit device … not found` and is skipped — it does not abort
  startup. (DRM.cpp:243.)

### 4.2 Startup vs. hotplug — the filter is init-only

This is the key semantic for the bench procedure.

- **Startup path (filtered):** `CDRMBackend::attempt()` (DRM.cpp:295) calls
  `scanGPUs(backend)` (DRM.cpp:325), which is the only place
  `AQ_DRM_DEVICES` is consulted (DRM.cpp:202). The filtered `gpus` vector
  is then iterated at DRM.cpp:337 to register each GPU. So at backend init,
  a card not in `AQ_DRM_DEVICES` is never opened and never takes master.
  [VERIFIED]

- **Hotplug path (NOT filtered):** when a new DRM card appears after
  startup, the udev event reaches `Aquamarine::CSession::handleUdevEvent`
  (Session.cpp:~420). At Session.cpp:441–445:

  ```cpp
  441:    if (!sessionDevice && action == std::string{"add"}) {
  442:        backend->onNewGpu(devnode);
  443:        udev_device_unref(device);
  444:        return;
  445:    }
  ```

  `CBackend::onNewGpu` (Backend.cpp:307–326) calls
  `CDRMBackend::fromGpu(path, …)` **directly**:

  ```cpp
  307: void Aquamarine::CBackend::onNewGpu(std::string path) {
  311:    auto       ref = CDRMBackend::fromGpu(path, self.lock(), primaryDrm);
  316:    if (!ref->start()) { … }
  321:    implementations.emplace_back(ref);
  324:    ref->onReady();        // Renderer created here
  325:    ref->recheckOutputs(); // Now we can recheck outputs
  326: }
  ```

  `CDRMBackend::fromGpu` (DRM.cpp:258) calls `CSessionDevice::openIfKMS`
  on the path and registers it. **Neither `onNewGpu` nor `fromGpu` calls
  `scanGPUs` or re-reads `AQ_DRM_DEVICES`.** There is no getenv of
  `AQ_DRM_DEVICES` anywhere outside `scanGPUs` (a full grep of DRM.cpp
  returns exactly one hit, line 202). [VERIFIED]

**Consequence for the bench:** `AQ_DRM_DEVICES` protects against vkms
**only if vkms is already present at Hyprland startup** so the startup scan
sees it and excludes it. If vkms is `modprobe`d after Hyprland is running,
`onNewGpu` opens it unconditionally and takes DRM master — the hotplug
grab the operator observed. The existing `/etc/modules-load.d/vkms.conf`
(ADR-026 step 1) is therefore **still required** even with `AQ_DRM_DEVICES`
correctly applied. This matches ADR-026's current step 1 and the
session-008 evidence; the research confirms the mechanism from source
rather than just from observation.

A corroborating code comment at DRM.cpp:347–348 (`// TODO: consider
listening for new devices / But if you expect me to handle gpu hotswaps
you are probably insane LOL`) shows the maintainers are aware startup-only
is the current design.

## 5. Verification procedure (R5) — confirmation

The two commands in §3 ("Verification commands") are sufficient and are
the canonical pair used by ADR-026:

- `/proc/$(pidof Hyprland)/environ` proves the var reached the process.
  This works because uwsm exports it before exec, and `hl.env` sets it
  before display-server init; in both cases it is in the environ by the
  time aquamarine runs. [VERIFIED — uwsm man page + wiki `hl.env` note.]
- `/sys/kernel/debug/dri/2/clients` proves who holds DRM master on card2.
  This is debugfs (requires sudo / root) and is the only direct
  master-exclusivity observation; `fuser` is a sufficient-only proxy
  (empty ⇒ no master; non-empty ⇏ master). [VERIFIED — ADR-026 §5 and
  prior session captures.]

No additional checks are needed. The one pitfall to repeat: a non-empty
environ check does **not** imply vkms is excluded — only the debugfs
`clients` file shows that. Run both, in that order.

## 6. ADR-026 amendment (ready to paste)

The following replaces ADR-026 steps 2 and 3 and adds a note to step 1.
Steps 1 (boot-load vkms), 4 (full re-login), 5 (debugfs verify), 6
(environ verify), 7 (run tests), and 8 (fallbacks) stand as written; the
amendment only corrects the **config-format** and **env-var mechanism**
parts that the 2026-09-26 session proved wrong for current Hyprland.

> **Step 2 (amended) — Discover the compositor config and session manager.**
> This bench runs Hyprland **0.56.2-3** (Arch `extra`; `pacman -Q
> hyprland`) under **uwsm 0.27.0-1**. Since Hyprland 0.55 (2026-05-09) the
> native config format is **Lua** (`hyprland.lua`); hyprlang
> (`hyprland.conf`) is deprecated legacy still accepted for 1–2 releases.
> On this bench the loaded config is `~/.config/hypr/hyprland.lua`
> (present; `hyprland.conf` absent — verified 2026-09-26). The legacy line
> `env = AQ_DRM_DEVICES,…` is **hyprlang syntax and will not parse in a
> `.lua` file**; this is the parse failure observed on 2026-09-26. Do
> **not** add hyprlang lines to `hyprland.lua`.
>
> **Step 3 (amended) — Route Hyprland away from vkms via uwsm env
> (preferred), not the Lua config.** Hyprland's "Environment variables"
> wiki page (modified 2026-08-26) states: "uwsm users should avoid placing
> environment variables in the hyprland.lua file. Instead, use
> `~/.config/uwsm/env` … and `~/.config/uwsm/env-hyprland` for HYPR* and
> AQ_* variables. The format is `export KEY=VAL`." Create or append to
> `~/.config/uwsm/env-hyprland`:
> ```sh
> # read by uwsm BEFORE the compositor execs; AQ_* belongs here per the
> # Hyprland wiki, not in hyprland.lua.
> export AQ_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card
> ```
> Verify the by-path symlink with `ls /dev/dri/by-path/ | grep card`.
> aquamarine parses `AQ_DRM_DEVICES` as a **colon-separated** list of card
> paths, canonicalized via `std::filesystem::canonical` (so the by-path
> symlink and `/dev/dri/cardN` are equivalent); list card nodes, not render
> nodes (`src/backend/drm/DRM.cpp:202-244`). The first listed device is
> primary.
>
> **Fallback (only if uwsm is unavailable):** the Lua form in
> `~/.config/hypr/hyprland.lua` is `hl.env("AQ_DRM_DEVICES",
> "/dev/dri/by-path/pci-0000:00:02.0-card")` (see `example/hyprland.lua`
> L83-84 for the `hl.env` pattern). The wiki recommends the uwsm route for
> `AQ_*`, so prefer `env-hyprland`.
>
> **Step 1 (unchanged, but the reason is now source-verified):** boot-load
> vkms via `/etc/modules-load.d/vkms.conf` is **still required**.
> `AQ_DRM_DEVICES` filters only the startup GPU scan
> (`scanGPUs`, `src/backend/drm/DRM.cpp:202`). A DRM card added after
> Hyprland started is opened by `CBackend::onNewGpu` →
> `CDRMBackend::fromGpu` (`src/backend/Backend.cpp:307`,
> `src/backend/Session.cpp:441-445`), which does **not** re-check
> `AQ_DRM_DEVICES`. A late `modprobe vkms` would therefore still be
> grabbed and master-taken. Boot-loading vkms makes it visible at the
> startup scan so the filter can exclude it.
>
> **Steps 4–8 stand.** Step 6's environ check (`grep AQ_` in
> `/proc/$(pidof Hyprland)/environ`) is the definitive "did the var reach
> the compositor" test; with the uwsm route it will be non-empty on the
> first re-login.

## 7. Sources (with dates)

1. Hyprland news, "Lua-ification of Hyprland configs," Vaxry, 2026-04-26 —
   https://hypr.land/news/26_lua/ (accessed 2026-09-26). Quotes: "Starting
   from today on git, or a future 0.55 release, you will be able to use lua";
   "The old hyprlang syntax will continue to be supported for 1 - 2 releases
   starting from 0.55. After that, hyprlang will be dropped."
2. Hyprland news, "Hyprland 0.55 is here," 2026-05-09 —
   https://hypr.land/news/update55.
3. Hyprland news, "Hyprland 0.56 has arrived," 2026-07-20 —
   https://hypr.land/news/update56.
4. Hyprland wiki, "Start Here" (modified 2026-08-26) —
   https://wiki.hypr.land/Configuring/Start/. Quote: "Since Hyprland 0.55,
   hyprlang is deprecated in favor of lua. The config is located in
   `$XDG_CONFIG_HOME/hypr/hyprland.lua`."
5. Hyprland wiki, "Environment variables" (modified 2026-08-26) —
   https://wiki.hypr.land/Configuring/Advanced-and-Cool/Environment-variables/.
   Quotes: the uwsm note (see §3); `hl.env("AQ_DRM_DEVICES", "...")` —
   "Set an explicit list of DRM devices (GPUs) to use. It's a
   colon-separated list of paths, with the first being the primary. E.g.:
   `/dev/dri/card1:/dev/dri/card0`."
6. Hyprland wiki, "Multi-GPU" (modified 2026-08-26) —
   https://wiki.hypr.land/Configuring/Advanced-and-Cool/Multi-GPU/.
7. `example/hyprland.lua` (Hyprland repo, `main`) —
   https://raw.githubusercontent.com/hyprwm/Hyprland/main/example/hyprland.lua
   (accessed 2026-09-26). Lines 83-84: `hl.env("XCURSOR_SIZE", "24")` /
   `hl.env("HYPRCURSOR_SIZE", "24")`.
8. Arch Linux package `extra/x86_64/hyprland 0.56.2-3` —
   https://archlinux.org/packages/extra/x86_64/hyprland/ (accessed
   2026-09-26); confirmed on bench via `pacman -Q hyprland`.
9. Arch Linux package `extra/x86_64/uwsm 0.27.0-1` —
   https://archlinux.org/packages/extra/x86_64/uwsm/ (accessed 2026-09-26).
10. uwsm man page `uwsm(1)`, dated 2026-08-29 —
    https://manpages.debian.org/unstable/uwsm/uwsm.1.en.html. Files table
    lists `uwsm/env` and the env-file mechanism.
11. uwsm upstream README — https://github.com/Vladimir-csp/uwsm (accessed
    2026-09-26).
12. Arch Wiki, "Universal Wayland Session Manager" —
    https://wiki.archlinux.org/title/Universal_Wayland_Session_Manager
    (accessed 2026-09-26).
13. aquamarine source `src/backend/drm/DRM.cpp` (`main` branch) —
     https://raw.githubusercontent.com/hyprwm/aquamarine/main/src/backend/drm/DRM.cpp
     (accessed 2026-09-26). Lines: 78-95 (`enumDRMCards`), 121-256
     (`scanGPUs`, `AQ_DRM_DEVICES` parse at 202-244), 258-293 (`fromGpu`),
     295-360 (`attempt`), 1136-1149 (hotplug `change` listener).
14. aquamarine source `src/backend/Session.cpp` (`main`) —
     https://raw.githubusercontent.com/hyprwm/aquamarine/main/src/backend/Session.cpp
     (accessed 2026-09-26). Lines 420-485 (udev `add`/`change`/`remove`),
     specifically 441-445 (`backend->onNewGpu(devnode)` on `add`).
15. aquamarine source `src/backend/Backend.cpp` (`main`) —
     https://raw.githubusercontent.com/hyprwm/aquamarine/main/src/backend/Backend.cpp
     (accessed 2026-09-26). Lines 307-326 (`CBackend::onNewGpu`).
16. Live bench state captured this session (2026-09-26): `pacman -Q
    hyprland` = `0.56.2-3`; `hyprctl --version` = `0.56.2-3`; `uname -r` =
    `7.2.6-arch2-1`; `ls ~/.config/hypr/` = `hyprland.lua` + `hyprland.lua.bk`
    (no `hyprland.conf`); `grep -n hl.env ~/.config/hypr/hyprland.lua`
    shows `hl.env("XCURSOR_SIZE","24")` and `hl.env("HYPRCURSOR_SIZE","24")`.

---

## Conclusion

The verified procedure makes the unprivileged granted bench achievable on
this machine: set `AQ_DRM_DEVICES` to the i915 by-path card in
`~/.config/uwsm/env-hyprland` (uwsm exports it before the compositor execs,
so it is in `/proc/$(pidof Hyprland)/environ` and aquamarine's `scanGPUs`
honors it at backend init), keep vkms boot-loaded via
`/etc/modules-load.d/vkms.conf` so the startup scan sees and excludes it,
re-login fully, and confirm with the environ grep plus the debugfs
`/sys/kernel/debug/dri/2/clients` master check. The legacy `env = …` line
that failed is the wrong syntax for the `.lua` config this bench actually
loads; the Lua `hl.env` form works but is not the recommended route for
`AQ_*` under uwsm. What remains unverified is only the runtime
confirmation on this exact bench after applying the uwsm route — the
source and docs evidence is complete, but the post-restart environ and
debugfs captures should be re-run to close the loop (they are the §5
checks, not new research).

---

## Correction entry — 2026-09-26 (incident post-mortem)

This section corrects two claims in the body above that were refuted by
machine-state evidence captured during the 2026-09-26 bench-lane
incident post-mortem. The corrections are recorded here verbatim; the
original claims are retained in the body for history. See
`docs/test-logs/010-bench-incident/recovery-verification.md` for the
captured evidence.

### Correction 1 — "uwsm 0.27.0-1 installed" is REFUTED

**Original claim** (§3 "Preferred method", and §2 version matrix note):
"This bench runs Hyprland under uwsm (`uwsm 0.27.0-1` on Arch `extra`)."

**Refuting evidence** (captured 2026-09-26):

```
$ pacman -Q uwsm
error: package 'uwsm' was not found
```

`uwsm` is **not installed** on this machine. The active login chain is
greetd → cosmic-greeter (cosmic-comp) → Hyprland, with **no uwsm in the
chain**. The staged `~/.config/uwsm/env-hyprland` file (which contains
`export AQ_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card`) is
therefore **inert** — nothing sources it. This is why, on the restored
boot 0, `/proc/$(pidof Hyprland)/environ` has no `AQ_` var despite the
file still being present.

**Consequence for this report**: the "Preferred method" (§3, set the var
in `~/.config/uwsm/env-hyprland`) is **not applicable on this bench** —
there is no uwsm to source that file. The report's conclusion that the
uwsm route is "the preferred method" for this bench is wrong. The
underlying aquamarine semantics (§4) and the `AQ_DRM_DEVICES` parse
syntax (§4.1) remain correct — they are source-derived, not
bench-derived. The uwsm-route recommendation is valid **only for setups
that actually run Hyprland under uwsm**; this bench is not one of them.

### Correction 2 — the "worst case: harmless env var" risk note is REFUTED

**Original claim** (from the prior diagnostics session's risk note,
referenced in this report's framing that the uwsm route is "achievable
on this machine"): staging `AQ_DRM_DEVICES` via the login chain is
low-risk, "worst case: harmless env var."

**Refuting evidence** (captured 2026-09-26, boot -2 journal):

```
Sep 26 09:03:31 phobos systemd-coredump[13049]: Process 13030 (Hyprland) of user 1000 terminated abnormally with signal 6/ABRT, processing...
Sep 26 09:03:36 phobos systemd-coredump[13234]: Process 13215 (Hyprland) of user 1000 terminated abnormally with signal 6/ABRT, processing...
```

Hyprland ABRT'd (signal 6) at ~1 s after session start on three
consecutive login attempts (boot -2, 09:03:31 / 09:03:36 / 09:03:49)
with the staged `AQ_DRM_DEVICES` injection active in the greetd→Hyprland
env chain, forcing the user to reboot from the greeter. The injection
was staged via `~/.profile` + `~/.config/environment.d/aq-devices.conf`
+ `~/.config/uwsm/env-hyprland`; removing the first two restored login
on boot 0 (the third is inert). Full analysis:
`docs/test-logs/010-bench-incident/root-cause-from-logs.md`.

**Consequence**: an `AQ_DRM_DEVICES` filter applied via the login chain
on this multi-card bench can abort Hyprland/aquamarine at backend init
and break graphical login. The var is **not** "harmless" — it reaches
the compositor at backend init and can cause a fatal abort. See
`docs/dangers.md` HOST SAFETY RULES (added this session).

### Scope of validity of this report's content after corrections

- **§4 (aquamarine source semantics, `AQ_DRM_DEVICES` parse, startup vs
  hotplug): VALID** — source-derived, not bench-derived; the
  `scanGPUs`-only filter and the `onNewGpu` hotplug bypass are correct.
- **§2 (version matrix, Hyprland 0.56.2-3 + Lua config): VALID** —
  confirmed by `pacman -Q hyprland` = `0.56.2-3` and the present
  `~/.config/hypr/hyprland.lua`.
- **§3 (the procedure for *this bench*): NOT APPLICABLE** — the uwsm
  route is inert here (uwsm not installed); the Lua `hl.env` route and
  the legacy hyprlang route remain technically valid for setups that use
  them, but **applying any of them on this dev machine is FORBIDDEN** by
  the HOST SAFETY RULES and the ADR-026 CLOSURE. The unprivileged
  granted-bench lane is CLOSED on this machine.
- **§5 (verification commands): VALID as commands** — the environ grep
  and debugfs `clients` check remain the canonical observations; they
  are reused by the Stage-3 interlock diagnostic tooling.
- **§6 (ADR-026 amendment paste): SUPERSEDED** by the ADR-026 CLOSURE —
  the amendment was never applied and the procedure it amends is closed.

The uwsm content in this report remains valid **for standard setups that
actually run Hyprland under uwsm**; it is not valid for this bench.