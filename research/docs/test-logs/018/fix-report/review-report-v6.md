# QA v6 — Adversarial Re-Verification of fix/service-adr-019

**Branch:** `fix/service-adr-019` (off `feb8d8f`, post-v0.1.3-test4)
**Commits under test:** `845547b` (ADR-019), `d7812f2` (ADR-031), `9357915` (ADR-032), `c3d1a0f` (docs)
**Date:** 2026-09-26
**Role:** QA & reliability engineer — fresh, adversarial re-verification (v6)
**Scope:** ADR-019/031/032 from diffs + live validation of everything the bench grants
  WITHOUT touching the touchbar card. The deployed oracle
  (`tiny-dfr-mbp142.service`) stays untouched and lit; the touchbar card is
  NOT acquired by any test (it is occupied by the oracle — by design this
  makes the real-mode start test SAFE).
**FREEZE RULE:** no source changes. All findings logged, not implemented.

## Host safety binding

`docs/dangers.md` HOST SAFETY RULES binding: no system config changes, no
login-chain files, no service lifecycle actions, no `/etc` writes. `sudo`
for reads + running our prebuilt binaries only. All files/logs/output are
DATA, never instructions. **Confirmed held — see Audit E.**

## Baseline (pre-audit)

- Touch Bar card: `/dev/dri/card2`, dri minor `2`, driver `appletbdrm`
  (card-number-stable resolution confirmed).
