# QA Re-Review v4 — fix/hygiene-adr-016-023 (off master, v0.1.2-test3)

Date: 2026-09-26T01:05+01:00
Reviewer: QA & reliability engineer (re-derivation, adversarial)
Branch: `fix/hygiene-adr-016-023` @ `27bbdf5`
Bench: uid=1000 (emzmo), session 3, Type=wayland, State=active, Seat=seat0
Binary: `target/debug/tbard` (rebuilt this session, 00:57)

FREEZE RULE observed: no code changes — findings only. Sim harness only;
the deployed oracle (`backup_old/tiny-dfr-mbp142`) stays untouched.

---

## Per-claim verdicts

### Claim 1 — ADR-020 (three-space model + tap observability): **VERIFIED (with one caveat)**

- **`Geometry` type** (`src/geometry.rs:40-82`): carries `logical` and
  `framebuffer` `FramebufferDims`; `from_framebuffer` swaps short/long
  (lines 52-62) → logical 2170×60 from fb 60×2170. `apply_paint_matrix`
  (78-81) does `translate(logical.height, 0) ∘ rotate(90°)`. Matches the
  ADR.
- **`layout()`/`hit_test()`/gestures in logical space**: `real_main`
  calls `pages[active_page].layout(geometry.logical_width(),
  geometry.logical_height())` (`src/main.rs:362`); `hit_test` is called
  with the gesture's logical (x,y) (`main.rs:480,502`); `update_gesture`
  (`widgets/mod.rs:90`) operates on the input (x,y) which the providers
  already deliver in logical-landscape. No framebuffer-space math leaks
  into layout/hit_test/gestures (the only fb-space use is the
  `DamageRect` clip at `main.rs:378-383` and the surface dims at 281 —
  both correct for the flush/surface).
- **Rotation confined to paint**: `geometry.apply_paint_matrix(&ctx)`
  at `main.rs:364`, applied AFTER `layout` and BEFORE `page.render`. No
  rotation in the hit_test/gesture path. Matches the ADR.
- **Tap observability log**: `main.rs:481-487` logs
  `tbard: tap page={} logical=({x},{y}) hit={widget_id}` on `Gesture::Tap`,
  and `main.rs:503-510` logs the swipe variant with page + logical +
  delta + hit. Matches the ADR's "page id, widget id, logical (x,y),
  gesture classification."
- **Pre-fix pixel-probe FAILING at v0.1.2-test3 from a worktree, test+fix
  in one commit**: the pixel-probe test (`geometry.rs:112-152`) reads
  cairo `ImageSurface` pixels (the dumb-buffer analog) and asserts
  `red_at(pred_x, pred_y) == 0xFF` where `pred_x = logical_height - y`,
  `pred_y = x` — exactly the matrix-predicted device coords. Commit
  `d22c8a6` lands both `src/geometry.rs` (test + `Geometry`) and the
  `main.rs`/`page.rs` fix in one commit. The devlog records the pre-fix
  worktree FAIL. **Caveat**: the pre-fix FAIL is documented in the
  devlog/self-assessment, not archived as a separate test-log artifact
  in this branch; the claim rests on the devlog entry + the test's own
  comment (`geometry.rs:107-111`). Acceptable but noted.
- **Oracle citations** (spot-checked verbatim):
  - `backup_old/tiny-dfr-mbp142/src/main.rs:842`:
    `let (height, width) = drm.mode().size();` — swaps DRM (60,2170) →
    `height=60, width=2170`. **EXISTS, says what ADR claims.**
  - `:599-600`: `c.translate(height as f64, 0.0); c.rotate((90.0f64).to_radians());`
    = `translate(60, 0) ∘ rotate 90°`. **EXISTS, matches.**
  - `:1073-1075`: `x_transformed(width as u32)=x_transformed(2170)`,
    `y_transformed(height as u32)=y_transformed(60)`,
    `hit(width, height, x, y)=hit(2170, 60, x, y)`. **EXISTS, matches.**

### Claim 2 — ADR-021 (hot-reload storm): **VERIFIED**

