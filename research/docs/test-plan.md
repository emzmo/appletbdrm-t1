# Test Plan — touchbar-engine FIRST hardware test session

**Status**: Pre-session. Subject to the FREEZE RULE: once a session starts the
codebase is read-only. Findings → logs. Fixes → later branch + ADR.
**Target hardware**: MacBookPro14,2 (T1, `05ac:8600` iBridge), kernel
`7.2.6-arch2-1`, `appletbdrm` + `hid_multitouch` loaded.
**Review status**: `docs/review-report.md` records **6 blocking FAILs**.
**Therefore**: only **Stage 0** (read-only environment capture) is cleared to
run from this build. Stages 1–7 are blocked until the FAILs are resolved on a
branch and this plan is re-baselined. The staged commands and criteria for
1–7 are written below so the path is documented, but each is marked
**BLOCKED** and must not be run until unblocked by a follow-up review.

## Cross-stage rules

- **No code edits during a session.** If an abort criterion trips: capture
  evidence, stop the daemon, do not patch. File `docs/test-logs/NNN-issue-M.md`.
- **One terminal = one captured log.** Every command that produces output
  writes to `docs/test-logs/NNN/<name>.log` via `tee`.
- **Verbosity**: run the daemon with `RUST_LOG=tbard=debug,warn` unless a
  stage says otherwise.
- **Timestamps**: every log file begins with `date -Is` header.
- **Reproducibility**: record `git rev-parse HEAD` (or the no-git fallback:
  `sha256sum target/release/tbard`) at the start of each session.

## Session directory layout

```
docs/test-logs/NNN/
  environment.log        # Stage 0 capture
  dmesg-baseline.log
  lsusb.log
  evtest-<dev>.log       # one per digitizer evtest
  journalctl.log
  tbard-stdout.log
  tbard-stderr.log
  stage-M-<name>.log
  NNN-issue-K.md        # one per anomaly
```

---

## Stage 0 — Environment capture (READ-ONLY) ✅ CLEARED

**Goal**: record the pre-contact baseline. No daemon is started. Nothing is
written to the Touch Bar. This stage is safe regardless of review outcome.

### Commands (run from the repo root)

```bash
SESS=docs/test-logs/000
mkdir -p $SESS
date -Is | tee $SESS/environment.log
git rev-parse HEAD 2>/dev/null | tee -a $SESS/environment.log || \
  sha256sum target/release/tbard 2>/dev/null | tee -a $SESS/environment.log
uname -a | tee -a $SESS/environment.log
cat /proc/version | tee -a $SESS/environment.log

# Kernel + module versions
lsmod | grep -iE 'appletbdrm|hid_appletb|apple_ibridge|hid_multitouch|ibridge|apple_bce|t2bce' \
  | tee -a $SESS/environment.log
modinfo appletbdrm 2>/dev/null | tee -a $SESS/environment.log
modinfo hid_multitouch 2>/dev/null | tee -a $SESS/environment.log
modinfo hid_appletb_bl 2>/dev/null | tee -a $SESS/environment.log
modinfo hid_appletb_kbd 2>/dev/null | tee -a $SESS/environment.log

# USB
lsusb -v -d 05ac:8600 2>/dev/null | tee $SESS/lsusb.log
lsusb | tee -a $SESS/lsusb.log
cat /sys/bus/usb/devices/1-3/bConfigurationValue 2>/dev/null | tee -a $SESS/environment.log

# DRM nodes
ls -la /dev/dri/ | tee -a $SESS/environment.log
for c in /dev/dri/card*; do
  echo "== $c ==" | tee -a $SESS/environment.log
  cat /sys/class/drm/$(basename $c)/device/uevent 2>/dev/null | tee -a $SESS/environment.log
  cat /sys/class/drm/$(basename $c)-*/status 2>/dev/null | tee -a $SESS/environment.log
  cat /sys/class/drm/$(basename $c)-*/modes 2>/dev/null | tee -a $SESS/environment.log
done

# Backlight
ls /sys/class/backlight/ | tee -a $SESS/environment.log
for b in /sys/class/backlight/*; do
  echo "== $b ==" | tee -a $SESS/environment.log
  cat $b/max_brightness $b/brightness 2>/dev/null | tee -a $SESS/environment.log
done

# Input devices + seats
for d in /sys/class/input/input*/name; do
  n=$(cat $d); dev=$(basename $(dirname $d))
  seat=$(cat /sys/class/input/$dev/device/seat 2>/dev/null)
  echo "$dev: name='$n' seat='$seat'" | tee -a $SESS/environment.log
done

# dmesg baseline (last 500 lines, timestamped)
dmesg -T --level=err,warn,info 2>/dev/null | tail -500 | tee $SESS/dmesg-baseline.log

# evtest baseline of the digitizer (5s passive capture, no touch)
# Find the digitizer by name; on this bench it is input13 = "Apple Inc. iBridge Touchpad"
DIGIDEV=$(grep -El 'iBridge Touchpad|T1 Controller Touchpad|Touch Bar Display Touchpad' /sys/class/input/input*/name | head -1)
if [ -n "$DIGIDEV" ]; then
  dev=$(basename $(dirname $DIGIDEV))
  timeout 5 evtest /dev/input/$dev | tee $SESS/evtest-$dev.log || true
fi

# journalctl baseline (last boot, touchbar/appletbdrm/usb)
journalctl -b -0 -k 2>/dev/null | tail -300 | tee $SESS/journalctl.log
```

### Pass criteria
- All command outputs are non-empty and saved to `$SESS/`.
- **DRIVER-RESOLVED Touch Bar DRM node** (card numbers are UNSTABLE across
  boots — do NOT hard-code `card0`; see `docs/test-logs/010-bench-incident/`:
  incident-recovery baseline had `appletbdrm=card2`, earlier boots `card0`).
  Resolve the Touch Bar card by **driver**, not by number:
  ```bash
  ls -l /sys/class/drm/card*/device/driver | grep appletbdrm
  # e.g. /sys/class/drm/cardN/device/driver -> .../appletbdrm
  ```
  That resolved `cardN` must report mode `60x2170`, status `connected`
  (`cat /sys/class/drm/cardN/modes /sys/class/drm/cardN/status`).
- The digitizer is found by name and its evtest captures the device
  descriptor (no events expected since we are not touching it).
- `bConfigurationValue` reads `2` (Config 2 = DRM mode). If it reads `1`,
  do NOT proceed — the iBridge is in keyboard/DFU mode and the DRM card
  should not be present; re-check the stack.

### Abort criteria
- No card under `/sys/class/drm/card*/device/driver` resolves to
  `appletbdrm`, or the resolved Touch Bar card's mode is not `60x2170` →
  the Touch Bar DRM node is not available; stop and file an issue (do not
  run `touchbar-activate` or any config-switch script during a frozen
  session).
- `bConfigurationValue` ≠ 2 → stop, file an issue.
- Any `dmesg` line containing `appletbdrm: *ERROR*`, `usb 1-3: reset`,
  `appletbdrm: probe of … failed` → stop, file an issue with the dmesg
  excerpt.

### Evidence-capture (continuous, all later stages)
```bash
# In a separate terminal, for the duration of any active stage:
journalctl -f -k 2>/dev/null | tee $SESS/journalctl-live.log
dmesg -wT 2>/dev/null | tee $SESS/dmesg-live.log
```

---

## Stage 1 — Dry-run (simulated provider) ❌ BLOCKED

**Blocker**: `docs/review-report.md` §2.7 — no `--dry-run` flag, no
simulated-provider selection in `main`. The mock providers exist but are not
wired into `main`.

### Intended commands (do NOT run until unblocked)
```bash
RUST_LOG=tbard=debug ./target/release/tbard --dry-run 2>&1 | tee $SESS/stage-1-dryrun.log
```
### Intended pass criteria
- Daemon prints "dry-run: using MockDisplay/MockInput/MockBacklight".
- Daemon does NOT open `/dev/dri/card*`, `/dev/uinput`, or any sysfs path.
- Daemon exits 0 after 5 s or on SIGTERM.
### Abort criteria
- Any line `Opening /dev/dri` or `open /dev/uinput` → the dry-run is talking
  to real hardware; stop immediately, file an issue.
### Why blocked
No dry-run path exists. Running the normal binary here would skip straight
to real-hardware I/O (Stage 3/4 territory) without the bounded mock
exercise. This violates the staged protocol.

---

## Stage 2 — Inspect-only (daemon reads device metadata, never renders) ❌ BLOCKED

**Blocker**: §2.2 (discovery opens all cards and takes master on the eDP
card) and §2.3 (no bounded shutdown; hw-path `expect()` at
`drm.display_info().expect(…)`). Even "inspect-only" with the current binary
performs a full `acquire()` (atomic commit, modeset) — there is no
metadata-only mode.

### Intended commands (do NOT run until unblocked)
A dedicated `--inspect` subcommand that prints `DisplayInfo`, backlight
`max_brightness`, and the matched digitizer name, then exits without
allocating a framebuffer or issuing an atomic commit. **This subcommand does
not exist.**
### Intended pass criteria
- Prints the matched card path, mode size (60×2170), backlight path, and
  digitizer name.
- No atomic commit, no dumb buffer, no framebuffer.
- `dmesg` shows no new `appletbdrm` lines beyond probe.
### Abort criteria
- Any `atomic_commit` or `create_dumb_buffer` call → stop, file an issue.

---

## Stage 3 — Render-only (display lit, no touch handling) ❌ BLOCKED

**Blocker**: §2.2 (master contention on eDP), §2.3 (infinite loop, no
shutdown, hw unwraps), §2.6 (backlight fail-safe not enforced). Running the
daemon as built will perform a full modeset on the Touch Bar AND attempt to
take master on the i915 card during discovery, with no clean shutdown.

### Stage-3 interlock (DRIVER-RESOLVED — card numbers are UNSTABLE across boots)

**Rationale**: card numbers are NOT stable across boots. Evidence:
`docs/test-logs/010-bench-incident/recovery-verification.md` — the incident-
recovery baseline had `appletbdrm=card2` (with `card0=faux_driver/vkms`,
`card1=i915`), while earlier boots had `appletbdrm=card0`. Resolving the
Touch Bar card by **driver** (`appletbdrm`) instead of by number is the only
sound precondition. The deployed oracle (`tiny-dfr-mbp142.service`) holds
DRM master on the Touch Bar card; it must be stopped first and restored
afterward so the bar is not left dark. `docs/dangers.md` HOST SAFETY RULES
apply — no restarts, no service deployment, no login-chain changes; the
oracle stop/start here is the bounded, reversible test interlock only.

### Stage-3 acceptance (ADR 019) — step 1 = first real start of tbard.service

**ADR 019**: Stage 3 step 1 is the **first real start of `tbard.service`
under the interlock** — the unit's first real start IS Stage 3 (the
privdrop + post-drop self-check against the real `/dev/uinput`,
`appletb_backlight`, and — per ADR 036 — the Touch Bar digitizer input
fd are validated here, not in the sim/sandbox session). Run the
preflight tool first:

