# ADR 043: Backlight Enable-Write on the Render Path

## Status: Accepted

## Date: 2026-09-26

## Context

Stage-3 attempt #3 (session 033) reached first-pixels but the bar stayed
dark: the render-to-plane path SUCCEEDED (`debugfs dri/2/framebuffer[41]
allocated by = tbard`, 64×2170 XR24, `vmap_use_count=1`; `dri/2/state`
`plane-0 crtc=crtc-0 fb=41 src-pos=60×2170` — CRTC actively scanning
tbard's buffer), yet `appletb_backlight/brightness` stayed at 0 and its
sysfs `brightness` file mtime was unchanged since boot on BOTH starts
(`docs/test-logs/033/step5-hc2.txt`). tbard HOLDS fd 23 →
`appletb_backlight/brightness` (w-only, opened pre-drop, held post-drop —
ADR-015 deterministic select works, ADR-036 self-check passed) but NEVER
performs the enable-write that would light the panel. HC2: "Dark — no
pixels". Acceptance items 4 (first pixels) + 9 (backlight write) NOT met;
the other 9 of 11 live-verified.

This is the ADR-041 lesson again: the test gap that let the bug through
was a missing "non-zero backlight write occurred on the render path"
assertion. The held-fd capability (ADR-015/036) is necessary but not
sufficient — the write must actually happen, deterministically, at the
right time.

## Task 0 — Derivations (cite file:line; docs before code)

### D1 — Ancestry: WHY is there no enable-write? (lost in port, or never designed?)

**Lost in port.** The oracle
`backup_old/tiny-dfr-mbp142/src/backlight.rs` carries the write and it is
structural to its render loop:

- `BacklightManager::new()` (`backlight.rs:78-98`) opens the brightness
  fd (`OpenOptions::new().write(true).open(bl_path.join("brightness"))`,
  `backlight.rs:84-86`) and reads `current_bl` from sysfs
  (`read_attr(&bl_path, "brightness")`, `backlight.rs:94`) but does NOT
  write — the constructor is read-only.
- The write lives in `update_backlight` (`backlight.rs:119-145`): it
  recomputes `new_bl` from the adaptive/idle/lid policy and calls
  `set_backlight(&self.bl_file, self.current_bl)` (`backlight.rs:144`)
  whenever `self.current_bl != new_bl` (`backlight.rs:140`).
- `update_backlight` is called once per loop iteration at the BOTTOM of
  the oracle's render loop (`backup_old/tiny-dfr-mbp142/src/main.rs:1108`),
  i.e. AFTER the first `drm.dirty(&clips)` flush (`main.rs:1005`). So the
  oracle's first visible backlight write happens in the SAME first loop
  iteration as the first frame, just after the flip — frame 1 is flipped
  and then immediately lit, within one ~16ms iteration.

Our port preserved the `update()` call at the bottom of `real_main`'s
loop (`src/main.rs:821`, mirroring the oracle's `main.rs:1108`) and the
`current_bl != new_bl` gate (`src/providers/backlight.rs:213-215`). What
was LOST in the port to the engine architecture is the DETERMINISM: the
oracle's `update_backlight` writes on the first iteration because
`current_bl` (read fresh from sysfs at `new()`) differs from the computed
`new_bl`. Our `SysfsBacklight::update()` has the SAME gate, so it ALSO
should write on the first iteration — yet the HC2 evidence
(`docs/test-logs/033/step5-hc2.txt`) shows the sysfs mtime never moved.
The port introduced a path where the first write is not guaranteed to
reach the kernel: the held-fd write path (`set_backlight_file`,
`backlight.rs:115-135`) does `rewind` + `write!` + `flush` on the held
fd, but nothing on the render path FORCES a write before the first
visible frame. Whether the adaptive `display_bl_path` read silently
failed post-drop (nobody cannot read `intel_backlight/brightness`) and
the fallback `max_bl/2` happened to equal a stale `current_bl`, or the
held-fd write silently did not land, the structural defect is the same:
**there is no deterministic enable-write on the render path.** The
oracle gets away with "write at loop-bottom if changed" because it reads
`current_bl` fresh and the policy always diverges from a dark boot/oracle-
stop state; our engine must not rely on that coincidence.

Classification: **lost in port** — the write existed in the oracle's
`update_backlight` and was ported, but the port did not preserve the
determinism guarantee (an unconditional enable-write at scanout-begin).
The intended write policy in our design (ADR-008 fail-safe-ON,
ADR-015 deterministic select) requires the bar be lit on success — ADR-008
§1 ("a dark bar is never the result of an unnoticed failure") is violated
when the bar is dark because we simply never wrote.

### D2 — Timing: WHERE on the render path should the enable-write live?

Derive from the oracle. The oracle's first write is at loop-bottom
(`main.rs:1108`), AFTER the first flush (`main.rs:1005`). This means the
oracle's frame 1 is flipped BEFORE the backlight is lit — but within the
same ~16ms iteration, so the user perceives frame 1 as already lit. The
constraint for our engine, stated as a ordering requirement:

1. The enable-write must follow the fd open + a successful modeset
   (otherwise we write before scanout exists — the brightness is set but
   nothing is scanning it out; on some panels a brightness write with no
   scanout is harmless, on others it can flicker). In our architecture
   the modeset is `display.acquire()` (`src/main.rs:308` for the real
   DRM path, `src/main.rs:196` for dry-run), which completes BEFORE
   `real_main` is entered (`src/main.rs:479`).
2. The enable-write must precede the FIRST page-flip the user could see
   (otherwise frame 1 is invisible — exactly the session-033 outcome:
   the frame was on the plane, the CRTC was scanning, but the panel
   emitted no light). In our `real_main` the first flush is at
   `src/main.rs:702` (`display.flush(&data, &clips)`), inside the
   `needs_redraw` block (`src/main.rs:677`). The enable-write must
   therefore happen AFTER `display.acquire()` returns Ok (which is before
   `real_main`) and BEFORE the first `display.flush` (which is at
   `src/main.rs:702`).

The correct insertion point is the TOP of `real_main`, after
`display_info` is read (so we know the modeset succeeded and geometry is
resolved) and BEFORE the render loop begins — equivalently, "at
scanout-begin". This is structurally earlier than the oracle's
loop-bottom write, which is fine: writing the backlight before the first
flip guarantees frame 1 is visible, which is strictly better than the
oracle's "flip then light within one iteration".

**T2/ALS interplay — scoped OUT for this ADR.** The oracle re-writes on
every loop iteration via `update_backlight` (`main.rs:1108`), and its
adaptive path reads the main display backlight (`backlight.rs:128-130`)
to follow the ambient brightness. Event-driven re-brightening on
wake/DPMS is a FUTURE ADR (scope note, not implementation). For THIS
ADR, the scope is: **enable-write at scanout-begin + restore/zero on
clean exit.** The existing `backlight.update()` at loop-bottom
(`src/main.rs:821`) is preserved for the adaptive/idle dimming policy —
it is not removed; ADR-043 adds the deterministic first-write that the
adaptive path cannot guarantee.

### D3 — Restore semantics: what happens on clean exit?

The oracle's `BacklightManager::new()` does NOT write on startup
(`backlight.rs:78-98` is read-only). The oracle's first write is
`update_backlight` at loop-bottom (`main.rs:1108`), which computes
`new_bl` from the adaptive/idle policy and writes if changed. So the
oracle lights the bar on its first loop iteration, NOT in its
constructor. HC3 evidence (`docs/test-logs/033/step8-restore-hc3.txt`):
after session-033's clean exits (SIGTERM ×2, exit 0), the oracle was
restarted and "backlight: 54 (oracle holding the panel lit)" + HC3
answer "Yes — F-row + Esc works". The oracle RELIT the bar to a normal
level on its own startup — it does not need tbard to restore anything.

**Decision: clean-exit restore is UNNECESSARY — do NOT write on clean
exit.** Justification:
- The oracle's `update_backlight` (`main.rs:1108`) writes a non-zero
  `new_bl` on its first iteration after restart (the adaptive policy
  with `last_active = Instant::now()` at `backlight.rs:96` means
  `since < BRIGHTNESS_DIM_TIMEOUT`, so `new_bl` is the active level, not
  0). HC3 confirms this live: oracle restart → backlight 54 → bar lit.
- If tbard wrote 0 on clean exit, it would briefly darken the bar in the
  window between tbard's exit and the oracle's first
  `update_backlight` — a user-visible flicker with no benefit.
- If tbard wrote a non-zero "restore" value on clean exit, it would
  race the oracle's own startup write and could conflict (the oracle
  reads `current_bl` at `new()` and writes only if changed — a tbard
  restore value that equals the oracle's computed `new_bl` would make
  the oracle's first write a no-op, leaving the bar at tbard's chosen
  value rather than the oracle's policy). This is strictly worse than
  letting the oracle set its own level.

The clean-exit path (`src/main.rs:827-830`) therefore does NOT add a
backlight write. The `Drop` glue for `SysfsBacklight` does not write
either (there is no `Drop` impl). The bar transitions dark→lit
seamlessly because the oracle's first `update_backlight` writes a
non-zero level within one iteration of its restart. This is the
documented justification; no restore code is implemented.

## Decision

### 1. Enable-write at scanout-begin, through the HELD pre-drop fd

Add an explicit, unconditional enable-write to the held backlight
brightness fd at the top of `real_main`, after `display_info()` confirms
the modeset succeeded and BEFORE the render loop (which contains the
first `display.flush`). The value is the configured `active_brightness`
(default 128, `src/config/yaml.rs:63-65` `default_brightness()`), clamped
to `max_bl`. This is NOT a new invented constant — it is the same
`active_brightness` the adaptive `update()` path uses as its active-level
target (`src/providers/backlight.rs:227-229`), derived from ADR-008's
fail-safe-ON policy (the bar is lit on success, dark only on intentional
idle/lid).

The write goes through the HELD pre-drop fd (`held_brightness_fd`), NOT a
fresh sysfs open. Per ADR-036/NF-020-A, post-drop `nobody` cannot open
sysfs (`docs/adr/036-digitizer-fd-pre-drop.md` "Gap 1/Gap 2"; NF-020-A:
nobody ∉ input, no `seat-touchbar` ACL — `docs/self-assessment-8.md:73,
84, 135`). The held fd was opened pre-drop by
`open_backlight_brightness_fd_pre_drop` (`src/main.rs:895-908`) and
installed via `backlight.hold_brightness_fd(f)` (`src/main.rs:436`). The
enable-write uses `set_backlight_file` (which already routes through the
held fd when present, `src/providers/backlight.rs:117-135`), so no new
write mechanism is needed — only a new CALL SITE on the render path.

The enable-write is implemented as a new `BacklightProvider` trait method
`enable(&mut self) -> anyhow::Result<()>` with a default no-op (so
`MockBacklight` and other simple backends are unaffected), overridden by
`SysfsBacklight` to perform the deterministic write. This keeps the
engine provider-agnostic (ADR-005) and testable: the unit/integration
tests assert the enable-write occurs through the trait, on the render
path, before the first flush.

### 2. Clean-exit restore: NOT implemented (per D3)

Per D3, the oracle relights the bar on its own startup
(`backlight.rs:119-145` `update_backlight` writes a non-zero `new_bl` on
the first iteration; HC3 `docs/test-logs/033/step8-restore-hc3.txt`
confirms "backlight: 54 (oracle holding the panel lit)" + "Yes — F-row +
Esc works"). A tbard restore write would race the oracle's startup write
and risk a dark flicker or a policy conflict. No restore code is added.
The clean-exit path (`src/main.rs:827-830`) and `SysfsBacklight`'s
(nonexistent) `Drop` are unchanged.

### 3. Tests (the ADR-041 lesson: assert the write happened)

- **Unit (mocked fd capture):** `src/providers/backlight.rs` tests —
  construct a `SysfsBacklight` with a tempdir-backed `bl_path` and a
  held fd captured to a `tempfile::tempfile()`; call `enable()`; assert
  (a) the write occurred exactly once, (b) the value is the configured
  `active_brightness` clamped to `max_bl`, (c) the write precedes any
  `update()`/`flush` call (verified by call-order recording on a
  recording backlight wrapper in the render-path unit test below).
- **Unit (render-path ordering):** a `RecordingBacklight` wrapper that
  records every `enable()` / `update()` / `set_brightness()` call in
  order; drive `real_main` with `MockDisplay` + `RecordingBacklight` for
  one iteration; assert the sequence is `[enable, ...flush..., update]`
  — i.e. `enable` is called BEFORE the first `display.flush` and before
  the loop-bottom `update`.
- **Unit (clean exit):** drive `real_main` to a SIGTERM-triggered break
  (`lifecycle::request_shutdown()`); assert NO `set_brightness(0)` /
  restore write occurred on the backlight after the break (per D3).
- **Integration (sim, `--dry-run`):** extend the dry-run backlight
  provider with a write recorder. The dry-run path currently uses
  `MockBacklight` (`src/main.rs:231`); replace it with a
  `RecordingBacklight` wrapping `MockBacklight` so the `--dry-run`
  integration test (in `tests/`) can assert the sim backlight provider
  received the enable-write (non-zero value, exactly once) on the render
  path. This is the sim analog of the real sysfs path — the sim
  provider does not touch real sysfs.

### 4. check-invariants guard (non-vacuous)

Add a grep-style assertion to `scripts/check-invariants.sh` (section 8)
that the render path (`src/main.rs`) contains a call to
`backlight.enable()` (or the trait method `enable`) BEFORE the first
`display.flush` call. This is the guard against the exact regression
that got us here: removing the enable-write. The guard is scoped to code
lines (not comments) per the D-031-2 ride-along. Adversarial demo: plant
a removal on a throwaway copy → guard FAILS → delete the copy (evidence
recorded in `docs/test-logs/034/`).

### 5. D-031-3 ride-along: preflight STEP 0e `--probe-input` strings check

`scripts/bench/interlock-preflight.sh` STEP 0e currently checks
`strings /usr/bin/tbard | grep -c -- --service` (≥ 1, the ADR-038
stale-binary guard). Add a parallel `--probe-input` check: `strings
/usr/bin/tbard | grep -c -- --probe-input` ≥ 1. Rationale: STEP 0d now
calls `/usr/bin/tbard --probe-input` (ADR-041); a stale binary predating
ADR-041 would lack the `--probe-input` flag and fail with "unrecognized
argument" rather than silently passing. The 0e check makes this a loud
preflight FAIL, not a confusing 0d failure.

**STEP 0c write-permission viability — derive, don't guess.** STEP 0c
checks the touchbar backlight device is resolvable
(`interlock-preflight.sh:85-89`). Should 0c also assert write-permission
viability of the held-fd path? Derivation: the held fd is opened
PRE-drop by `open_backlight_brightness_fd_pre_drop` (`src/main.rs:895`)
which runs AS ROOT (the service arm's entry guard verifies `euid == 0`
per ADR-034, before any device work). Preflight runs as root
(`sudo sh scripts/bench/interlock-preflight.sh`), so a 0c write-probe
would test root's ability to open the brightness file — which is always
true (root bypasses sysfs perms). The ACTUAL question is whether the
held fd remains writable POST-drop by nobody — and that is exactly what
the ADR-036 post-drop self-check (`src/main.rs:471-475`) verifies at
runtime. A 0c write-probe would be vacuous (root can always write) and
would NOT catch the ADR-043 defect (the defect is a missing CALL, not a
permission failure — the held fd IS writable, we just never wrote).
**Verdict: do NOT add a 0c write-permission check.** It would be
non-informative (root always passes) and would not have caught the
ADR-043 bug. The ADR-043 guard is the check-invariants grep (section 4
above), not a preflight permission probe.

## Alternatives considered

- **Write in `SysfsBacklight::new` (constructor).** Rejected: the
  constructor runs BEFORE `display.acquire()` (the modeset). D2 forbids
  writing before scanout exists. Also, in service mode `new()` is called
  before the held fd is installed (`main.rs:349` then `main.rs:436`),
  so the constructor cannot use the held fd — it would open per-write,
  which EACCESes post-drop.
- **Rely on `update()` at loop-bottom to light the bar (status quo).**
  Rejected: this is exactly the session-033 failure. The `current_bl !=
  new_bl` gate is not a deterministic guarantee — it depends on the
  stale sysfs read coinciding with the computed target. HC2 proves this
  is unreliable.
- **Restore to 0 on clean exit.** Rejected per D3: causes a dark
  flicker before the oracle relights, and races the oracle's startup
  write. The oracle relights itself (`backlight.rs:119-145`; HC3
  confirms), so restore is unnecessary.
- **Restore to a non-zero default on clean exit.** Rejected per D3:
  races the oracle's `update_backlight` and could leave the bar at
  tbard's value instead of the oracle's policy.

## Impact list

- `src/providers/mod.rs` — add `enable(&mut self) -> anyhow::Result<()>`
  to `BacklightProvider` with a default no-op.
- `src/providers/backlight.rs` — override `enable()` on
  `SysfsBacklight` to perform the deterministic write through the held
  fd (or per-write fallback) with `active_brightness` clamped to
  `max_bl`; update `current_bl` on success; on failure reset to
  fail-safe (ADR-008) and propagate.
- `src/main.rs` — call `backlight.enable()` at the top of `real_main`,
  after `display_info()` and before the render loop; replace the dry-run
  `MockBacklight` with a `RecordingBacklight` wrapper (or extend
  `MockBacklight` with a write recorder) for the integration test path.
- `src/providers/mock_backlight.rs` — add a `write_log` recorder
  (VecDeque of values) so the dry-run/integration path can assert the
  enable-write occurred.
- `scripts/check-invariants.sh` — section 8: grep for the
  `backlight.enable()` call on the render path in `src/main.rs`,
  scoped to code lines (adversarial demo recorded).
- `scripts/bench/interlock-preflight.sh` — STEP 0e: add the
  `--probe-input` strings check.
- `src/providers/backlight.rs` tests — unit tests for enable-write
  value, ordering, and clean-exit no-restore.

## Regression tests

- `test_enable_write_occurs_once_with_active_brightness` — held-fd
  capture, assert one write of `active_brightness` clamped to `max_bl`.
- `test_enable_write_precedes_first_flush` — `RecordingBacklight`
  wrapper, drive `real_main` one iteration, assert `[enable, flush,
  update]` order.
- `test_clean_exit_no_restore_write` — SIGTERM break, assert no
  `set_brightness(0)` after the break.
- `test_dry_run_backlight_enable_write_recorded` (integration,
  `tests/`) — `--dry-run` render path, assert the sim backlight
  provider received the enable-write (non-zero, exactly once).

## References

- `docs/test-logs/033/step5-hc2.txt` — HC2 "Dark — no pixels"; root-cause
  diagnosis (render-to-plane succeeded, backlight never written, sysfs
  mtime unchanged since boot on both starts).
- `docs/test-logs/033/step8-restore-hc3.txt` — HC3 "Yes — F-row + Esc
  works"; oracle relit the bar to 54 on its own restart (D3 evidence).
- `backup_old/tiny-dfr-mbp142/src/backlight.rs:78-98` — oracle `new()`
  (read-only, no startup write).
- `backup_old/tiny-dfr-mbp142/src/backlight.rs:119-145` — oracle
  `update_backlight` (first write, loop-bottom, `current_bl != new_bl`
  gate).
- `backup_old/tiny-dfr-mbp142/src/main.rs:1005,1108` — oracle ordering:
  `drm.dirty` (flush) then `update_backlight` (backlight write) within
  one iteration.
- `src/providers/backlight.rs:81-83` — our `new()` reads `current_bl`
  from sysfs (the stale-read coincidence root).
- `src/providers/backlight.rs:200-237` — our `update()` with the
  `current_bl != new_bl` gate (the non-deterministic path).
- `src/providers/backlight.rs:117-135` — held-fd write path
  (`rewind` + `write!` + `flush`).
- `src/main.rs:895-908` — `open_backlight_brightness_fd_pre_drop`
  (root, pre-drop).
- `src/main.rs:436` — `backlight.hold_brightness_fd(f)` (install held fd).
- `src/main.rs:702` — first `display.flush` in `real_main` (the
  enable-write must precede this).
- `src/config/yaml.rs:63-65` — `default_brightness() = 128` (the value
  source for the enable-write).
- `docs/adr/008-backlight-failsafe.md` §1 — fail-safe-ON policy (dark
  bar is never the result of an unnoticed failure).
- `docs/adr/015-backlight-selection.md` — deterministic touchbar
  backlight select (the held fd is the right one).
- `docs/adr/036-digitizer-fd-pre-drop.md` — pre-drop fd requirement;
  NF-020-A (nobody cannot open sysfs post-drop).
- `docs/adr/041-unified-digitizer-identity.md` — the test-gap lesson
  (assert the predicate fired; analogously, assert the write fired).