- **Persistent (non-ONESHOT) watch**: `config/manager.rs:77` flags are
  `IN_MOVED_TO | IN_CLOSE_WRITE` — no `IN_ONESHOT`. `arm_watch` (73-90)
  called once in `new` (51); `check_reload` only re-arms if
  `self.watch.is_none()` (134-136), which happens only on an inotify
  error (144), NOT every iteration. **No per-iteration re-arm.**
- **Queue drained to EAGAIN**: `drain_queue` (95-106) loops
  `read_events` until `EAGAIN`, discarding. Called after a detected
  change both inside the debounce window (162) and before reload (167).
- **200ms debounce, injectable**: `DEFAULT_RELOAD_DEBOUNCE = 200ms`
  (22); `for_test` (57-68) takes an explicit `debounce: Duration`.
  `test_one_write_one_reload` (224-267) injects 20ms. **Injectable.**
- **One write ⇒ one reload; quiescent ⇒ zero**: the test (249-266)
  writes once, asserts `first.is_some()` + `Ok`, then 5 quiescent
  `check_reload` calls assert `is_none()`. PASSES (gate log).
- **Tolerates the delay**: the test uses a 20ms debounce + 30ms sleeps,
  so it tolerates the real 200ms in production via injection. Correct.

### Claim 3 — ADR-022 (SIGTERM-responsive retry): **VERIFIED**

- **`should_shutdown()` every iteration**: `drm_backend.rs:251-254`
  checks at the top of each iteration; `anyhow::bail!("...aborted by
  shutdown signal")` on shutdown. Distinct from the "card never
  appeared" bail at 284.
- **Shutdown-aware 50ms sleeps**: `shutdown_aware_sleep` (422-433)
  polls `should_shutdown()` every 50ms step. Used at 281.
- **Attempted-open injectable**: `open_with_retry_injectable` (233-285)
  takes a closure `F: FnMut() -> Result<...>`; `pub(crate)`; production
  default `default_attempt_open` (68-78) does discover + try_open.
- **Test: injected EBUSY + shutdown ⇒ clean abort < 2s, resources
  released**: `test_retry_aborts_on_shutdown` (451-488) injects
  always-EBUSY, sets the flag via `set_shutdown_for_test` after 50ms,
  asserts `Err` contains "aborted by shutdown" AND `elapsed < 2s`.
  PASSES. The `DrmProvider` has no card/db/fb allocated (the closure
  never returns `Ok`), so there is nothing to leak — resources released
  trivially. **Caveat**: the test does not assert a partially-allocated
  state is released (the injection never allocates); the ADR's
  "releasing any partial resources" is vacuously true for this test.
  Non-blocking.
- **main's outer retry honors shutdown**: `main.rs:155-158` checks
  `should_shutdown()` at the top of each outer-retry iteration and
  `return`s cleanly. **VERIFIED.**

### Claim 4 — ADR-023 (frame counter): **VERIFIED**

- **Frame counter**: `main.rs:298` `frame_counter: u64`, incremented at
  416 (`saturating_add`).
- **Structured log every 100 frames**: `FRAME_LOG_INTERVAL = 100`
  (`main.rs:57`); the log at 418-424 emits
  `tbard: frame stats: frames=N uptime=Ts dirty_flushes=M last_flush=...`
  when `frame_counter.is_multiple_of(FRAME_LOG_INTERVAL)` (417). Fields
  match the ADR (frames, uptime, dirty_flushes, last_flush).
- **`dirty_flushes`/`last_flush_result`**: 299/304, updated on flush
  result (388/392). `dirty_flushes` counts successful flushes
  (391); `last_flush` records `Err(...)`/`Ok`.
- **Test**: `test_frame_log_interval_constant` (845-848) asserts
  `FRAME_LOG_INTERVAL == 100`. PASSES. The ADR explicitly scopes the
  periodic-log emission to the smoke (no unit test for the `info!`
  line) — acceptable.

