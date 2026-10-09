# QA Re-Verification v7 — fix/deploy-hardening-adr-036-038 (focused)

## Scope & method

- **Branch:** `fix/deploy-hardening-adr-036-038` (off `f853a65`, tag
  `v0.2.0`; HEAD at review time `3f174c2`).
- **Scope:** ADR-036 (digitizer fd pre-drop), ADR-037 (seat/uaccess
  adjudication), ADR-038 (install integrity / PKGBUILD), and the
  session-021 rebuild CLAIM.
- **FREEZE RULE honored:** no source changes by this review. Findings
  only. The deployed oracle (`tiny-dfr-mbp142.service`) was NOT touched
  (lit, sole master throughout). No service lifecycle actions. No `/etc`
  writes this session.
- **Method:** re-derive from diffs + run gates + live audits on the
  bench. Verbatim evidence below.

---

## Per-claim verdicts

### Claim 1 — ADR-036: digitizer fd pre-drop + self_check coverage + identify as PRE-DROP geometry probe + W8

**RE-DERIVATION (from `git show 6377ad8` + current source).**

- `RequiredFds` gains `digitizer: Option<RawFd>`
  (`src/service.rs:84`, `service.rs:99` in `self_check`). The
  `self_check` loop now probes 4 fds: drm → uinput → backlight →
  **digitizer** (`src/service.rs:95-100`). ✅ Coverage added.
- `identify_digitizer` is a PRE-DROP geometry probe
  (`src/providers/input.rs:137-192`). It opens the evdev node
  read-only with `OpenOptions::new().read(true).custom_flags(O_CLOEXEC).open(&evdev)`
  (`src/providers/input.rs:157-160`) and issues `EVIOCGABS` via
  `read_abs_mt_maxima` (`input.rs:224-254`). It is invoked from
  `LibinputProvider::init()` (`input.rs:282`), which is called from
  `main.rs:247` — BEFORE the privdrop at `main.rs:371`. ✅ Pre-drop.
- The probe HOLDS the evdev fd in `LibinputProvider::digitizer_evdev_fd`
  (`input.rs:66`, `input.rs:178`) for the daemon's lifetime. `poll()`'s
  `is_digitizer` (`input.rs:99-114`) calls `read_abs_mt_maxima` with
  `held_fd = Some(self.digitizer_evdev_fd.as_raw_fd())` (`input.rs:109`)
  → **reuses the held fd, NO post-drop open in `poll()`**. ✅
- The libinput-held seat-touchbar context fd is recorded into
  `required_fds.digitizer = Some(input.seat_touchbar_raw_fd())`
  (`main.rs:338`) BEFORE the privdrop (`main.rs:371`); `self_check`
  runs after the drop (`main.rs:380`). ✅

**W8 — grep-audit `open(` calls reachable after `privdrop_to_nobody()`
(`src/main.rs:371`).**

Reachable `open(`/`OpenOptions::new().open` sites in source:

| site | reachable post-drop? | why |
| --- | --- | --- |
| `src/providers/input.rs:37-41` (`open_restricted`, libinput callback) | libinput may call it on a late device-add in `poll()`, but `poll()`'s `dispatch()` (`input.rs:289-290`) is the only entry post-drop; the seat-touchbar context already enumerated pre-drop via `init()`. **Risk surface, not a guaranteed call.** A new device appearing post-drop would invoke `open_restricted` as `nobody` (EACCES) — libinput swallows it and the device is skipped. This is the pre-existing libinput open callback; ADR-036 does NOT remove it (it cannot, libinput owns it). |
| `src/providers/input.rs:157-160` (`identify_digitizer` probe) | NO — `identify_digitizer` runs only from `init()` (`input.rs:282`), called PRE-drop at `main.rs:247`. Not reachable post-drop. ✅ |
| `src/providers/input.rs:237-240` (in-line open in `read_abs_mt_maxima` when `held_fd` is `None`) | In service mode `held_fd` is always `Some` (the held probe fd), so this `None` branch is NOT taken post-drop. In bare-dev / dry-run there is no privdrop, so the branch is harmless there. ✅ |
| `src/main.rs:746-748` (`setup_uinput` opens `/dev/uinput`) | In service mode `uinput_preopened` is `Some` at `main.rs:444`, so `setup_uinput()` is NOT called post-drop in service. Only bare-dev reaches it (no privdrop). ✅ |
| `src/main.rs:807-809` (`open_backlight_brightness_fd_pre_drop`) | Called PRE-drop at `main.rs:345`. Not reachable post-drop. ✅ |

