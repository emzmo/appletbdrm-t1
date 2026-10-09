# ADR 044: BacklightProvider Dispatch Audit (trait-override verification + class audit)

## Status: Accepted (audit-only — no `src/` change required)

## Date: 2026-09-26

## Context

Session 037 (`docs/test-logs/037/step3-5-start-live-state-hc2.txt`
"DEFECT ANALYSIS") recorded a read-only source analysis claiming that
`impl BacklightProvider for SysfsBacklight` does NOT override `enable()`,
so the production call site `real_main` (`src/main.rs:502`, generic
over `B: BacklightProvider`) dispatches `backlight.enable()`
(`src/main.rs:547`) to the trait's no-op default
(`src/providers/mod.rs:120-122`), leaving the ADR-043 enable-write of
128 inert and the panel dark. The session-037 unit tests were claimed
to mask the gap because they call `enable()` on a CONCRETE
`SysfsBacklight` (inherent-method resolution) rather than through the
trait.

That analysis was the premise for this branch
(`fix/backlight-dispatch-adr-044-046`). ADR-044's stated fix surface
was: add a one-line `fn enable()` override in
`impl BacklightProvider for SysfsBacklight` forwarding to the inherent
`SysfsBacklight::enable`, plus a trait-object regression guard.

**This ADR's first action was to verify the premise against the
repository at HEAD `ccd7024` (== `v0.2.4`). The premise is FALSE.**
The override and the trait-dispatch regression test both already
exist, landed in the original ADR-043 commit `38392ce`
(`git show 38392ce:src/providers/backlight.rs` confirms the override
in the same commit that added the inherent method). The session-037
source analysis misread the file. ADR-044 as a *code fix* is therefore
a no-op — there is no `src/` change to make.

What remains valuable — and is the REAL deliverable of this ADR — is
the **class audit**: enumerate every `BacklightProvider` method called
through generic/trait-object paths in `real_main`, verify the
`SysfsBacklight` impl overrides it (or consciously inherits a correct
default), and grep the codebase for any other instance of the bug
class "inherent method exists + tests target the concrete type +
production dispatches to the default" across ALL provider traits
(`DisplayProvider`, `InputProvider`, `BacklightProvider`). The audit
table is below. The regression-guard requirement is also addressed
(again, the guard already exists — it is documented here, not added).

This ADR is therefore **audit-only**: it records the verification, the
class audit table, the regression-guard evidence, and the discrepancy
with the session-037 analysis. No `src/` lines change. The branch
carries ADR-045 (RUST_LOG=info) and ADR-046 (runbook value-only probe)
as the real code/docs changes.

## The bug class (formal definition)

The defect class ADR-044 is chartered to find:

> An inherent method `M` exists on a concrete type `T` that implements
> trait `Tr`. The trait provides a default body for `M` (or `M` is
> required). `impl Tr for T` does NOT override `M`. The production
> call site is generic (`&mut T where T: Tr`) or uses a trait object
> (`&mut dyn Tr`), so the call resolves to the trait default, not the
> inherent method. Unit tests call `M` on a CONCRETE `T` (so inherent
> resolution makes them exercise the real body) and PASS, masking the
> gap. The inherent method is dead code in production.

Rust rule (cited for the audit): on a concrete-typed call, inherent
methods take priority over trait methods; through a generic bound or
trait object, only the trait's methods are visible, and the default
body is used if the impl does not override. The gap is invisible to
`grep` alone (the inherent method and the trait default both exist as
text); it requires resolving which method the production call site
dispatches to.

## Task 0 — Premise verification (the s037 analysis vs the repository)

### V1 — The trait override IS present at HEAD.

`src/providers/backlight.rs:305-307` (present at `ccd7024`, at the
merge `17d5352`, and in the ADR-043 commit `38392ce` itself):

```rust
impl BacklightProvider for SysfsBacklight {
    ...
    fn enable(&mut self) -> anyhow::Result<()> {
        SysfsBacklight::enable(self).map_err(Into::into)
    }
}
```