### Claim 5 — ADR-016/017/018 + ADR-010 amendment: **VERIFIED (016/017); REFUTED (018)**

- **ADR-016 (logind seat-ACL path, corrected EACCES narrative,
  /proc/562/fd root caveat)**: ADR-010 amended at
  `docs/adr/010-...:190-200` (third execution path, context-dependent
  EACCES) and `:26-28` (root-privilege caveat on the `/proc/562/fd`
  capture). ADR-016 itself (`docs/adr/016-...`) documents the seat-ACL
  path with `getfacl`/`udevadm` evidence. **VERIFIED.**
- **ADR-017 (check-invariants asserts deny guard)**:
  `scripts/check-invariants.sh:67-90` greps each required module root
  for `#![deny(clippy::indexing_slicing)]`. All six files carry the
  line (verified: `src/main.rs:19`, `src/widgets/mod.rs:8`,
  `src/widgets/page.rs:4`, `src/widgets/button.rs:4`,
  `src/widgets/slider.rs:7`, `src/config/yaml.rs:4`). Adversarial test
  (T2): removing the line from a throwaway copy → `check-invariants`
  FAILs with the file path. **VERIFIED.**
- **ADR-018 (3 main.rs startup panic!s converted)**: the three
  `panic!`s ARE converted to `log::error!` + `return`
  (`main.rs:123-127, 128-135, 196-203`). **HOWEVER** the ADR's claim
  "the daemon still exits non-zero on a startup failure" is **REFUTED**
  — see Exit-Code Audit below. This is a **BLOCKER for the service
  session.**

### Claim 6 — Gates: **VERIFIED (39/39; reconciliation 32+7=39 holds)**

Raw gate output archived at `docs/test-logs/008/gates-verbatim.log`:

- `cargo fmt --check` → exit 0
- `cargo clippy --all-targets -- -D warnings` → exit 0
- `cargo test` → **39 passed; 0 failed; 0 ignored** (exit 0)
- `scripts/check-invariants.sh` → PASS (exit 0)
- `scripts/ci-gate.sh` → PASS (exit 0)

**39 = 32 + 7 reconciliation**: 7 new tests this branch:
`test_geometry_swaps_framebuffer_to_logical`,
`test_geometry_already_landscape_stays`,
`test_pixel_probe_paint_matrix_in_bounds`,
`test_hit_test_round_trip_logical_space`,
`test_one_write_one_reload`, `test_retry_aborts_on_shutdown`,
`test_frame_log_interval_constant`. 32 baseline + 7 = 39. **Holds.**

**Caveat (test-harness fragility, non-blocking)**:
`test_sigterm_releases_master` spawns `target/debug/tbard`, which
`cargo test` does NOT rebuild (it builds the test bin in
`target/debug/deps/`, not the main `tbard` bin). A stale `tbard` binary
causes the test to FAIL with a REGRESSION panic from the OLD binary
(observed this session with the 00:29 binary before `cargo build --bin
tbard`). The fix is `cargo build --bin tbard` (or `cargo test --bins`)
before `cargo test`. Recommend the ci-gate add a `cargo build --bin
tbard` step or document the prerequisite. Non-blocking for merge; a
real hazard for CI reproducibility.

### Claim 7 — Hygiene (ADR-before-code; one commit per ADR): **VERIFIED with the recorded exception**

- **ADR-before-code**: each ADR's `docs/adr/0NN-*.md` lands in the SAME
  commit as its code (verified via `git show --stat`):
  - `d22c8a6` ADR-020 + `geometry.rs` + `main.rs` + `page.rs`
  - `2af9513` ADR-021 + `config/manager.rs`
  - `075bae3` ADR-022 + `drm_backend.rs` + `lifecycle.rs` + `main.rs`
  - `b457f42` ADR-023 + `main.rs`
  - `00a1689` ADR-016 + 017 + 018 + ADR-010 caveat +
    `check-invariants.sh` + `main.rs`
  The ADR files are authored in the commit (so predate the merge);
  no commit adds code without its ADR.