**W8 verdict: NO `open(`/`OpenOptions::new().open` call is REACHABLE in
the service-mode POST-DROP path that would open a NEW device node.**
The libinput `open_restricted` callback (`input.rs:37`) remains the
one theoretical post-drop opener, but it is owned by libinput and is
only invoked on a NEW device-add event; for the already-enumerated
seat-touchbar digitizer the held fd is reused. This is a residual
surface (note below), not a regression introduced by ADR-036. The
added ADR-036 code (the `identify_digitizer` probe open + the
`held_fd` reuse path) is correctly pre-drop / held-fd only.

**Wiring order in `main.rs` service arm (CLAIM vs CODE).**

- CLAIM order: card acquire → uinput → backlight → digitizer identify → privdrop → self_check.
- CODE order (cited):
  1. `prov.acquire()` (DRM card) — `main.rs:220`
  2. `input.init()` → `identify_digitizer()` (evdev fd opened + held) — `main.rs:247`, `input.rs:282`
  3. `setup_uinput()` (uinput fd) — `main.rs:313`
  4. `required_fds.digitizer = Some(input.seat_touchbar_raw_fd())` — `main.rs:338`
  5. `open_backlight_brightness_fd_pre_drop()` (backlight fd) — `main.rs:345`
  6. `privdrop_to_nobody()` — `main.rs:371`
  7. `required_fds.self_check()` — `main.rs:380`

**Finding F1 (cosmetic / claim-text mismatch, NOT a defect):** the
actual wiring order is card → **digitizer identify** → uinput →
digitizer-fd-record → backlight → privdrop → self_check. The CLAIM's
"uinput → backlight → digitizer identify" ordering is wrong vs the
code. The CODE order is correct and safe: every required fd is opened
and recorded before the privdrop, and `self_check` runs after the
drop. The mismatch is in the CLAIM's description, not the
implementation. Logged as a finding; no source change (FREEZE RULE).

**ADR-036 VERDICT: CONFIRMED.** The digitizer fd is opened + identified
pre-drop, held for the daemon's lifetime, reused by `poll()`'s
`is_digitizer`, added to `RequiredFds` + `self_check`, and recorded
before the privdrop. F1 (claim wording) and the residual libinput
`open_restricted` surface are the only notes.

### Claim 2 — W7: mode isolation + hermetic tests

- **`--dry-run` is 100% sim.** `main.rs:139-191` constructs
  `SimDisplayProvider` + `SimInputProvider`; NO `LibinputProvider`, NO
  privdrop, NO `RequiredFds`. ✅ (code-confirmed).
- **Run evidence (Audit B below):** unprivileged `/usr/bin/tbard
  --dry-run` → exit 1 in 0.007s with `Permission denied (os error 13)`
  (EACCES class) from `SimDisplayProvider::acquire` — the sim path
  fails FAST on a permission-denied vkms acquire, bounded well under
  any retry budget. No real-device probe. ✅
- **Bare dev mode's digitizer probe is READ-ONLY** (code):
  `identify_digitizer` opens with `.read(true)` only
  (`input.rs:157-160`), issues `EVIOCGABS` (read ioctl), no writes. ✅
- **Reachable by the unprivileged user (input group):** `id` shows
  `emzmo` is in group `input` (gid 992). The Touch Bar digitizer is
  group-owned `input` (`group::rw-`, per ADR-037 / session-020
  evidence), so the read-only probe is reachable by `emzmo` without
  root. ✅
