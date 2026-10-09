# Review Report v14 — fix/transposed-dims-adr-054-056 (re-verification)

**Reviewer:** opencode QA & reliability agent (independent of the implementer —
this was the first fix session executed by the orchestrator directly via
`sys_exec` + file tools, not by an opencode session).
**Branch:** `fix/transposed-dims-adr-054-056` off master `325ee31` (v0.2.7 source).
**Date:** 2026-09-27.
**Scope:** ADR-054 / ADR-055 / ADR-056 + s051 erratum + session-053 docs.
**Freeze rule:** no source changes; findings only. No source changes were made
during this review (adversarial plants were applied to throwaway working-tree
copies and restored from byte-identical backups; `diff` confirmed clean
restoration after every step).

## Per-claim verdicts

### Claim 1 — ADR-054: damage clip corner construction — VERIFIED

**Diff evidence (commit 49ff7ea, `src/providers/drm_backend.rs`):**

Pre-fix mapping (removed, drm_backend.rs:463-465 of the pre-fix tree):
```rust
let drm_clips: Vec<ClipRect> = clips
    .iter()
    .map(|c| ClipRect::new(c.y, c.x, c.h, c.w))
    .collect();
```
Fix (drm_backend.rs:466-467, current tree):
```rust
let drm_clips: Vec<ClipRect> = clips.iter().copied().map(damage_clip_rect).collect();
```
Fix body (drm_backend.rs:491-493, current tree):
```rust
pub(crate) fn damage_clip_rect(c: DamageRect) -> ClipRect {
    ClipRect::new(c.x, c.y, c.x.saturating_add(c.w), c.y.saturating_add(c.h))
}
```