- **One commit per ADR — EXCEPTION recorded**: `00a1689` bundles
  ADR-016 + ADR-017 + ADR-018 + the ADR-010 caveat in one commit. This
  is the documented exception (the prompt asked to record it). The
  commit message explicitly enumerates the four items ("Task F (QA v3
  proposals 016/017/018 + ADR-010 caveat)").
- **Revertability**: bundling 016+017+018 means they revert together.
  016 is docs-only (ADR-010 amendment), 017 is the invariant-guard
  grep, 018 is the `panic!`→`return` conversion. They are logically
  independent (reverting 018 should not revert 017), so the bundle is
  **less granular than ideal** but each item is internally coherent.
  **Non-blocking**; logged as the recorded hygiene exception.

---

## Investigation C — Touch Coordinate Scaling: **VERIFIED PRESENT (sim/real divergence confirmed; Stage-4 only)**

Full evidence at `docs/test-logs/008/008-issue-C.md`.

- **Does the input provider apply an ABS→logical scale today? YES** —
  `src/providers/input.rs:178-184` uses
  `dn.x_transformed(2170)` / `dn.y_transformed(60)`, libinput's
  raw→logical scale. Matches the oracle
  (`backup_old/tiny-dfr-mbp142/src/main.rs:1073-1074`).
- **Sim/real divergence CONFIRMED**: `SimInputProvider` sets the uinput
  ABS_MT max to 2170/60 (`sim_input.rs:38-39,100-104`), so
  `x_transformed(2170)` is the identity map. The sim NEVER exercises
  the 32767→2170 scale the real digitizer requires.
- **libinput returns logical-px (not mm)**: `x_transformed(width)`
  scales by the abs info `maximum`, not `ABS_MT_RESOLUTION`; the real
  digitizer has `resolution: 0` (per ADR-020's live EVIOCGABS). No mm
  path is in play; the oracle and our engine agree.
- **Classification**: **Stage-4 blocker only — does NOT hold Stage 3.**
  The real-input scale is correct by code + oracle provenance; Stage 3
  (merge) does not depend on exercising it.
- **Proposed ADR-024 (next session, do NOT fix now)**: (1) a
  uinput-backed test with abs_max disjoint from logical (32767/127)
  asserting the scale; (2) wire `LibinputProvider`'s scale target to
  `Geometry` instead of the hardcoded `(2170, 60)` at `input.rs:178`.
- **Standing Stage-4 precondition** (hid_field_extract
  once-vs-per-report via hid-recorder) can share a future
  evidence-capture session with a live `EVIOCGABS` re-capture (the
  `docs/test-logs/000/evtest-input13.log` abs-MT line is empty; the
  ADR-020 live capture is not archived in-tree).

---

## Exit-Code Audit (ADR-018 risk): **BLOCKER for the service session**

Full evidence at `docs/test-logs/008/exit-code-audit.md`.

`fn main()` (`src/main.rs:96`) returns `()`. The three ADR-018-converted
startup-failure paths (`return` at 126, 133, 201) and the real-mode
"card never appeared" path (182) all exit **0**, as do the
`Ok(Err(e))`/`Err(_)` engine-failure matches (145, 146, 209, 210).

**Live evidence (this session, fresh binary)**:
```
$ HOME=$(mktemp -d) RUST_LOG=info ./target/debug/tbard --dry-run
[INFO  tbard] tbard: Touch Bar engine starting (mode: dry-run)
[ERROR tbard] tbard: dry-run SimDisplay acquire failed: Permission denied (os error 13)
$ echo $?
0
```
Control: `--bogus-arg` → exit 2 (correct).

**ADR-018's own claim is REFUTED**: "the daemon still exits non-zero on
a startup failure" is false. A `Restart=always` service (ADR-019,
reserved) would treat these startup failures as success (exit 0) and
spin silently. This is a **pre-existing** latent bug (the pre-ADR-018
`catch_unwind` path also exited 0 on a caught panic) that ADR-018's
conversion preserved rather than fixed.