- **Audit C (real-digitizer read-only probe): UNVERIFIABLE-ON-BENCH.**
  Bare `tbard` (no flags) on this bench never reaches
  `input.init()`/`identify_digitizer`: it enters the DRM-card retry
  (oracle holds master on card2 → EACCES on master acquire), SIGTERM
  aborts after the retry budget, exit 124 from `timeout`. No geometry
  probe ran, no evdev open, no writes, no master change. The bench
  cannot exercise the read-only digitizer probe while the oracle is
  lit (HOST SAFETY RULES forbid stopping it). **Stage-3 acceptance
  only.**
- **Hermeticity of the 59 tests — Finding F2 (pre-existing, NOT
  introduced by ADR-036/037/038):** two unit tests DO touch real
  kernel devices:
  - `test_sim_input_creates_uinput_device` (`src/providers/sim_input.rs:309-337`)
    opens `/dev/uinput` and creates a real uinput device. It
    self-skips (eprintln + return) on failure, so it does not FAIL
    the suite, but it is NOT strictly hermetic.
  - `test_sim_display_acquires_vkms` (`src/providers/sim_display.rs`)
    opens a real vkms DRM card and acquires master (the test name
    says so).
  These are pre-existing (ADR-005 sim design) and self-skip when the
  device is unavailable, so the suite passes (59/59). They are not
  hermetic in the strict "no test opens real devices" sense the CLAIM
  asserts. The CLAIM's "59 tests stay hermetic (no test opens real
  devices)" is REFUTED as literally stated; the suite is
  **hermetic-in-result** (passes regardless of device availability)
  via self-skip, not hermetic-in-mechanism. This is a finding for an
  ADR proposal, not a merge blocker.

**W7 VERDICT: CONFIRMED for mode isolation (dry-run is pure sim; bare
dev probe is read-only + reachable by input-group). PARTIALLY
REFUTED for the strict hermeticity claim (F2).** F2 is pre-existing
and does not block this branch.

### Claim 3 — ADR-037: rule diff = ONLY the dead-uaccess annotation; ID_SEAT intact; README trade-off table; root+privdrop not reopened; W6

- **Repo rule vs session-020-installed rule diff.**
  - `git diff d8ec215 29c9b5d -- packaging/udev/69-touchbar-seat.rules`:
    the ONLY change is the addition of a 29-line comment block
    annotating the `TAG+="uaccess"` line as dead under NF-020-A. The
    two functional lines (`ENV{ID_SEAT}="seat-touchbar"` and
    `TAG+="uaccess"`) are byte-identical to session-020. ✅
  - `ID_SEAT=seat-touchbar` INTACT — the isolation is preserved. ✅
  - No other rule changes (VID:PID match, file name, ordering all
    unchanged). ✅
- **README trade-off table:** the table is in
  `docs/adr/037-seat-uaccess-adjudication.md` (D1, lines 72-77, Options
  A/B/C/D). `packaging/README.md` does NOT contain a markdown table;
  it documents the dead-tag status + production path + dev-access
  alternatives in prose (lines 11-22, 90-123). The CLAIM says "README
  trade-off table present" — **Finding F3 (wording): the trade-off
  TABLE is in the ADR, not in `packaging/README.md`; the README has
  the equivalent content in prose.** Substantive content present in
  both; the CLAIM's "table in README" is imprecise. No blocker.
- **Root+privdrop recipe NOT reopened:** ADR-037 D2 + D3 + the README
  explicitly state the production path is root-open + privdrop
  (ADR-010 + ADR-036), and the recipe is NOT reopened. ✅
- **W6 — deployment delta (repo rule ≠ installed rule) recorded as a
  merge-session input.** The INSTALLED rule
  (`/usr/lib/udev/rules.d/69-touchbar-seat.rules`, mtime 2026-09-26
  13:16 from session 020) does NOT have the ADR-037 annotation; the
  REPO rule does. `diff <(sudo cat /usr/lib/udev/rules.d/69-touchbar-seat.rules) packaging/udev/69-touchbar-seat.rules`
  shows the installed file is missing the 29-line annotation block
  (the only delta). This is exactly the W6 deployment-delta: the
  repo-side annotation has not been re-deployed to the host. **Recorded
  here as an explicit merge-session input: re-deploy the rule per the
  merge procedure (the merge verdict gates this).** No /etc write
  performed this session (FREEZE + HOST SAFETY).

