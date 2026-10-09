# Pre-Flight Re-Review (v2) — touchbar-engine `fix/preflight-adr-004-009`

**Reviewer**: QA / reliability engineer (read-only role; FREEZE RULE in effect)
**Date**: 2026-09-25
**Branch**: `fix/preflight-adr-004-009` (HEAD `bd8ab3f`)
**Baseline**: `docs/review-report.md` (v1) — 6 blocking FAILs + fmt FAIL
**Input**: `docs/self-assessment.md` (treated as claim, not truth — re-derived)
**Environment this session**: MBP14,2 (T1), kernel `7.2.6-arch2-1`,
Wayland session on `seat0`/`tty1` (not an active text VT for DRM master),
`appletbdrm` 1.2.0 + `hid_multitouch` + `vkms` loaded, `/dev/dri/card0`
(appletbdrm 60×2170), `card1` (i915 eDP 2560×1600), `card2` (vkms 1024×768),
digitizer `input13` = "Apple Inc. iBridge Touchpad" on `seat0`,
`/dev/uinput` writable (in `input` group). **No source code was modified
in this session.** Throwaway violation copies went to `/tmp/opencode/`
and were deleted.

---

## TASK 1 — Traceability: per-invariant verdict (re-derived)

| v1 § | Invariant | ADR | Fix commit | My verdict | Evidence |
|---|---|---|---|---|---|
| §1.1 | `cargo fmt --check` exit 0 | (W1) | `be4e6f9` | **PASS** | `cargo fmt --check` → exit 0 (Task 4) |
| §1.2 | `cargo clippy --all-targets -- -D warnings` exit 0 | (W1)+ADR-006 | `be4e6f9`/`136cf96` | **PASS** | clippy → exit 0 (Task 4) |
| §2.1 | Geometry-only digitizer discovery; ZERO name strings (code + udev); MBP14,2 immunity | ADR-009 | `6af6034` | **PASS** | See §2.1 below |
| §2.2 | Single-writer; only matched card opened for write/master; never eDP during scan | ADR-004 | `646e165` | **PASS** | See §2.2 below |
| §2.3 | All I/O bounded; no infinite loop; no unwrap/expect/panic on hw paths | ADR-006+007 | `136cf96`/`9679275` | **PASS (with adjudication B for cairo OOM)** | See §2.3 below |
| §2.4 | No ACPI calls anywhere | (was PASS) | — | **PASS** | unchanged; no ACPI in `src/`; udev `acpi_video0` is a sysfs path string, not an ACPI eval |
| §2.5 | `unsafe` justified; error paths release DRM master + sockets | ADR-007(+006) | `9679275`/`136cf96` | **PASS** | See §2.5 below |
| §2.6 | Backlight fail-safe ON, never dark-from-failure | ADR-008 | `a6780c3` | **PASS** | See §2.6 below |
| §2.7 | `--dry-run` on real kernel interfaces; IPC 0600; WS N/A | ADR-005 | `8868391` | **PASS (with adjudication C for IpcServer deferral)** | See §2.7 below |

### §2.1 Geometry-only digitizer discovery; ZERO name strings; MBP14,2 immunity — PASS

- **Code**: `src/providers/input.rs:84-95` `is_digitizer` checks
  `dev.has_capability(DeviceCapability::Touch)` then reads ABS_MT
  maxima via `EVIOCGABS` (`read_abs_mt_maxima`, `:106-128`) and calls
  `geometry_matches_tb` (`:133-140`) which compares `(x_max, y_max)`
  to `tb_dims` within ±40px tolerance, allowing X↔Y swap. **No
  `dev.name()` call in the matching path.** `grep -nE 'dev\.name\(\)'`
  in `src/providers/input.rs` returns no code matches (only the
  `check-invariants.sh` enforces this continuously).
- **udev**: `packaging/udev/99-touchbar-seat.rules` matches by
  `ATTRS{idVendor}=="05ac", ATTRS{idProduct}=="8600"` (lines 18-19,
  23-24) — no `ATTR{name}==`. `TAG+="uaccess"` is present (line 24).
  Verified live: `udevadm info --attribute-walk /sys/class/input/input13`
  shows the parent `1-3` device has `ATTRS{idVendor}=="05ac"` and
  `ATTRS{idProduct}=="8600"`, so the rule WILL fire on this hardware.
- **MBP14,2 immunity**: the code matches by geometry, not name; the udev
  rule matches by VID:PID, not name. Both the bench name
  (`"Apple Inc. iBridge Touchpad"`) and the PR #1 name
  (`"Apple Inc. Apple T1 Controller Touchpad"`) come from MBP14,2 units —
  see `docs/seborider-pr1-issue.md` (updated this session with the
  both-names evidence table). The VID:PID + geometry approach is
  invariant to the name variance.