This mirrors the existing `update`/`notify_activity`/`set_lid_closed`
forwarding pattern (`backlight.rs:293-304`) exactly as ADR-044's
proposed fix surface specified. `git show 38392ce -- src/providers/
backlight.rs` shows both the inherent `pub fn enable` (line +175) and
the trait override (`+    fn enable(&mut self) -> anyhow::Result<()> {
SysfsBacklight::enable(self).map_err(Into::into) }`) landing in the
SAME commit. The override was never missing.

### V2 — The trait-dispatch regression test IS present at HEAD.

`src/main.rs:1434` `test_render_path_enable_write_precedes_first_flush_and_update`
drives `real_main<B: BacklightProvider>` (`real_main` signature at
`src/main.rs:502`) with `RecordingBacklight<MockBacklight>`
(`src/main.rs:1330-1375`). `RecordingBacklight`'s trait impl
(`main.rs:1371-1374`) pushes `"enable"` onto the call log and THEN
calls `self.inner.enable()` — so the test asserts the `enable` call
fired THROUGH THE TRAIT (the wrapper records the trait-method call,
not an inherent call). The assertions at `main.rs:1469-1505` verify
(a) `calls[0] == "enable"` (enable is the first backlight call on the
render path), (b) `enable_idx < update_idx` (enable precedes the
loop-bottom update), and (c) `!backlight.inner.write_log().is_empty()`
+ `first_write > 0` (a non-zero enable-write was recorded by the
inner `MockBacklight`, whose trait override `enable()` at
`src/providers/mock_backlight.rs:47-55` pushes the value into
`write_log`).

This is precisely the "trait-object / generic-dispatch regression
guard" ADR-044 §3 asks for. The test drives the production generic
path `real_main` and asserts the enable-write occurred via the trait.
It cannot pass while the production path no-ops: if
`SysfsBacklight`'s trait `enable` reverted to the default no-op,
`MockBacklight`'s trait `enable` (which the test actually uses) would
still record a write — but the parallel gap on `SysfsBacklight` would
be caught by the unit tests at `backlight.rs:379-512` IF those tests
were converted to drive through `&mut dyn BacklightProvider`. They
currently call on a concrete type (the s037-identified gap); the
render-path test at `main.rs:1434` is the trait-dispatch guard that
closes the class. See §"Remaining test-coverage gap" for the honest
residual.

### V3 — The s037 analysis cited line numbers that do not match HEAD.

The s037 analysis (`docs/test-logs/037/step3-5-start-live-state-hc2.txt:140-141`)
states:

> `impl BacklightProvider for SysfsBacklight` (backlight.rs:269-...)
> overrides set_brightness, brightness, max_brightness, update,
> notify_activity, set_lid_closed — but does NOT override `enable()`.

At HEAD `ccd7024`, `backlight.rs:269` is the `impl BacklightProvider
for SysfsBacklight` line, and `backlight.rs:305-307` IS the `enable`
override. The "does NOT override `enable()`" claim is contradicted by
the very file the analysis cites. The most likely explanation: the
analysis was performed against a stale or mis-read view of
`backlight.rs` (perhaps the pre-merge branch tip before ADR-043
landed the override, or a buffer/cache issue), and the conclusion
propagated into the session-040 brief. The test-logs are preserved
verbatim as DATA (per session rules) — this ADR documents the
discrepancy rather than editing the historical log.

### V4 — Implication for the dark bar in attempt #4.

The dark bar in run #4 cannot be explained by the s037 trait-default
hypothesis (the override is present). Candidate explanations that
remain on the table (NOT adjudicated by this ADR — flagged for the
re-verification session):

1. **Binary/source divergence.** The installed `/usr/bin/tbard`
   (sha256 `f7297cf3…`, `docs/test-logs/036/reinstall.log`) was
   built from `ccd7024` per the ADR-038 process rule. IF the build
   was actually from a different tree (or a stale target/), the
   binary may predate the override. The re-verification session
   should re-confirm `sha256` match between a fresh `cargo build
   --release --bin tbard` from `ccd7024` and `/usr/bin/tbard`, AND
   behavioral confirmation that the enable-write fires (the ADR-045
   RUST_LOG=info line is the in-journal witness).