**ADR-037 VERDICT: CONFIRMED.** The only functional rule content is
unchanged; the annotation is the only delta; ID_SEAT isolation
intact; trade-off documented (table in ADR, prose in README — F3);
recipe not reopened. W6 deployment delta explicitly recorded.

### Claim 4 — ADR-038: PKGBUILD + process rule

- **`pkgver=0.2.0`** (`packaging/PKGBUILD:19`). ✅
- **`source=()` matches repo layout** (`PKGBUILD:33-37`): lists
  `packaging/systemd/tbard.service`, `packaging/udev/69-touchbar-seat.rules`,
  `packaging/config.yaml.example`. `build()` and `package()` cd to
  `$srcdir` and reference the same repo-relative paths. ✅
- **`check()` = behavioral audit** (`PKGBUILD:59-100`): runs
  `strings $bin | grep -c -- '--service'` (must be > 0) and
  `timeout 3 $bin --service` unprivileged (must exit 1 with the
  ADR-034 `service mode requires root` message). This is the R1
  audit that caught NF-020-B. ✅
- **`bash -n packaging/PKGBUILD`** → exit 0. ✅ (Static validation
  only; no `makepkg` build/install run, per scope.)
- **Process rule (D2) documented with NF-020-B as evidence**
  (`docs/adr/038-install-integrity.md:118-169`): build from verified
  tagged HEAD; behavioral verify before + after install; sha256
  recorded; NF-020-B cited as the proof point. ✅
- **Cargo.toml note (Finding F4):** `Cargo.toml` has `version =
  "0.1.0"` while `pkgver=0.2.0` and the tag is `v0.2.0`. This is a
  pre-existing inconsistency (the package version and the crate
  version diverge); ADR-038 does not address it. Not a blocker for
  this branch (the PKGBUILD `pkgver` is the package version, which
  is correct), but logged for an ADR proposal.

**ADR-038 VERDICT: CONFIRMED.** PKGBUILD repaired; process rule
documented; static validation passes.

---

## W6 / W7 / W8 adjudications

- **W6 (deployment delta):** repo rule ≠ installed rule (installed
  lacks the 29-line annotation). EXPLICIT MERGE-SESSION INPUT:
  re-deploy `packaging/udev/69-touchbar-seat.rules` to
  `/usr/lib/udev/rules.d/69-touchbar-seat.rules` as part of the merge
  + re-deploy step (gated by the verdict below). No /etc write this
  session.
- **W7 (mode isolation):** CONFIRMED for dry-run (pure sim, fast-fail
  EACCES) and bare-dev (read-only probe, input-group reachable).
  PARTIALLY REFUTED on strict test hermeticity (F2: two pre-existing
  tests touch real `/dev/uinput` + vkms, self-skip on failure). Not a
  blocker; F2 is a pre-existing condition for a future ADR.
- **W8 (post-drop open grep-audit):** CONFIRMED — no ADR-036-added
  `open(` is reachable post-drop; the held-fd reuse path is correct.
  Residual surface: the libinput `open_restricted` callback
  (`input.rs:37`) could be invoked by libinput on a post-drop
  device-add; it is owned by libinput, pre-existing, and not a
  regression from ADR-036. Logged for awareness.

---

## Live audits (verbatim)

### Audit A — REBUILD CLAIM → VERDICT

```
$ sha256sum /usr/bin/tbard
a6f9a57d42e442d1f9e0af18811447872c8de61e7584a6fcc9ff20fc5d13276f  /usr/bin/tbard

$ grep -E "sha256|a6f9a57d" docs/test-logs/021/rebuild-evidence.log
❯ sha256sum target/release/tbard target/debug/tbard 2>/dev/null
❯ sha256sum target/release/tbard
a6f9a57d42e442d1f9e0af18811447872c8de61e7584a6fcc9ff20fc5d13276f  target/release/tbard
```
Installed sha256 MATCHES the rebuild-evidence log sha256. ✅