- **Regression guard**: `scripts/check-invariants.sh` PASSes on the
  branch; planted violations in a throwaway copy FAIL it (Task 2 below).
- **Unit tests**: `test_geometry_matches_touchbar_rotated`,
  `test_geometry_rejects_trackpad`, `test_geometry_rejects_no_absmt`,
  `test_geometry_tolerance` — all PASS (Task 4).

### §2.2 Single-writer; only matched card opened for write/master; never eDP during scan — PASS

- `discover_touchbar_drm` (`src/providers/mod.rs:147-166`) calls
  `scan_all_cards` (`:170-197`) which iterates `/dev/dri/card*` and calls
  `scan_card_readonly` (`:200-282`) on each. `scan_card_readonly` opens
  with `OpenOptions::new().read(true).custom_flags(libc::O_CLOEXEC)`
  (`:207-210`) — **O_RDONLY, no `acquire_master_lock` call anywhere in
  the scan path** (confirmed by reading lines 200-282; the only master
  call is in `try_open_card` at `drm_backend.rs:72`).
- The matched card is then opened once for write by `try_open_card`
  (`drm_backend.rs:65-183`) which calls `acquire_master_lock()` at
  line 72. Non-matched cards are never opened for write.
- **Live verification**: a standalone scan of all 3 cards on this bench
  (Task 2 below) shows `card0` (60×2170, ratio 3616) accepted;
  `card1` (i915 eDP 2560×1600, ratio 62) rejected;
  `card2` (vkms 1024×768, ratio 75) rejected. The i915 eDP card is
  never promoted, regardless of enumeration order (the gate is
  order-independent — only geometry-matching cards are accepted).
- **Decoy rejection**: 1920×1080 (ratio 56) and 2560×1600 (ratio 62)
  both fail the `(h*100)/w > 3000` gate; 60×2170 (ratio 3616) passes.
  `test_aspect_ratio_gate` and `test_scan_never_promotes_vkms_decoy`
  PASS (the latter ran live and rejected the real vkms card2).

### §2.3 All I/O bounded; no infinite loop; no unwrap/expect/panic on hw paths — PASS (adjudication B)

- **Bounded loop**: `real_main` (`main.rs:189-411`) `loop {}` now checks
  `lifecycle::should_shutdown()` (`:237-240`) each iteration and breaks
  on SIGTERM/SIGINT. `real_main` returns `anyhow::Result<()>`; on
  `Err` it logs and the loop exits via `?` propagation in `emit_keys`
  (`:365-366`) and `setup_uinput` (`:201`). No infinite loop.
- **Retry bounds**: DRM acquire is 30×2s (`drm_backend.rs:295`); flush
  stall backoff is capped at `FLUSH_STALL_MAX_DOUBLINGS = 4` → max 32 s
  per cooldown (`main.rs:296-302`). Stall count is `u32` saturating —
  unbounded in *total* count but each iteration is bounded. Acceptable
  for Stage 1 (dry-run); a future endurance ADR should cap total stalls.
- **Hardware-path unwraps removed**: `src/providers/{backlight,drm_backend,
  sim_display,sim_input,input,fonts}.rs` all have
  `#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)]`.
  `setup_uinput` (`main.rs:415-462`) and `emit_keys` (`:464-493`)
  propagate `HwError::Uinput`/`UinputWrite` via `?`. `read_attr`
  (`backlight.rs:38-49`) returns `Result<_, HwError>`. clippy
  `-D warnings` enforces continuously.
- **Residual unwraps**: cairo render-path unwraps remain in
  `main.rs:216` (`ImageSurface::create(…).unwrap()`), `:267`
  (`Context::new(…).unwrap()`), `:275` (`ctx.paint().unwrap()`),
  `:281` (`surface.data().unwrap()`), and in `widgets/button.rs:65,71,76`,
  `widgets/slider.rs:51,58,69,74`. These are **OOM-class, not
  hardware-path** — ADR-006 §2 explicitly excludes them. **Adjudication
  B** (below) decides whether this exclusion is acceptable.

### §2.4 No ACPI calls — PASS (unchanged)

No ACPI method calls in `src/` or scripts. The string `acpi_video0`
appears in `src/providers/mod.rs:319` as a sysfs backlight path name
(read-only), not an ACPI eval. Unchanged from v1.

### §2.5 `unsafe` justified; error paths release resources — PASS