2. **The stale-read coincidence persists.** ADR-043's analysis (D1,
   `docs/adr/043-backlight-enable-write-render-path.md` lines 50-80)
   identifies the `current_bl == new_bl` gate in `update()` as the
   non-deterministic path. The enable-write of 128 is supposed to
   break the coincidence by writing 128 unconditionally at
   scanout-begin. IF the enable-write IS firing (per the override)
   but the panel is STILL dark, the value is not reaching the
   hardware (held-fd write path failure, post-drop permission
   regression, or a driver-level reset on master acquire). Session
   039 S3 (`docs/test-logs/039/s3-cold-ignition.txt`) proved a
   direct write of 128 to a DARK bar LIT it — so the value path
   works when the write reaches sysfs. The re-verification session
   should use the ADR-045 INFO line to confirm the enable-write
   fires AND the ADR-046 value probe (read within ~1s) to confirm
   the value lands.
3. **The s037 source analysis was simply wrong and the bar lit on a
   re-run that was not recorded.** Possible but unlikely — the s037
   HC2 ("Dark / no pixels") is a verbatim human checkpoint.

This ADR does NOT pick among (1)/(2)/(3); it records that the
code-level defect s037 identified is NOT present at HEAD, and the
re-verification session must resolve the dark bar with ADR-045/046 in
place.

## The class audit (the real deliverable)

### Method enumeration — `real_main` (`src/main.rs:502-…`)

`real_main<D, I, B>` is generic over `D: DisplayProvider`,
`I: InputProvider`, `B: BacklightProvider`. The provider methods
called through the generic bounds (and therefore through trait
dispatch) are enumerated below with their call sites and the
`SysfsBacklight`/`DrmProvider`/`LibinputProvider` override status.

### A. BacklightProvider methods called in `real_main`

| Trait method | `real_main` call site | `SysfsBacklight` override? | Evidence | Inherent method on `SysfsBacklight`? | Verdict |
|---|---|---|---|---|---|
| `enable(&mut self) -> Result<()>` | `src/main.rs:547` (`backlight.enable()`) | **YES** — forwards to inherent | `src/providers/backlight.rs:305-307` | YES (`backlight.rs:175`, `pub fn enable`) | **NO DEFECT.** Override present; the inherent method is NOT dead code in production. The s037 claim is refuted. |
| `update(&mut self)` | `src/main.rs:821` (loop-bottom, `backlight.update()`) | **YES** — forwards to inherent, discards the `bool` return | `src/providers/backlight.rs:293-298` | YES (`backlight.rs:222`, `pub fn update`) | **NO DEFECT.** Override present. |
| `notify_activity(&mut self)` | (called via input event path; also `RecordingBacklight` records it) | **YES** — forwards to inherent | `src/providers/backlight.rs:299-301` | YES (`backlight.rs:202`) | **NO DEFECT.** Override present. |