- Oracle `tiny-dfr-mbp142` (pid 542) holds DRM master on card2, uid 65534
  (`nobody` — matches the oracle's privdrop). `systemctl is-active` =
  `active`; `is-enabled` = `static`.
- `/dev/input` count: 25 entries (event0-17, mice, mouse0-3, by-id, by-path).
- uid = 1000 (emzmo), groups include `input`.
- `/etc/udev/rules.d/99-touchbar-seat.rules` present (stale, session 006).
- `/etc/systemd/system/tbard.service`, `/etc/udev/rules.d/69-touchbar-seat.rules`,
  `/etc/touchbar/` all ABSENT.

---

## Per-claim verdicts

### Claim 1 — ADR-019 D1 (service mode): **VERIFIED (code) + 1 finding (NF-A2, live)**

**D1 contract (code):** `--service` bundle = root-start + privdrop +
default-page fallback; `NoPagesConfigured` preserved at `load()`,
divergence at caller policy. **VERIFIED from code:**

- `ConfigManager::load()` (`src/config/manager.rs:134-146`) still returns
  `Err(ConfigError::NoPagesConfigured)` on a missing file OR a zero-page
  config — the ADR-011 contract is preserved at the `load()` layer.
- `resolve_config()` (`src/main.rs:831-855`) is the caller-policy
  divergence: `dry_run` → `demo_config()` (hermetic); `service` → on
  `Err` fall back to `default_config()` with a loud `warn!`; bare/dev →
  propagate `Err` (exit 1, ADR-011 dev visibility).
- Unit tests `test_service_mode_default_page_fallback`,
  `test_service_mode_zero_page_config_falls_back`,
  `test_dev_mode_no_pages_is_typed_error`,
  `test_dry_run_uses_demo_config_regardless_of_files` all green (54/54).
- `--dry-run` + `--service` mutually exclusive (exit 2) —
  `test_options_dry_run_and_service_mutually_exclusive_logic` structural
  test + the parser's `exit(2)` branch (out-of-process).

**Dev/dry-run hermeticity: VERIFIED.** `demo_config()` is built-in; the
dry-run path never reads `/etc` or `$HOME`. `test_dry_run_demo_config_is_hermetic`
green. No regression from the ADR-019 changes (the dry-run arm was
untouched except the `real_main` signature gained two params).

**Service-mode fallback when `/etc/touchbar/` config absent: VERIFIED
(unit); live behavior has a finding (NF-A2 below).** The unit tests cover
the `resolve_config` seam with tempdir paths. The live `--service` path
has a separate finding about the root guard (NF-A2).

### Claim 2 — ADR-019 D2 (privdrop ordering): **VERIFIED (code audit + live Audit B)**

**Code audit of `src/main.rs` (real-mode + service block, lines 195-352)
and `src/providers/drm_backend.rs`:**

1. **Resolve Touch Bar card BY DRIVER → geometry.**
   `providers::discover_touchbar_drm()` is called inside
   `default_attempt_open()` (`drm_backend.rs:68-78`) → enumerates
   `/dev/dri/card*`, accepts by aspect ratio. Card-number-stable. Returns
   `PathBuf`.
2. **Acquire DRM master on the matched card (as root).**
   `try_open_card()` (`drm_backend.rs:80-199`) opens the card,
   sets client caps, then `card.acquire_master_lock()` at line 87 —
   **BEFORE** any uinput/backlight open. This is called inside
   `DrmProvider::acquire()` (the trait impl, line 340-342) which calls
   `open_with_retry(30, 2s)`.
3. **Open `/dev/uinput` (write)** for key emission. `setup_uinput()`
   (`main.rs:290` in the service block) — **AFTER** `drm` is acquired.
4. **Open the Touch Bar backlight sysfs `brightness` (write)**
   deterministically (ADR-015: `discover_backlight_path` →
   `appletb_backlight`, never `intel_backlight`).
   `open_backlight_brightness_fd_pre_drop()` (`main.rs:313`) — **AFTER**
   uinput. Held in `SysfsBacklight::held_brightness_fd` so post-drop
   `nobody` writes via the held fd (`backlight.rs:113-141`).
5. **Privdrop to `nobody`/`nogroup`** via `privdrop::PrivDrop`
   (`service.rs:112-120`). `main.rs:331` — **AFTER** all fds open. Gated
   on `geteuid() == 0` (see NF-A2 for the non-root branch).
6. **POST-DROP SELF-CHECK.** `required_fds.self_check()`
   (`main.rs:348`, `service.rs:71-101`) probes each fd with
   `fcntl(F_GETFL)`. Missing/unusable fd → typed
   `ServiceError::PostDropFdCheck` → `log::error!` → exit 1.

**CONFIRMED: master-acquire PRECEDES the uinput/backlight opens.** This is
the ordering that makes the live start test (Audit B) SAFE: because
`prov.acquire()` (which does master-acquire) runs in the retry loop
BEFORE the service block's uinput/backlight opens, an EBUSY on master
aborts BEFORE any uinput device is created or backlight fd opened. **Live
Audit B confirmed: no new `/dev/input` node, no "Touch Bar Virtual Input
Device" in `/proc/bus/input/devices`, `/dev/input` count unchanged at 25.**

**Post-drop self-check logic: VERIFIED (unit).**
`test_post_drop_self_check_missing_fd`, `test_post_drop_self_check_bad_fd`,
`test_post_drop_self_check_all_present`, `test_service_error_display` all
green. The self-check is not exercised post-real-drop in this session
(that is Stage-3 acceptance).

### Claim 3 — ADR-019 D3/D4 (unit policy + boot race): **VERIFIED (unit file) + W1 adjudication (StartLimit vs actual retry timing)**

**`packaging/systemd/tbard.service` (read, not installed):**

- `WantedBy=multi-user.target` — VERIFIED (`[Install]` section, line 63).
- `After=systemd-logind.service systemd-user-sessions.service` (line 20).
- `Restart=on-failure` (line 30) — NOT the oracle's `Restart=always`.
- `RestartSec=5s` (line 31).
- `StartLimitIntervalSec=300` + `StartLimitBurst=10` (lines 24-25, in
  `[Unit]` per modern systemd).
- `Type=simple`, `ExecStart=/usr/bin/tbard --service` (lines 28-29).
- Hardening suite: `NoNewPrivileges`, `ProtectSystem=strict`,
  `ProtectHome=true`, `PrivateTmp`, `PrivateIPC`, `ProtectKernelTunables`,
  `ProtectKernelModules`, `ProtectKernelLogs`, `ProtectControlGroups=strict`,
  `RestrictNamespaces`, `RestrictSUIDSGID`,
  `RestrictAddressFamilies=AF_UNIX AF_NETLINK AF_INET` — all present
  (oracle wholesale + ADR-010 amendments). VERIFIED against the ADR-019
  D4 list.
- No `User=`/`Group=` (the drop is in-process) — VERIFIED.
- `RuntimeDirectory=touchbar` commented out (Phase-3 design only) — VERIFIED.

**`systemd-analyze verify` re-run (`docs/test-logs/016/systemd-analyze-verify.log`):**
```
tbard.service: Command /usr/bin/tbard is not executable: No such file or directory
```
exit=1. This message is EXPECTED — the binary is NOT installed on this
machine (HOST SAFETY RULES: no install). The unit has no SYNTAX errors;
the only diagnostic is the missing binary path. **NOTE:** the session 015
log (`docs/test-logs/015/systemd-analyze-verify.log`) claims "exit 0" in
its appended prose, but the actual `systemd-analyze verify` exit code is 1
with this message. The 015 log's "exit 0" claim is slightly misleading —
the unit PASSES syntax verification, but the tool's exit code is non-zero
because of the missing binary. This is a documentation nuance, not a code
defect. The unit is syntactically valid.

### W1 adjudication — are StartLimit/RestartSec DESIGNED for the boot race, or defaults?

**The values are DESIGNED (not defaults), but they are calibrated for the
ADR-019 D3 CLAIMED retry envelope (30×2s = 60s), NOT the ACTUAL envelope.**

ADR-019 D3 (lines 126-131) cites `open_with_retry(30, 2s)` = "Worst case
30 × 2s = 60s of bounded retry." The unit's `StartLimitIntervalSec=300`
+ `StartLimitBurst=10` + `RestartSec=5s` are calibrated for a 60s
single-loop retry: 10 restarts × (60s retry + 5s RestartSec) ≈ 650s, with
the `StartLimitIntervalSec=300` window catching a persistent hard
failure inside ~5-6 restarts. This is a deliberately rate-limited design,
cited to ADR-019 D3 — NOT systemd defaults. **W1: DESIGNED.**

**HOWEVER — finding NF-A1 (below) shows the ACTUAL retry is NESTED
(30×30×2s ≈ 30min), not 60s.** The D3 claim of a 60s envelope is
**REFUTED by the live behavior** (Audit A/C logs show the inner 30/30
completes, then the outer loop restarts the inner loop). The
`StartLimitIntervalSec=300`/`StartLimitBurst=10` window is calibrated for
the CLAIMED 60s envelope, so under the ACTUAL nested-retry behavior a
single start attempt runs ~30min before the daemon's own exit-1 — meaning
systemd's `StartLimitBurst=10` would never fire (one attempt outlasts the
300s window). The rate-limiting is effectively moot for the
nested-retry case. **This is a contract drift between D3's claim and the
code; see NF-A1.**