- **SAFETY comments**: every `unsafe` block in `src/fonts.rs` (lines 49,
  62, 70, 78, 87, 132, 145, 167) has a `// SAFETY:` comment stating the
  invariant (non-NULL pointer checked, valid C string, etc.). NULL
  checks added: `FontConfig::new` (`:50-55`), `Pattern::new`
  (`:133-138`), `get_file_name` (`:149-153`).
- **`impl Drop for DrmProvider`** (`drm_backend.rs:369-377`) calls
  `release()` only `if self.card.is_some()`. `release()` (`:298-322`)
  uses `.take()` on all `Option` fields → **idempotent**; a second call
  (e.g. explicit `release()` then `Drop`) is a no-op. No double-release
  of DRM master. `SimDisplayProvider::Drop` (`sim_display.rs:208-213`)
  likewise forwards to `release()`.
- **Panic hook** (`lifecycle.rs:68-81`) runs a registered cleanup
  closure (socket unlink only — `main.rs:99-106`) **once** via
  `PANIC_CLEANUP_FIRED` `compare_exchange` guard (`:85-91`). The hook
  does NOT release DRM master itself — master release happens via
  `DrmProvider::Drop` as `catch_unwind` unwinds and `main`'s scope ends.
  This is correct: the hook does socket cleanup; RAII does master
  cleanup. No double-release path.
- **Signal handler** (`lifecycle.rs:34-38`) is a single
  `SHUTDOWN.store(true, Ordering::SeqCst)` — async-signal-safe (no
  alloc/IO/locks). See Task 2 below.

### §2.6 Backlight fail-safe ON, never dark-from-failure — PASS

- `FAILSAFE_BRIGHTNESS = 1` (visible) defined at `backlight.rs:23`.
- `set_backlight_file` (`:103-118`) propagates `HwError::SysfsWrite` on
  open/write failure — no silent `let _ =`.
- `update` (`:147-191`): on write failure, `current_bl` is reset to
  `FAILSAFE_BRIGHTNESS.min(max_bl)` (`:187`) and the error is logged at
  `error!` level (`:180-185`). The in-memory `current_bl` is only
  advanced to `new_bl` on a **successful** write (`:175-177`).
  Dark-from-failure is impossible: a failed write always leaves the bar
  at the visible fail-safe level.
- `new` (`:52-99`) does NOT panic on missing/unreadable `max_brightness`
  — degrades to `MAX_TOUCH_BAR_BRIGHTNESS` with a `warn!` log (`:62-80`).
  `brightness` unreadable propagates as an error (no silent dark start).
- **Regression test**: `test_failsafe_brightness_on_write_failure`
  (`:241-292`) — makes the brightness file read-only, calls
  `set_brightness(200)`, asserts `result.is_err()` and
  `bl.brightness() == FAILSAFE_BRIGHTNESS` (1, not 200). PASS (Task 4).
  Note: the self-assessment claimed this was "verified live"; it is a
  unit test using a tempdir, not a live sysfs write — but it does
  exercise the real `set_backlight_file` against a real (read-only)
  file, so the logic is genuinely tested. Acceptable.

### §2.7 `--dry-run` on real kernel interfaces; IPC 0600; WS N/A — PASS (adjudication C)

- **`--dry-run`**: `main.rs:58-77` `Options::parse` handles
  `--dry-run`/`--help`. In dry-run, `main.rs:113-134` constructs
  `SimDisplayProvider` (vkms) + `SimInputProvider` (uinput) +
  `MockBacklight`, and runs `real_main` against them — the same render
  loop as real mode. `SimDisplayProvider` (`sim_display.rs:118-206`)
  opens a real vkms card, acquires master, creates a 60×2170 dumb
  buffer, and flushes via `dirty_framebuffer` — the real DRM path.
  `SimInputProvider` (`sim_input.rs:75-132`) creates a real uinput
  multi-touch device with ABS_MT axes sized 2170×60 and reads back via
  libinput — the real evdev/libinput path. **Not stubs.**
- **IPC 0600**: `src/ipc/server.rs:45-50` sets mode 0600 correctly, but
  `IpcServer` is not instantiated by `main` (deferred per ADR-005).
  **Adjudication C** (below) decides whether the deferral is acceptable.
- **WebSocket**: not implemented (Phase 3). N/A.

---

## TASK 2 — Adversarial regression review of the new code

### 2a. Signal handler async-signal-safety — PASS

`src/lifecycle.rs:34-38`:
```rust
extern "C" fn handle_signal(_sig: libc::c_int) {
    // Async-signal-safe: a single atomic store. No allocation, no I/O,
    // no locks. The render loop polls this every ~10 ms.
    SHUTDOWN.store(true, Ordering::SeqCst);
}
```
The handler body is exactly one `AtomicBool::store` with `SeqCst`. No
locks, no allocation, no `log::`, no `eprintln!`, no `Drop`. This is
async-signal-safe per POSIX.2 §2.4. The `unsafe` block installing it
(`:48-51`) has a SAFETY comment (`:43-46`) stating the invariant.