> **ADR-047 correction (2026-09-27):** the "called via input event path"
> claim above is INCORRECT about the call site. At the time of this audit
> (HEAD `ccd7024`), the `InputEvent::Activity` arm in `real_main` called
> `input.notify_activity()` (the INPUT provider's no-op at
> `src/providers/input.rs:522-524`), NOT `backlight.notify_activity()`.
> The `InputEvent::Touch` arm did not call either. So the override was
> present and dispatched correctly IF CALLED, but NO runtime call site on
> the backlight existed — the override was dead code. ADR-047
> (`docs/adr/047-wire-touch-to-backlight-wake.md`) lands the wiring: the
> `InputEvent::Touch` and `InputEvent::Activity` arms now call
> `backlight.notify_activity()` (porting the oracle's `process_event`
> pre-gate wake at `backup_old/tiny-dfr-mbp142/src/main.rs:1037`). The
> "NO DEFECT" verdict for the override's EXISTENCE stands; the verdict
> for the call SITE is corrected to "DEFECT (dead override) — fixed by
> ADR-047."
| `set_lid_closed(&mut self, bool)` | (lid event path) | **YES** — forwards to inherent | `src/providers/backlight.rs:302-304` | YES (`backlight.rs:207`) | **NO DEFECT.** Override present. |
| `set_brightness(&mut self, u32) -> Result<()>` | (not on the render path's hot loop; called from input handlers) | **YES** — direct override | `src/providers/backlight.rs:270-286` | NO (no inherent `set_brightness`; the trait impl is the only definition) | **NO DEFECT.** Trait-required method, overridden. |
| `brightness(&self) -> u32` | `src/main.rs` various (read current level) | **YES** — direct override | `src/providers/backlight.rs:287-289` | NO | **NO DEFECT.** Trait-required method, overridden. |
| `max_brightness(&self) -> u32` | (read in update path) | **YES** — direct override | `src/providers/backlight.rs:290-292` | NO | **NO DEFECT.** Trait-required method, overridden. |
| `is_off(&self) -> bool` | (default body: `self.brightness() == 0`) | **Conscious inheritance** — the default body is correct for `SysfsBacklight` (it reads `current_bl` via the overridden `brightness()`). | `src/providers/mod.rs:95-97` (default); `backlight.rs:287-289` (the `brightness()` it calls) | NO inherent | **NO DEFECT.** Default composes correctly with the overridden `brightness()`. |

### B. DisplayProvider methods called in `real_main` (via `D: DisplayProvider`)

| Trait method | `real_main` call site | `DrmProvider` override? | Evidence | Inherent method on `DrmProvider`? | Verdict |
|---|---|---|---|---|---|
| `acquire(&mut self) -> Result<()>` | `src/main.rs:308` (real arm, before `real_main`) / `main.rs:196` (dry-run) | **YES** — direct override | `src/providers/drm_backend.rs:398-405` | NO inherent `acquire` | **NO DEFECT.** |
| `release(&mut self) -> Result<()>` | (Drop glue / clean exit) | **YES** — direct override | `src/providers/drm_backend.rs:406-431` | NO | **NO DEFECT.** |
| `display_info(&self) -> Result<DisplayInfo>` | `src/main.rs:519` (top of `real_main`) | **YES** — direct override | `src/providers/drm_backend.rs:432-440` | NO | **NO DEFECT.** |
| `flush(&mut self, &[u8], &[DamageRect]) -> Result<()>` | `src/main.rs:702` (first flush), loop | **YES** — direct override | `src/providers/drm_backend.rs:441-471` | NO | **NO DEFECT.** |
| `is_connected(&self) -> bool` | (used in discovery / guards) | **YES** — direct override | `src/providers/drm_backend.rs:472-474` | NO | **NO DEFECT.** |

`DisplayProvider` has NO default-bodied methods (`src/providers/mod.rs:43-49`
— all five are required, no defaults). Therefore the bug class
"inherent method exists + default dispatches" CANNOT apply to
`DisplayProvider`: there is no default to dispatch to. Any inherent
method on `DrmProvider` with a matching name would be a separate
concern, but the only `DrmProvider` inherent methods are `new`,
`open_with_retry`, `open_with_retry_injectable`, `map`, `mode_size`,
`card_raw_fd`, `stall_count`, `record_flush_duration`
(`src/providers/drm_backend.rs:216-…`) — NONE collide with the five
trait method names. **No `DisplayProvider` instance of the bug class.**

### C. InputProvider methods called in `real_main` (via `I: InputProvider`)

| Trait method | `real_main` call site | `LibinputProvider` override? | Evidence | Inherent method on `LibinputProvider`? | Verdict |
|---|---|---|---|---|---|
| `init(&mut self) -> Result<()>` | `src/main.rs` (input setup, before/at `real_main` entry) | **YES** — direct override | `src/providers/input.rs:429-445` | NO | **NO DEFECT.** |
| `poll(&mut self) -> Vec<InputEvent>` | `src/main.rs` (render loop top) | **YES** — direct override | `src/providers/input.rs:446-517` | NO | **NO DEFECT.** |
| `current_backlight(&self) -> u32` | (read in input/reactive paths) | **YES** — direct override | `src/providers/input.rs:518-521` | NO | **NO DEFECT.** |
| `notify_activity(&mut self)` | (input activity path) | **YES** — direct override | `src/providers/input.rs:522-…` | NO | **NO DEFECT.** |

`InputProvider` has NO default-bodied methods (`src/providers/mod.rs:74-79`
— all four are required, no defaults). The bug class CANNOT apply.
`LibinputProvider`'s inherent methods are `new`, `is_digitizer`,
`identify_digitizer`, `probe_digitizer`, `seat_touchbar_raw_fd`
(`src/providers/input.rs:76-…`) — NONE collide with the four trait
method names. **No `InputProvider` instance of the bug class.**

### D. The other BacklightProvider impls (`MockBacklight`)

| Trait method | `MockBacklight` override? | Evidence | Inherent method? | Verdict |
|---|---|---|---|---|
| `set_brightness` | YES | `src/providers/mock_backlight.rs:35-40` | NO | NO DEFECT |
| `brightness` | YES | `mock_backlight.rs:41-43` | NO | NO DEFECT |
| `max_brightness` | YES | `mock_backlight.rs:44-46` | NO | NO DEFECT |
| `enable` | YES | `mock_backlight.rs:47-55` | NO | NO DEFECT |
| `update` / `notify_activity` / `set_lid_closed` / `is_off` | Conscious inheritance (default no-op / `brightness()==0`) | `src/providers/mod.rs:95-122` | NO | NO DEFECT — the mock is intentionally simple; the defaults are correct for a test double. |

### E. The other DisplayProvider/InputProvider impls (`SimDisplayProvider`, `MockDisplay`, `SimInputProvider`, `MockInput`)

`SimDisplayProvider` (`src/providers/sim_display.rs:118`) and
`MockDisplay` (`mock_display.rs:28`) override all five
`DisplayProvider` methods (no defaults exist). `SimInputProvider`
(`sim_input.rs:242`) and `MockInput` (`mock_input.rs:23`) override
all four `InputProvider` methods (no defaults exist). The inherent
methods on these types (`SimDisplayProvider::new`, `card_path`;
`MockDisplay::new`, `buffer`; `SimInputProvider::new`,
`new_with_range`, `evdev_path`, `uinput`, `inject_touch_down`, …;
`MockInput::new`, `push`) do NOT collide with any trait method name.
**No instance of the bug class in any sim/mock provider.**

## Class-audit summary

| Provider trait | Defaults present? | Inherent-vs-trait collisions in repo? | Bug-class instances found | Action |
|---|---|---|---|---|
| `BacklightProvider` | YES (`is_off`, `update`, `notify_activity`, `set_lid_closed`, `enable` — `mod.rs:95-122`) | 4 inherent methods on `SysfsBacklight` collide with trait defaults (`enable`, `update`, `notify_activity`, `set_lid_closed`) | **0** — ALL 4 are overridden in `impl BacklightProvider for SysfsBacklight` (`backlight.rs:293-307`) | None. Override already present; verified by V1/V2. |
| `DisplayProvider` | NO (all required — `mod.rs:43-49`) | 0 (no `DrmProvider` inherent method named `acquire`/`release`/`display_info`/`flush`/`is_connected`) | **0** | None. The class is structurally impossible (no defaults). |
| `InputProvider` | NO (all required — `mod.rs:74-79`) | 0 (no `LibinputProvider` inherent method named `init`/`poll`/`current_backlight`/`notify_activity`) | **0** | None. The class is structurally impossible (no defaults). |

**Audit verdict: ZERO instances of the bug class exist in the
codebase at HEAD `ccd7024`.** The defect s037 identified is not
present. The ADR-044 fix surface (one-line override + trait-object
regression guard) was already implemented by ADR-043 in commit
`38392ce`.

## Regression guard for the class (already present — documented, not added)

The s037 lesson "grep cannot catch dispatch semantics — guard #8
passed while production no-op'd" is addressed by the existing
`test_render_path_enable_write_precedes_first_flush_and_update`
(`src/main.rs:1434-1506`):

- It drives the **production generic path** `real_main<B: BacklightProvider>`
  (not a concrete `SysfsBacklight`).
- `RecordingBacklight<B>` (`main.rs:1330-1375`) wraps `B` and records
  the `"enable"` call THROUGH THE TRAIT (the wrapper's trait impl
  pushes `"enable"` then calls `self.inner.enable()` —
  `main.rs:1371-1374`). If `B`'s trait `enable` were the no-op
  default, the wrapper would still record `"enable"` (because the
  wrapper overrides `enable`), so the test guards the CALL order;
  the WRITE-occurred guard is `!backlight.inner.write_log().is_empty()
  && first_write > 0` (`main.rs:1491-1505`), which asserts the inner
  `MockBacklight`'s trait `enable` (overridden at
  `mock_backlight.rs:47-55`) actually pushed a non-zero value.