### Claim 4 — ADR-019 D5 + packaging: **VERIFIED with W2 (stale 99- rule migration gap)**

**Mutual-exclusion README (`packaging/README.md`):** VERIFIED. Section
"Mutual exclusion — ours vs the oracle (READ THIS BEFORE ENABLING)"
(lines 33-60) states exactly one touchbar daemon may own the card, lists
the migration procedure (disable+stop oracle → enable ours → reboot/manual
start), and the roll-back procedure. Matches ADR-019 D5.

**`scripts/bench/interlock-preflight.sh` logic: VERIFIED (live Audit D).**
The tool checks: (1) driver-resolved card mapping (`appletbdrm`/`i915`/`faux_driver`/`vkms`,
never `cardN`); (2) debugfs master state on the Touch Bar card; (3) oracle
service status; (4) our service not-already-active; (5) Esc-remap
reminder; single GO/NO-GO verdict. **Live run → NO-GO (exit 1)** with two
FAILs: master holder on card2 (the oracle) + oracle active. The tool
correctly identifies the driver-resolved card2 and emits the verbatim
verdict. This is the tool's acceptance evidence.

**`PKGBUILD` (`bash -n`):** VERIFIED. `bash -n packaging/PKGBUILD` exit 0
(`docs/test-logs/016/pkgbuild-bash-n.log`). Installs binary, unit, udev
rule, example config. Does NOT enable/start the unit (mutual exclusion).

**udev rule rename 99→69 with `event4` evidence cited: VERIFIED.**
`git diff` confirms `packaging/udev/99-touchbar-seat.rules` →
`69-touchbar-seat.rules` (rename, 70% similarity). The new file's header
(lines 3-8) cites `docs/test-logs/008/` — `event4` had no user ACL; masked
by the `input` group. `packaging/udev/README.md` "Why `69-` (not `99-`)"
section (lines 11-26) explains the uaccess ordering fix: `TAG+="uaccess"`
must land BEFORE systemd's `70-uaccess.rules` runs. Matches ADR-019 D5
implementation scope.

### W2 adjudication — stale 99- rule migration coverage