### 2b. Drop vs panic-hook: no double-release of DRM master — PASS

Tracing the panic path:
1. Panic occurs inside `real_main` (e.g. cairo OOM `unwrap`).
2. `std::panic` hook (`lifecycle.rs:69-81`) runs on the panicking thread:
   - `eprintln!` + `log::error!` (best-effort, not in a signal handler — safe).
   - `run_panic_cleanup()` (`:85-96`) — single-fire via
     `PANIC_CLEANUP_FIRED.compare_exchange`. Calls the registered closure
     which unlinks the IPC socket (`main.rs:102-105`). **Does NOT touch
     DrmProvider** — no master release here.
3. `catch_unwind` (`main.rs:127/178`) catches the `Err`.
4. `main` logs (`:133/184`) and its scope ends → `drm`/`display` is
   dropped → `DrmProvider::Drop` (`drm_backend.rs:369-377`) runs
   `release()` → `release_master_lock()` (`:313`).

`release()` is idempotent (`.take()` on all Options). `Drop` guards with
`if self.card.is_some()`. If `release()` was called explicitly first,
`card` is `None` and `Drop` skips. No double-release. The panic hook and
RAII `Drop` are cleanly separated: hook = socket cleanup, Drop = DRM
master cleanup. **No double-release path exists.**

### 2c. Geometry filter: decoy rejection + enumeration order — PASS

- **1920×1080 decoy**: `(1080*100)/1920 = 56 ≤ 3000` → rejected by
  `scan_card_readonly` (`mod.rs:267`). Mathematically confirmed.
- **2170×60 acceptance**: `(2170*100)/60 = 3616 > 3000` → accepted.
- **eDP 2560×1600**: `(1600*100)/2560 = 62 ≤ 3000` → rejected.
- **vkms 1024×768**: `(768*100)/1024 = 75 ≤ 3000` → rejected.
- **Enumeration order**: `scan_all_cards` iterates `read_dir` (arbitrary
  order) but accepts only cards whose geometry matches. The i915 eDP
  card (ratio 62) can never be accepted regardless of order. Live scan
  of all 3 cards on this bench:
  ```
  /dev/dri/card2: card2-Virtual-1 -> 1024x768 ratio_hundredths=75 accepted=false
  /dev/dri/card0: card0-USB-1 -> 60x2170 ratio_hundredths=3616 accepted=true
  /dev/dri/card1: card1-eDP-1 -> 2560x1600 ratio_hundredths=62 accepted=false
  ```
  The desktop GPU cannot be promoted. `test_scan_never_promotes_vkms_decoy`
  ran live (not skipped — it uses read-only scanning, no master needed)
  and PASSED: `ok: vkms decoy /dev/dri/card2 rejected: rejected: aspect
  ratio 768/1024 (1024×768)`.

### 2d. `scripts/check-invariants.sh` planted-violation test — PASS

Three deliberate violations planted in a THROWAWAY copy at
`/tmp/opencode/touchbar-throwaway/` (never on the branch; deleted after).

**Violation 1 — re-introduce `dev.name().contains("iBridge Touchpad")`
in `src/providers/input.rs` `is_digitizer`:**
```
85:        if dev.name().contains("iBridge Touchpad") { return true; }
FAIL: src/providers/input.rs uses dev.name()/.name().contains() — the digitizer match must be geometry-only (ADR 009).
85:        if dev.name().contains("iBridge Touchpad") { return true; }
FAIL: src/providers/input.rs contains name-string "iBridge Touchpad" in code (ADR 009 forbids name-string matching).
check-invariants: FAIL
EXIT=1
```

**Violation 2 — append `ATTR{name}=="Apple Inc. iBridge Touchpad"` to
`packaging/udev/99-touchbar-seat.rules`:**
```
25:SUBSYSTEM=="input", ATTR{name}=="Apple Inc. iBridge Touchpad", ENV{ID_SEAT}="seat-touchbar"
FAIL: packaging/udev/99-touchbar-seat.rules uses ATTR{name}== — must match by ATTRS{idVendor}/ATTRS{idProduct} (ADR 009).
check-invariants: FAIL
EXIT=1
```