**Fix pointer (ADR for the NEXT session — freeze respected, no fix
here)**: `fn main()` should return `Result<(), E>` or call
`std::process::exit(1)` on startup-failure paths. SIGTERM-clean exit
(157) may stay 0; acquire/backlight/card-never-appeared (126, 133, 182,
201) and the engine-`Err` matches (145, 146, 209, 210) must exit
non-zero. Pair with a sim test asserting `$? != 0` on an injected
acquire failure. Suggest folding into ADR-019 (the service session) or a
standalone ADR-024.

---

## Gate output (verbatim)

Archived at `docs/test-logs/008/gates-verbatim.log`. Summary:

```
### Gate 1: cargo fmt --check         → FMT_EXIT=0
### Gate 2: cargo clippy --all-targets -- -D warnings → CLIPPY_EXIT=0
### Gate 3: cargo test                → 39 passed; 0 failed  TEST_EXIT=0
### Gate 4: scripts/check-invariants.sh → check-invariants: PASS  INV_EXIT=0
### Gate 5: scripts/ci-gate.sh        → CI gate: PASS  CIGATE_EXIT=0
```

---

## T4 LIVE re-verification: **PARTIALLY VERIFIED; seat-gated paths UNVERIFIABLE this bench**

- **Hermetic smoke** (`HOME=$(mktemp -d) tbard --dry-run`): the daemon
  CANNOT acquire vkms master in this bench state — Hyprland (PID 749)
  holds `card2`. As uid 1000: EACCES; under sudo: EBUSY. The daemon
  logs the typed error and exits (exit 0 — see Exit-Code Audit). **No
  frames rendered; no tap log produced.** The T4 acceptance
  ("frames render; tap log present with widget id + logical coords")
  **could NOT be exercised** this session.
- **Tap-log observability assertion (S1-F1)**: asserted from code
  (`main.rs:481-487` logs `tap page={} logical=({x},{y}) hit={widget_id}`)
  + the unit test `test_hit_test_round_trip_logical_space` which
  exercises the logical-space hit_test. The live log emission is
  **UNVERIFIABLE** this session (no master → no render loop → no tap).
- **SIGTERM clean exit / immediate rerun**: cannot be exercised (no
  running daemon to signal). The `test_sigterm_releases_master` unit
  test SKIPs (case 2, EACCES) with verbatim stderr — no regression.
- **Seat-gated tests** (`test_sim_display_acquires_vkms`,
  `test_sigterm_releases_master`): both **SKIP** (do not EXECUTE) —
  Hyprland holds card2 master. ADR-013 correctly classifies this as
  the seat/privilege case and skips with verbatim stderr. The prompt's
  "must EXECUTE and PASS in a granted environment" is **UNVERIFIABLE**
  in this bench state. The logind seat-ACL is granted
  (`user:emzmo:rw-` on card2, active seat0), but Hyprland's master
  lease prevents the acquire. This is exactly the ADR-016 bench-change
  caveat: "if Hyprland holds card2 without the seat-ACL grant, the
  unprivileged path EACCESes." Bench state archived at
  `docs/test-logs/008/bench-state.md`; seat-gated attempt at
  `docs/test-logs/008/seat-gated-attempt.log`; smoke attempt at
  `docs/test-logs/008/hermetic-smoke-attempt.log`.

**Prior live evidence** (`docs/test-logs/006/stage1/run1-smoke.log`):
at a prior bench state (Hyprland not holding card2, release binary),
the daemon DID acquire vkms, render frames, and exit cleanly on
SIGTERM. That evidence is stale for THIS branch's startup paths
(ADR-018 changed them), but the render-loop behavior (frames, SIGTERM)
is unchanged by ADR-016-023 except the frame-counter log (ADR-023).
The ADR-018 startup-failure exit-code change is the one live path that
DID change and WAS re-verified this session (→ exit 0, the blocker).

uid=1000, session=wayland/seat0 active, per run.

---

## Adversarial checks (T2)