> **Session 020 install note (2026-09-26)**: `tbard.service` is now
> INSTALLED at `/usr/lib/systemd/system/tbard.service` (sha256
> `4193c3ca…`, hash-matches `packaging/systemd/tbard.service`) but
> **DISABLED** — not enabled, not started. The interlock preflight
> (`scripts/bench/interlock-preflight.sh`) emits **NO-GO** against the
> current machine state because the oracle
> (`tiny-dfr-mbp142.service`) is active and holds DRM master on the
> Touch Bar card (`card2` / dri minor 2, appletbdrm). This is the
> correct pre-Stage-3 baseline. Stage 3 will be the unit's **first
> start**, under the interlock (oracle stopped, preflight re-run to
> GO, then `systemctl start tbard.service`).
>
> **BLOCKER for Stage 3 (NF-020-B, must be resolved BEFORE Stage 3)**:
> the binary currently installed at `/usr/bin/tbard` is a **pre-ADR-019
> build** (mtime 2026-09-25 23:34, ~13.5h before the ADR-019 service-
> mode merge `26f3f3f` at 2026-09-26 13:11). It rejects `--service`
> as an unknown argument (exits 2 in 5ms with "unknown argument
> '--service'"); `strings /usr/bin/tbard | grep -- --service` → 0
> matches. The unit's `ExecStart=/usr/bin/tbard --service` would
> therefore fail-loop on first start. `systemd-analyze verify` exits 0
> (it only checks the path exists, not the binary's args). The
> **rebuild** (`cargo build --release --bin tbard` from v0.2.0 HEAD,
> re-install at `/usr/bin/tbard`, re-verify
> `strings … --service` > 0 and unprivileged `--service` → exit 1
> with the ADR-034 "service mode requires root" message) must happen
> OUTSIDE a session (FREEZE RULE D10) before Stage 3 is attempted.
> See `docs/test-logs/020/` (install-evidence.log §1, regression.log
> §R1, systemd-analyze-verify.log).
>
> **UPDATE (session 021, ADR 038):** the rebuild was performed outside
> a code session (FREEZE RULE D10); the verbatim evidence is at
> `docs/test-logs/021/rebuild-evidence.log`. The installed
> `/usr/bin/tbard` is now a v0.2.0 build (sha256
> `a6f9a57d42e442d1f9e0af18811447872c8de61e7584a6fcc9ff20fc5d13276f`)
> that accepts `--service` (`strings --service` → 6) and fast-fails
> correctly when unprivileged (exit 1 with the ADR-034 message). The
> NF-020-B binary-half is closed. ADR 038 D2 is now the PROCESS RULE
> for all future deployment/install sessions: build from the verified
> tagged HEAD and verify binary identity behaviorally
> (`strings --service` + unprivileged `--service` → exit 1) +
> `sha256`-match BEFORE and AFTER install. The behavioral check is the
> gate that caught NF-020-B (every repo gate was green; only R1 caught
> it). The PKGBUILD is repaired (`pkgver=0.2.0`, `source=()` matches
> the repo layout, a `check()` runs the R1 audit).

```bash
# 0. PREFLIGHT (ADR 019): single GO/NO-GO verdict. NO service lifecycle
#    actions; read-only checks (driver-resolved card, debugfs master,
#    oracle status, Esc-remap reminder).
scripts/bench/interlock-preflight.sh
# Expect: GO (oracle inactive, no master holder, tbard.service not running).
# If NO-GO: resolve the failures; do NOT proceed.
```

### Intended commands (do NOT run until unblocked)
```bash
# 1. STOP + MASK THE ORACLE (ADR-049: the deployed tiny-dfr-mbp142.service
#    holds DRM master on the Touch Bar card; it must release before we can
#    acquire master. `systemctl stop` ALONE is INSUFFICIENT — the unit is
#    `is-enabled=static` with `Restart=always`
#    (backup_old/systemd/tiny-dfr-mbp142.service:9); `stop` does not
#    suppress the restart policy, and `disable` is a no-op for a static
#    unit. Session 043 PROVED the oracle self-restarts under explicit
#    stop and panic-retries against the busy card
#    (docs/test-logs/043/step6-stop-tbard.txt:32-55). `mask --now` stops
#    the current activation AND blocks ANY restart path (socket,
#    dependency, manual, `Restart=`) for the duration. Reversed with
#    `unmask` at STEP 8. The mask is an administrative action by the
#    session operator; NO change to the oracle's deployed unit file at
#    /usr/lib/systemd/system/tiny-dfr-mbp142.service.)
#
# F-045-3 (session 045/047, canonical amendment): on deployments where
# the oracle's unit is a REAL FILE at /etc/systemd/system/ (NOT a
# package artifact at /usr/lib/systemd/system/), `systemctl mask` FAILS
# ("File already exists") — it cannot overwrite a real file. Use the
# MOVE-ASIDE + mask variant below for /etc-deployed units. The deployed
# unit on this bench is byte-identical to the repo's
# backup_old/systemd/tiny-dfr-mbp142.service reference (sha256
# 5310c917... — findings-045.txt:145-146); it is an operator-installed
# copy. The move-aside is reversible + verified byte-identical (sha256
# match) at restore.
#
# Variant A — /usr/lib-deployed unit (package artifact, direct mask):
sudo systemctl mask --now tiny-dfr-mbp142.service
# Variant B — /etc-deployed unit (operator-installed real file,
# F-045-3 move-aside + mask):
#   # Record pre-session sha256 (for the byte-identical restore check).
#   sha256sum /etc/systemd/system/tiny-dfr-mbp142.service | tee $SESS/oracle-unit-pre.sha256
#   sudo cp /etc/systemd/system/tiny-dfr-mbp142.service \
#           /etc/systemd/system/tiny-dfr-mbp142.service.bak
#   sudo rm /etc/systemd/system/tiny-dfr-mbp142.service
#   sudo ln -s /dev/null /etc/systemd/system/tiny-dfr-mbp142.service
#   sudo systemctl daemon-reload
#   sudo systemctl stop tiny-dfr-mbp142.service 2>/dev/null || true
# Verify the mask took (is-active=inactive, is-enabled=masked NOT static):
systemctl is-active tiny-dfr-mbp142.service   # inactive
systemctl is-enabled tiny-dfr-mbp142.service  # masked
# ADR-049 assertion: verify NO auto-restart within +60s (the mask blocks
# it; this is the assertion that the s043 race cannot recur):
sleep 60 && systemctl is-active tiny-dfr-mbp142.service  # still inactive

# 2. RESOLVE THE TOUCH BAR DRM CARD BY DRIVER (not by number — card numbers
#    are unstable across boots; see docs/test-logs/010-bench-incident/).
ls -l /sys/class/drm/card*/device/driver | grep appletbdrm
# → /sys/class/drm/cardN/device/driver -> .../appletbdrm   (note this N)

# 3. VERIFY NO MASTER HOLDER on the resolved cardN before we run ours.
#    (card numbers are unstable, so substitute the N resolved in step 2.)
sudo cat /sys/kernel/debug/dri/<N>/clients
# Expect: no row with "m" (master) in the capabilities column for our card.
# If a master holder remains → the oracle did not release; do NOT proceed.

# 4. RUN OURS — ADR 019: this is the FIRST REAL START of tbard.service
#    under the interlock. The privdrop + post-drop self-check against the
#    real /dev/uinput + appletb_backlight + the seat-touchbar digitizer
#    fd (ADR 036) are validated here. Either start the unit (preferred,
#    production-faithful) or run the binary directly with --service for
#    the same code path without systemd.
sudo systemctl start tbard.service
# OR (binary-direct, same --service code path):
# sudo -E RUST_LOG=tbard=debug ./target/release/tbard --service 2>&1 | tee $SESS/stage-3-render.log
# Observe the bar for 10 s, then stop and check for clean release:
sudo systemctl stop tbard.service
# journalctl -u tbard.service --no-pager | tee $SESS/stage-3-journal.log

# 5. RESTORE THE ORACLE (ADR-049: bounded test interlock ends — bar
#    must not be left dark; the oracle re-acquires master on the
#    resolved cardN. UNMASK first (the mask at STEP 1 blocked all
#    restart paths; unmask re-enables the static activation sources),
#    then START as the safety net).
# Variant A — /usr/lib-deployed unit (package artifact, direct unmask):
sudo systemctl unmask tiny-dfr-mbp142.service
sudo systemctl start tiny-dfr-mbp142.service
# Variant B — /etc-deployed unit (F-045-3 move-aside restore — reverse
#   the move-aside, verify byte-identical to pre-session sha256):
#   sudo rm /etc/systemd/system/tiny-dfr-mbp142.service
#   sudo mv /etc/systemd/system/tiny-dfr-mbp142.service.bak \
#           /etc/systemd/system/tiny-dfr-mbp142.service
#   sudo systemctl daemon-reload
#   sudo systemctl start tiny-dfr-mbp142.service
#   # Byte-identical restore check (sha256 MUST match $SESS/oracle-unit-pre.sha256):
#   sha256sum /etc/systemd/system/tiny-dfr-mbp142.service | diff - $SESS/oracle-unit-pre.sha256
#   # Verify the backup is GONE (cleanup — /etc returns to pre-session state):
#   ls /etc/systemd/system/tiny-dfr-mbp142.service.bak 2>/dev/null  # → No such file
# Verify: is-active=active, is-enabled=static (restored).
systemctl is-active tiny-dfr-mbp142.service   # active
systemctl is-enabled tiny-dfr-mbp142.service  # static (restored)
```
### STEP 4 — verify live state (ADR-046 value-only probe — the canonical procedure)

> **ADR-046 (2026-09-26): the STEP 4b backlight-write probe is
> VALUE-ONLY.** The sysfs `brightness` mtime is STRUCTURALLY INVALID
> as a "did userspace write" witness on `appletbdrm`
> (`docs/research/touchbar-interaction-manual/backlight.md` §4, §7.2;
> `docs/test-logs/038/`, `docs/test-logs/039/s2-persistence.txt`):
> kernel-internal brightness changes (the auto-dim decay) do NOT
> move mtime, while userspace writes DO — the two are
> indistinguishable from mtime alone. The runbook's prior "mtime
> moved since boot" criterion is unsatisfiable on this driver and is
> DROPPED. The VALUE probe is reliable in the userspace-written
> regime (tbard's enable-write is a userspace write) PROVIDED it is
> read within ~1s of the expected write — BEFORE the auto-dim decay
> begins (s039 S2: a written 128 decays to 1 by ~30s and to 0 by
> ~60s of idle, mtime FROZEN throughout the decay). Late reads are
> unreliable by decay; this is a documented limitation, NOT a defect
> to "fix" by re-adding mtime.

**4a — DRM master + privdrop (read-only).** `sudo cat
/sys/kernel/debug/dri/<N>/clients` (resolved N) → tbard is SOLE
master, `uid 65534` (nobody). `ps`/`/proc/<pid>/status` UID/GID
65534. eDP UNAFFECTED (card1 i915 masters unchanged).

**4b — backlight write (VALUE-ONLY, read within ~1s) — ADR-046.**
Immediately after `systemctl start tbard.service` (within ~1s —
BEFORE the auto-dim decay), read:
```bash
cat /sys/class/backlight/appletb_backlight/brightness
cat /sys/class/backlight/appletb_backlight/max_brightness
# ADR-045 (RUST_LOG=info): the journal witness —
journalctl -u tbard.service --no-pager | grep "backlight enable-tick"
# Also read the main display brightness to compute the expected curve output:
cat /sys/class/backlight/acpi_video0/brightness
```
- **EXPECT (ADR-048 reframed):** `brightness` ==
  `display_to_touchbar(current display_bl, active_brightness)` =
  `sqrt(display_bl/509) * active_brightness + 1` (clamped to
  `max_bl`), NOT raw `active_brightness` (128). At display_bl=90 +
  active_brightness=128, the expected value is **54**. The adaptive
  loop is the SINGLE owner of the maintained level; `enable()` forces
  an adaptive tick (writes the curve output), not a raw 128 write.
  The `tbard: backlight enable-tick → 54 (display_bl active_brightness
  128, adaptive true, max 255)` INFO line (ADR-045) confirms the
  write fired from the journal. Compute the expected value from the
  current display brightness with:
  `python3 -c "import math; print(int(math.sqrt($(cat /sys/class/backlight/acpi_video0/brightness)/509)*128)+1)"`.
- **DO NOT use mtime.** The `brightness` file mtime is NOT a reliable
  write-probe on `appletbdrm` (s038 §4, s039 §7.2: kernel-internal
  changes do not move mtime; the mtime probe is structurally invalid
  and is DROPPED by ADR-046). Do not re-add it.
- **If the read is later than ~1s after start:** the value may have
  decayed (s039 S2: the curve output →1 by ~30s, →0 by ~60s of no
  touch). A late read of 0 or 1 is UNRELIABLE — it does NOT prove the
  enable-tick failed. Re-run the start and read within ~1s, OR rely
  on the ADR-045 journal INFO line (the `backlight enable-tick → ...`
  line confirms the write fired regardless of the current decayed
  value).
- **Decay sources documented (both are by design, not defects):**
  1. **Kernel-side auto-dim** (`appletbdrm` driver): a userspace-
     written value decays on idle (s039 S2: 128→1 by ~30s, →0 by
     ~60s), mtime FROZEN, `bl_power` stays 0. This is the driver's
     own idle-dim, independent of tbard.
  2. **tbard's own ported adaptive path** (`update()` at loop-bottom,
     `src/providers/backlight.rs:222-266`, called at
     `src/main.rs:821`): the engine dims itself by design during a
     no-touch validation window — `BRIGHTNESS_DIM_TIMEOUT_MS = 30s`
     → `DIMMED_BRIGHTNESS = 1`, `BRIGHTNESS_OFF_TIMEOUT_MS = 60s` →
     0 (`backlight.rs:17-19`). A no-touch validation run WILL dim
     the bar by design; this is NOT a defect.
  A lit bar observed MINUTES after start may legitimately be dim/dark
  under either source. The probe reads immediately (~1s); the human
  checkpoint (HC2) reads the CURRENT state — see HC2 timing below.

**4c — no EACCES / open_restricted / permission-denied** in
`journalctl -u tbard.service` (acceptance item 11). With ADR-045
(RUST_LOG=info), the frame-counter cadence is observable at INFO
(`tbard: frame stats: frames=N uptime=Ts dirty_flushes=M
last_flush=...` every 100 frames, ADR-023) — a stall is now
detectable from the journal without debugfs.

**4d — `/dev/input` count** unchanged (no uinput device created on an
idle run — expected).

**4e — `dmesg` delta** since start: none (no `appletbdrm: … stall` /
`flush timed out`).

**4f — ADR-049 mid-run assertion (oracle masked, no oracle row).**
During long validation runs, re-check debugfs for an oracle row
periodically (or before every stage step). The mask at STEP 1 blocks
any restart path, but a mid-session check catches the case where the
mask is accidentally reversed or a systemd version behaves
unexpectedly:
```bash
sudo cat /sys/kernel/debug/dri/<N>/clients | grep -i tiny-dfr
# EXPECT: no output (the oracle is masked; no row should appear).
# If a tiny-dfr-mbp142 row appears mid-run, the mask failed or was
# reversed — ABORT the run (the oracle is racing tbard for the card).
# Re-mask + verify, or stop tbard and restore the oracle (STEP 8).
```

### HC2 — first pixels (ADR-046 timing alignment)

> **ADR-046 (2026-09-26): HC2 timing must account for BOTH decay
> sources.** A lit bar observed minutes after start may legitimately
> be dim/dark (kernel-side auto-dim + tbard's own adaptive path,
> both by design — see STEP 4b above). s037's HC2 was asked minutes
> after start, by which time the enable-write of 128 had decayed to
> 0 under the no-touch validation window — the "Dark / no pixels"
> answer was consistent with a SUCCESSFUL write + decay, not a
> missing write (ADR-044 V5).

Ask HC2 **within ~30s of `systemctl start`**, OR have the human
**touch the bar first** (wake-to-bright: a touch event wakes the bar
via tbard's adaptive `notify_activity` path, resetting `last_active`
and re-brightening to `active_brightness`), THEN answer. Document
the chosen protocol in the session log. If HC2 is asked later than
~60s after start with no touch in between, a "Dark / no pixels"
answer is UNRELIABLE — it may reflect decay, not a write failure.
Re-run with the ~30s-or-touch protocol.

> **ADR-047 (2026-09-27): the touch-to-wake path is now WIRED.** The
> `InputEvent::Touch` arm in `real_main` calls
> `backlight.notify_activity()` BEFORE the gesture handler (porting the
> oracle's `process_event` pre-gate wake at
> `backup_old/tiny-dfr-mbp142/src/main.rs:1037`). A touch on a dark bar
> resets `last_active`; the loop-bottom `update()` lights the bar; the
> `set_current_backlight` push opens the digitizer gate for the NEXT
> touch. The waking touch is consumed by the wake (no button hit on a
> dark bar — macOS UX). The journal witness is the new INFO line
> `tbard: touch wake → backlight.notify_activity()`. The HC2
> touch-to-wake protocol is now operable (it was aspirational when
> ADR-046 was written).

### Intended pass criteria
- The resolved Touch Bar card (`appletbdrm`, by driver not by number)
  atomic commit succeeds; `dmesg` shows no stall warnings.
- `sudo cat /sys/kernel/debug/dri/<N>/clients` (resolved N) showed no master
  holder before we ran, and shows our daemon as master while running, and
  shows no master holder after clean release.
- **STEP 4b (ADR-046 value-only, ADR-048 reframed):** `cat
  /sys/class/backlight/appletb_backlight/brightness` (read within
  ~1s of start) == `display_to_touchbar(current display_bl,
  active_brightness)` (at display 90 + active 128 = **54**), NOT raw
  128; the ADR-045 journal INFO line `tbard: backlight enable-tick →
  54 ...` is present. **mtime is NOT used** (structurally invalid on
  `appletbdrm` — s038/s039; dropped by ADR-046). **The adaptive loop
  is the single owner of the maintained level (ADR-048); `enable()`
  forces a tick that writes the curve output, not a raw 128.**
- **HC2 (ADR-046 timing):** asked within ~30s of start OR after a
  touch-to-wake; "lit" / "first pixels visible" is the pass. A late
  no-touch "dark" is unreliable (decay by design) — re-run with the
  ~30s-or-touch protocol.
- Laptop eDP panel does **not** black-blink (no master contention on i915).
- On `kill -TERM`, the daemon exits within 2 s, releases DRM master, and
  removes the IPC socket (when IPC is wired in).
- The oracle is restored (`tiny-dfr-mbp142.service` active) and the bar is
  lit again at the end of the stage.
### Abort criteria
- Laptop panel flickers or goes black → kill the daemon, **restore the
  oracle** (`sudo systemctl start tiny-dfr-mbp142.service`), file an issue
  (master contention on the i915 card — do NOT cite a card number; resolve
  by driver per the Stage-3 interlock).
- `dmesg` shows `appletbdrm: … stall` or `flush timed out` → kill, file.
- Daemon does not exit on SIGTERM within 5 s → `kill -9`, file an issue
  (no signal handler / no clean shutdown).
- Touch Bar stays dark after the daemon is running for 5 s → kill, file
  (backlight fail-safe).

### Stage-3 hardware validation — session 025 (2026-09-26) — ABORTED at STEP 3

**Result: ABORTED at STEP 3 (first real start). Oracle restored; tbard
left disabled+inactive (validation run, NOT a migration). FREEZE
respected (`git diff v0.2.1 HEAD -- src/` = 0 lines).**

The interlock procedure (P1 → HC1 → STEP 1 → STEP 2 → STEP 3) was
executed verbatim with evidence captured to `docs/test-logs/025/`:

- **P1 baseline** (`P1-baseline.txt`): HEAD `f636f1a` = one docs commit
  on top of v0.2.1 (`f3edeb7`); `src/` frozen (0-line diff vs v0.2.1);
  installed `/usr/bin/tbard` sha256 `a6f9a57d…` (matches); touchbar card
  resolved by driver = card2/appletbdrm; debugfs oracle (tgid 542,
  uid 65534) sole master; 18 `/dev/input` nodes; backlight 54/255;
  oracle active+static, tbard inactive+disabled. Baseline NO-GO (oracle
  active) — as expected.
- **HC1** (`P1-baseline.txt` tail): human confirmed (a) working Esc
  fallback tested just now, (b) Esc on the Touch Bar sent Esc, (c) read
  `docs/recovery.md`.
- **STEP 1 — stop oracle** (`STEP1-stop-oracle.txt`): `systemctl stop
  tiny-dfr-mbp142.service` → inactive and STAYS inactive (Restart=always
  does not fight an explicit stop; verified at +2s and +7s). debugfs
  touchbar card (`dri/2` + `dri/1-3:2.3`) EMPTY (master released). i915
  card UNAFFECTED. `/dev/input` 18→17 (oracle uinput removed). Bar dark
  (expected).
- **STEP 2 — preflight** (`STEP2-preflight.txt`):
  `sudo sh scripts/bench/interlock-preflight.sh` → **GO (exit 0)**.
  Touchbar card located by driver (card2/appletbdrm); no master holder;
  oracle inactive; tbard inactive+disabled.
- **STEP 3 — first real start** (`STEP3-first-start-failure.txt` +
  `STEP3-journal-live.log`): `systemctl start tbard.service` at
  15:08:59 → **FAILED at privdrop** in 3 bursts (15:08:59, 15:09:04,
  15:09:10), then `start-limit-hit` at 15:09:15 (calibrated StartLimit
  behavior — recorded as evidence, not an anomaly). Journal verbatim:
  `tbard: privdrop failed: privdrop failed: Privilege drop error: Group
  not found` / `Error: PrivDrop { detail: "Privilege drop error: Group
  not found" }` ×3.

**Root cause (read-only diagnosis; NO /etc or code change — both outside
this session's authority):** the privdrop at `src/service.rs:139`
hardcodes `.group("nogroup")`. On this Arch system the group `nogroup`
**does not exist** (`getent group nogroup` → exit 2); only `nobody`
exists with gid 65534, and the `nobody` user's primary gid is 65534 (the
`nobody` group). The `privdrop` crate's group-by-name lookup returns
NotFound → privdrop fails → exit 1 BEFORE any DRM acquire, uinput,
backlight, or digitizer work. debugfs touchbar card was EMPTY throughout
(no master acquired → no RAII leak). No dmesg delta. This is a
**deployment-environment gap** (Arch uses nobody:nobody; the code
expects the Debian/Ubuntu nobody:nogroup pair), not a code bug. The
doc comment at `src/service.rs:130` anticipates "`nobody` not in
`/etc/passwd`" but not the Arch variant where `nogroup` is absent.

**Abort recovery executed** (`STEP8-restore-oracle.txt`):
`systemctl stop tbard.service` + `systemctl reset-failed tbard.service`
→ tbard inactive+disabled; `systemctl start tiny-dfr-mbp142.service` →
active, sole master on touchbar card (tgid 87113, uid 65534), `/dev/input`
back to 18, backlight 54.
- **HC3** (`STEP8-restore-oracle.txt` tail): human confirmed the bar
  shows the oracle's normal F-row and Esc on the bar sends Esc again.
  Interlock window CLOSED.
- **STEP 9 final state** (`STEP9-final-state.txt`): oracle active+static
  (sole master); tbard inactive+disabled; FREEZE respected (only
  `docs/test-logs/025/` untracked).

**Stage-3 acceptance items (all 11)** — none reached/verified (all
blocked by the privdrop failure at acceptance item 2):

| # | Acceptance | Result | Evidence |
|---|------------|--------|----------|
| 1 | real acquire | NOT reached (failed before acquire) | `STEP3-first-start-failure.txt` |
| 2 | real privdrop to nobody/nogroup | **FAILED** (root cause: `nogroup` group not found) | `STEP3-first-start-failure.txt`, `src/service.rs:139` |
| 3 | post-drop self-check (real fds incl. digitizer) | NOT reached | — |
| 4 | real render loop — first pixels | NOT reached | — |
| 5 | SIGTERM from running loop → exit 0 | NOT reached | — |
| 6 | RAII master release → card free (debugfs) | N/A (never acquired; debugfs empty = no leak) | `STEP3-first-start-failure.txt` |
| 7 | immediate rerun acquires cleanly | NOT reached | — |
| 8 | preflight → GO post-stop | N/A (preflight was GO pre-start; abort) | `STEP2-preflight.txt` |
| 9 | backlight writes via held pre-drop fd | NOT reached | — |
| 10 | digitizer identify_digitizer (ABS X 32767 / Y 127) | NOT reached | — |
| 11 | libinput open_restricted post-drop residual | NOT reached | — |

**ADR proposals (for a future branch; NOT implemented on the air):**

- **ADR-039 (proposed): privdrop group resolution — Arch `nogroup`
  portability.** The privdrop currently hardcodes the group name
  `nogroup` (`src/service.rs:139`), which does not exist on Arch
  (where `nobody` has gid 65534 for both user and group). Options to
  adjudicate on a branch: (a) resolve the group gid from the `nobody`
  user's `/etc/passwd` entry (gid 65534) instead of a separate group
  name — matches the oracle's own uid 65534/gid 65534 drop; (b) make
  the group name configurable via the unit / env; (c) document the
  `nogroup` group as a hard deployment precondition (add a
  `groupadd nogroup` step to the install docs) and keep the code. (a)
  is the most portable and matches what the oracle actually runs as;
  recommend (a). Either way this must be decided + implemented on a
  branch under FREEZE, then re-validated in a fresh Stage-3 session.
- **ADR-040 (proposed): Stage-3 preflight — extend the
  `nogroup`-existence check.** `scripts/bench/interlock-preflight.sh`
  should add a read-only check that the privdrop target group exists
  (`getent group nogroup` || the resolved gid path) so this class of
  failure is caught at preflight (NO-GO) rather than at first start.
  Cheap, read-only, no hardware touched.

**Stage-4 preview: SKIPPED** (precondition not met — STEP 3 aborted
before any running loop; the one-touch observation requires a clean
STEP-4 run window).

**Next session:** after ADR-039/040 are adjudicated + implemented on a
branch and merged (and the preflight extended), re-run Stage 3 from P1
in a fresh session. The interlock protocol itself (P1→HC1→STEP1→STEP2
→STEP3) is validated and reusable verbatim; only the privdrop target
needs to resolve.

### Stage-3 hardware validation — session 029 (RE-RUN, 2026-09-26) — ABORTED at STEP 3

**Result: ABORTED at STEP 3 (first real start). Oracle restored; tbard
left disabled+inactive (validation run, NOT a migration). FREEZE
respected (HEAD `a7a461b` = v0.2.2; `src/` untouched; only
`docs/test-logs/029/` untracked).**

The session-025 privdrop ABORT root cause was FIXED off-band by ADR-039
(resolve the privdrop gid from `/etc/passwd` → uid/gid 65534, BEFORE the
acquire) and ADR-040 (preflight STEP 0 environment inventory). This
RE-RUN re-validated the live-verified items (StartLimit 3-burst,
fast-fail-before-scan ordering, preflight STEP 0 all-PASS) and progressed
PAST the session-025 failure point — tbard now reaches the digitizer
identify step (ADR-036 pre-drop phase) before failing. A NEW, distinct
blocker was found there.

The interlock procedure (P1 → HC1 → STEP 1 → STEP 2 → STEP 3) was
executed verbatim with evidence captured to `docs/test-logs/029/`:

- **P1 baseline** (`p1-baseline.txt`): HEAD `a7a461b` = v0.2.2 (clean
  tree); installed `/usr/bin/tbard` sha256 `9a58dea7…` (matches
  session-028 verified hash); touchbar card resolved by driver =
  card2/appletbdrm (DRI minor 2); debugfs oracle `tiny-dfr-mbp142`
  (tgid 87113, uid 65534) sole master; 18 `/dev/input` nodes;
  `appletb_backlight` 54/255; oracle active+static, tbard
  inactive+disabled. Baseline matches protocol CONTEXT exactly.
- **HC1** (`hc-answers.txt`): human confirmed "a yes, b yes, c yes" —
  (a) Esc fallback connected+tested, (b) Esc on the Touch Bar sent Esc,
  (c) `docs/recovery.md` read.
- **STEP 1 — stop oracle** (`step1-stop-oracle.txt`):
  `systemctl stop tiny-dfr-mbp142.service` → inactive and STAYS inactive
  after +10s (explicit stop beats Restart=always; live-verified).
  debugfs touchbar card EMPTY (master released).
- **STEP 2 — preflight** (`step2-preflight.txt`):
  `sudo sh scripts/bench/interlock-preflight.sh` → **GO (exit 0)**.
  STEP 0 a–f all PASS (incl. 0d: digitizer resolvable by geometry at
  `/dev/input/event7`: ABS_MT X max 32767 / Y max 127). Touchbar card
  located by driver (card2/appletbdrm, dri minor 2); no master holder;
  oracle inactive; tbard inactive+disabled.
- **STEP 3 — first real start** (`step3-first-start.txt` +
  `step3-journal-live.log` + `step3-diagnosis.txt`):
  `systemctl start tbard.service` at 15:51:22 → **FAILED at digitizer
  identify** in 3 bursts (15:51:23, 15:51:28, 15:51:33), then
  `start-limit-hit` at 15:51:39 (calibrated StartLimit behavior —
  recorded as expected, not an anomaly). Journal verbatim:
  `tbard: input init (digitizer identify) failed: input init failed:
  no digitizer found on seat-touchbar (geometry gate: ABS_MT vs
  (60, 2170))` ×3. debugfs touchbar card EMPTY throughout (tbard never
  acquired master — it failed in input init, before the DRM master
  acquire and before privdrop). No dmesg delta. The ADR-039 privdrop
  fix was therefore NOT exercised on hardware this run (tbard fails
  before reaching it).

**Root cause (read-only diagnosis; NO code change — outside this
session's authority):** a contradiction between the preflight script and
tbard's runtime geometry gate. The iBridge Touch Bar digitizer
(`/dev/input/event7`, "Apple Inc. iBridge Touchpad", USB 05ac:8600 if 2)
reports ABS_MT_POSITION_X max=32767 / ABS_MT_POSITION_Y max=127 (read
live via EVIOCGABS this session) — the exact "audit-C / acceptance-10"
geometry. `scripts/bench/interlock-preflight.sh:0d` hardcodes
`DIGI_GEOM_X=32767 / DIGI_GEOM_Y=127` and accepts this device (its
header claims it "Mirrors identify_digitizer"). But the runtime
predicate `geometry_matches_tb` (`src/providers/input.rs:262-269`)
compares the raw ABS_MT maxima against `tb_dims=(60,2170)` with
TOLERANCE=40: `near(32767,60)=false`, `near(32767,2170)=false`,
`near(127,60)=false`, `near(127,2170)=false` → REJECTS the same device.
The runtime gate compares raw evdev abs maxima (typically 2^n−1) to DRM
framebuffer pixel dims and never scales; `src/providers/sim_input.rs`
explicitly models 32767/127 and scales to 2170/60, but the REAL
provider's gate does not. The unit tests at `input.rs:375-404` only
exercise `geometry_matches_tb` with values already in the 2170/60
neighborhood, so the 32767/127 case was never tested against the real
predicate. The preflight's "Mirrors identify_digitizer" claim is FALSE;
a preflight GO does NOT guarantee a runtime GO. This is a code defect,
not an environment regression. Secondary observation (NOT the blocker):
no `/dev/input` device on this host carries an `ID_SEAT=seat-touchbar`
tag; the libinput seat-touchbar context may not enumerate the digitizer
even after the gate is fixed — flagged for the same ADR.

**Abort recovery executed** (`step8-restore-oracle.txt`):
`systemctl reset-failed tbard.service` → tbard inactive+disabled;
`systemctl start tiny-dfr-mbp142.service` at 15:53:02 → active, sole
master on touchbar card (tgid 105638, uid 65534 — identity by name+uid,
NOT tgid).
- **HC3** (`hc-answers.txt`): human confirmed "I see F keys and it
  toggles to control keys if I press fn key. also is reacting when I
  touch it." Interlock window CLOSED.
- **STEP 9 final state** (`step8-restore-oracle.txt`): oracle
  active+static (sole master); tbard inactive+disabled; FREEZE
  respected (only `docs/test-logs/029/` untracked).

**Stage-3 acceptance items (all 11)** — item 2 (the session-025 blocker)
is now PASSED IN CODE by ADR-039 but NOT reached on hardware this run
(tbard fails earlier at item 10); items 1/3/4/5/7/9/11 NOT reached; item
6 N/A (never acquired); item 8 GO; item 10 is the NEW blocker:

| # | Acceptance | Result | Evidence |
|---|------------|--------|----------|
| 1 | real acquire | NOT reached (failed before acquire) | `step3-first-start.txt` |
| 2 | real privdrop to nobody/65534 | NOT reached on hw (ADR-039 fix in code, untested here — failed before privdrop) | `step3-first-start.txt` |
| 3 | post-drop self-check (real fds incl. digitizer) | NOT reached | — |
| 4 | real render loop — first pixels | NOT reached | — |
| 5 | SIGTERM from running loop → exit 0 | NOT reached | — |
| 6 | RAII master release → card free (debugfs) | N/A (never acquired; debugfs empty = no leak) | `step3-first-start.txt` |
| 7 | immediate rerun acquires cleanly | NOT reached | — |
| 8 | preflight → GO post-stop | **PASS** (GO, exit 0) | `step2-preflight.txt` |
| 9 | backlight writes via held pre-drop fd | NOT reached | — |
| 10 | digitizer identify_digitizer (ABS X 32767 / Y 127) | **FAILED** (runtime geometry gate rejects 32767/127 vs tb_dims 60/2170) | `step3-diagnosis.txt`, `src/providers/input.rs:262-269`, `scripts/bench/interlock-preflight.sh:103-130` |
| 11 | libinput open_restricted post-drop residual | NOT reached | — |

**ADR proposals (for a future branch; NOT implemented on the air):**

- **ADR-041 (proposed): Unify the digitizer geometry gate.**
  `geometry_matches_tb` (`src/providers/input.rs:262`) must accept the
  real iBridge digitizer's ABS_MT maxima (32767/127), either by (a)
  scaling the raw maxima to the DRM mode space before the `near()`
  comparison (mirror `sim_input`'s 32767→2170 / 127→60 scaling), or (b)
  comparing against the raw 2^n−1 ranges the device actually reports,
  with the DRM-mode dims carried separately for layout.
  `interlock-preflight.sh:0d`'s "Mirrors identify_digitizer" claim must
  become true: the preflight must run the SAME predicate the runtime
  runs, so a preflight GO guarantees a runtime GO (the property the
  protocol relies on). Unit tests at `input.rs:375-404` must add a
  32767/127 case against the REAL predicate (not just the sim), to
  close the test gap that let this survive to hardware. Secondary:
  audit whether a udev rule should tag the iBridge digitizer with
  `ID_SEAT=seat-touchbar`, or whether tbard should enumerate by device
  geometry across seats rather than trusting a seat tag (no device on
  this host carries `ID_SEAT=seat-touchbar` today).

**Stage-4 preview: SKIPPED** (precondition not met — STEP 3 aborted
before any running loop; the one-touch observation requires a clean
STEP-4 run window).

**Next session:** after ADR-041 is adjudicated + implemented on a branch
and merged (and the preflight + unit tests extended to truly mirror the
runtime), re-run Stage 3 from P1 in a fresh session. The interlock
protocol itself (P1→HC1→STEP1→STEP2→STEP3) remains valid and reusable
verbatim; only the geometry gate needs to accept the real digitizer.

---

### Stage-3 hardware validation — session 030 (ADR-041 fix, 2026-09-26) — CODE fix, NOT re-verified on hardware

**Result: ADR-041 implemented on `fix/digitizer-identity-adr-041`; the
session-029 blocker is fixed in CODE + read-only probe. NOT re-verified
on hardware this session (sim/sandbox only per the brief). READY FOR
RE-VERIFICATION (a Stage-3 RE-RUN from P1 in a fresh session).**

The session-029 blocker (runtime `geometry_matches_tb` rejected the
real iBridge 32767/127 vs `tb_dims=(60,2170)`; preflight GO, runtime
NO) is fixed by ADR-041 — the structural predicate
`geometry::is_touchbar_digitizer` (multitouch + strip-class +
iBridge-associated + resolution-aspect). The live `--probe-input` run
on this bench (read-only, oracle active) ACCEPTS `/dev/input/event7`
(32767/127, iBridge=true) → exit 0 — the blocker device is now
accepted. See `docs/adr/041-unified-digitizer-identity.md` for the
full D1/D2/D3 derivations + the predicate semantics; `devlog.md`
session 030 for the implementation log; `docs/self-assessment-10.md`
for claims (not verdicts).

**Changes (ADR-041 commit `7836041`):**

- `src/geometry.rs` — new `DigitizerCandidate` +
  `is_touchbar_digitizer` (the structural predicate, single source of
  truth); 12-test accept/reject matrix.
- `src/providers/input.rs` — `geometry_matches_tb` removed;
  `is_digitizer`/`identify_digitizer` build a `DigitizerCandidate` and
  call `geometry::is_touchbar_digitizer`; `read_abs_mt_maxima` →
  `read_abs_mt_info` (resolutions); new `is_ibridge_associated`
  (`ID_SEAT` + `05ac:8600` sysfs ancestry, no name strings); new
  `probe_digitizer` (the `--probe-input` executor).
- `src/main.rs` — `--probe-input` arm (read-only, no DRM/privdrop);
  `Options.probe_input`; mutual exclusion.
- `scripts/bench/interlock-preflight.sh` STEP 0d — rewritten to call
  `/usr/bin/tbard --probe-input`; python EVIOCGABS block removed.
- `scripts/check-invariants.sh` — ADR-041 guards (single predicate;
  no `geometry_matches_tb`; predicate in `geometry.rs`).
- `docs/adr/041-unified-digitizer-identity.md`,
  `docs/adr/040-preflight-environment-inventory.md` — the ADR + the
  ADR-040 STEP 0d binary-backed update.

**ADR-042 status:** NOT triggered. D3 (seat audit) shows our seat
mechanism is identical to the oracle's, which receives touches. The
blocker is the predicate, not the seat.

**Test counts:** 70 unit + 4 integration = 74 total (was 66: 62 unit +
4 integration). Net +8 unit (12 predicate tests in `geometry.rs` − 4
old `geometry_matches_tb` tests in `input.rs` + 1 `probe_input`
assertion in the `Options` test; +1 in `main.rs` tests). Gates: `cargo
fmt --check`, `cargo build --bin tbard`, `cargo clippy --all-targets
-- -D warnings`, `cargo test`, `scripts/check-invariants.sh`,
`scripts/ci-gate.sh`, `bash -n scripts/bench/interlock-preflight.sh`,
`bash -n packaging/PKGBUILD` — all green.

**Live `--probe-input` evidence (read-only, this bench, oracle active):**

```
$ ./target/debug/tbard --probe-input
probe: candidate /dev/input/event7 (sysname=event7) → ABS_MT X max=32767 Y max=127 res=(0,0) iBridge=true
   predicate verdict: ACCEPT
probe-input: digitizer IDENTIFIED (exit 0)
EXIT=0
```

**Stage-3 RE-RUN procedure (for a fresh session):**

1. Merge `fix/digitizer-identity-adr-041` to `master` (or validate on
   the branch).
2. Reinstall `/usr/bin/tbard` from the tip (`makepkg -si` or the manual
   install in `packaging/README.md`).
3. Verify `strings /usr/bin/tbard | grep -c -- --probe-input` ≥ 1 (the
   binary has the probe subcommand — a NEW behavioral check; the
   preflight's 0e checks `--service` but not `--probe-input`; a stale
   pre-ADR-041 binary would fail 0d loudly with "unknown argument
   '--probe-input'", not silently).
4. Run the preflight (`sudo sh scripts/bench/interlock-preflight.sh`);
   STEP 0d now calls `/usr/bin/tbard --probe-input` — the same
   predicate the runtime uses. Preflight GO ⇒ runtime GO is structural.
5. Proceed to STEP 1–3 (stop oracle → start `tbard.service` → observe).
   The ADR-039 privdrop fix is now reachable (the daemon no longer
   fails at identify before privdrop).

**Acceptance items (11) — session 030 did NOT re-run Stage 3; the
items below are the EXPECTED state after a Stage-3 RE-RUN, claims from
reading the code, NOT live-verified this session:**

| # | Acceptance | Expected after RE-RUN | This session |
|---|------------|------------------------|--------------|
| 1 | real acquire | reachable (was failed-before-acquire; now identify passes, acquire is step 3) | NOT run |
| 2 | real privdrop to nobody/65534 | reachable (ADR-039 fix now exercised — was failed-before-privdrop) | NOT run |
| 3 | post-drop self-check (real fds incl. digitizer) | reachable | NOT run |
| 4 | real render loop — first pixels | reachable | NOT run |
| 5 | SIGTERM from running loop → exit 0 | reachable | NOT run |
| 6 | RAII master release → card free (debugfs) | reachable | NOT run |
| 7 | immediate rerun acquires cleanly | reachable | NOT run |
| 8 | preflight → GO post-stop | PASS (STEP 0d binary-backed; probe ACCEPTS event7) | probe-only (read-only) |
| 9 | backlight writes via held pre-drop fd | reachable | NOT run |
| 10 | digitizer identify (ABS X 32767 / Y 127) | **FIXED in CODE** (structural predicate ACCEPTS 32767/127; live probe exit 0) | CODE + probe (DATA) |
| 11 | libinput open_restricted post-drop residual | reachable | NOT run |

**Next session:** a Stage-3 RE-RUN from P1 in a fresh session, on a
host where `/usr/bin/tbard` is reinstalled from this branch's tip.

---

### Stage-3 hardware validation — session 033 (attempt #3, 2026-09-26) — ABORTED at STEP 5 (dark bar); lifecycle contract verified

**Result: ABORTED at STEP 5 (HC2 first pixels = "Dark — no pixels").
Oracle restored; tbard left disabled+inactive (validation run, NOT a
migration). FREEZE respected (HEAD `9ce94af` == `v0.2.3`; `src/`
untouched; only `docs/test-logs/033/` + this docs/test-log commit).
No code fixes on the air.**

This run PROGRESSED PAST both prior abort points (s025 privdrop,
s029 digitizer identify) and verified the lifecycle contract on
hardware end-to-end, including the SUCCESS-path RAII release (the
new evidence this run owed — s025/s029 only showed failure-path
release). First pixels were NOT achieved: the render-to-plane path
succeeded but the backlight was never lit.

The interlock procedure (P1 → HC1 → STEP 1 → … → STEP 9) was
executed verbatim with evidence captured to `docs/test-logs/033/`:

- **P1 baseline** (`p1-baseline.txt`): HEAD `9ce94af` == `v0.2.3`
  (clean except untracked `docs/test-logs/032/tag-identity-proof.txt`
  from prior session — not touched); touchbar card by driver =
  card2/appletbdrm (DRI minor 2, symlink `dri/2 -> 1-3:2.3`);
  debugfs oracle `tiny-dfr-mbp142` (tgid 105638, uid 65534) sole
  master — identity by **name+uid, not tgid** (tgid changed across
  the session: 105638 → 144955 → 146140 → 146352, confirming the
  protocol rule); 18 `/dev/input` nodes;
  `appletb_backlight` 54/255; oracle active+static, tbard
  inactive+disabled. Baseline matches protocol CONTEXT exactly.
- **HC1** (`hc1.txt`): human confirmed **"Confirmed a, b, c"** —
  (a) Esc fallback connected+tested, (b) Esc on the Touch Bar sent
  Esc, (c) `docs/recovery.md` read.
- **STEP 1 — stop oracle** (`step1-oracle-stop.txt`):
  `systemctl stop tiny-dfr-mbp142.service` → inactive and STAYS
  inactive after +10s (explicit stop beats Restart=always). debugfs
  touchbar card EMPTY.
- **STEP 2 — preflight** (`step2-preflight.txt`):
  `sudo sh scripts/bench/interlock-preflight.sh` → **GO (exit 0)**.
  STEP 0 a–f all PASS (0d: `/usr/bin/tbard --probe-input` ACCEPTS
  `/dev/input/event7`, 32767/127, iBridge=true, exit 0). No master
  holder; oracle inactive; tbard inactive+disabled. (The "unknown"
  lines under STEP 3/4 are a shell is-enabled interpolation artifact;
  the real values are the next line — static / disabled. Verdict GO.)
- **STEP 3 — first real start** (`step3-4-first-start-verify.txt` +
  `step3-journal.log`): `systemctl start tbard.service` at 17:51:28Z
  → **active (running)**, `Result=success`, `NRestarts=0`, PID
  144955. The historical 14:08Z (privdrop) and 14:51Z (digitizer
  gate) start-limit episodes in the unit journal are pre-ADR-039/041
  (s025/s029), already cleared — NOT this run's starts. The running
  instance emitted **zero** application log lines (no
  `StandardOutput`/`RUST_LOG` capture; frame counter not observable
  in the journal at default level — inferred from process state).
- **STEP 4 — verify live state** (`step3-4-first-start-verify.txt`):
  - **4a**: debugfs `dri/2/clients` → `tbard 144955 dev 2 master y
    uid 65534` SOLE master; `ps` UID 65534 nobody; `/proc/status`
    Uid/Gid 65534; hyprctl eDP-1 2560×1600@60 dpmsStatus:1
    (desktop/eDP UNAFFECTED).
  - **4b**: `appletb_backlight/brightness` = 0 (baseline 54) —
    CHANGED but in the dark direction; flagged for HC2. (Held fd 23
    → brightness sysfs, w-only.)
  - **4c**: NO `EACCES`/`open_restricted`/permission-denied in all
    tbard journal history (acceptance 11 VERIFIED). Frame counter
    not in journal (no per-frame logs routed at default level);
    render inferred from process state + debugfs framebuffer (see
    STEP 5 diagnosis). No retry-budget exhaustion (`NRestarts=0`).
  - **4d**: `/dev/input` count = 18 (unchanged) — tbard did NOT
    create a uinput virtual device (holds `/dev/uinput` write fd 22
    but no virtual node added; either acceptable per plan —
    recorded: NO uinput device created).
  - **4e**: dmesg delta = none (only brcmfmac wifi noise).
  - FD inventory (25 fds): fd 3 → `/dev/dri/card2` (master); fd 9
    + 21 → `/dev/input/event7` (digitizer, post-drop held —
    ADR-036); fd 22 → `/dev/uinput` (w); fd 23 →
    `.../appletb_backlight/brightness` (w, held, never written —
    mtime unchanged since boot).
- **STEP 5 — HC2** (`step5-hc2.txt`): asked verbatim; human answered
  **"Dark — no pixels"**. Read-only diagnosis (NO code change):
  the render-to-plane path SUCCEEDED — `debugfs dri/2/framebuffer`
  shows `framebuffer[41] allocated by = tbard`, format XR24, size
  64×2170, `vmap_use_count=1` (CPU-mapped); `dri/2/state` shows
  `plane-0 crtc=crtc-0 fb=41 src-pos=60×2170` (CRTC actively
  scanning tbard's buffer — geometry matches the gate's 60/2170).
  `/proc/144955/stack` = `hrtimer_nanosleep` (frame-timer cadence,
  ADR-023; no DRM ioctl blocked — static frame already on plane).
  The bar is dark because the BACKLIGHT is off (brightness=0): tbard
  HOLDS the backlight fd (ADR-015 select works) but the sysfs
  `brightness` mtime is unchanged since boot on BOTH starts —
  **tbard never performs the enable-write.** Single, localized
  defect.
- **STEP 6 — SIGTERM from running loop** (`step6-success-path-release.txt`):
  `systemctl stop tbard.service` → rc=0, `Result=success`,
  `ExecMainStatus=0` (**ADR-025 exit contract VERIFIED from the
  running loop — success path**, contrast with s025/s029
  failure-path status=1). RAII release VERIFIED on success path:
  debugfs `dri/2/clients` EMPTY (master released); `dri/2/framebuffer`
  EMPTY (fb[41] freed); `dri/2/state` `plane-0 crtc=(null) fb=0`
  (plane detached, CRTC disabled). No tbard process. Journal:
  `Deactivated successfully`, 1.039s CPU over 4min 42.7s wall.
- **STEP 7 — immediate rerun** (`step7-rerun.txt`): start →
  acquired sole master (tgid 146140, uid 65534); ~15s run; stop →
  exit 0 (ADR-025 reproducible); release verified (debugfs empty,
  framebuffer empty) — RAII release on success path ×2. Backlight
  bug reproduced (fd held, mtime unchanged, no write).
- **STEP 8 — restore oracle + HC3** (`step8-restore-hc3.txt`):
  `systemctl start tiny-dfr-mbp142.service` → active, sole master
  by name+uid (`tiny-dfr-mbp142` + uid 65534, tgid 146352);
  backlight 54. HC3: human confirmed **"Yes — F-row + Esc works"**.
  Window CLOSED.
- **STEP 9 — final state** (`step9-final-state.txt`): tbard
  inactive+disabled (validation, NOT migration); oracle active+
  static sole master; `/dev/input` 18; backlight 54; eDP
  unaffected; no dmesg anomalies. `reset-failed` returned "not
  loaded" rc=1 — benign (`NRestarts=0`; no failed state to reset;
  historical start-limit episodes pre-this-run, already cleared).

**Stage-3 acceptance items (all 11)** — this run owed items 2, 3, 4,
5, 6-success-path, 7, 9, 10, 11. Status BEFORE this run (from
protocol CONTEXT) and AFTER:

| # | Acceptance | Before this run | After this run | Evidence |
|---|------------|-----------------|----------------|----------|
| 1 | real acquire | pre-verified 6× (s025/s029 bursts) | VERIFIED (clean acquire, sole master) | `step3-4-first-start-verify.txt` |
| 2 | real privdrop to nobody/65534 | fixed in code ADR-039, NOT reached on hw | **VERIFIED** (UID/GID 65534, `/proc/status`; ADR-039 first hw exercise) | `step3-4-first-start-verify.txt` |
| 3 | post-drop self-check (real fds incl. digitizer) | NOT reached | **VERIFIED** (digitizer fd 9+21, uinput 22, backlight 23, DRM 3 all held post-drop by uid 65534; no EACCES) | `step3-4-first-start-verify.txt` |
| 4 | real render loop — first pixels | NOT reached | **NOT MET** (HC2 "Dark — no pixels"; framebuffer on plane but backlight off) | `step5-hc2.txt` |
| 5 | SIGTERM from running loop → exit 0 | NOT reached | **VERIFIED** ×2 (STEP 6 + STEP 7; ADR-025 success path) | `step6-success-path-release.txt`, `step7-rerun.txt` |
| 6 | RAII master release → card free (debugfs) | pre-verified 6× failure-path | **VERIFIED success-path** ×2 (debugfs empty, fb freed, plane detached) | `step6-success-path-release.txt`, `step7-rerun.txt` |
| 7 | immediate rerun acquires cleanly | NOT reached | **VERIFIED** (STEP 7; idempotent re-acquire, exit 0, release) | `step7-rerun.txt` |
| 8 | preflight → GO post-stop | PASS (s029) | **VERIFIED** (GO, exit 0; STEP 0 a–f PASS) | `step2-preflight.txt` |
| 9 | backlight writes via held pre-drop fd | NOT reached | **NOT MET** (fd held ADR-015 select works; NO write performed — sysfs mtime unchanged since boot on both starts) | `step3-4-first-start-verify.txt`, `step5-hc2.txt` |
| 10 | digitizer identify (ABS X 32767 / Y 127) | predicate pre-verified via probe; runtime arm NOT exercised | **VERIFIED in the runtime arm** (event7 held post-drop; ADR-041 first hw exercise beyond probe) | `step3-4-first-start-verify.txt` |
| 11 | libinput open_restricted post-drop residual | NOT reached | **VERIFIED** (zero EACCES/open_restricted/permission-denied in all tbard journal history) | `step3-4-first-start-verify.txt` |

**ADR proposals (for a future branch; NOT implemented on the air):**

- **ADR-043 (proposed): Light the backlight on the render path.**
  tbard's render/init path must perform the enable-write to the
  held backlight brightness fd (raise
  `appletb_backlight/brightness` to non-zero when scanout begins;
  zero/restore on clean exit, coordinated with the oracle so the
  interlock restore relights cleanly). The held fd (ADR-015) is
  necessary but not sufficient — the write must actually happen.
  Audit whether the value-54-read-on-rerun vs 0-on-first-start
  reflects hardware/firmware default behavior (sysfs mtime is the
  reliable write indicator and never moved this session). Add a
  unit/integration test that asserts a non-zero backlight write
  occurs on the render path (the gap that let this survive to
  hardware — analogous to the ADR-041 test gap).

**Stage-4 preview: SKIPPED** (precondition not met — no first
pixels; the one-touch observation requires a clean STEP-4 run
window with the bar lit).

**Next session:** after ADR-043 is adjudicated + implemented on a
branch and merged (and `/usr/bin/tbard` reinstalled from the tip),
re-run Stage 3 from P1 in a fresh session. The interlock protocol
itself remains valid and reusable verbatim; only the backlight
enable-write needs to land. Items 1, 2, 3, 5, 6, 7, 8, 10, 11 are
now live-verified and need not be re-proven; the re-run owes only
items 4 + 9 (first pixels + the backlight write).

### Stage-3 hardware validation — session 037 (attempt #4, 2026-09-26) — ABORTED at STEP 5 (dark bar); root cause isolated to a code-level trait-dispatch defect; lifecycle contract re-verified

**Result: ABORTED at STEP 5 (HC2 first pixels = "Dark / no pixels").
Oracle restored; tbard left disabled+inactive (validation run, NOT a
migration). FREEZE respected (HEAD `ccd7024` == `v0.2.4`; `src/`
untouched; only `docs/test-logs/036/tag-identity-proof.txt` swept +
`docs/test-logs/037/` + this docs/test-log commit). No code fixes on the air.**

This run owed ONLY acceptance items 9 (backlight write — the
two-candidate mechanism's empirical closure) and 4 (first pixels, via
HC2). The other nine items were pre-verified in attempt #3 (s033) and
were NOT re-proven individually this run; the run re-verified the
lifecycle contract en route (real privdrop, post-drop fd retention,
SIGTERM→exit 0, success-path RAII release ×1).

The interlock procedure (P1 → HC1 → STEP 1 → … → STEP 9) was executed
verbatim with evidence captured to `docs/test-logs/037/`:

- **P1 baseline** (`p1-preflight.txt`): HEAD `ccd7024` == `v0.2.4` (clean
  except untracked `docs/test-logs/036/tag-identity-proof.txt` — swept
  into this docs commit); touchbar card by driver = card2/appletbdrm
  (DRI minor 2, `dri/2` and `dri/1-3:2.3` alias paths); debugfs oracle
  `tiny-dfr-mbp142` (tgid 146352, uid 65534) sole master — identity by
  **name+uid, not tgid** (tgid changed across the session: 146352 →
  237628[tbard] → 241900[oracle restored], confirming the protocol
  rule); 25 `/dev/input` nodes; `appletb_backlight` 54/255, mtime
  1790411567 (boot+7s — the oracle's own boot-time D3 write); oracle
  active+static, tbard inactive+disabled. Baseline matches protocol
  CONTEXT exactly.
- **HC1** (`hc1.txt`): human confirmed **"All three confirmed"** —
  (a) Esc fallback connected+tested, (b) Esc on the Touch Bar sent Esc,
  (c) `docs/recovery.md` read.
- **STEP 1 — stop oracle** (`step1-2-stop-oracle-and-preflight.txt`):
  `systemctl stop tiny-dfr-mbp142.service` → inactive and STAYS inactive
  after +10s (explicit stop beats Restart=always). debugfs touchbar card
  EMPTY.
- **STEP 2 — preflight** (`step1-2-stop-oracle-and-preflight.txt`):
  `sudo sh scripts/bench/interlock-preflight.sh` → **GO (exit 0)**. STEP
  0 a–f all PASS (0d: `/usr/bin/tbard --probe-input` ACCEPTS
  `/dev/input/event7`, 32767/127, iBridge=true, exit 0). No master
  holder; oracle inactive; tbard inactive+disabled. (STEP 3 "oracle
  enabled: unknown" is a shell is-enabled interpolation artifact for
  `static` — the real value is `static`, captured in P1; not a NO-GO
  trigger.)
- **STEP 3 — first real start** (`step3-5-start-live-state-hc2.txt`):
  `systemctl start tbard.service` at 20:52:03 → **active (running)**,
  PID 237628, `Result=success`. The running instance emitted **zero**
  application log lines in the journal: `env_logger::init()`
  (`src/main.rs:133`) with no `RUST_LOG` in the service environment
  (`systemctl show tbard.service` → `Environment=` empty) defaults to
  the `error` level, so every success-path `log::info!(...)` line
  (including the ADR-043 enable-write success line) is SUPPRESSED.
  `log::error!` lines WOULD appear — NONE did, and the daemon did not
  restart (`Restart=on-failure` never fired), so no error-path was
  taken. stdout/stderr ARE wired to journald (`/proc/<pid>/fd/{1,2}` →
  `/run/systemd/journal/stdout`, verified via `ss`), so the silence is
  the log-level filter, not a wiring fault.
- **STEP 4 — verify live state** (`step3-5-start-live-state-hc2.txt`):
  - **4a**: debugfs `dri/2/clients` → `tbard 237628 dev 2 master y uid
    65534` SOLE master; `ps` UID 65534 (nobody); eDP UNAFFECTED (card1
    i915 masters unchanged: systemd-logind uid 0 + Hyprland uid 1000).
  - **4b DECISIVE**: `appletb_backlight/brightness` = **0** (EXPECT 128
    if ADR-043 enable-write fired), max 255, mtime 1790411567
    **UNCHANGED from the P1 baseline**. Render-to-plane SUCCEEDED
    (`dri/2/framebuffer`: `framebuffer[41] allocated by = tbard`,
    XR24, 64×2170, refcount 2; `dri/2/state`: plane-0 → fb 41,
    crtc-0 enable=1 active=1, mode 60×2170, connector USB-1) — the
    panel is dark ONLY because backlight=0. tbard HOLDS fd 23 →
    `.../appletb_backlight/brightness` (w-only, opened pre-drop) — the
    ADR-015 deterministic select + pre-drop hold work. **But the
    ADR-043 enable-write of 128 never reached sysfs.** ACCEPTANCE
    ITEM 9 FAILS this run.
  - **4c**: NO `EACCES`/`open_restricted`/permission-denied in the
    journal; no retry-budget exhaustion (acquire succeeded; daemon
    stable). Frame-counter cadence NOT observable (INFO-suppressed).
  - **4d**: `/dev/input` 25 → 25 (no delta; no uinput device created —
    expected for an idle run).
  - **4e**: dmesg delta since start: NONE.
- **STEP 5 — HC2** (`hc2.txt`): human answered **"Dark / no pixels"**.
  Item 4 FAILS this run — NO first pixels. This is the runbook's
  anticipated "STEP 4b sysfs not written + panel dark" branch — a
  DISTINCT, NEW defect class from attempt #3's framing (see defect
  analysis below; do NOT conflate).
- **STEP 6 — SIGTERM from the running loop**
  (`step6-9-sigterm-restore-final.txt`): `systemctl stop tbard.service`
  → `Deactivated successfully`, `ExecMainCode=0`, `ExecMainStatus=0`,
  `Result=success`. debugfs touchbar card EMPTY (RAII Drop released
  master). **Success-path release VERIFIED ×1 this run (×3 total across
  #3 ×2 + #4 ×1).**
- **STEP 7 — immediate rerun**: SKIPPED. Item 9 failed due to a
  DETERMINISTIC code-level defect (ADR-043 enable-write dead-code via
  trait-default dispatch — see below); a rerun cannot change the
  outcome and would only burn StartLimit budget. Deliberate protocol
  call, not an omission.
- **STEP 8 — restore the oracle** (`step6-9-sigterm-restore-final.txt`):
  `systemctl start tiny-dfr-mbp142.service` → active+static, sole
  master on dev 2 (name+uid; tgid 241900). Bar relit (value 0→54,
  framebuffer now allocated by tiny-dfr-mbp142 — D3 evidence).
- **STEP 8 / HC3** (`hc3.txt`): human confirmed **"Both confirmed"** —
  (a) oracle F-row visible, (b) Esc on the bar sends Esc. Window CLOSED.
- **STEP 9 — final state** (`step6-9-sigterm-restore-final.txt`):
  tbard disabled+inactive (validation, NOT migration); oracle active+
  static, sole master; backlight 54 (lit); FREEZE intact (only
  `docs/test-logs/036/` + `docs/test-logs/037/` untracked; no `src/`
  changes).

> **ERRATUM — session 040 (2026-09-26), ADR-044 dispatch audit
> (D-027-1/D-031-1 discipline: annotate, never rewrite).** The
> root-cause analysis below ("ADR-043 enable-write is dead code via
> trait-default dispatch") is **REFUTED by an independent source
> re-read at HEAD `ccd7024` (== `v0.2.4`)**. The trait override IS
> present at `src/providers/backlight.rs:305-307`
> (`fn enable(&mut self) -> anyhow::Result<()> { SysfsBacklight::enable(self).map_err(Into::into) }`),
> landed in the original ADR-043 commit `38392ce` (verified via
> `git show 38392ce -- src/providers/backlight.rs`). The trait-dispatch
> regression test IS present at `src/main.rs:1434`
> (`test_render_path_enable_write_precedes_first_flush_and_update`,
> driving `real_main` generic over `B: BacklightProvider` with
> `RecordingBacklight<MockBacklight>` recording `enable` through the
> trait at `main.rs:1371-1374`). The s037 source analysis cited line
> numbers that do not match HEAD; the "does NOT override `enable()`"
> claim is contradicted by the very file it cites.
>
> **The corrected explanation for the dark bar (closed by ADR-044 V5,
> the enable-propagation check):** s037 observed `Result=success` +
> `ExecMainCode=0` + zero ERROR-level journal lines. Per ADR-025, a
> failing `enable()` on the startup path must propagate `Err` via
> `src/main.rs:547-553` (`return Err(e)`) → `main.rs:478-496`
> (`Ok(Err(e)) => Err(e.into())`) → `main`'s `Result` return → exit
> 1 → `Result=failed`. s037 saw exit 0 + `Result=success`, so
> `enable()` did NOT fail — the enable-write of 128 SUCCEEDED. The
> value=0 / dark / mtime-frozen / journal-empty quartet is consistent
> with: **successful enable-write of 128 → adaptive idle-dim decay
> (s039 S2: 128→1 by ~30s, →0 by ~60s of no touch, mtime FROZEN
> throughout the kernel-side decay) → the STEP 4b value probe read
> AFTER the decay completed → HC2 asked minutes after start**, with
> the ADR-045 INFO-suppression making the success-path enable-write
> line invisible in the journal (so the success was inferable only
> from the absence of ERROR lines, which s037 did not flag as
> exculpatory). **No code defect existed at HEAD `ccd7024`.** The
> dark bar was an observation-timing artifact, not a write failure.
> ADR-044 (audit-only + one guard-hardening test) + ADR-045
> (RUST_LOG=info) + ADR-046 (value-only probe, read within ~1s) are
> the fixes for the OBSERVATION gap, not a code defect. See
> `docs/adr/044-backlight-provider-dispatch-audit.md` for the full
> dispatch-audit table and the adversarial disposable-check evidence.
>
> **Devlog meta-rule (session 040):** live-session root causes are
> CLAIMS, not premises — no ADR may be premised on one without an
> independent source re-read. This is the fourth correction of its
> kind (s025 ordering, s029 acquire, s037 dispatch — see
> `docs/adr/044-...md` §V3).

**DEFECT ANALYSIS — ADR-043 enable-write is dead code (trait-default
dispatch).** Read-only source analysis (NO fix applied — FREEZE on
`src/`):

1. `BacklightProvider::enable()` has a DEFAULT no-op impl returning
   `Ok(())` (`src/providers/mod.rs:120-122`).
2. `SysfsBacklight` has an INHERENT `pub fn enable(&mut self)`
   (`src/providers/backlight.rs:175`) that performs the actual ADR-043
   write (value = `active_brightness.min(max_bl)` = 128, via the held
   fd, with INFO success / ERROR fail-safe logging).
3. `impl BacklightProvider for SysfsBacklight` (`backlight.rs:269`)
   overrides `set_brightness`, `brightness`, `max_brightness`, `update`,
   `notify_activity`, `set_lid_closed` — but does **NOT** override
   `enable()`.
4. The call site `real_main` is generic: `backlight: &mut B where B:
   BacklightProvider` (`main.rs:502-513`). The call `backlight.enable()`
   (`main.rs:547`) dispatches through the TRAIT, so it resolves to the
   trait's DEFAULT no-op — NOT the inherent `SysfsBacklight::enable()`.
   (Rust: inherent methods take priority only on concrete-typed calls,
   not through a generic/trait bound.)
5. Therefore the ADR-043 enable-write NEVER executes. The inherent
   method is dead code. Its unit tests (`backlight.rs:379-508`) call
   `bl.enable()` on a CONCRETE `SysfsBacklight`, so they exercise the
   inherent method and PASS — masking the trait-dispatch gap. The
   integration test at `main.rs:1435` uses a `RecordingBacklight<B>`
   wrapper whose `enable()` forwards to `self.inner.update()` (NOT
   `self.inner.enable()`) — so it also does not catch the missing trait
   override.

Why the panel is dark (the full chain): `SysfsBacklight::new`
(`backlight.rs:88-99`) initializes `current_bl` to the sysfs-read value
at construction = 54 (the oracle's boot-time D3 write). `enable()`
(trait no-op) does NOT write 128 and does NOT update `current_bl` →
`current_bl` stays 54. The render loop calls `backlight.update()` every
10ms (`main.rs:845`); `update()` computes `new_bl` via the adaptive
curve: `display_to_touchbar(acpi_video0.brightness=90,
active_brightness=128)` with `MAX_DISPLAY_BRIGHTNESS=509` →
`sqrt(90/509)*128+1` ≈ 54. `new_bl(≈54) == current_bl(54)` → the
`if current_bl == new_bl { return false; }` gate (`backlight.rs:243`)
makes `update()` a NO-OP — no write. This is EXACTLY the session-033
stale-read coincidence that ADR-043 was designed to break — but
ADR-043's breaker (the unconditional `enable()` write of 128) is dead
code via trait-default dispatch, so the coincidence is unbroken. The
54→0 transition in the sysfs READ value is the appletbdrm driver
resetting the hardware on the oracle's master release (kernel-side, no
userspace write, hence mtime unchanged). tbard then neither wrote 128
(enable no-op) nor corrected the 0 (update gated on stale
`current_bl=54`).

**METHODOLOGY DISCOVERY — the sysfs `brightness` mtime is NOT a reliable
write-probe for appletbdrm.** The oracle's STEP-8 restore write lit the
bar (value 0→54, framebuffer re-allocated by tiny-dfr-mbp142) but the
sysfs `brightness` file mtime STAYED at 1790411567 (boot+7s) —
unchanged across the oracle's write. The appletbdrm `brightness` sysfs
store handler writes through to the USB device and the read returns the
current hardware value, but does NOT touch the sysfs inode mtime.
Implications: (a) the runbook's STEP 4b "mtime moved since boot"
criterion is STRUCTURALLY UNSATISFIABLE on this driver, by EITHER
daemon; (b) the VALUE probe is reliable (tbard's run: value=0 dark;
oracle's restore: value=54 lit); (c) attempt #3's "mtime unchanged
since boot" evidence was consistent with BOTH "no write" AND "write
that didn't move mtime" — the value probe would have been the decisive
test (#3's panel was also dark + value would have read 0, so #3's "no
effective write lit the panel" conclusion stands, but the mtime
reasoning was flawed). For THIS run (#4): the trait-default no-op is
independently confirmed by source analysis, and value=0 throughout
tbard's run corroborates "no write of 128 occurred". Item 9 FAILS on
the VALUE probe alone; the mtime probe is discounted as structurally
invalid for this driver.

**Stage-3 acceptance items (all 11)** — this run owed items 4 + 9 only;
the other nine were pre-verified in s033 and re-verified-in-passing
en route. Status BEFORE this run (from protocol CONTEXT) and AFTER:

| # | Acceptance | Before this run | After this run | Evidence |
|---|------------|-----------------|----------------|----------|
| 1 | real acquire | pre-verified (s033) | VERIFIED (clean acquire, sole master) | `step3-5-start-live-state-hc2.txt` |
| 2 | real privdrop to nobody/65534 | pre-verified (s033) | VERIFIED (UID 65534; debugfs uid=65534) | `step3-5-start-live-state-hc2.txt` |
| 3 | post-drop self-check (real fds incl. digitizer) | pre-verified (s033) | VERIFIED (fds 3/21/22/23 held post-drop by uid 65534; no EACCES; daemon did not exit 1) | `step3-5-start-live-state-hc2.txt` |
| 4 | real render loop — first pixels | NOT MET (s033) | **NOT MET** (HC2 "Dark / no pixels"; framebuffer on plane but backlight=0) | `hc2.txt` |
| 5 | SIGTERM from running loop → exit 0 | pre-verified (s033 ×2) | VERIFIED ×1 (ExecMainCode=0, ExecMainStatus=0, Result=success) | `step6-9-sigterm-restore-final.txt` |
| 6 | RAII master release → card free (debugfs) | pre-verified success-path (s033 ×2) | VERIFIED success-path ×1 (debugfs empty after stop) | `step6-9-sigterm-restore-final.txt` |
| 7 | immediate rerun acquires cleanly | pre-verified (s033) | SKIPPED (deterministic code-level failure; rerun cannot change outcome) | `step6-9-sigterm-restore-final.txt` |
| 8 | preflight → GO post-stop | pre-verified (s033) | VERIFIED (GO, exit 0; STEP 0 a–f PASS) | `step1-2-stop-oracle-and-preflight.txt` |
| 9 | backlight writes via held pre-drop fd | NOT MET (s033) | **NOT MET** (fd 23 held; NO write of 128 — value=0 throughout; ADR-043 enable-write dead-code via trait-default dispatch) | `step3-5-start-live-state-hc2.txt` |
| 10 | digitizer identify (ABS X 32767 / Y 127) | pre-verified in runtime arm (s033) | VERIFIED (fd 21 → event7 held post-drop; preflight probe ACCEPT iBridge=true) | `step3-5-start-live-state-hc2.txt` |
| 11 | libinput open_restricted post-drop residual | pre-verified (s033) | VERIFIED (zero EACCES/open_restricted/permission-denied) | `step3-5-start-live-state-hc2.txt` |

**ADR proposals (for a future branch; NOT implemented on the air):**

- **ADR-044 (proposed): ADR-043 enable-write must override the
  `BacklightProvider` trait method, not add an inherent method.**
  ADR-043 landed `enable()` as an inherent `SysfsBacklight::enable()`
  (`backlight.rs:175`) but the production call site
  (`real_main`, generic over `B: BacklightProvider`, `main.rs:547`)
  dispatches through the trait, whose default `enable()` is a no-op
  (`mod.rs:120`). Fix surface: add
  `fn enable(&mut self) -> anyhow::Result<()> { SysfsBacklight::enable(self) }`
  to `impl BacklightProvider for SysfsBacklight` (`backlight.rs:269`),
  mirroring the existing `update`/`notify_activity`/`set_lid_closed`
  forwarding pattern (`backlight.rs:293-303`). Regression guard: add
  an integration test that calls `backlight.enable()` through a
  `&mut dyn BacklightProvider` (trait object) and asserts the write
  occurred — the current tests call on a concrete type and so miss the
  gap (the same class of test-gap that let ADR-041 survive to
  hardware).
- **ADR-045 (proposed): observable service logging.** Set
  `Environment=RUST_LOG=info` (or a tbard-specific filter) in
  `tbard.service` so the boot sequence + ADR-043 enable-write line are
  observable in the journal on validation runs. The INFO-suppression
  (`env_logger` default = `error` with no `RUST_LOG`) made this run
  partially blind: the defect was inferable only from sysfs + debugfs +
  source, not from the journal. The enable-write success line at INFO
  is the single most important diagnostic for item 9 and it was
  invisible.
- **ADR-046 (proposed): revise the STEP 4b acceptance criterion — drop
  the mtime probe, keep the value probe.** The appletbdrm `brightness`
  sysfs store handler does NOT update the inode mtime on writes (the
  oracle's restore write lit the bar 0→54 without moving mtime). The
  runbook's "value > 0 + mtime moved since boot" criterion is
  structurally unsatisfiable on this driver. Replace with "value > 0
  AND value matches the expected `active_brightness` clamp (128) within
  a tolerance" — the value probe is reliable; the mtime probe is not.
  Re-attempt #3's evidence under the corrected criterion: the value
  under tbard-#3 would have read 0 (dark), so #3's "no effective write"
  conclusion stands, but the mtime reasoning is discounted.

**Stage-4 preview: SKIPPED** (precondition not met — no first pixels;
the one-touch observation requires a clean STEP-4 run window with the
bar lit).

**Next session:** after ADR-044 (the trait-override fix) is adjudicated
+ implemented on a branch and merged (and `/usr/bin/tbard` reinstalled
from the tip), re-run Stage 3 from P1 in a fresh session. The
interlock protocol itself remains valid and reusable verbatim; only the
`enable()` trait-override needs to land (a one-line fix + a trait-object
regression test). Items 1, 2, 3, 5, 6, 7, 8, 10, 11 are now
live-verified and need not be re-proven; the re-run owes only items 4 +
9 (first pixels + the backlight write) — the SAME two items this run
owed, now with a sharp, code-level root cause and a one-line fix
surface. ADR-045 (RUST_LOG=info) and ADR-046 (value-only probe) should
land alongside ADR-044 so the next run is observable and the acceptance
criterion is driver-correct.

---

### Stage-3 attempt #5 — PASS (session 043, 2026-09-27)

**Result: STAGE 3 PASS — first pixels achieved and OBSERVED, full
lifecycle contract verified on hardware.** Full evidence:
`docs/test-logs/043/`. Devlog session 043 + CHANGELOG
`[Unreleased — Stage-3 hardware validation (attempt #5)]`.

On `v0.2.5` (HEAD `d66f3ef` == tag; installed `/usr/bin/tbard` sha
`90daf3d6…`). ADR-043 (enable-write override) + ADR-045 (RUST_LOG=info)
+ ADR-046 (value-only probe) all live in the installed binary/unit.
Preflight GO (STEP 0 a–f PASS, exit 0). The enable-write INFO line
fired at 23:44:15.208 (`backlight enable-write 128 (max 255,
active_brightness 128)`) — the ADR-043 override IS live (the central
doubt from attempt #4 is resolved). tbard ran 54min44s stable as sole
master (uid 65534) of the touchbar card. SIGTERM → exit 0,
success-path RAII release (debugfs empty of tbard after stop; card
passed to the waiting oracle). eDP unaffected; no dmesg delta;
/dev/input unchanged (18 event, no uinput device — render-only).

**Item 4 (first pixels): VERIFIED via HC2.** Human observed tbard's
rendering — "a single bright widget mark on the left side of the
strip" (the auto-added `esc` button, `src/main.rs:1141-1145`),
distinct from the oracle's classic F-row. tbard was sole master at
observation. Lit condition induced by a manual `brightnessctl 50`
write (tbard's adaptive path had decayed to 0 by +20s — see finding
(b)); the pixels are tbard's framebuffer (tbard = sole master + only
renderer). Elapsed since enable-write: ~15 min (outside the ~30s
window; the touch-first branch applied but touch produced no wake —
finding (a)). Photo: `docs/test-logs/043/first-pixels.jpg` (to be
saved by the human).

**Item 9 (backlight write): write path PROVEN, +1s=128 criterion
SUPERSEDED.** The panel's luminance followed tbard's own writes
128→54→0. The strict +1s=128 sysfs value is NOT achievable: the
adaptive loop's first `update()` tick (~10ms after `enable()`)
overwrites 128 with the curve output 54 = `display_to_touchbar(90,
128)` = `(sqrt(90/509)*128)+1` = 54 (math verified on-hardware:
acpi_video0 brightness=90). Coordination defect (finding (b)), not a
write failure — the write PATH is proven (journal line + luminance
tracked tbard's writes).

**NEW findings (FREEZE — ADR proposals, no fixes on the air):**
- **(a) INPUT PATH SILENT** — `backlight.notify_activity()` has ZERO
  call sites in `src/`; the only call (`src/main.rs:839`) targets the
  input provider (intentional no-op, `src/providers/input.rs:522-524`).
  Plus `LibinputProvider::current_bl` stuck at 0 (`:89`, no setter) →
  gate at `src/providers/input.rs:471` drops touches when bar dark.
  Both HC2 symptoms (no tap log, no wake) from ONE root cause.
  Empirically corroborated: non-exclusive evtest on /dev/input/event7
  captured a valid single tap (TRACKING_ID=203, POSITION_X=8319,
  BTN_TOUCH=1/0, SYN-framed) structurally identical to
  `docs/research/corpus/single-tap.evdev` — digitizer hardware works;
  drop is in tbard's code. Tap log IS at `info!` (`src/main.rs:786-794`)
  — NOT a level-filter issue.
- **(b) ENABLE-WRITE CLOBBERED** — 54 is the adaptive
  `display_to_touchbar(90,128)` first-tick target
  (`src/providers/backlight.rs:159-163`, `:233`, `:249`), overwriting
  128 immediately. The dimming curve is a step function: 128 (enable)
  → ~54 (first tick) → 1 (at 30s) → 0 (at 60s), no input resetting
  `last_active` (finding (a)).
- **(c) NO KERNEL AUTO-DIM** — manual `brightnessctl 50` held 10+ min
  with tbard quiet (cache==target → no writes). s039 "kernel-side
  decay" was the oracle's adaptive loop (same `display_to_touchbar`
  curve, `backup_old/tiny-dfr-mbp142/src/backlight.rs:96-101`), NOT a
  kernel-side auto-dim. Erratum against manual §7 + ADR-046:77-87
  (D-027-1 — annotate, never rewrite).

**Interlock discovery (ADR-049 proposed):** the oracle (static +
Restart=) does NOT stay stopped when `systemctl stop` is issued — it
self-restarted during the tbard run and spun in a panic-retry loop
against the busy card (exit 101, restart counter 4). Benign for
validation (tbard held master throughout) but a migration-planning
concern: the oracle must be MASKED or its Restart suppressed during
tbard's run, not just stopped.

**Stage-4 preview: SKIPPED.** Precondition ("no default-page widget
action performs uinput key injection") is FALSE — every default-page
widget is a key-emitting ButtonWidget (`src/main.rs:1004-1039`;
`esc`+F1..F12+Brightness). The HC2 "bright widget mark" is the `esc`
button — touching it WOULD inject Esc if the touch reached the
handler. Safety depended on the input-path defect (finding (a)) —
NOT a safe basis for a preview.

**ADR proposals:** ADR-047 (wire touch → backlight.notify_activity +
fix current_bl==0 gate); ADR-048 (enable-write vs adaptive-loop
coordination / reframe +1s=128 acceptance); ADR-049 (oracle masking
during tbard runs); ADR-044 correction (notify_activity call-site
claim is incorrect); erratum (D-027-1) for manual §7 + ADR-046:77-87.

**Next session:** Stage 4 (touch-logging) is unblocked IN PRINCIPLE
(digitizer hardware proven to produce valid events matching the
corpus), but requires ADR-047 + ADR-048 adjudicated + implemented on
a branch and merged (and `/usr/bin/tbard` reinstalled from the tip)
before re-running. The Stage-4 preview additionally requires a
render-only page config (no key actions) OR explicit acknowledgment
that the default page injects by design — the runbook's "no
injection" criterion cannot be met with the default page. Items 1,
2, 3, 5, 6, 7, 8, 10, 11 remain live-verified and need not be
re-proven.

## Stage 4 — Touch-logging (capture raw touch, no gesture actions) ❌ BLOCKED (session 051 ABORT — F-045-1 recurrence on v0.2.7 shapes-only page; item 3 reconfirmed; item 5 mechanism witnessed LIVE)

**Blocker (original, §2.1)**: digitizer is name-gated; udev seat rules miss
the actual device name on this bench. The digitizer will not be on
`seat-touchbar`, so `LibinputProvider` will never enumerate it, so no touch
events will be logged — the stage would produce a false-negative "touch
works" when in fact nothing was tested. **(NOTE: session 047's STEP 0d
preflight FOUND the digitizer via the ADR-041 structural predicate on
/dev/input/event7 — the §2.1 name-gating blocker is NOT in effect on this
bench; the digitizer IS identified. The blocker that actually tripped
session 047 is F-045-1 below, NOT §2.1.)**

> **Session 047 (2026-09-27) — Stage-4 attempt #1 ABORTED at STEP 5:
> F-045-1.** The ADR-049 `mask --now` interlock held (move-aside variant —
> the oracle's deployed unit lives at /etc, not /usr/lib; F-045-3). The
> ADR-047 wake-wiring was PROVEN on hardware for the first time: a real
> touch at 01:50:40 produced 14 `tbard: touch wake →
> backlight.notify_activity()` INFO lines (F-045-2 — the on-hardware
> wake-path proof). The +1s curve-value probe PASSED (54==54) on both runs;
> the render-only page loaded (no config-fallback WARN); /dev/input was
> UNCHANGED (zero injection, render-only page); the mask interlock held
> (STEP 4f); the lifecycle contract re-verified (SIGTERM → exit 0, debugfs
> release, rerun clean). HOWEVER the bar produced NO visible glow at ANY
> brightness (0/1/54/200/255 via brightnessctl) under tbard in BOTH runs,
> despite bl_power=0, dpms=On, connector enabled, appletbdrm bound, USB
> Config 2, and the sysfs value being accepted (writes read back
> correctly). At STEP 8 the oracle re-acquired master and the bar lit
> IMMEDIATELY ("F-row visible + Esc works") — the SAME sysfs path glows
> under the oracle but not under tbard. This is a backlight-activation
> differential (F-045-1), NOT a render issue (no glow even at 255, pure
> backlight) and NOT a tbard write issue (enable-tick INFO line + +1s
> probe PASS). Hypotheses H1–H4 (read-only): a DRM-side panel-enable
> (DPMS-on / connector set_property / page-flip flag) the oracle performs
> and tbard does not; or a T1/USB init the oracle's startup does and tbard
> omits. ADR-050 candidate. The Stage-4 HC2 (wake-from-dark visible) /
> HC3 (tap log) / HC4 (maintenance) could NOT be evaluated because the bar
> produces no light under tbard. Evidence: `docs/test-logs/045/`. Next
> step (between sessions): read-only diff of the oracle's DRM init/flush
> path vs tbard's `src/providers/drm.rs` + `src/main.rs` render loop.
> Re-run Stage-4 once F-045-1 is resolved — the wake-wiring proof
> (F-045-2), the mask interlock, the lifecycle contract, and the
> zero-injection check are already in hand; only the
> visible-backlight-dependent HC2/HC3/HC4 remain.

> **ADR-047 / ADR-049 / Stage-4 prep (2026-09-27):** the touch path is
> now WIRED (ADR-047: touch → backlight.notify_activity + the gate
> tracks the real level + the digitizer-is-identified self-check). The
> Stage-4 "no gesture actions" preview criterion is met by CONFIG, not
> by accident: a render-only validation page
> (`examples/render-only-validation-page.yaml`) ships with ZERO key
> actions on every widget. **ADR-051 revision (session 048,
> 2026-09-27):** the page is now SHAPES-ONLY — `type: shape` widgets
> (filled rectangles drawn via `ctx.rectangle()` + `ctx.fill()`, NO
> `select_font_face` / `show_text` / `text_extents` — see
> `src/widgets/shape.rs`). The page is visible BY CONSTRUCTION: even
> when cairo's toy text API silently renders nothing on a font failure
> (the confirmed F-045-1 root cause — `docs/test-logs/047-ab/REPORT.md`),
> the shape widgets still glow. The prior all-text page (labels + time
> + spacers) rasterized to all-black on a font miss → bar dark at any
> brightness; the shape widgets remove that failure mode. `tap_action()
> -> None` on every widget (shape widgets have no action field; the
> safety property holds). The default page (auto-added `esc` +
> F1..F12) is UNSAFE for a render-only preview — every default-page
> widget is key-emitting. Install the render-only page as
> `/etc/touchbar/config.yaml` for a Stage-4 run; `/dev/input` stays
> unchanged (STEP 4d count check). ADR-047's wake still fires (a touch
> wakes the bar) but produces NO key. The interlock uses ADR-049's
> `mask --now` (the oracle does not self-restart during the run) — for
> /etc-deployed units, use the F-045-3 move-aside + mask variant (see
> STEP 1 above).

> **ADR-053 (documentation-only, session 048, 2026-09-27):** the
> `TAP_MAX_MS=300ms` threshold (`src/widgets/mod.rs:87`) is the correct
> gesture-classification boundary — NOT a defect. Normal taps in the
> corpus are ~750ms; the threshold requires CRISP taps (<300ms) for a
> Down→Up to classify as `Gesture::Tap` and emit the `tap page=...`
> log line. **Stage-4 caveat:** if a touch exceeds 300ms, NO tap line
> appears and item 3 (tap log) stays blocked on a CRISP re-touch, NOT
> on an input defect. A missing tap line after a touch is NOT evidence
> of a gate failure or input defect — re-touch crisply (<300ms) before
> filing. Session 047's Run A (12 TAP lines) and Run B (5 TAP lines)
> both produced tap lines (both touches were crisp).

> **Idle-decay testability caveat (session 048, 2026-09-27):** the
> idle-decay path (DIM at 30s, OFF at 60s — `dim_timeout_ms` /
> `off_timeout_ms` in `src/config/yaml.rs`) CANNOT be exercised under
> an active operator session: any seat0 pointer event pushes an
> `InputEvent::Activity` (the `src/providers/input.rs` catch-all),
> which resets `last_active` via `backlight.notify_activity()`
> (`src/main.rs`) every ~10ms loop tick. This is CORRECT adaptive
> behavior (the bar follows user activity — the oracle ports the same
> wake at `backup_old/tiny-dfr-mbp142/src/backlight.rs:102-118`), but
> it means the idle-decay schedule is only testable under a
> NO-INPUT/HEADLESS condition. **Stage-4 validation runs must account
> for this:** idle-decay verification (DIM/OFF transitions) requires
> the operator to stop all seat0 input (no mouse movement, no keyboard
> activity) for the full decay window — or scope it to a headless
> condition. This is a testability gap, NOT a defect.

> **Session 051 (2026-09-27) — Stage-4 completion interlock ABORT:
> F-045-1 recurrence on v0.2.7 with the shapes-only page; item 3
> reconfirmed; item 5 mechanism witnessed LIVE (first time).** On
> master at v0.2.7 (`07813f4`; installed `/usr/bin/tbard` sha256
> `18b368c4…`). The ADR-051 shapes-only validation page (zero font
> dependency in the draw path) was deployed as
> `/etc/touchbar/config.yaml` under the Variant B (F-045-3) move-aside
> + mask interlock. The interlock held throughout (oracle
> inactive+masked at +60s, ADR-049 assertion passed, no oracle row in
> debugfs mid-run); the preflight was GO (STEP 0 a–f PASS, 0d:
> `--probe-input` ACCEPTS `/dev/input/event4` — digitizer resolved
> fresh this boot by predicate, shifted from event7 on the prior boot
> as predicted). tbard started cleanly: full boot sequence in the INFO
> journal — privdrop to nobody/65534, DRM scan accepted card2
> (appletbdrm, 60×2170), post-drop fd self-check OK, post-drop
> digitizer-identified self-check OK (ADR-047), backlight enable-tick
> → 54 (exactly the expected `display_to_touchbar(90, 128)` = 54;
> ADR-048 adaptive curve), NO config-fallback WARN (shapes-only page
> loaded cleanly). STEP 4 verified: tbard sole master (uid 65534),
> dri/2 scanout active (fb 41 on plane-0, crtc-0 enable=1 active=1,
> connector USB-1), eDP unaffected, /dev/input unchanged (18, no
> uinput device — render-only page), no dmesg delta, mask held.
>
> **HC2 (WAKE, 11:48:24) — FAIL: F-045-1 recurrence.** Operator: "I
> see no changes when I touch it. touchbar completely dark. and it has
> been dark the whole process." The journal PROVES the touch reached
> tbard (80+ `touch wake → backlight.notify_activity()` INFO lines at
> 11:47:18–11:47:56 — F-045-2 wake-wiring reproducible) and tbard's
> adaptive write re-brightened sysfs to 54, but the panel produced NO
> visible light. Direct `brightnessctl` writes of 255/200/100 all
> read back correctly under tbard's sole mastership — HC2b: "no
> changes" — the bar stays dark at any sysfs brightness under tbard.
> STEP 8 restore confirmed the differential: the same sysfs path
> (value 54) is VISIBLE under the oracle's sole mastership
> (HC-restore: "yes f-row visible"). **ADR-051 (font rasterization)
> is REFUTED as the F-045-1 fix** — the shapes-only page has zero
> font dependency yet the bar was dark under tbard. F-045-1 is a
> DRM-side panel-activation differential (the oracle performs a
> DRM-side panel-enable tbard does not), NOT a content or sysfs-write
> issue. The ADR-051 shapes-only page is STILL the correct validation
> page (it removes the font failure mode and is the right HC target
> per F-13-1) — it just doesn't fix F-045-1, which ADR-051 never
> claimed to fix.
>
> **Item 3 (tap log, reconfirm on the safe page): RECONFIRMED via
> journal evidence this boot** (not the prior-boot 12+5 lines).
> Multiple fresh `tap page=render-only-validation logical=(x,1068)
> hit=None` lines at 11:47:18–11:47:56, x ∈ {0,2,5,6,8,9,14}, y=1068
> (mid-strip), hit=None (shape widgets have no action — zero
> injection, render-only page safe). CRISP taps (<300ms, ADR-053)
> classified as `Gesture::Tap` correctly. Independent of the visible
> panel — the gesture handler ran on real digitizer events.
>
> **Item 5 (config hot-reload, LIVE — the session headline): MECHANISM
> PROVEN, visual confirmation BLOCKED by F-045-1.** FIRST
> live-hardware witness of config hot-reload. HOT-RELOAD TRIPLE:
> (1) edit 2026-09-27T11:51:47+01:00 (single write, first shape fill
> 0.5 → 1.0; sha256 `8e6865f0…` → `587cc3e2…`); (2) reload line
> 2026-09-27T11:51:47+01:00 — `tbard: config reloaded` INFO line, SAME
> SECOND as the edit (ADR-021 debounce holds: one write = one reload
> line, NO storm); (3) visual confirmation N/A — panel dark under
> tbard (F-045-1 recurrence), HC4 visual impossible this session
> (documented limitation, NOT a hot-reload defect). Follow-up finding
> (ADR candidate): after the first reload, the config watcher does NOT
> fire on subsequent writes (edit 2 restored original sha256 — no
> reload; edit 3 a distinct value — no reload; total reload lines =
> 1). The watcher may be one-shot or have a post-reload re-arm bug;
> ADR-021 debounce window length and the inotify re-arm logic need
> audit on a branch.
>
> **Lifecycle contract (STEP 7) — re-verified.** SIGTERM → exit 0 ×2
> (ExecMainStatus=0, Result=success both stops). RAII release ×2:
> debugfs `dri/2/clients` EMPTY after both stops; `plane-0 fb=0`
> (detached). Idempotent rerun: second start acquired sole master
> cleanly (uid 65534). +1s probe on rerun: 54/255 == expected.
>
> **Interlock (Variant B, F-045-3) — clean open + close; sha256
> chain.** Open: oracle unit sha256 `5310c917…` recorded pre-move; cp
> to `.bak`, rm original, `ln -s /dev/null`, daemon-reload, stop →
> inactive+masked; +60s no-restart assertion PASSED. Close: removed
> `/etc/touchbar/config.yaml` (original state: no live config);
> reversed the move-aside; daemon-reload; start → active+static, sole
> master (name+uid); bar relit. sha256 chain: pre
> `5310c917bd8d4cf5f429ae3419ac3339edf9efa7095df16ec1938ac2acc5b047`
> == post `5310c917…` — byte-identical restore verified. `.bak` gone.
> Final state == P1 baseline.
>
> **ADR proposals (for a future branch; NOT implemented on the air):**
> ADR-054 (DRM-side panel-activation — the F-045-1 differential; the
> oracle performs a DRM-side panel-enable tbard does not; next step is
> a read-only diff of the oracle's DRM init/flush path vs tbard's
> `src/providers/drm.rs` + `src/main.rs` render loop); ADR-055
> (config-watcher re-arm after the first reload — the watcher does not
> re-fire on subsequent writes; audit the inotify re-arm / debounce
> coalescer on a branch, add a TWO-edits-TWO-reloads regression test).
> Evidence: `docs/test-logs/051/`. devlog: session 051.
>
> **Stage-4 acceptance board after session 051:**
>
> | # | Item | Verdict | Evidence |
> |---|------|---------|----------|
> | 1 | wake (visible, on the safe page) | **FAIL (F-045-1 recurrence)** — touch wake FIRED (journal), sysfs re-brightened to 54, but panel produced NO visible light at any brightness under tbard | s051 `HC2-and-evidence.txt`, `HC2b-and-item3.txt`, `F045-1-recurrence-diagnostic.txt`, `HC-restore.txt` |
> | 2 | (closed prior) | PASS | s047/AB |
> | 3 | tap log (reconfirm on safe page) | **RECONFIRMED** — multiple fresh `tap page=render-only-validation logical=(x,1068) hit=None` lines this boot; CRISP <300ms taps classified correctly; hit=None (zero injection) | s051 `HC2-and-evidence.txt`, `HC2b-and-item3.txt` |
> | 4 | (closed prior) | PASS | s047/AB |
> | 5 | config hot-reload (LIVE) | **MECHANISM PROVEN** (first live-hardware reload witnessed: edit 11:51:47 → reload line 11:51:47, ADR-021 debounce holds, no storm); **visual confirmation BLOCKED by F-045-1** (HC4 N/A — panel dark); follow-up finding: watcher does not re-fire after the first reload (ADR-055) | s051 `STEP6-hot-reload-edit.txt`, `STEP6-hot-reload-journal.txt`, `STEP6-summary.txt`, `STEP6-edit2-investigation.txt`, `STEP6-edit3.txt` |
> | 6 | (closed prior) | PASS | s047/AB |
> | 7 | (closed prior) | PASS | s047/AB |
>
> Items 1 (visible) and 5 (visual confirmation of hot-reload) remain
> blocked by F-045-1 — a pre-existing DRM panel-activation
> differential, NOT a content/write/hot-reload defect. Item 3 is
> reconfirmed. Item 5's mechanism is proven live. **Next session:**
> after ADR-054 (the F-045-1 DRM-side panel-activation fix) is
> adjudicated + implemented on a branch and merged (and `/usr/bin/tbard`
> reinstalled from the tip), re-run Stage 4 from P1 in a fresh session
> with the shapes-only page. ADR-055 (config-watcher re-arm) should
> land alongside it so the second-edit regression is closed. The
> interlock protocol itself remains valid and reusable verbatim.

### Intended commands (do NOT run until unblocked)
```bash
# ADR-049: mask the oracle (static + Restart=always self-restarts
# under explicit stop — session 043).
sudo systemctl mask --now tiny-dfr-mbp142.service
systemctl is-active tiny-dfr-mbp142.service   # inactive
systemctl is-enabled tiny-dfr-mbp142.service  # masked
sleep 60 && systemctl is-active tiny-dfr-mbp142.service  # still inactive (ADR-049 assertion)

# ADR-047/048/Stage-4 prep + ADR-051: install the render-only validation
# page (SHAPES-ONLY — `type: shape` widgets, ZERO key actions, visible
# BY CONSTRUCTION — no font dependency in the draw path). See
# examples/render-only-validation-page.yaml.
sudo cp examples/render-only-validation-page.yaml /etc/touchbar/config.yaml

# Run with input enabled + the render-only page (NO key emission).
sudo -E RUST_LOG=tbard=info ./target/release/tbard --service 2>&1 | tee $SESS/stage-4-touch.log
# Touch the bar in 3 known positions; watch the log for:
#   tbard: touch wake → backlight.notify_activity()  (ADR-047 wake)
#   tbard: tap page=... logical=(x,y) hit=...         (ADR-020 tap log)
# /dev/input count UNCHANGED (no uinput device — render-only page).

# Restore: stop tbard, restore the operator's config, unmask + start the oracle.
# (For /etc-deployed oracle units, use the F-045-3 move-aside restore variant
# — see STEP 5 above; verify byte-identical via sha256.)
sudo systemctl stop tbard.service
sudo rm -f /etc/touchbar/config.yaml   # (or restore the operator's config)
sudo systemctl unmask tiny-dfr-mbp142.service
sudo systemctl start tiny-dfr-mbp142.service
```
### Intended pass criteria
- Touching the bar produces `InputEvent::Touch` log lines with sane
  coordinates (x ∈ [0,2170], y ∈ [0,60]).
- The ADR-047 wake line `tbard: touch wake → backlight.notify_activity()`
  fires on every touch (the bar wakes from dark on touch).
- No spurious key emissions (no `emit_keys` lines — the render-only
  page's widgets have `action: []`).
- `/dev/input` count UNCHANGED during the run (STEP 4d — no uinput
  device created; the render-only page produces no key events).
- ADR-049 mid-run assertion: `sudo cat /sys/kernel/debug/dri/<N>/clients
  | grep -i tiny-dfr` → no output (the oracle is masked, no row).
### Abort criteria
- No touch events after 10 s of touching → kill, file an issue (digitizer
  not enumerated — check seat assignment and `is_digitizer`; ADR-047's
  digitizer-is-identified self-check should have caught this at startup).
- `dmesg` shows `hid-multitouch` errors → kill, file.
- An oracle row appears in debugfs mid-run → the mask failed or was
  reversed; abort (ADR-049).

---

## Stage 5 — Interaction (full gesture + key emission) ❌ BLOCKED

**Blocker**: all of §2.1–2.6. Depends on Stages 3 and 4 passing.
### Intended commands (do NOT run until unblocked)
```bash
sudo -E RUST_LOG=tbard=debug ./target/release/tbard 2>&1 | tee $SESS/stage-5-interact.log
# Tap each F-key button; verify the corresponding key event appears via `evtest /dev/input/eventX`
# (the uinput virtual device "Touch Bar Virtual Input Device").
```
### Pass criteria
- Each tap emits the correct `Key::F1`..`Key::F12` (and `Esc` on the
  auto-added esc button).
- A horizontal swipe on a slider updates `self.value` and the rendered fill.
- FN double-press swaps pages (if `double_press_switch_layers_ms > 0`).
### Abort criteria
- Wrong key emitted, or no key emitted on a tap → file an issue.
- Daemon panics (any `unwrap` in `emit_keys`/render) → kill, file.

---

## Stage 6 — IPC / web mirror ❌ BLOCKED

**Blocker**: §2.7 — `IpcServer` is not instantiated by `main`; the Unix
socket is never created. WebSocket is not implemented (Phase 3).
### Intended commands (do NOT run until unblocked)
```bash
# After wiring IpcServer into main:
socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/touchbar/engine.sock | tee $SESS/stage-6-ipc.log
# Send: {"type":"set_pages","pages":[{"id":"t","widgets":[{"type":"button","label":"X","action":["F1"]}]}]}
# Send: {"type":"get_state"}
```
### Pass criteria
- Socket file mode is `0600` (`ls -l $XDG_RUNTIME_DIR/touchbar/engine.sock`).
- `set_pages` changes the rendered bar; `get_state` returns a `state` reply.
- Only the owning user can connect (another user gets EACCES).
### Abort criteria
- Socket mode ≠ 0600 → file an issue (security).
- Another user can connect → file a security issue.

---

## Stage 7 — Endurance ❌ BLOCKED

**Blocker**: §2.3 (no clean shutdown, no flush-stall cap on count),
§2.6 (idle-to-0 + silent write failure). A long run could silently leave the
bar dark or leak DRM resources.
### Intended commands (do NOT run until unblocked)
```bash
# Same Stage-3 interlock preconditions apply: STOP THE ORACLE, RESOLVE THE
# TOUCH BAR CARD BY DRIVER (appletbdrm; card numbers are UNSTABLE across
# boots — see docs/test-logs/010-bench-incident/), VERIFY NO MASTER HOLDER
# via `sudo cat /sys/kernel/debug/dri/<N>/clients`, then run ours; RESTORE
# THE ORACLE afterward.
sudo systemctl stop tiny-dfr-mbp142.service
TBARD_CARD_N=$(ls -l /sys/class/drm/card*/device/driver | grep appletbdrm | grep -oE 'card[0-9]+' | head -1)
sudo cat /sys/kernel/debug/dri/${TBARD_CARD_N#card}/clients  # expect no master holder
sudo -E RUST_LOG=tbard=info ./target/release/tbard 2>&1 | tee $SESS/stage-7-endurance.log &
PID=$!
sleep 3600   # 1 hour
kill -TERM $PID
wait $PID
# Capture: dmesg tail, DRM resource leak check (resolved N), socket cleanup.
sudo systemctl start tiny-dfr-mbp142.service
```
### Pass criteria
- 1 hour continuous run, no panic, no stall storm (≤ N stall warnings).
- Clean exit on SIGTERM within 2 s; no leaked dumb buffer / framebuffer
  (check `cat /sys/kernel/debug/dri/<N>/state` for the **driver-resolved**
  Touch Bar card N — do NOT assume `dri/0`; card numbers are UNSTABLE across
  boots, see `docs/test-logs/010-bench-incident/`).
- Touch Bar still responsive at end of run.
- The oracle is restored (`tiny-dfr-mbp142.service` active) and the bar is
  lit at the end of the stage.
### Abort criteria
- Any panic, any `dmesg` `appletbdrm` error, any stall storm (≥ 10 stalls)
  → kill, **restore the oracle** (`sudo systemctl start
  tiny-dfr-mbp142.service`), file an issue.

---

## On-abort procedure (all stages)

1. **Stop the daemon**: `kill -TERM <pid>`; if no exit in 5 s, `kill -9`.
2. **Restore the oracle** (bounded test interlock ends — do NOT leave the
   bar dark): `sudo systemctl start tiny-dfr-mbp142.service`. This applies
   to any stage that stopped the oracle as part of the Stage-3 interlock
   (Stages 3, 5, 7).
3. **Capture**:
   ```bash
   journalctl -b -0 -k --since "10 min ago" | tee $SESS/abort-journalctl.log
   dmesg -T | tail -200 | tee $SESS/abort-dmesg.log
   cp $SESS/tbard-stdout.log $SESS/abort-tbard-stdout.log
   cp $SESS/tbard-stderr.log $SESS/abort-tbard-stderr.log
   ```
4. **Do not edit code.** File `docs/test-logs/NNN-issue-M.md` with repro,
   evidence, root-cause hypothesis, affected surface.
5. **Recovery**: see `docs/recovery.md`.

---

## Unblocking procedure

1. For each FAIL in `docs/review-report.md`, write `docs/adr/NNN-*.md` with
   root cause + impact + fix design.
2. Implement fixes on a branch (never on the frozen trunk during a session).
3. Re-run `cargo fmt --check`, `cargo clippy --all-targets`,
   `cargo test`; require fmt exit 0, clippy exit 0, test all green.
4. Re-run this review; update `docs/review-report.md` verdicts.
5. Only then advance the relevant stage from BLOCKED to CLEARED.

---

## Seat-gated test execution paths (ADR-010, ADR-013)

Two tests require DRM master access on a vkms card and therefore depend on
the *session class* in which `cargo test` runs:

- `test_sim_display_acquires_vkms` — acquires master on a vkms card.
- `test_sigterm_releases_master` — spawns `tbard --dry-run`, which acquires
  vkms master, sends SIGTERM, and asserts a second master acquisition
  succeeds (master was released).

Both **passed in the fix/sim-harness-adr-011-015 session** (this shell had
vkms master access on `card2`; BUG A was fixed by ADR-011 so the daemon
reaches the render loop). In other session classes they may skip with a
verbatim-stderr message (ADR-013: no guessing). To EXECUTE them when they
skip, use one of these two paths:

### Path (a) — graphical session after releasing card2 from Hyprland

Hyprland holds `/dev/dri/card2` (vkms) RW. Set Hyprland's
`AQ_DRM_DEVICES` to the i915 by-path device so Hyprland releases card2,
then run the tests in the graphical session:

```sh
# In the Hyprland session, before starting Hyprland (or via its config):
export AQ_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card   # i915 only
# restart Hyprland (or re-login), then:
cargo test -- --nocaptured test_sim_display_acquires_vkms test_sigterm_releases_master
```

### Path (b) — prebuilt binaries under sudo (production-faithful)

Per ADR-010's root-acquire model, run the prebuilt test binary under sudo
(so the process has the master-acquire privilege the production service
will have via root-start + privdrop):

```sh
cargo build  # prebuild
sudo target/debug/deps/tbard-<hash> test_sim_display_acquires_vkms \
    test_sigterm_releases_master -- --nocaptured
# or, since the tests spawn target/debug/tbard:
sudo target/debug/tbard --dry-run &  # smoke
sudo cargo test -- --nocaptured test_sim_display_acquires_vkms \
    test_sigterm_releases_master
```

Either path is acceptable. The tests tell the truth either way: they
`panic!` (REGRESSION) if the daemon panics at startup, skip with verbatim
EACCES stderr if master is denied, or PASS if master is acquired +
released.

### Hermetic smoke (no privilege needed)

```sh
HOME=$(mktemp -d) RUST_LOG=info cargo run -- --dry-run
# → frames render (vkms dirtyfb returns ENOSYS — a vkms limitation, not
#   our bug; the render path executes fully), Ctrl+C clean exit,
#   immediate rerun OK (master released by RAII Drop).
```