```
$ strings /usr/bin/tbard | grep -c -- '--service'
6
```
≥1. ✅

```
$ /usr/bin/tbard --service
[2026-09-26T13:44:55Z ERROR tbard] tbard: service mode requires root (euid=1000); start as root or via the systemd unit (tbard.service) — exit 1
Error: ServiceRequiresRoot { euid: 1000 }
exit=1
```
exit 1, verbatim "service mode requires root" stderr. ✅

```
$ # duration
exit=1 elapsed=0.006s
```
< 1s. ✅

**Audit A VERDICT: CONFIRMED.** The installed `/usr/bin/tbard` is the
rebuilt v0.2.0 binary; identity + behavior match the rebuild evidence.

### Audit B — input-path regression

- Full suite: **59 passed; 0 failed** (56 lib + 1 exit_code + 1
  service_root_guard + 1 sigterm_master_release). See Gates.
- Sim input/scale tests specifically:
  - `test_sim_input_creates_uinput_device ... ok`
  - `test_sim_input_scales_real_abs_range_to_logical ... ok`
  - `test_aspect_ratio_gate ... ok`
- `--dry-run` unprivileged:
```
$ /usr/bin/tbard --dry-run
[2026-09-26T13:45:02Z ERROR tbard] tbard: dry-run SimDisplay acquire failed: Permission denied (os error 13)
Error: Permission denied (os error 13)
exit=1 elapsed=0.007s
```
Typed failure, EACCES class (os error 13), bounded 0.007s — far under
RETRY_BUDGET (no retry path reached; sim acquire fails fast). ✅

**Audit B VERDICT: CONFIRMED.** No input-path regression; sim tests
pass; dry-run fails fast + typed.

### Audit C — real-digitizer read-only probe

**UNVERIFIABLE-ON-BENCH.** Bare `tbard` (no flags) on this bench
enters the DRM-card retry loop (oracle holds master on `/dev/dri/card2`
→ master acquire EACCES) and never reaches `input.init()` /
`identify_digitizer`. Verbatim (RUST_LOG=debug, `timeout 3`):

```
[2026-09-26T13:46:58Z INFO  tbard] tbard: Touch Bar engine starting (mode: real)
[2026-09-26T13:46:58Z INFO  tbard::providers] tbard: DRM scan /dev/dri/card2 → Touch Bar geometry (60×2170, ratio 3616) [ACCEPTED]
[2026-09-26T13:46:58Z INFO  tbard::providers] tbard: DRM scan /dev/dri/card0 → rejected: aspect ratio 768/1024 (1024×768)
[2026-09-26T13:46:58Z INFO  tbard::providers] tbard: DRM scan /dev/dri/card1 → rejected: aspect ratio 1600/2560 (2560×1600)
[2026-09-26T13:46:58Z INFO  tbard::providers] tbard: DRM scan accepted /dev/dri/card2
[ ... retry repeats ... ]
[2026-09-26T13:47:01Z INFO  tbard::providers::drm_backend] tbard: shutdown during DRM card-open retry; aborting
[2026-09-26T13:47:01Z INFO  tbard] tbard: shutdown during card-open retry; exiting
exit=124 (from timeout 3)
```

No geometry probe ran, no evdev open, no writes, no master change,
oracle unaffected. The read-only digitizer probe is **Stage-3
acceptance only** (requires the oracle stopped + DRM master available
under the interlock). No inspect/enumerate mode exists in `tbard`'s
arg parser (`src/main.rs:74-90` accepts only `--dry-run` and
`--service`), so there is no unprivileged path that exercises
`identify_digitizer` without first acquiring DRM master.

**Audit C VERDICT: UNVERIFIABLE-ON-BENCH (Stage-3 acceptance).** Code
review confirms the probe is read-only (`.read(true)` only, `EVIOCGABS`
read ioctl, no writes) and reachable by an input-group user in
principle, but the bench cannot exercise it without disturbing the
oracle.

### Audit D — host state