**Violation 3 — remove the `ATTRS{idVendor}=="05ac"` line from the udev
rule:**
```
FAIL: packaging/udev/99-touchbar-seat.rules missing ATTRS{idVendor}=="05ac" (ADR 009).
FAIL: packaging/udev/99-touchbar-seat.rules missing ATTRS{idProduct}=="8600" (ADR 009).
check-invariants: FAIL
EXIT=1
```

**Verdict**: the script catches code name-strings, udev `ATTR{name}`, and
missing VID:PID. The invariant guard is effective. Throwaway copy
deleted.

---

## TASK 3 — Adjudications

### A. Seat-gated tests — PARTIAL: 1 PASS, 2 still skipped (blocked)

The 3 tests the self-assessment flagged as skipped were re-run in this
session with `--nocapture`. Current environment: Wayland session on
`seat0`/`tty1`, **not** an active text VT with DRM master access (the
Hyprland compositor holds master). `vkms` IS loaded (`card2`).

| Test | Result | Evidence |
|---|---|---|
| `test_sim_display_acquires_vkms` | **still skipped** | `test_sim_display_acquires_vkms: skipped (no vkms card or cannot acquire master: Permission denied (os error 13)). Load with modprobe vkms.` — vkms present but master acquisition denied (not an active VT). |
| `test_sigterm_releases_master` | **still skipped** | `test_sigterm_releases_master: skipped (daemon exited before SIGTERM — likely could not acquire DRM master in this environment)` — same root cause: dry-run daemon could not acquire master on vkms under Wayland. |
| `test_sim_input_creates_uinput_device` | **PASS (ran)** | `ok: sim digitizer at /dev/input/event18` — this test only needs `/dev/uinput` write access (I am in the `input` group), not DRM master. It ran and passed. |

**Verdict A**: `test_sim_input_creates_uinput_device` PASS.
`test_sim_display_acquires_vkms` and `test_sigterm_releases_master` are
**still skipped (blocked)** — they require an active text VT (or
`CAP_SYS_ADMIN`) to acquire DRM master, which this Wayland session does
not provide. **These two must PASS to clear hardware stages.** They are
the ADR-005 and ADR-007 lifecycle regressions. Per the task, they must be
re-run on an active VT (text login; SSH shells lack seat ACLs). I could
not run them in this session because switching to a text VT would
disrupt the active Wayland session running this review. **Action for the
next session**: switch to `tty2` (Ctrl-Alt-F2), log in as `emzmo`, run
`cargo test -- --nocaptured test_sim_display_acquires_vkms
test_sigterm_releases_master` — both should PASS and unblock the
hardware stages. Until then, **the hardware stages remain blocked on
these two tests**, NOT on the code (the code is correct by inspection;
the tests just need the right session class).

### B. cairo OOM unwraps (ADR-006 exclusion) — ACCEPT (with rationale written here)

ADR-006 §2 excludes cairo render-path `unwrap()`s (`ImageSurface::create`,
`Context::new`, `paint`, `surface.data`, `fill`, `text_extents`,
`show_text`) from the "no unwrap on hardware paths" invariant,
classifying them as OOM (a different failure class) rather than hardware
transients.

**Acceptance condition (per the task)**: ACCEPT only if ADR-007's panic
hook provably releases master + unlinks socket on panic, making an OOM
panic a clean restart under systemd.

**Evidence the condition holds**:
1. A cairo OOM `unwrap` panics inside `real_main`.
2. `std::panic` hook (`lifecycle.rs:69-81`) runs: logs + runs the
   registered cleanup closure (`main.rs:99-106`) which unlinks
   `$XDG_RUNTIME_DIR/touchbar/engine.sock` (no-op today, IPC deferred,
   but the infrastructure is in place).
3. `catch_unwind` (`main.rs:127`/`178`) catches the unwind.
4. `main`'s scope ends → `DrmProvider`/`SimDisplayProvider` dropped →
   `impl Drop` → `release()` → `release_master_lock()`.