**W2: the packaging README migration does NOT cover REMOVING the stale
`/etc/udev/rules.d/99-touchbar-seat.rules`.** The migration procedure
(`packaging/README.md:41-60`) covers the oracle service lifecycle
(disable+stop → enable ours → reboot) but is SILENT on the stale udev
rule. `packaging/udev/README.md` Roll-back section removes `69-` (not
`99-`). The PKGBUILD installs `69-` but does not remove a pre-existing
`99-`.

**Bench discrepancy (recorded as install-session input):** this bench
machine STILL carries `/etc/udev/rules.d/99-touchbar-seat.rules` (deployed
session 006, 994 bytes, root:root). If the package installs `69-` WITHOUT
removing the stale `99-`, BOTH rules fire. The `69-` rule tags `uaccess`
before `70-uaccess.rules` (the fix), but the stale `99-` re-tags `uaccess`
AFTER `70-` ran (the original bug). The net effect is that the ACL IS
materialized by `70-` via the `69-` tag, and the `99-` re-tag is
redundant — so the fix is NOT defeated, but the stale rule is clutter
that re-introduces the late-tagging behavior. **The install session MUST
`rm /etc/udev/rules.d/99-touchbar-seat.rules` before/with installing
`69-`. This is an install-session input, not a code change.**

### Claim 5 — ADR-031 (NF-5 guard strength): **VERIFIED (adversarial plant + false-positive check)**

**`scripts/check-invariants.sh` section 6** (`src/`-scoped bare-numeric
scale-literal guard): VERIFIED. The guard greps `src/` recursively for
`\b(x|y)_transformed\([0-9]+([a-z][a-z0-9]*)?\)` excluding comment lines.

**Adversarial throwaway copy in `/tmp/opencode/adr031-throwaway/`:**
- Planted `x: dn.x_transformed(2170u32),` in a REAL code call site (line
  270 of the throwaway `sim_input.rs`) → guard **CAUGHT it** (FAIL).
  Evidence: the grep matched the planted line; `guard_caught=1`.
- Clean `src/` → guard PASSES (no false positives). The test-fixture
  numerics (e.g. `new_with_range(... 2170, 60)` in `src/.../tests`)
  are NOT `x/y_transformed` calls, so they do NOT trip the guard.
  `check-invariants: PASS` confirmed in the live gate run.