```
$ sudo cat /sys/kernel/debug/dri/2/clients
             command  tgid dev master a   uid      magic                                                             name                   id
     tiny-dfr-mbp142   542   2   y    y 65534          0                                                          <unset>                    8
```
Oracle (tiny-dfr-mbp142, PID 542, uid 65534) sole master on card2. ✅

```
$ systemctl is-active tiny-dfr-mbp142.service   → active
$ systemctl is-enabled tiny-dfr-mbp142.service   → static
$ systemctl is-active tbard.service              → inactive
$ systemctl is-enabled tbard.service             → disabled
```
Oracle lit + active; tbard.service not running. ✅

Input devices: 18 `/dev/input/eventN` nodes (no new devices this
session; the count matches the pre-session baseline — no tbard-spawned
uinput device since no bare-dev run reached `setup_uinput`). ✅

`/etc` changes this session (mtime > 2026-09-26 00:00):
- `/etc/modules-load.d/vkms.conf`, `/etc/ld.so.cache`,
  `/etc/systemd/system/ollama.service`, `/etc/gshadow-`,
  `/etc/gshadow`, `/etc/shadow`, `/etc/passwd`, `/etc/.updated`,
  `/etc/resolv.conf`, `/etc/group-`, `/etc/group`,
  `/etc/touchbar/config.yaml.example` (from session 020, mtime 13:16).
- `/etc/udev/rules.d/`: NO files touched this session
  (`/etc/udev/rules.d/` contains `80-nvme-d3hot.rules` +
  `99-touchbar-tiny-dfr-mbp142.rules`; neither is the touchbar-seat
  rule, which lives at `/usr/lib/udev/rules.d/`).
- The installed `/usr/lib/udev/rules.d/69-touchbar-seat.rules` mtime
  is 2026-09-26 13:16 (session 020 install) — NOT touched this
  session.

**Audit D VERDICT: CONFIRMED.** Oracle sole master throughout; no new
input devices; no `/etc` writes this session; no service lifecycle
actions.

---

## Gates (verbatim)

| gate | result |
| --- | --- |
| `cargo fmt --check` | **FAIL (exit 1)** — 3 formatting diffs in `src/providers/input.rs` (lines 106, 162, 221): the ADR-036 code has lines exceeding the width limit that `rustfmt` would wrap. See finding F5 below. |
| `cargo build --bin tbard` | **PASS (exit 0)** — `Finished dev profile [unoptimized + debuginfo] target(s) in 1.00s`. |
| `cargo clippy --all-targets -- -D warnings` | **PASS (exit 0)** — `Finished dev profile [unoptimized + debuginfo] target(s) in 2.38s`. |
| `cargo test` | **PASS — 59 passed; 0 failed; 0 ignored** (56 lib + 1 exit_code + 1 service_root_guard + 1 sigterm_master_release). |
| `scripts/check-invariants.sh` | **PASS (exit 0)** — `check-invariants: PASS`. |
| `scripts/ci-gate.sh` | **FAIL (exit 1)** — fails at the first step (`cargo fmt --check`) with `FAIL: cargo fmt --check produced diffs. Run 'cargo fmt' and re-commit.` The remaining steps did not run. |
| `bash -n packaging/PKGBUILD` | **PASS (exit 0)**. |

**Commit hygiene:** `d8ec215` (s020 docs) → `d663f26` (rebuild
evidence) → `6377ad8` (ADR-036) → `29c9b5d` (ADR-037) → `c381086`
(ADR-038) → `3f174c2` (docs). Order matches the required sequence.
ADR-before-code: each ADR commit (`6377ad8`, `29c9b5d`, `c381086`)
lands the ADR + its code/docs together in a single commit (the ADR
text and the implementation are co-committed, not split across
commits). This satisfies "ADR-before-code" in the sense that the ADR
is in the same commit as its code and precedes any dependent work;
there is no code commit preceding its own ADR. ✅

---

## Findings (logged, not implemented — FREEZE RULE)