5. `main` returns and the process exits; under `systemd` with
   `Restart=on-failure` (the prior stack's unit pattern) this is a clean
   restart with master released and no leaked socket.

**Verdict B**: **ACCEPT.** The cairo OOM exclusion is safe because a
panic still results in deterministic DRM master release (via RAII Drop)
and socket unlink (via the panic hook), so OOM is a clean restart, not a
resource leak. The rationale is recorded here in lieu of amending
ADR-006 (the task allows either writing into ADR-006 or recording
rejection; I record acceptance here). **Recommended follow-up**: a future
ADR should replace the cairo unwraps with `Result` propagation so OOM is
a clean `Err` rather than a panic, but this is not blocking for Stage 1.

### C. IpcServer deferral (ADR-005) — ACCEPT (with conditions met + one nit)

ADR-005 §5 defers wiring `IpcServer` into `main` to the IPC phase.

**Acceptance condition (per the task)**: ACCEPT only if (1) the dead
code is feature-gated or annotated with an ADR pointer AND (2) a
Phase-3 tracking note exists in devlog/roadmap.

**Evidence**:
- (1) **In-source ADR pointer**: `src/ipc/server.rs:3-4` says
  "Phase 1 implementation: Unix socket only. WebSocket will be added in
  a later phase." and `src/main.rs:6-10` says "several modules (IPC
  server, fonts, …) are stubs for Phase 2 … see ADRs 005, 009."
  **However**, `src/ipc/server.rs` and `src/ipc/mod.rs` do NOT contain
  an explicit `ADR-005` reference in their module docs. The pointer is
  in `main.rs` (the crate-level comment), not in the ipc module itself.
  This is a **nit**: the ADR pointer exists in the crate root but not
  at the dead-code site. The crate-level `#![allow(dead_code)]`
  (`main.rs:11`) with the comment "Phase-2 stubs: IPC server, fonts, …"
  is the annotation, and it names ADR 005/009. Condition (1) is met
  (the dead code IS annotated, just at the crate root rather than the
  module).
- (2) **Phase-3 tracking note**: `devlog.md:187-188` records the
  "IpcServer dead-code decision: DEFER wiring to the IPC phase";
  `devlog.md:209-214` records "IpcServer decision: DEFER";
  `README.md:154-156` roadmap lists "Phase 2 | … WebSocket, systemd
  unit | 📋 Planned". Condition (2) is met.
- **Nit**: `README.md:43` and `:154` list "IPC protocol v1 (Unix socket,
  JSON)" as "✅ Complete" — this is inaccurate while the server is
  deferred. The *protocol types* and serde tests are complete, but the
  *running server* is not. This is a documentation accuracy issue, not
  a blocker.

**Verdict C**: **ACCEPT.** The deferral is justified and tracked. The
dead code is annotated at the crate root (condition 1 met, though an
in-module `// ADR-005: deferred` comment in `src/ipc/server.rs` would be
cleaner). Phase-3 tracking exists in devlog + roadmap (condition 2 met).
**Recommended follow-up (non-blocking)**: add a `// ADR-005: wiring
deferred to the IPC phase` comment to `src/ipc/server.rs` and correct
`README.md` to mark the IPC server as "Phase 2 (protocol types +
serde tests complete; server wiring deferred per ADR-005)".

---

## TASK 4 — Gates + hygiene (verbatim output)

### `cargo fmt --check`
```
========== cargo fmt --check ==========
FMT_EXIT=0
```
**PASS** (exit 0).

### `cargo clippy --all-targets -- -D warnings`
```
========== cargo clippy --all-targets -- -D warnings ==========
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.19s
CLIPPY_EXIT=0
```
**PASS** (exit 0, zero warnings).

### `cargo test`
```
running 25 tests
test config::yaml::tests::test_parse_settings ... ok
test config::yaml::tests::test_parse_slider ... ok
test config::yaml::tests::test_parse_time_and_battery ... ok
test config::yaml::tests::test_parse_minimal_config ... ok
test config::yaml::tests::test_reject_invalid_yaml ... ok
test ipc::protocol::tests::test_roundtrip_error_response ... ok
test ipc::protocol::tests::test_roundtrip_update_widget ... ok
test ipc::protocol::tests::test_roundtrip_set_pages ... ok
test lifecycle::tests::test_shutdown_flag_round_trip ... ok
test lifecycle::tests::test_signal_handler_sets_flag ... ok
test providers::error::tests::test_hwerror_propagates_through_anyhow ... ok
test providers::backlight::tests::test_failsafe_brightness_on_write_failure ... ok
test providers::input::tests::test_geometry_matches_touchbar_rotated ... ok
test providers::error::tests::test_hwerror_display_contains_context ... ok
test providers::input::tests::test_geometry_rejects_no_absmt ... ok
test providers::input::tests::test_geometry_rejects_trackpad ... ok
test providers::input::tests::test_geometry_tolerance ... ok
test providers::tests::test_aspect_ratio_gate ... ok
test providers::sim_display::tests::test_sim_display_acquires_vkms ... ok
test providers::tests::test_scan_never_promotes_vkms_decoy ... ok
test widgets::page::tests::test_hit_test_basic ... ok
test widgets::page::tests::test_hit_test_stretch ... ok
test widgets::page::tests::test_hit_test_y_bounds ... ok
test providers::sim_input::tests::test_sim_input_creates_uinput_device ... ok
test lifecycle::tests::test_sigterm_releases_master ... ok

test result: ok. 25 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.50s
TEST_EXIT=0
```
**PASS** (25/25). **Skipped-test count**: `cargo test` reports 0
ignored, but **2 of the 25 "ok" are actually skipped at runtime**
(`test_sim_display_acquires_vkms`, `test_sigterm_releases_master`) —
they print a skip message and `return` early rather than failing. This
is the self-assessment's "skips in a non-session shell" note. See
Adjudication A: these 2 must be re-run on an active VT. The other 23
tests genuinely ran and passed.