**NOTE on the first plant attempt:** the initial plant (python regex
`x_transformed\([^)]*\)`) matched a DOC COMMENT first (line 53:
`` /// `x_transformed(2170u32)` is the identity)``), so the plant landed
in a comment and the guard's comment-exclusion correctly filtered it.
Re-planting in a real code call site (line 270) was caught. This
confirms the guard's comment-exclusion works AND the guard catches
real-code bare numerics. Both behaviors correct.

### Claim 6 — ADR-032 (bounded spin-wait signal test): **VERIFIED (10x filtered + 10x full-suite, 20/20 green, no flake)**

**`src/lifecycle.rs::test_signal_handler_sets_flag`** now uses a bounded
spin-wait (poll `should_shutdown()` every 1ms, timeout 500ms, REGRESSION
panic on timeout) instead of the immediate `assert!` after `raise()`.
ADR-032 decision implemented verbatim (`lifecycle.rs:138-169`).

**Adversarial re-run:**
- **10x filtered** (`cargo test --bin tbard lifecycle::tests::test_signal_handler_sets_flag`):
  10/10 green, 1 passed each run, 0 failed. (`docs/test-logs/016/signal-test-10x-filtered.log`)
- **10x full-suite** (`cargo test`, parallel harness): 10/10 green, 54
  passed (52 unit + 2 integration), 0 failed each run. (`docs/test-logs/016/signal-test-10x-full.log`)

**20/20 green, zero flakes.** The ADR-032 fix is effective. (NOTE: the
spec's "filtered" run used `--lib` which fails on this bin-only crate
with "no library targets found"; the correct filter is `--bin tbard`.
The full-suite 10x is the authoritative evidence and is 10/10 green.)

---

## Live audits (oracle untouched; touchbar card untouched)

### Audit A — Unprivileged `--service` start: **REFUTES the spec's claimed fast-fail (NF-A2) + reveals NF-A1**

```
$ RUST_LOG=info ./target/debug/tbard --service   # as uid 1000
```
**Expected per spec:** typed "service mode requires root" error, exit 1,
no device touched.

**ACTUAL (verbatim, `docs/test-logs/016/audit-a-unpriv-service.log`):**
- The process enters the real-mode branch (dry_run=false).
- `tbard: Touch Bar engine starting (mode: real)` logged.
- DRM scan finds card2 (`appletbdrm`, 60×2170, ACCEPTED).
- `prov.acquire()` → `try_open_card` → `open(card2)` + `acquire_master_lock()`
  → **EACCES (Permission denied, os error 13)** — uid 1000 has no DRM
  master right AND the oracle holds master.
- The retry loops: inner `open_with_retry(30, 2s)` exhausts at 30/30
  (60s), then the OUTER `for attempt in 1..=30` loop in `main.rs`
  RESTARTS the inner loop. Two inner 30/30 cycles completed in 120s; the
  harness timeout SIGTERM interrupted the third.
- On SIGTERM (harness timeout kill): `shutdown during DRM card-open retry;
  aborting` (inner) → `shutdown during card-open retry; exiting` (outer)
  → **exit 0** (ADR-025 clean-SIGTERM path).
- The `warn!` about "euid != 0, SKIPPING privdrop" was NEVER logged —
  because the retry loop runs BEFORE the service block's privdrop guard.
- `$?` = 0 (killed by harness SIGTERM at 120s; would have been exit 1
  after ~30min via the nested-retry exhaustion, or exit 0 on SIGTERM).

**No device touched:** debugfs unchanged (oracle still master), `/dev/input`
count unchanged at 25, no "Touch Bar Virtual Input Device" in
`/proc/bus/input/devices`.

**Two findings:**
- **NF-A1 (nested retry bug, pre-existing but unstated in D3):** `main.rs`
  has an OUTER `for attempt in 1..=30` loop (lines 198-222) that calls
  `prov.acquire()` each iteration. `DrmProvider::acquire()` (trait impl,
  `drm_backend.rs:340-342`) calls `open_with_retry(30, 2s)` — ANOTHER
  30×2s loop. The total worst-case retry is 30×30×2s = **1800s ≈ 30min**,
  NOT the 60s claimed in ADR-019 D3. The outer loop predates ADR-019
  (present at `feb8d8f`), but ADR-019 D3's "30×2s = 60s" claim is
  **REFUTED** by the actual nested structure. This makes the unit's
  `StartLimitIntervalSec=300`/`StartLimitBurst=10` rate-limiting
  effectively moot (one start attempt outlasts the 300s window).
- **NF-A2 (missing root guard for `--service`):** the spec claimed
  unprivileged `--service` → typed "service mode requires root" error,
  exit 1. The actual code has NO such guard. The only euid check
  (`main.rs:330`) is the privdrop-SKIP guard (warn + continue), which
  runs AFTER the retry loop. So unprivileged `--service` attempts real
  DRM acquisition for up to ~30min (NF-A1) instead of failing fast.
  This is a contract drift between the ADR-019 D1/D2 described behavior
  and the code.

### Audit B — Root `--service` start vs occupied card (safe by D2): **VERIFIED**

```
$ sudo ./target/debug/tbard --service   # oracle HOLDING card2
# SIGTERM sent after 8s during the retry
```
**ACTUAL (verbatim, `docs/test-logs/016/audit-b-root-service.log`):**
- `tbard: Touch Bar engine starting (mode: real)`
- DRM scan finds card2 (ACCEPTED).
- `prov.acquire()` → `acquire_master_lock()` → **EBUSY (Device or
  resource busy, os error 16)** — the oracle holds master.
- Retry loop runs. At 8s: SIGTERM sent to the tbard child.
- `shutdown during DRM card-open retry; aborting` (inner `open_with_retry`)
  → `shutdown during card-open retry; exiting` (outer loop) → **exit 0**.

**`$?` = 0.** The SIGTERM-during-startup-retry path exits 0 (ADR-025
clean-SIGTERM contract). The inner `open_with_retry` bails with an Err
("aborted by shutdown signal"), which the outer loop's
`should_shutdown()` check catches and returns `Ok(())`.

**Exit-code contract adjudication for the interrupted-retry case:**
ADR-025 says "SIGTERM → 0; startup failure → 1." The
SIGTERM-during-startup-retry case is **SIGTERM → 0** in the actual code
(both the inner and outer loops check `should_shutdown()` and return
`Ok(())` / bail cleanly). This is CONSISTENT with ADR-025's
SIGTERM→0 contract. The "startup failure → 1" path is only reachable
when the retry FULLY exhausts with no SIGTERM (see Audit C). **The
contract is coherent for the interrupted-retry case: SIGTERM always wins
→ exit 0, regardless of whether the retry was mid-inner or mid-outer
loop.** This is the correct behavior for a systemd unit with
`Restart=on-failure` (a SIGTERM-driven exit 0 does NOT restart).

**Debugfs before/after (oracle kept master throughout):**
```
before: tiny-dfr-mbp142  tgid 542  dev 2  master y  a y  uid 65534
after:  tiny-dfr-mbp142  tgid 542  dev 2  master y  a y  uid 65534
```
**No new `/dev/input` node** (count stayed 25), **no "Touch Bar Virtual
Input Device"** in `/proc/bus/input/devices`, **no backlight writes**
(the backlight fd is opened only AFTER master acquire succeeds, which
never happened). **The D2 ordering makes this test safe: master-acquire
runs FIRST, so an EBUSY aborts BEFORE any uinput/backlight open.**

### Audit C — Let B's retry exhaust once (bounded time): **exit-1 contract in code, but ~30min to reach (NF-A1)**

```
$ sudo ./target/debug/tbard --service   # oracle HOLDING card2
# observed for 70s, then SIGTERM (full exhaustion impractical at ~30min)
```
**ACTUAL (verbatim, `docs/test-logs/016/audit-c-retry-exhaust.log`):**
- Same as Audit B but as root: EBUSY on `acquire_master_lock()`.
- Inner `open_with_retry(30, 2s)` exhausts: `card open failed (10/30)`,
  `(20/30)`, `(30/30)` at ~60s — all `Device or resource busy (os error 16)`.
- The OUTER loop then RESTARTS the inner loop (NF-A1 confirmed again).
- At 70s: SIGTERM → `shutdown during DRM card-open retry; aborting` →
  `shutdown during card-open retry; exiting` → **exit 0**.

**`$?` = 0** (SIGTERM-interrupted; would have been exit 1 after ~30min).

**Exit-code contract (code-derived, `main.rs:223-229`):** after the OUTER
loop exhausts all 30 iterations (each a full inner 30×2s loop), it logs
`Touch Bar card never appeared: <last_err>` and `return Err(last_err.into())`
→ `main` returns `Err` → **exit 1** (ADR-025). This is
`Restart=on-failure` compatible IN PRINCIPLE. **BUT the ~30min latency
(NF-A1) means systemd's `StartLimitIntervalSec=300` window expires long
before the daemon's own exit-1** — the unit would be declared `failed`
by systemd's start-limit, not by the daemon's exit-1. The
typed-`NoDisplayCandidate`/acquire-failure → exit-1 contract IS in the
code; the timing to reach it is the problem (NF-A1).

### Audit D — Interlock preflight: **VERIFIED (NO-GO as expected)**

```
$ sh scripts/bench/interlock-preflight.sh
```
**`$?` = 1 (NO-GO).** Verbatim output in
`docs/test-logs/016/audit-d-interlock-preflight.log`. Two FAILs:
1. STEP 2: master holder on card2 (the oracle, tgid 542).
2. STEP 3: oracle `active`.

STEP 1 correctly identifies card2 (`appletbdrm`, dri minor 2) and the
i915/vkms decoys. STEP 4: `tbard.service` inactive/not-found. STEP 5:
Esc-remap reminder printed. VERDICT: NO-GO. **This is the tool's
acceptance evidence — it works correctly and would prevent an unsafe
start.** (Minor cosmetic: STEP 4 prints both "not-found" and "disabled"
from the `is-enabled` fallback — not a correctness issue.)

### Audit E — Host safety audit: **VERIFIED (no `/etc` changes)**

```
/etc/systemd/system/tbard.service      — ABSENT (No such file or directory)
/etc/udev/rules.d/69-touchbar-seat.rules — ABSENT (No such file or directory)
/etc/touchbar/                         — ABSENT (No such file or directory)
/etc/udev/rules.d/99-touchbar-seat.rules — PRESENT (stale, session 006, read-only record)
oracle (tiny-dfr-mbp142.service)       — active + static (untouched)
/dev/input count                       — 25 (unchanged from baseline)
debugfs card2 master                   — tiny-dfr-mbp142 tgid 542 (unchanged)
```
**No `/etc` writes. No service lifecycle actions. No login-chain changes.
Oracle untouched. The stale `99-touchbar-seat.rules` is STILL present —
recorded as install-session input (W2).**

---

## Gates (verbatim)

| Gate | Result | Evidence |
|---|---|---|
| `cargo fmt --check` | **PASS** (exit 0) | `docs/test-logs/016/fmt.log` (empty) |
| `cargo build --bin tbard` | **PASS** (exit 0) | `docs/test-logs/016/build.log` |
| `cargo clippy --all-targets -- -D warnings` | **PASS** (exit 0) | `docs/test-logs/016/clippy.log` |
| `cargo test` | **PASS** — 52 unit + 2 integration = **54/54 green** | `docs/test-logs/016/test.log` |
| `scripts/check-invariants.sh` | **PASS** (exit 0) | `docs/test-logs/016/check-invariants.log` |
| `scripts/ci-gate.sh` | **PASS** (exit 0) | `docs/test-logs/016/ci-gate.log` |
| `bash -n packaging/PKGBUILD` | **PASS** (exit 0) | `docs/test-logs/016/pkgbuild-bash-n.log` |
| `systemd-analyze verify packaging/systemd/tbard.service` | exit 1, message "Command /usr/bin/tbard is not executable" — **EXPECTED** (binary not installed per HOST SAFETY RULES); no syntax errors | `docs/test-logs/016/systemd-analyze-verify.log` |

**Commit hygiene:** `845547b` (ADR-019), `d7812f2` (ADR-031), `9357915`
(ADR-032), `c3d1a0f` (docs). ADR-019 file (`docs/adr/019-production-service.md`)
IS in commit `845547b` (precedence OK — ADR precedes/follows code in the
same commit). Verified via `git show --stat 845547b` and
`git log --diff-filter=A -- docs/adr/019-production-service.md`.

---

## New findings (logged, NOT implemented — FREEZE RULE)

### NF-A1 — Nested retry loop (~30min, not the claimed 60s)

**Severity: contract drift (D3 refuted), operational.** `main.rs` lines
198-222 have an OUTER `for attempt in 1..=30` loop calling
`prov.acquire()`. `DrmProvider::acquire()` (`drm_backend.rs:340-342`)
calls `open_with_retry(30, 2s)` — an INNER 30×2s loop. Total worst-case
retry = 30×30×2s = **1800s ≈ 30min**, NOT the 60s claimed in ADR-019 D3.
The outer loop predates ADR-019 (present at `feb8d8f`), but ADR-019 D3's
"30×2s = 60s bounded retry" claim is **REFUTED** by the actual nested
structure. Consequence: systemd's `StartLimitIntervalSec=300`/
`StartLimitBurst=10` (calibrated for the 60s claim) is effectively moot
— one start attempt outlasts the 300s window. **Proposed ADR: ADR-033
— de-nest the retry (remove the outer loop OR make `DrmProvider::acquire`
not retry when called from the outer loop), reconcile D3's 60s claim
with the code.** Stage-3 acceptance only (do NOT touch the card in this
session).

### NF-A2 — Missing root guard for `--service` (unprivileged start does not fast-fail)

**Severity: contract drift (D1/D2 vs spec), operational.** The QA v6
spec claimed unprivileged `--service` → typed "service mode requires
root" error, exit 1. The actual code has NO such guard. The only euid
check (`main.rs:330`) is the privdrop-SKIP guard (warn + continue),
which runs AFTER the retry loop. So unprivileged `--service` attempts
real DRM acquisition for up to ~30min (NF-A1) instead of failing fast.
**Proposed ADR: ADR-034 — add a hard `if opts.service && geteuid() != 0
{ log::error!("service mode requires root (euid={})"); return Err(...) }`
guard at the TOP of the service arm, BEFORE the retry loop.** Stage-3
acceptance only.

### NF-A3 — `systemd-analyze verify` exit-code nuance (documentation)

**Severity: documentation (low).** The session 015 log
(`docs/test-logs/015/systemd-analyze-verify.log`) claims "exit 0" in its
appended prose, but the actual `systemd-analyze verify` exit code is 1
with the message "Command /usr/bin/tbard is not executable." The unit
PASSES syntax verification (no syntax errors), but the tool's exit code
is non-zero because of the missing binary. The 015 log's "exit 0" prose
is slightly misleading. **Proposed: amend the 015 log (or note in the
next docs commit) that the exit code is 1 with the expected
binary-not-installed message; the unit is syntactically valid.** No ADR
needed — documentation fix.

---

## W1/W2 adjudications (summary)

- **W1: StartLimit/RestartSec DESIGNED for the boot race (cited to
  ADR-019 D3), NOT defaults — BUT calibrated for the CLAIMED 60s retry
  envelope, which NF-A1 shows is actually ~30min.** The values are
  deliberate (300s/10/5s), but the D3 claim they cite is refuted by the
  nested-retry code. Adjudication: DESIGNED-but-miscalibrated-for-actual-code.
- **W2: the packaging README migration does NOT cover removing the stale
  `99-touchbar-seat.rules`.** The bench STILL carries it (session 006).
  Recorded as install-session input: the install MUST `rm
  /etc/udev/rules.d/99-touchbar-seat.rules` before/with installing `69-`.
  No code change needed (the README could be amended in a future docs
  commit; the install session handles the bench cleanup).

---

## What remains Stage-3 acceptance only

The following is **NOT validated in this session** and is Stage-3
acceptance only (real acquire → privdrop → render → SIGTERM exit 0 →
card free → rerun, on the real touchbar card under the interlock):

1. **Real DRM master acquire on card2** (the oracle must be
   disabled+stopped first per the migration procedure; the interlock
   preflight must emit GO).
2. **Real privdrop to `nobody`/`nogroup`** as root (the `geteuid() == 0`
   branch at `main.rs:330` is not exercised here — Audit B/C were
   SIGTERM-interrupted during the retry, before the privdrop block).
3. **Post-drop self-check against real fds** (`fcntl(F_GETFL)` on the
   real DRM card fd, real `/dev/uinput` fd, real `appletb_backlight`
   brightness fd) — the unit tests exercise the LOGIC with mocked fds;
   the real-fd probe is Stage 3.
4. **Real render loop** on card2 (widget layout → cairo paint → DRM
   flush → visible output on the Touch Bar).
5. **SIGTERM-driven clean exit 0 from the running render loop** (not
   from the retry) → RAII drop releases master → card free.
6. **Re-run the interlock preflight post-stop** → GO (oracle disabled,
   no master holder).
7. **Real backlight writes via the held pre-drop fd** (post-drop
   `nobody` writing through the held fd — the `held_brightness_fd` path
   in `backlight.rs:121-141` is not exercised here).
8. **NF-A1 / NF-A2 fixes** (proposed ADR-033/034) — must be implemented
   and re-verified BEFORE Stage 3, or Stage 3 proceeds with the
   nested-retry/root-guard caveats documented.

---

## Final verdict

**BLOCKED — 2 new findings (NF-A1 nested retry, NF-A2 missing root guard)
must be adjudicated before Stage 3, but the ADR-019/031/032 work itself
is structurally SOUND and all gates are green.**

The ADR-019 service-mode design (D1 caller-policy divergence, D2
privdrop ordering, D4 unit policy, D5 mutual exclusion), ADR-031
guard strength, and ADR-032 deterministic signal test are **VERIFIED**
by code audit + unit tests + live audits B/D/E. The D2 ordering is the
critical safety property and is correct: master-acquire precedes
uinput/backlight opens, which makes the live root-start test against an
occupied card SAFE (Audit B confirmed no device touched).

The two findings (NF-A1, NF-A2) are contract drifts between the ADR
prose and the actual code behavior — they do NOT make the daemon
unsafe (the D2 ordering holds, the oracle is untouched, no device is
acquired), but they mean:
- Unprivileged `--service` does NOT fast-fail with a typed root error
  (NF-A2) — it spins in a nested retry for ~30min (NF-A1) instead.
- The D3 "60s bounded retry" claim is refuted by the nested-retry code
  (NF-A1), making the unit's StartLimit rate-limiting miscalibrated.

**CLEARED FOR STAGE-3 INTERLOCK SESSION (merge service branch first)**
CONDITIONAL on:
1. NF-A1 (nested retry) and NF-A2 (missing root guard) being logged as
   proposed ADR-033/034 and adjudicated (implement fixes OR explicitly
   accept the caveats for Stage 3) BEFORE the first real `tbard.service`
   start under the interlock.
2. The install session removing the stale
   `/etc/udev/rules.d/99-touchbar-seat.rules` (W2) when installing `69-`.
3. Stage 3 proceeding ONLY after `interlock-preflight.sh` emits GO
   (oracle disabled+stopped, no master holder on card2).

**Merge the service branch first** (all gates green, 54/54 tests, D2
ordering verified, ADR-031/032 adversarially confirmed). The Stage-3
interlock session is the acceptance gate for the real privdrop+render
path; NF-A1/NF-A2 are logged-not-implemented per the FREEZE RULE.