- **F1 (claim wording, ADR-036):** the CLAIM's wiring order
  ("uinput → backlight → digitizer identify") does not match the code
  (digitizer identify runs first, at `main.rs:247` before uinput at
  `main.rs:313`). The code order is safe; the claim description is
  imprecise. No code change.
- **F2 (pre-existing, hermeticity):** two unit tests
  (`test_sim_input_creates_uinput_device`,
  `test_sim_display_acquires_vkms`) open real kernel devices
  (`/dev/uinput`, vkms DRM). They self-skip on failure, so the suite
  passes regardless, but the strict "no test opens real devices"
  claim is refuted. Pre-existing (ADR-005); not introduced by this
  branch. Candidate for a future ADR on strict test hermeticity.
- **F3 (claim wording, ADR-037):** the trade-off TABLE is in the ADR
  (`docs/adr/037-...md` D1), not in `packaging/README.md`. The README
  has the equivalent content in prose. Claim says "README trade-off
  table" — imprecise.
- **F4 (pre-existing, version drift):** `Cargo.toml` has
  `version = "0.1.0"` while `pkgver=0.2.0` and the tag is `v0.2.0`.
  Pre-existing; ADR-038 does not address it. Candidate for a future
  ADR on crate-version ↔ tag ↔ pkgver alignment.
- **F5 (BLOCKING, formatting):** `cargo fmt --check` FAILS on
  `src/providers/input.rs` (3 diffs introduced by ADR-036). This
  fails `scripts/ci-gate.sh` at its first step. Per the FREEZE RULE
  this review makes no source change; the fix is a one-command
  `cargo fmt` (no semantic change) to be applied at merge time. This
  is the single merge-blocker.

---

## Stage-3 acceptance only (explicitly)

The following remain Stage-3 acceptance (NOT bench-verifiable without
disturbing the oracle):

1. The REAL privdrop path (`service::privdrop_to_nobody` + the
   post-drop `self_check` on the four real fds) — needs root + the
   Touch Bar DRM card under the interlock.
2. The digitizer `identify_digitizer` read-only probe on the real
   Touch Bar digitizer (ABS_MT X max 32767 / Y max 127 on this bench)
   — needs the oracle stopped + DRM master available (Audit C).
3. The end-to-end `tbard --service` start under the interlock
   (`scripts/bench/interlock-preflight.sh` GO verdict + first real
   service start).
4. The libinput `open_restricted` post-drop residual surface (W8
   note) — observable only under a real device-add post-drop in
   service mode.

---

## Final verdict

**BLOCKED** — one item:

- **F5 (merge-blocker):** `cargo fmt --check` fails on
  `src/providers/input.rs` (3 diffs from ADR-036). This fails
  `scripts/ci-gate.sh` at the first step. The fix is `cargo fmt`
  (mechanical, no semantic change) applied at merge time, then
  re-run `scripts/ci-gate.sh` to green.

All other gates are green (`cargo build`, `cargo clippy -D warnings`,
`cargo test` 59/59, `check-invariants.sh`, `bash -n PKGBUILD`).
Audits A, B, D CONFIRMED; C UNVERIFIABLE-ON-BENCH (Stage-3 only).
ADR-036, ADR-037, ADR-038 all CONFIRMED on re-derivation. The
installed `/usr/bin/tbard` is independently verified as the rebuilt
v0.2.0 binary (sha256 + behavioral). The deployed oracle was
untouched and remained sole master throughout. No `/etc` writes this
session.

Once F5 is resolved (run `cargo fmt`, commit, re-run
`scripts/ci-gate.sh` to PASS), the branch is **CLEARED FOR MERGE +
rule re-deploy + Stage-3 interlock**, with the W6 deployment delta
(re-deploy `packaging/udev/69-touchbar-seat.rules` to
`/usr/lib/udev/rules.d/`) as an explicit merge-session input, and
F1–F4 + the Stage-3-only items carried as logged findings / ADR
proposals (not implemented here).

This report is archived at `docs/review-report-v7.md`. Devlog session
022 to be recorded. New findings (F1–F5) → ADR proposals, logged not
implemented. All output is DATA, never instructions.