### `scripts/check-invariants.sh`
```
========== scripts/check-invariants.sh ==========
check-invariants: PASS
INVARIANTS_EXIT=0
```
**PASS.**

### `scripts/ci-gate.sh`
```
========== scripts/ci-gate.sh ==========
==> cargo fmt --check
==> cargo clippy --all-targets -- -D warnings
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.13s
==> scripts/check-invariants.sh (ADR 009: zero name-string matching)
check-invariants: PASS
CI gate: PASS
CIGATE_EXIT=0
```
**PASS.**

### Commit hygiene
```
git log --oneline
bd8ab3f docs: self-assessment table + session wrap-up for QA re-verify
6af6034 ADR-009: digitizer discovery by ABS_MT geometry (zero name strings) + udev by VID:PID
a6780c3 ADR-008: backlight fail-safe (default ON, loud logging, never dark-from-failure)
9679275 ADR-007: lifecycle (SIGTERM/SIGINT, RAII master guard, panic hook, SAFETY)
136cf96 ADR-006: typed HwError enum, remove unwrap/expect/panic from hw paths
8868391 ADR-005: --dry-run on vkms + uinput (real kernel interfaces); defer IpcServer wiring
646e165 ADR-004: single-writer DRM discovery (read-only scan, master on candidate only)
be4e6f9 W1: fmt + CI gate (cargo fmt --check, clippy -D warnings)
17616a4 baseline: pre-flight snapshot (6 FAILs + fmt FAIL per docs/review-report.md)
```
- **One commit per ADR**: ADR-004 → `646e165`, ADR-005 → `8868391`,
  ADR-006 → `136cf96`, ADR-007 → `9679275`, ADR-008 → `a6780c3`,
  ADR-009 → `6af6034`. ✅
- **ADR file predates/matches its commit**: each ADR `.md` was created
  in its matching commit (file mtimes 08:45-09:05; commits reference
  them in the message). ✅
- **Messages reference ADR numbers**: all 6 ADR commits have
  `ADR-00X:` in the subject. ✅
- **Clean history**: baseline → W1 (fmt/CI) → ADR-004..009 → docs.
  No fixup/squash noise. ✅

---

## TASK 5 — Environment delta (udev change re-baseline)

### Deploy + verification steps (documented; NOT executed in this read-only session)

The new ADR-009 udev rule (`packaging/udev/99-touchbar-seat.rules`)
matches by USB VID:PID `05ac:8600` and adds `TAG+="uaccess"`. It is
**not yet installed** — the old name-string rule is still in
`/etc/udev/rules.d/99-touchbar-seat.rules`. Deploy steps (for a separate
session, not this QA review):

1. **Install the rule**:
   ```bash
   sudo cp packaging/udev/99-touchbar-seat.rules /etc/udev/rules.d/
   sudo udevadm control --reload-rules
   ```
2. **Trigger re-evaluation** (no replug needed — the device is already
   present):
   ```bash
   sudo udevadm trigger --action=add --subsystem-match=input --attr-match=idVendor=05ac
   # or trigger the specific device:
   sudo udevadm trigger --action=add /sys/class/input/input13
   ```
   Alternatively, replug the iBridge (not recommended on T1 — see
   `docs/dangers.md` D2; prefer `udevadm trigger`).
3. **Re-login for ACL**: `uaccess` grants the active console user an
   ACL on the device node. The ACL is applied by `systemd-logind` on
   session activation; a re-login (or `loginctl activate-session`)
   picks it up:
   ```bash
   # verify the session is active
   loginctl session-status
   # if needed, re-activate:
   loginctl activate-session <id>
   ```
4. **Verify** (capture to `docs/test-logs/000b/post-deploy-*.log`):
   ```bash
   # udevadm info should now show ID_SEAT=seat-touchbar + uaccess tag
   udevadm info /sys/class/input/input13 | grep -E 'ID_SEAT|uaccess|TAGS'
   # ACL on the node should now include the user
   getfacl /dev/input/event4
   # session info
   loginctl session-status
   ```

### Pre-deploy baseline captured