- **Deny-line removal in a throwaway copy**: removed
  `#![deny(clippy::indexing_slicing)]` from `src/widgets/page.rs` in a
  copy at `/tmp/opencode/inv-test/`. `check-invariants.sh` FAILed:
  `FAIL: ADR 017 src/widgets/page.rs missing #![deny(clippy::indexing_slicing)]`.
  The guard guards the guard. **VERIFIED.**
- **Pixel-probe reads dumb-buffer pixels + asserts matrix-predicted
  device coords**: `geometry.rs:112-152` reads `surface.data()` and
  asserts `red_at(logical_height - y, x) == 0xFF` for two predicted
  points. **VERIFIED.**
- **Framebuffer-space math leak in hit_test/gesture paths**: none
  found. Layout/hit_test/gestures use logical dims; only the
  `DamageRect` clip and surface dims use framebuffer (correct).
  **VERIFIED.**

---

## Final paragraph

**BLOCKED.** The branch's static gates are green (fmt 0, clippy 0,
39/39 tests, invariants PASS incl. the new deny-guard, ci-gate PASS),
the ADR-020/021/022/023/016/017 code matches the ADRs, the oracle
citations are verbatim-accurate, the adversarial deny-line guard works,
and Investigation C confirms the abs→logical scale is present and
correct (Stage-4 only). **Two blockers prevent "CLEARED FOR MERGE +
service session":**

1. **Exit-Code Audit (ADR-018) — BLOCKER for the service session.**
   `fn main()` returns `()`, so every ADR-018-converted startup-failure
   path (`log::error!` + `return`) exits **0**, refuting ADR-018's own
   claim. Live-confirmed: dry-run EACCES → exit 0. A `Restart=always`
   service would spin on a "successful" exit 0. Fix: `main` returns a
   typed `Result` (or `exit(1)` on startup failures); add a sim test
   asserting `$? != 0` on an injected acquire failure. → propose
   **ADR-024** (or fold into the reserved **ADR-019** service session).
   Evidence: `docs/test-logs/008/exit-code-audit.md`.

2. **T4 live re-verification incomplete — seat-gated paths did not
   EXECUTE this session** (Hyprland holds card2 master; both
   seat-gated tests SKIP with EACCES, no frames rendered, no tap log
   captured). This is a bench-state limitation (ADR-016 caveat), not a
   code defect, but the prompt's mandatory T4 live acceptance (tap log
   with widget id + logical coords) is **UNVERIFIABLE** here. To clear:
   re-run on a bench where Hyprland releases card2 (set
   `AQ_DRM_DEVICES` to the i915 by-path so Hyprland drops card2, or run
   on a clean VT with vkms), rebuild `cargo build --bin tbard`, then
   re-execute the hermetic smoke + the two seat-gated tests and assert
   frames + tap log + master release. The render-loop behavior is
   unchanged by this branch except ADR-023's frame-counter log; the
   ADR-018 startup-failure path is the one changed live path and WAS
   re-verified (→ blocker 1).

**Non-blocking findings (logged, not blockers):**
- Hygiene exception `00a1689` bundles ADR-016+017+018+caveat (revert
  granularity coarser than ideal; recorded per the prompt).
- Test-harness fragility: `cargo test` does not rebuild
  `target/debug/tbard`; a stale binary makes
  `test_sigterm_releases_master` FAIL with a stale-binary REGRESSION.
  Add `cargo build --bin tbard` to ci-gate or document the
  prerequisite.
- ADR-018's `test_retry_aborts_on_shutdown` does not assert
  partial-resource release (the injection never allocates); vacuously
  true. Consider a closure that allocates then fails on a later call.
- Investigation C sim/real divergence: the abs→logical scale is
  untested by the sim (sim raw range == logical). Propose ADR-024 for
  a uinput-backed scale test + wiring `LibinputProvider`'s scale
  target to `Geometry`. Stage-4 only.

**To unblock**: land the exit-code fix (ADR-024/019), then re-run T4
on a bench where the daemon can acquire vkms. The branch is **not
cleared for merge + service session** until the exit-code blocker is
fixed and T4's live tap-log acceptance is exercised on a granted
bench.