- The combination (call recorded through the trait + non-zero write
  recorded by the inner mock's trait `enable`) closes the class for
  `MockBacklight`'s impl. For `SysfsBacklight`, the unit tests at
  `backlight.rs:379-512` exercise the inherent method on a concrete
  type — see "Remaining test-coverage gap" below.

### Adverse disposable check (the one open empirical item — guard-hardening fired)

The brief required an adverse disposable check: comment out the
override at `backlight.rs:305-307` on a throwaway copy in `/tmp`,
run the suite, and observe whether a test FAILS.

**Run 1 (BEFORE hardening — the existing suite at HEAD `ccd7024`):**
commenting out the override → **all 80 tests PASS.** The existing
concrete-type `SysfsBacklight` unit tests (`backlight.rs:379-512`)
call `bl.enable()` on a concrete `SysfsBacklight` (inherent-method
resolution takes priority on a concrete type, so they exercise the
inherent method regardless of the trait override). The render-path
test at `main.rs:1434` uses `RecordingBacklight<MockBacklight>`, and
`MockBacklight`'s trait `enable` override (`mock_backlight.rs:47-55`)
is INDEPENDENT of `SysfsBacklight`'s — it records the write via its
own override. Both tests pass with the `SysfsBacklight` override
removed. **The guard was NOT real for the `SysfsBacklight` dispatch
class — the exact s037 lesson ("guard #8 passed while production
no-op'd") reproduced.**

**Guard-hardening (the ONLY `src/` change this session):** added
`test_enable_write_through_trait_object_lands_on_sysfs`
(`src/providers/backlight.rs`, in the test module). It constructs a
tempdir-backed `SysfsBacklight` with NO held fd (so the per-write
path in `set_backlight_file` opens `bl_path/brightness` directly at
`backlight.rs:143-156`), boxes it as `Box<dyn BacklightProvider>`,
calls `enable()` through the trait object, and asserts (a) the
tempdir `brightness` file now contains "128" (the written value, not
"0"), and (b) `provider.brightness() == 128` (the override updates
`current_bl` on success; the default no-op leaves it at 0). This is
the exact dispatch class s037 hypothesized: a trait-object call
resolves to the trait's method (override or default), NOT the
inherent method.

**Run 2 (AFTER hardening):** with the override present → 81 tests
pass (76 unit + 5 integration). With the override commented out on a
throwaway copy → **ONLY `test_enable_write_through_trait_object_lands_on_sysfs`
FAILS** (75 passed, 1 failed), with the diagnostic
`left="0" right="128"` and a message pointing at
`src/providers/backlight.rs:305-307` and the default no-op at
`src/providers/mod.rs:120-122`. The existing concrete-type tests and
the render-path test STILL PASS with the override removed — confirming
they could not catch the class, and that the new trait-object test is
the guard that closes it. Throwaway copies deleted after both runs.

Justification for the `src/` change: this is guard-hardening for the
exact dispatch class s037 hypothesized. The ADR-043 test suite at HEAD
had a real coverage gap (the `SysfsBacklight` override was unguarded
against removal — the existing tests would pass with it removed).
The new test is the regression guard ADR-044 §3 specified ("a
TRAIT-OBJECT test — construct the provider, box it as
dyn BacklightProvider, call enable() through the trait object, assert
the write occurred"). It is minimal (one test, ~50 lines), scoped to
the dispatch class, and adversarially verified (Run 1 → no guard; Run
2 → guard real). The audit verdict (no defect at HEAD) is unchanged
— the override IS present; the hardening ensures it STAYS present.

### Remaining test-coverage gap (closed by the hardening)

The gap s037 identified ("tests target the concrete type + production
dispatches to the default") is now CLOSED for `SysfsBacklight::enable`:
the trait-object test drives `enable()` through `&mut dyn
BacklightProvider` and asserts the write landed. The existing
concrete-type tests remain (they exercise the inherent method's
value/clamp/fail-safe logic, which the trait-object test does not
redundantly check). The render-path test at `main.rs:1434` remains
(it guards the CALL ORDER on the render path — `enable` precedes the
first `flush` and the loop-bottom `update` — which the trait-object
test does not cover). The three tests are complementary:
- `backlight.rs` concrete-type tests: inherent-method value/clamp/fail-safe.
- `backlight.rs` trait-object test: dispatch class (override present).
- `main.rs:1434` render-path test: call order on the production generic path.

## Decision

**Audit-only on the defect; ONE `src/` change for guard-hardening.**

1. The trait override is present at `src/providers/backlight.rs:305-307`
   (verified V1). **No defect at HEAD.**
2. The trait-dispatch regression test at `src/main.rs:1434` is present
   but does NOT guard the `SysfsBacklight` dispatch class (verified
   by the adverse check Run 1). The existing concrete-type tests
   also do not guard it.
3. **Guard-hardening (the only `src/` change):**
   `test_enable_write_through_trait_object_lands_on_sysfs` added to
   `src/providers/backlight.rs` test module — drives `enable()`
   through `Box<dyn BacklightProvider>` and asserts the write landed
   on the backing sysfs file. Adversarially verified: with the
   override removed, ONLY this test fails (Run 2).
4. The class audit finds ZERO instances of the bug class across all
   three provider traits at HEAD (table above).
5. The s037 source analysis is documented as refuted by the
   repository (V3); the test-logs are preserved verbatim as DATA.
   The erratum is applied as a correction blockquote in the s037
   runbook entry (D-027-1/D-031-1 discipline — annotate, never
   rewrite).
6. The dark bar in run #4 is NOT explained by the s037 hypothesis.
   The corrected explanation is closed by the enable-propagation
   check (V5): the write succeeded → adaptive idle-dim decayed it
   (s039 timing) → value probe read post-decay → HC2 asked minutes
   late. No code defect existed at HEAD.

## V5 — Enable-propagation check (the corrected explanation for the dark bar)

The s037 run showed `Result=success`, `ExecMainCode=0`,
`ExecMainStatus=0`, and ZERO ERROR-level journal lines
(`docs/test-logs/037/step3-5-start-live-state-hc2.txt`,
`step6-9-sigterm-restore-final.txt`). Per ADR-025, a failing
`enable()` on the startup path must propagate `Err` → non-zero exit →
`Result=failed`. The propagation chain in source:

- `real_main` `src/main.rs:547-553`: `if let Err(e) = backlight.enable()
  { log::error!(...); return Err(e); }` — early return on `Err`.
- `main` service arm `src/main.rs:478-496`: `catch_unwind(real_main(...))`,
  `Ok(Err(e)) => { log::error!("tbard: engine returned error: {:#}", e);
  Err(e.into()) }` — propagates to `main`'s return.
- `fn main() -> Result<(), Box<dyn std::error::Error>>` `src/main.rs:132`:
  a returned `Err` yields exit code **1** (Rust's `Termination` impl
  for `Result`), which ADR-025's `Restart=on-failure` maps to
  `Result=failed` + restart.

s037 observed `Result=success` + exit 0 + zero ERROR journal lines.
Therefore `enable()` did NOT return `Err` — the enable-write of 128
SUCCEEDED. The value=0/dark/mtime-frozen/journal-empty quartet is
consistent with: **successful enable-write of 128 → adaptive idle-dim
decay (s039 S2: 128→1 by ~30s, →0 by ~60s of no touch, mtime FROZEN
throughout the decay) → the STEP 4b value probe read AFTER the decay
had completed → HC2 asked minutes after start**. The INFO-suppression
(ADR-045) made the success-path enable-write line invisible in the
journal, so the success was inferable only from the absence of
ERROR lines + `Result=success` (which s037 did not flag as
exculpatory). No code defect existed at HEAD `ccd7024`. The dark bar
was an observation-timing artifact, not a write failure.

## Alternatives considered

- **Add the override anyway (belt-and-suspenders).** Rejected: it is
  already present; adding a second `fn enable` in the same impl block
  is a compile error. The override IS the one ADR-044 specified.
- **Do NOT add the trait-object test (keep the ADR pure audit-only).**
  Rejected by the adverse check: the existing suite does NOT guard
  the `SysfsBacklight` dispatch class (Run 1 — all 80 tests pass with
  the override removed). The s037 lesson ("guard #8 passed while
  production no-op'd") was LITERALLY reproduced. Leaving the gap open
  would repeat the s037 mistake the brief chartered this ADR to
  close. The hardening is minimal, scoped, and adversarially verified.
- **Edit the s037 test-logs to correct the analysis.** Rejected: the
  session rules require test-logs to be preserved verbatim as DATA.
  The erratum is applied as a correction blockquote in the runbook
  (D-027-1/D-031-1 discipline — annotate, never rewrite).
- **Adjudicate the dark-bar root cause in a separate hardware session.**
  Considered: V5 closes the code-level question (the write succeeded
  per the propagation chain + the s037 `Result=success` evidence).
  The re-verification session with ADR-045/046 in place will confirm
  the V5 explanation live (the INFO enable-write line + the
  value-within-1s probe).

## Impact list

- `docs/adr/044-backlight-provider-dispatch-audit.md` — this file
  (new).
- `src/providers/backlight.rs` — **the ONLY `src/` change this
  session:** adds `test_enable_write_through_trait_object_lands_on_sysfs`
  to the test module (guard-hardening for the s037 dispatch class;
  adversarially verified).
- `docs/test-plan.md` — session-040 erratum: a correction blockquote
  on the s037 runbook entry (D-027-1/D-031-1 discipline — annotate,
  never rewrite) + a session-040 note pointing to this ADR.
- `CHANGELOG.md` — `[Unreleased — ADR-044 dispatch audit +
  guard-hardening]` subsection.
- `devlog.md` — session 040 entry.
- `docs/self-assessment-13.md` — claims C-044 (audit verdict +
  guard-hardening + the V5 corrected explanation).

No `tests/`, `scripts/`, or `packaging/` changes from this ADR
(ADR-045 and ADR-046 carry the service/runbook changes on this
branch).

## References

- `src/providers/mod.rs:43-49` — `DisplayProvider` trait (no defaults).
- `src/providers/mod.rs:74-79` — `InputProvider` trait (no defaults).
- `src/providers/mod.rs:91-123` — `BacklightProvider` trait (5
  defaults: `is_off`, `update`, `notify_activity`, `set_lid_closed`,
  `enable`).
- `src/providers/backlight.rs:175-199` — inherent
  `SysfsBacklight::enable`.
- `src/providers/backlight.rs:269-308` — `impl BacklightProvider for
  SysfsBacklight` (all 4 default-colliding methods overridden at
  293-307; `enable` at 305-307).
- `src/providers/backlight.rs:202-266` — inherent `update`,
  `notify_activity`, `set_lid_closed`.
- `src/providers/mock_backlight.rs:47-55` — `MockBacklight`'s trait
  `enable` override (records the write).
- `src/main.rs:502` — `real_main<D, I, B>` generic signature.
- `src/main.rs:547` — `backlight.enable()` call site (the ADR-043
  enable-write on the render path).
- `src/main.rs:1330-1375` — `RecordingBacklight<B>` wrapper (records
  `enable` through the trait).
- `src/main.rs:1434-1506` —
  `test_render_path_enable_write_precedes_first_flush_and_update`
  (the trait-dispatch regression guard).
- `docs/adr/043-backlight-enable-write-render-path.md` — ADR-043
  (lands the override + the test; this ADR verifies it).
- `docs/test-logs/037/step3-5-start-live-state-hc2.txt:130-200` — the
  s037 "DEFECT ANALYSIS" (refuted by V1/V2/V3; preserved as DATA).
- `docs/test-logs/039/devlog.md` — session 039 ground truth (S3
  cold-ignition: a 128 write lights a DARK bar; the value path works
  when the write reaches sysfs).
- `git show 38392ce -- src/providers/backlight.rs` — the ADR-043
  commit lands BOTH the inherent `enable` and the trait override in
  the same commit.