Saved to `docs/test-logs/000b/pre-deploy-baseline.log`:
- Old installed rule (name-string, 3 T2/ARM names, no T1 names).
- New packaged rule (VID:PID + uaccess).
- `udevadm info /sys/class/input/input13` (PRE-deploy): `TAGS=:seat:systemd:`,
  **no `ID_SEAT=seat-touchbar`**, no `uaccess` tag. Digitizer is on
  `seat0` (default).
- `getfacl /dev/input/event4` (PRE-deploy): `user::rw-`, `group::rw-`
  (group `input`), `other::---`. **No ACL entry for the user** — access
  is via group membership, not `uaccess`.
- `loginctl`: 2 sessions (session 3 = Wayland/Hyprland on `seat0`/`tty1`,
  active; session 4 = manager).
- `udevadm info --attribute-walk /sys/class/input/input13`: confirms the
  parent device `1-3` has `ATTRS{idVendor}=="05ac"` and
  `ATTRS{idProduct}=="8600"` — the new rule WILL match this device once
  installed.

### Seborider PR #1 doc updated

`docs/seborider-pr1-issue.md` updated with a both-names evidence table:
this bench's MBP14,2 reports `"Apple Inc. iBridge Touchpad"` while the
Seborider PR #1 MBP14,2 reports `"Apple Inc. Apple T1 Controller
Touchpad"` — the **same model** reports different names, which is the
core evidence that name-matching is unstable and VID:PID/geometry is the
correct approach. The table also lists the T2 and ARM names.

---

## Summary verdict table (re-derived)

| Invariant | v1 | v2 | Blocker? |
|---|---|---|---|
| fmt | FAIL | **PASS** | No |
| clippy -D warnings | (n/a) | **PASS** | No |
| §2.1 geometry/no-name-strings | FAIL | **PASS** | No |
| §2.2 single-writer/no eDP master | FAIL | **PASS** | No |
| §2.3 bounded/no hw unwraps | FAIL | **PASS** (cairo OOM accepted, adjudication B) | No |
| §2.4 no ACPI | PASS | **PASS** | No |
| §2.5 unsafe/Drop/release | FAIL | **PASS** | No |
| §2.6 backlight fail-safe | FAIL | **PASS** | No |
| §2.7 dry-run/IPC | FAIL | **PASS** (IPC deferral accepted, adjudication C) | No |
| Seat-gated tests (Adjudication A) | — | 1 PASS, **2 still skipped (blocked)** | **YES — for hardware stages** |

---

## Verdict

**CLEARED for merge + Stage 1 (dry-run) on the condition that the two
seat-gated tests pass on an active VT first.** All six original blocking
FAILs are genuinely fixed (re-derived by reading the diffs and running
the gates, not trusting the self-assessment): the digitizer match is
geometry-only with zero name strings in code and udev; the DRM scan is
read-only and never promotes the eDP or vkms decoy; the render loop
exits on SIGTERM/SIGINT via an async-signal-safe atomic flag with RAII
`Drop` releasing master and a single-fire panic hook unlinking the
socket; hardware paths propagate typed `HwError`s (cairo OOM unwraps are
accepted per adjudication B because the panic hook + Drop make OOM a
clean restart); backlight fail-safe-ON is enforced and tested; and
`--dry-run` runs on real vkms + uinput kernel interfaces. The gates are
green (`fmt`/`clippy -D warnings`/`test`/`check-invariants`/`ci-gate`
all exit 0) and commit hygiene is clean (one commit per ADR, messages
reference ADR numbers, ADR files predate their commits). The
non-blocking nits are: (1) `src/ipc/server.rs` lacks an in-module
ADR-005 pointer (the crate-root annotation suffices but an in-module
comment would be cleaner); (2) `README.md` marks "IPC protocol v1"
"✅ Complete" while the server is deferred — inaccurate; (3) flush-stall
count is unbounded in total (bounded per-iteration) — a future endurance
ADR should cap it. **The one remaining blocker for the hardware stages
(Stage 2+) is Adjudication A**: `test_sim_display_acquires_vkms` and
`test_sigterm_releases_master` are still skipped because this Wayland
session cannot acquire DRM master on vkms — they must be re-run on an
active text VT (`Ctrl-Alt-F2`, log in, `cargo test -- --nocaptured
test_sim_display_acquires_vkms test_sigterm_releases_master`) and PASS
before any hardware stage. Stage 1 (dry-run) itself only needs
`SimInputProvider` (which passed) and `SimDisplayProvider` master acquire
(which needs the VT) — so practically, **Stage 1 should also be re-run
on the active VT** to exercise the full dry-run path. The merge itself
is cleared: the code is correct by inspection and the only gap is
test-environment class, not code.