Confirmed: `damage_clip_rect(DamageRect) -> ClipRect` is `pub(crate)`, takes
`DamageRect` by value (`Copy`), and is called via `.copied().map(damage_clip_rect)`.
The mapping is corner construction `ClipRect::new(c.x, c.y, c.x + c.w, c.y + c.h)`
with **no axis swaps**. The pre-fix mapping `ClipRect::new(c.y, c.x, c.h, c.w)`
was transposed and is removed entirely. (The `saturating_add` guards `u16`
overflow on absurd inputs — a safety refinement, not a semantic change vs the
report's `c.x + c.w`.)

**Independent source check — three sources agree:**

1. **drm-0.14.1 crate** — `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/drm-0.14.1/src/control/mod.rs:1484-1514`:
   ```rust
   pub struct ClipRect(ffi::drm_sys::drm_clip_rect);
   impl ClipRect {
       /// Create a new clipping rectangle.
       pub fn new(x1: u16, y1: u16, x2: u16, y2: u16) -> Self { ... }
       pub fn x1(self) -> u16 { ... }  pub fn y1(self) -> u16 { ... }
       pub fn x2(self) -> u16 { ... }  pub fn y2(self) -> u16 { ... }
   }
   ```
   Confirmed: `ClipRect::new` takes **(x1, y1, x2, y2) corner coordinates**, NOT
   (x, y, w, h). The pre-fix call `new(c.y, c.x, c.h, c.w)` therefore passed
   `x1=c.y, y1=c.x, x2=c.h, y2=c.w` — i.e. the width/height were placed in the
   x2/y2 corner slots, which on a 60×2170 fb submitted `x2=2170, y2=60`.
2. **appletbdrm driver** — `backup_old/appletbdrm-1.2/appletbdrm.c:1055-1068`:
   ```c
   drm_atomic_for_each_plane_damage(&iter, &damage) {
       struct drm_rect dst_clip = state->dst;
       ...
       if (!drm_rect_intersect(&dst_clip, &damage))
           continue;
       frame->begin_x = cpu_to_le16(damage.y1);
       frame->begin_y = cpu_to_le16(adev->height - damage.x2);
       ...
   }
   ```
   Confirmed: `drm_rect_intersect` **clamps** (intersects `dst_clip` with
   `damage`); it does not reject. Only the intersected region is transmitted.
   The transposed `x2=2170, y2=60` clamps to a 60×60 window → only the leftmost
   ~60 px of the bar ever transmitted (F-045-1, live-confirmed s052 HC2).
3. **Our flush** — `src/providers/drm_backend.rs:466-467, 491-493` (current tree):
   corner construction, no swaps (quoted above).

Three sources agree. **VERIFIED.**

### Claim 2 — ADR-055: directory watch + name filter + IN_IGNORED — VERIFIED

**Diff evidence (commit b04a047, `src/config/manager.rs`):**

Pre-fix `arm_watch` (manager.rs:94-99 of the pre-fix tree):
```rust
fn arm_watch(&mut self) {
    for path in &self.paths {
        let flags = AddWatchFlags::IN_MOVED_TO | AddWatchFlags::IN_CLOSE_WRITE;
        match self.inotify.add_watch(path, flags) {
            ...
        }
    }
}
```
— watched the file **inode** directly; no `IN_IGNORED` handling; no `watch_name`.

Fix (current tree):
- `arm_watch` (manager.rs:106-124): resolves `path.parent()`, calls
  `add_watch(parent, flags)`, stores `self.watch_name = path.file_name()`.
- `check_reload` (manager.rs:186-203): filters events by
  `Some(evt.wd) == self.watch && watch_name.is_none_or(|n| evt.name.as_ref() == Some(n))`;
  handles `IN_IGNORED` → `self.watch = None; self.watch_name = None` (re-arm next iteration).
- New struct field `watch_name: Option<std::ffi::OsString>` (manager.rs:43),
  initialized `None` in both constructors (manager.rs:71, 89).

Confirmed: the pre-fix code watched the file directly (`add_watch(path, ...)`)
with no `IN_IGNORED` handling; the fix watches the parent directory, filters by
stored filename, and handles `IN_IGNORED`. **VERIFIED.**

### Claim 3 — ADR-056: input_scale_dims returns logical dims — VERIFIED

**Diff evidence (commit 15d4643, `src/main.rs`):**

Pre-fix call site (main.rs:328-330 of the pre-fix tree):
```rust
let tb_dims = drm
    .display_info()
    .map(|i| (i.width, i.height))
    .unwrap_or((60, 2170));
```
Fix (main.rs:333-336, current tree):
```rust
let tb_dims = drm
    .display_info()
    .map(|i| input_scale_dims(&i))
    .unwrap_or((2170, 60));
```
Fix body (main.rs:1152-1158, current tree):
```rust
fn input_scale_dims(info: &providers::DisplayInfo) -> (u16, u16) {
    let g = geometry::Geometry::from_framebuffer(geometry::FramebufferDims::new(
        info.width,
        info.height,
    ));
    (g.logical.width, g.logical.height)
}
```

Confirmed: `input_scale_dims(&DisplayInfo) -> (u16, u16)` is a pure fn that
constructs `Geometry::from_framebuffer` and returns `(g.logical.width,
g.logical.height)` — logical (landscape) dims, not the portrait `DisplayInfo`
dims. The call site uses it instead of the old `.map(|i| (i.width, i.height))`.
The default fallback was also corrected from `(60, 2170)` to `(2170, 60)`.

**Independent check — `Geometry::from_framebuffer` (src/geometry.rs:52-62):**
```rust
pub fn from_framebuffer(fb: FramebufferDims) -> Self {
    let (long, short) = if fb.width >= fb.height {
        (fb.width, fb.height)
    } else {
        (fb.height, fb.width)
    };
    Self { logical: FramebufferDims::new(long, short), framebuffer: fb }
}
```
For fb `(60, 2170)` → `long=2170, short=60` → `logical = (2170, 60)`. The
long/short split is performed. Confirmed. **VERIFIED.**

## Adversarial non-vacuity (independently reproduced)

All three reproductions used throwaway working-tree edits with byte-identical
backup/restore; `diff` confirmed clean restoration after each. Verbatim logs in
`docs/test-logs/054/fix-report/adversarial-reproduction-v14.log`.

### ADV-1 (ADR-054) — FAIL then PASS
- **Planted form** (drm_backend.rs:491-493): replaced `damage_clip_rect` body
  with `ClipRect::new(c.y, c.x, c.h, c.w)` (the transposed pre-fix).
- **Command:** `cargo test --bin tbard adr054_fullscreen`
- **FAIL (verbatim):**
  ```
  test providers::drm_backend::tests::test_adr054_fullscreen_damage_clip_covers_the_framebuffer ... FAILED
  thread '...' panicked at src/providers/drm_backend.rs:829:9:
  assertion `left == right` failed
    left: (0, 0, 2170, 60)
   right: (0, 0, 60, 2170)
  test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 95 filtered out
  ```
- **Restored; re-run:** `1 passed; 0 failed`. `diff` clean.

### ADV-2 (ADR-055) — FAIL then PASS (faithful pre-fix demo)
- **Method:** `git show master:src/config/manager.rs` (file-inode watch, no
  `IN_IGNORED` handler, no `watch_name`) → spliced in the two ADR-055 test fns
  (`test_adr055_watch_survives_atomic_replace`,
  `test_adr055_name_filter_ignores_other_files`) from the branch's `manager.rs`
  by inserting them before the tests-mod closing brace. This is the TRUE
  pre-fix implementation, not a naive revert.
- **Pre-fix `arm_watch` in spliced file** (manager.rs:94-106): `add_watch(path,
  flags)` on the file inode; no `IN_IGNORED` handling; no `watch_name` field.
- **Command:** `cargo test --bin tbard adr055_watch_survives`
- **FAIL (verbatim):**
  ```
  test config::manager::tests::test_adr055_watch_survives_atomic_replace ... FAILED
  thread '...' panicked at src/config/manager.rs:384:14:
  ADR-055: replace #2 must ALSO reload after an atomic replace
  test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 95 filtered out
  ```
- **Restored branch version; re-run (both ADR-055 tests):** `2 passed; 0
  failed`. `diff` clean.
- **NOTE (per the report's caveat):** a naive revert (file-watch + the new
  `IN_IGNORED` handler) may PASS — this is the "considered alternative"
  documented in ADR-055 (`IN_IGNORED`-rearm alone is viable; directory watch
  chosen for no dead window). The faithful demo required the TRUE pre-fix code
  with no `IN_IGNORED` handler at all, which is what was reproduced.

### ADV-3 (ADR-056) — FAIL then PASS
- **Planted form** (main.rs:1152-1158): in `input_scale_dims`, replaced
  `(g.logical.width, g.logical.height)` with `(info.width, info.height)`
  (portrait dims — the pre-fix).
- **Command:** `cargo test --bin tbard adr056`
- **FAIL (verbatim):**
  ```
  test tests::test_adr056_input_scale_dims_are_logical ... FAILED
  thread '...' panicked at src/main.rs:1957:9:
  assertion `left == right` failed: ADR-056: scale targets must be LOGICAL dims
    left: (60, 2170)
   right: (2170, 60)
  test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 95 filtered out
  ```
- **Restored; re-run:** `1 passed; 0 failed`. `diff` clean.

**All three adversarial reproductions confirmed FAIL-then-PASS.** The
non-vacuity claim of the report is independently substantiated.

## Gates (verbatim)

Captured in `docs/test-logs/054/fix-report/gates-v14.log`. Summary:

| Gate | Result |
|------|--------|
| `cargo fmt --check` | PASS (exit 0, no output) |
| `cargo build --bin tbard` | PASS (`Finished dev profile … in 0.93s`) |
| `cargo clippy --all-targets -- -D warnings` | PASS (`Finished … in 0.17s`) |
| `cargo test` | PASS — **96 unit + 5 integration = 101 passed; 0 failed** |
| `scripts/check-invariants.sh` | PASS (`check-invariants: PASS`) |
| `scripts/ci-gate.sh` | PASS (`CI gate: PASS`) |
| `bash -n packaging/PKGBUILD` | PASS (exit 0, no output) |

Test-count reconciliation: 92 baseline (v0.2.7) + 4 new (1 ADR-054 + 2 ADR-055 +
1 ADR-056) = 96 unit; 5 integration unchanged = 101 total. Matches the report's
claim.

## Commit hygiene

Branch commits off master `325ee31`:
```
7f37dce  ADR-054/056: transposed damage clip + input scale — three-source derivations, live-confirmed (session 052)
f8a1937  ADR-055: config watcher re-arm — directory watch + name filter (root cause: file-inode watch dies on atomic replace)
49ff7ea  ADR-054: damage clip corner construction (damage_clip_rect) — F-045-1 …
b04a047  ADR-055: directory watch + name filter + IN_IGNORED handling (file-inode watch died on atomic replace …)
15d4643  ADR-056: input_scale_dims — logical dims for the ABS→logical scale …
d65d8f4  docs: session 053 — ADR-054/055/056 fix session …
```

**ADR-before-code ordering within each pair:**
- ADR-054: docs `7f37dce` → code `49ff7ea`. ✓
- ADR-055: docs `f8a1937` → code `b04a047`. ✓
- ADR-056: docs `7f37dce` → code `15d4643`. ✓

**Deviation noted:** ADR-054 and ADR-056 share an ADR-docs commit (`7f37dce`
carries both ADR docs). This is a deviation from strict one-ADR-per-commit for
the docs-only step. **Assessment: non-blocking.** The two code commits
(`49ff7ea` for ADR-054, `15d4643` for ADR-056) are individually revertible —
`git revert 49ff7ea` removes only the damage-clip fix; `git revert 15d4643`
removes only the input-scale fix; the shared docs commit reverts both ADR docs
together, which is consistent with the code reverts being independently
appliable. Revertability is preserved. (If strict per-ADR docs isolation is
desired for future sessions, split docs commits one-per-ADR; not a blocker
here.)

## Docs checks

- **s051 erratum** (`docs/test-logs/051/REPORT.md`): a blockquote erratum is
  appended after the original closing paragraph. The original closing paragraph
  ("STAGE 4 ABORT … The interlock protocol itself … remains valid and reusable
  verbatim.") and the ADR-proposals list ("ADR-054: DRM-side panel-activation …
  ADR-055: config-watcher re-arm …") are preserved **verbatim** above the
  erratum. The erratum (lines 113-126) is a `>` blockquote citing ADR-054 +
  session 052's HC2 + the three sources (drm crate `ClipRect::new(x1,y1,x2,y2)`
  + our transposed flush + `appletbdrm.c:1055-1068` clamp), and lists the
  five-corrections lineage (s025 ordering, s029 acquire, s037 dispatch, s040
  "never wrote" → "wrote + decayed", s051 panel-activation → transposed clip).
  ✓
- **ADR-055 considered-alternative** (`docs/adr/055-config-watcher-rearm.md`,
  lines 30-36): documents that "Re-arm-on-IN_IGNORED with a FILE watch alone"
  is viable (discovered when the first adversarial plant self-healed) and
  explains why the directory watch was chosen instead ("no dead window"). ✓
- **devlog session 053 entry** (`devlog.md:7231-7264`): present with the three
  ADR summaries (ADR-054/055/056), gates reconciliation (101 tests, all green),
  and the Stage-4 hardware-acceptance remainder (items 1, 3, 5 still need the
  fixes live). ✓

## Host state (read-only)

- **Oracle process:** `tiny-dfr-mbp142` (pid 54206) alive at review start and
  end. (debugfs `/sys/kernel/debug/dri/<N>/clients` is not readable without
  root on this bench; the precise "sole master, uid 65534, never tgid/cardN"
  assertion is **UNVERIFIABLE** from this session without a privilege
  escalation, which the HOST SAFETY RULES forbid. The oracle process being
  alive + `/usr/bin/tbard` unchanged + tbard service inactive/disabled is
  consistent with the claimed state.)
- **/dev/input:** 18 event nodes (matches baseline; unchanged).
- **/etc:** untouched — `/etc/touchbar` contains only `config.yaml.example`
  (no live config; original state).
- **/usr/bin/tbard:** sha256
  `18b368c44cab753d92353ba197b0248f41b8768d171cf8fac11d3ed4c426474e` — the
  v0.2.7 build (the v0.2.8 reinstall is the merge session's job, not done
  here). ✓
- **tbard service:** inactive + disabled. No service lifecycle actions taken. ✓
- No `/etc` writes. Oracle untouched and lit.

## New findings

None. No source changes (findings only, per the freeze rule). No new ADR
proposals to log — the three ADRs under test are coherent, the implementation
matches the docs, and the adversarial demos confirm non-vacuity.

## Final

**CLEARED FOR MERGE (v0.2.8) + binary reinstall + Stage-4 completion interlock
(full-bar shapes + tap-hits-widget + hot-reload visual).**

All three claims (ADR-054, ADR-055, ADR-056) are VERIFIED by diff evidence plus
independent source checks (drm-0.14.1 crate, appletbdrm driver, our flush —
three sources agree for ADR-054; `Geometry::from_framebuffer` long/short split
for ADR-056). All three adversarial reproductions independently FAIL-then-PASS
with verbatim transcripts. All seven gates PASS verbatim, with 101 tests green
(96 unit + 5 integration, reconciled). Commit hygiene is good (ADR-before-code
within each pair; the shared ADR-054/056 docs commit is a non-blocking
deviation with individually-revertible code commits). Docs checks pass (s051
erratum preserves the original verbatim; ADR-055 considered-alternative
documented; devlog session 053 present). Host state is consistent with the
claimed safe state (oracle alive, /usr/bin/tbard unchanged at v0.2.7, /etc
untouched, tbard inactive). The merge session's remaining obligations are the
v0.2.8 binary reinstall and the Stage-4 hardware-acceptance interlock (item 1
full-bar shapes, item 3 tap-hits-widget, item 5 hot-reload visual) — all three
depend on these fixes being live, which is exactly what this branch delivers.