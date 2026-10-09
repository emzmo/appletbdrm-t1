# QA v11 — Focused Re-Verification of fix/observability-adr-044-046 (ADR-044 + ADR-045 + ADR-046 + F4 bump)

**Session**: 041, **Date**: 2026-09-26
**Role**: QA & reliability engineer (focused re-verification, v11).
**Branch**: `fix/observability-adr-044-046` off `master` `ccd7024`
(== v0.2.4). Six commits: `00a277d` (docs: sessions 037/038/039
evidence) → `2d764f6` (ADR-044 + guard-hardening test) → `3fdad79`
(ADR-045 RUST_LOG=info) → `5691150` (ADR-046 runbook revision) →
`3b69c3f` (F4 version bump 0.2.5) → `cac5d50` (docs: session 040 +
Cargo.lock regen). HEAD = `cac5d50`.
**Scope**: ADR-044 (audit-only + guard-hardening), ADR-045 (RUST_LOG),
ADR-046 (runbook), F4 bump. `ccd7024` is an ancestor of HEAD ✓.
**FREEZE RULE**: no source changes; findings only. No `src/` mutations
were committed in this session — the ONE `src/` change on the branch
(`backlight.rs` guard-hardening test, commit `2d764f6`) was made in
session 040, not here. The adversarial demo in this report mutated a
THROWAWAY copy in `/tmp/opencode/tb-adv` and was DELETED after; the
branch tree is byte-identical to HEAD throughout.
**HOST SAFETY RULES** (`docs/dangers.md`) binding; the deployed oracle
(`tiny-dfr-mbp142.service`) stayed untouched and lit throughout; no
service lifecycle actions; no `/etc` writes; no `udevadm trigger`.
Audit D confirmed at start AND end
(`docs/test-logs/041/host-state-and-adverse-check.log`).

**The report is a CLAIM; the live audits are VERDICTS.** The
self-assessment-13 (`docs/self-assessment-13.md`, archived under
`docs/test-logs/041/fix-report/`) is the implementer's CLAIM; every
claim below was re-derived from the diffs and adjudicated against live
execution. New findings → ADR proposals, logged not implemented per
FREEZE.

---

## Per-claim verdicts

### Claim 1 — ADR-044 enable-propagation chain (VERIFIED)

**Re-derivation (independent source read at HEAD `cac5d50`):**

- `src/main.rs:132` — `fn main() -> Result<(), Box<dyn std::error::Error>>`.
  A returned `Err` from the body is Rust's process exit code 1 contract
  (per ADR-025: `Result=failed` ↔ exit 1).
- `src/main.rs:478-496` — the `panic::catch_unwind(real_main(...))`
  arm: `Ok(Err(e)) => { log::error!(...); Err(e.into()) }` propagates
  `real_main`'s `Err` up to `main`'s `Result` return → exit 1. A panic
  (`Err(_)`) likewise returns `Err("engine panicked".into())` → exit 1.
- `src/main.rs:547-553` — the scanout-begin enable-write:
  `if let Err(e) = backlight.enable() { log::error!(...); return Err(e); }`.
  A failing `enable()` returns `Err` from `real_main`, which the
  catch_unwind arm propagates to `main`'s `Result` → exit 1.

**Syllogism adjudication:** s037 observed `Result=success` +
`ExecMainCode=0` + zero ERROR-level journal lines
(`docs/test-logs/037/step3-4-first-start-verify.txt` and the s037
devlog). Per the chain above, a failing `enable()` MUST surface as
exit 1 → `Result=failed` + an ERROR-level journal line at
`main.rs:548`. s037 saw exit 0 + `Result=success` + no ERROR line ⇒
`enable()` did NOT fail ⇒ the enable-write of 128 SUCCEEDED. The
quartet (value=0 / dark / mtime-frozen / journal-empty) is therefore
**decay + observation timing, not write failure** — exactly the ADR-044
V5 / ADR-046 corrected explanation (s039 S2: 128→1 by ~30s, →0 by ~60s
of no touch, mtime FROZEN throughout the kernel-side decay; ADR-045
INFO-suppression made the success-path enable-write line invisible).

**Verdict: VERIFIED.** The propagation chain is structurally sound and
the s037 evidence (exit 0, Result=success, no ERROR line) is
exculpatory of an enable-write failure. The s037 root-cause analysis
("dead code via trait-default dispatch") is REFUTED by Claim 2's
override presence and by this chain.

### Claim 2 — ADR-044 guard-hardening (VERIFIED, adversarially reproduced)

**Adverse check (independently reproduced this session, throwaway copy
in `/tmp/opencode/tb-adv`, deleted after):**

1. Cloned the branch to `/tmp/opencode/tb-adv` at HEAD `cac5d50`.
2. Removed the trait override at `src/providers/backlight.rs:305-307`:
   ```rust
   fn enable(&mut self) -> anyhow::Result<()> {
       SysfsBacklight::enable(self).map_err(Into::into)
   }
   ```
   (replaced with a comment marker).
3. Ran `cargo test`: **75 passed; 1 failed**. The SINGLE failure:
   ```
   thread 'providers::backlight::tests::test_enable_write_through_trait_object_lands_on_sysfs' panicked at src/providers/backlight.rs:582:9:
   assertion `left == right` failed: ADR 044 guard: enable() called through a &mut dyn BacklightProvider MUST write active_brightness (128, clamped to max_bl) to the backing sysfs brightness file. The file read "0\n"; ...
     left: "0"
    right: "128"
   ```
   This is the EXPECTED outcome — the guard catches the s037 dispatch
   class (trait default no-op invoked instead of the override). No
   other test failed (76−1=75 pass + 5 integration = 80 total run, 1
   failed; the trait-object test is in the unit suite).
4. Restored the override → `cargo test`: **76 unit + 5 integration =
   81 passed; 0 failed.**
5. Deleted `/tmp/opencode/tb-adv` (verified absent at end).

**The new test asserts the WRITE, not just call order — the s037 gap
closed:** the test at `src/providers/backlight.rs:540-609` constructs a
tempdir-backed `SysfsBacklight` (NO held fd → per-write path opens
`bl_path/brightness` directly), boxes it as
`Box<dyn BacklightProvider>`, calls `enable()` through the trait
object, and asserts:
- (a) the tempdir `brightness` file's contents advanced from `"0\n"` to
  `"128"` (`backlight.rs:582-595` — `file_contents.trim() == "128"`);
- (b) `provider.brightness() == 128` (`backlight.rs:600-608` — the
  override updates `current_bl` on success).

The panic message in the adverse run quotes `left: "0" right: "128"` —
the WRITE assertion fired, not a call-order recorder. The s037 gap
(order-vs-write) is closed: the existing concrete-type tests at
`backlight.rs:379-462` use inherent-method resolution and would still
pass with the override removed; the render-path integration test at
`main.rs:1434` uses `RecordingBacklight<MockBacklight>` whose trait
`enable` is independent of `SysfsBacklight`'s — neither would catch
the class. ONLY the new trait-object test catches it.

**Verdict: VERIFIED.** The guard is real (75+1 with override removed,
81 with it present), and the test asserts the write lands on the
backing sysfs file, not just call order.

### Claim 3 — Audit table re-derivation (VERIFIED)

**Independent grep at HEAD `cac5d50`:**

`BacklightProvider` trait (`src/providers/mod.rs:91-123`) — 8 methods
total, 5 with default bodies (`is_off` @95-97, `update` @100,
`notify_activity` @102, `set_lid_closed` @104, `enable` @120-122), 3
required (`set_brightness` @92, `brightness` @93, `max_brightness`
@94).

`impl BacklightProvider for SysfsBacklight` (`backlight.rs:269-308`) —
override/inherited status:

| Trait method | Default in trait? | SysfsBacklight override? | Evidence |
|---|---|---|---|
| `set_brightness` | NO (required) | YES (override) | `backlight.rs:270-286` |
| `brightness` | NO (required) | YES (override) | `backlight.rs:287-289` |
| `max_brightness` | NO (required) | YES (override) | `backlight.rs:290-292` |
| `is_off` | YES (@mod.rs:95-97) | INHERITED (no override) | not in `impl` block |
| `update` | YES (@mod.rs:100) | YES (override) | `backlight.rs:293-298` |
| `notify_activity` | YES (@mod.rs:102) | YES (override) | `backlight.rs:299-301` |
| `set_lid_closed` | YES (@mod.rs:104) | YES (override) | `backlight.rs:302-304` |
| `enable` | YES (@mod.rs:120-122) | YES (override) | `backlight.rs:305-307` |

**All 4 inherent-vs-trait collisions on `SysfsBacklight` are
overridden** (`update`, `notify_activity`, `set_lid_closed`, `enable`).
`is_off` is inherited (no inherent collision — the inherent `update`
returns `bool` and the trait `is_off` reads `brightness()`, no
shadowing). ZERO instances of the s037 bug class in
`BacklightProvider`.

**`DisplayProvider` (`mod.rs:43-49`) and `InputProvider`
(`mod.rs:74-79`) have NO default-bodied methods** — confirmed by read:
`DisplayProvider` has 5 required methods (`acquire`, `release`,
`display_info`, `flush`, `is_connected`); `InputProvider` has 4
required methods (`init`, `poll`, `current_backlight`,
`notify_activity`). The s037 dispatch class (inherent method exists,
trait override missing, production dispatches to a no-op default) is
**structurally impossible** for these two traits — there is no default
to dispatch to.

**Spot-check two rows against the diff (commit `2d764f6`):**
- `enable` row: the diff adds the test, not the override — the override
  at `backlight.rs:305-307` was ALREADY present (landed in ADR-043
  commit `38392ce`, verified via the audit). The audit table's "YES
  (override)" for `enable` matches the file at HEAD.
- `update` row: `backlight.rs:293-298` forwards to
  `SysfsBacklight::update(self)` (inherent, returns `bool`, result
  discarded) — matches the "YES (override)" status and the inherent
  method at `backlight.rs:222`.

**Verdict: VERIFIED.** The audit table is accurate; the bug class is
absent across all three provider traits; `DisplayProvider` and
`InputProvider` are structurally immune.

### Claim 4 — ADR-045 RUST_LOG=info (VERIFIED)

**`packaging/systemd/tbard.service` (HEAD `cac5d50`):**
- Line 78: `Environment=RUST_LOG=info` (with the ADR-045 justification
  comment block at lines 59-77 citing the ADR-023 frame cadence at
  INFO, the enable-write line at INFO, the silent adaptive common
  case, and the ERROR-level error path).

**`systemd-analyze verify packaging/systemd/tbard.service` → exit 0**
(re-run this session, recorded honestly: it is a static
syntax/reference check, not a runtime behavior test — no service
lifecycle actions per the rules). Output: empty (no warnings).
`docs/test-logs/041/gates-verbatim.log` captures VERIFY_EXIT=0.

**Level choice justification in the ADR
(`docs/adr/045-observability-rust-log-info.md`):**
- §"2. Level choice — INFO, not DEBUG" cites ADR-023 §1: the
  frame-counter cadence is `info!` every `FRAME_LOG_INTERVAL = 100`
  frames (~1 line/~10s at 10fps), designed for INFO — explicitly
  rejects per-frame `debug!` as too noisy. ✓
- The enable-write success line at `backlight.rs:180-185` is `info!`
  (verified at HEAD — `log::info!("tbard: backlight enable-write {} ...")`). ✓
- The adaptive `update()` path is silent on the common
  `current_bl == new_bl` no-op gate (verified — `backlight.rs:243-245`
  returns `false` with no log). ✓
- The error-path lines are `error!` (always emitted regardless of
  RUST_LOG) — verified at `backlight.rs:255-260` and `main.rs:548`. ✓

**Verdict: VERIFIED.** The directive is present, the verify exits 0,
and the level choice is justified by the ADR-023 frame cadence at INFO
+ the enable-write line at INFO + the silent adaptive common case.

### Claim 5 — ADR-046 runbook revision (VERIFIED)

**`docs/test-plan.md` "STEP 4 — verify live state (ADR-046 value-only
probe)" (lines 314-389) and "HC2 — first pixels (ADR-046 timing
alignment)" (lines 390-409):**

- **STEP 4b is VALUE-ONLY within ~1s of the expected write (expect 128
  clamped):** the canonical procedure at lines 338-360 reads
  `cat .../brightness` within ~1s of `systemctl start`, expects 128
  (clamped to `max_bl`), and the ADR-045 journal INFO line
  `tbard: backlight enable-write 128 ...` as the post-decay reliable
  witness. ✓
- **mtime dropped with s038/s039 citations:** lines 351-354 — "DO NOT
  use mtime. The `brightness` file mtime is NOT a reliable write-probe
  on `appletbdrm` (s038 §4, s039 §7.2...)" with the structural
  invalidity explanation. ✓
- **HC2 timing = within ~30s of start OR touch-to-wake then answer:**
  lines 401-408 — "Ask HC2 **within ~30s of `systemctl start`**, OR
  have the human **touch the bar first** (wake-to-bright...)". ✓
- **BOTH decay sources documented:** lines 361-375 enumerate (1)
  kernel-side auto-dim (`appletbdrm` driver: s039 S2 128→1 by ~30s,
  →0 by ~60s, mtime FROZEN, `bl_power` 0) and (2) tbard's own
  adaptive path (`update()` at loop-bottom,
  `backlight.rs:222-266`, called at `main.rs:821`;
  `BRIGHTNESS_DIM_TIMEOUT_MS = 30s` → `DIMMED_BRIGHTNESS = 1`,
  `BRIGHTNESS_OFF_TIMEOUT_MS = 60s` → 0, `backlight.rs:17-19`). ✓
- **Intended pass criteria (lines 410-430) revised:** STEP 4b value
  == 128 within ~1s + journal INFO line present; mtime NOT used;
  HC2 within ~30s or after touch-to-wake. ✓

**Verdict: VERIFIED.** The runbook is observationally faithful to the
driver's measured behavior (s038/s039) and to tbard's own adaptive
constants; the mtime probe is dropped with citations; both decay
sources are documented as by-design, not defects.

### Claim 6 — F4 version bump (VERIFIED)

- **`Cargo.toml:3`** — `version = "0.2.5"` ✓
- **`packaging/PKGBUILD:19`** — `pkgver=0.2.5` ✓
- **`Cargo.lock:1348-1349`** — `name = "touchbar-engine"` /
  `version = "0.2.5"` ✓ (regenerated consistently)
- **`cargo build --bin tbard` succeeds** (BUILD_EXIT=0 this session). ✓

**`tbard --version` record (honest):** tbard has NO `--version` flag.
Both the installed `/usr/bin/tbard` (v0.2.4 build) and the freshly-built
`target/debug/tbard` (v0.2.5) respond to `--version` with:
```
tbard: unknown argument '--version'
usage: tbard [--dry-run | --service | --probe-input]
...
```
exit code 2 (the installed binary) / 0 (the debug build's clap path —
both print the help message and reject the flag). The version is
carried ONLY in `Cargo.toml` + `PKGBUILD` + `Cargo.lock`, not exposed
via a CLI flag. Recording this as an OBSERVATION (not a finding —
adding `--version` is a future convenience, not a correctness gap).

**Verdict: VERIFIED.** All three version sources agree at 0.2.5;
`cargo build` succeeds; the binary does not expose `--version`
(recorded honestly).

### Claim 7 — Erratum discipline (VERIFIED)

**s037 root-cause section annotated per D-027-1/D-031-1 precedent:**

- `docs/test-plan.md` lines 1067-1112 carry the correction blockquote:
  ```
  > **ERRATUM — session 040 (2026-09-26), ADR-044 dispatch audit
  > (D-027-1/D-031-1 discipline: annotate, never rewrite).** The
  > root-cause analysis below ("ADR-043 enable-write is dead code via
  > trait-default dispatch") is **REFUTED by an independent source
  > re-read at HEAD `ccd7024`...**
  ```
  The blockquote cites the override at `backlight.rs:305-307`, the
  trait-dispatch regression test at `main.rs:1434`, and the corrected
  V5 explanation (successful write + decay + observation timing). ✓
- **Original text preserved VERBATIM:** the defect analysis starting
  at line 1114 ("**DEFECT ANALYSIS — ADR-043 enable-write is dead code
  (trait-default dispatch).**") continues unchanged through the
  methodology discovery and acceptance items — the blockquote is
  APPENDED above it, the original is NOT rewritten. Matches the
  D-027-1 precedent at `docs/test-logs/025/STEP3-first-start-failure.txt`
  lines 2-24 (erratum header, original below). ✓

**Devlog meta-rule recorded:**
- `docs/test-plan.md` lines 1108-1112: "**Devlog meta-rule (session
  040):** live-session root causes are CLAIMS, not premises — no ADR
  may be premised on one without an independent source re-read. This
  is the fourth correction of its kind (s025 ordering, s029 acquire,
  s037 dispatch — see `docs/adr/044-...md` §V3)."
- `devlog.md` lines 5761-5771: "Live-session root causes are CLAIMS,
  not premises... **fourth correction of its kind**: s025 ordering
  (the privdrop sequencing claim), s029 acquire (the geometry-gate
  claim), s037 dispatch (the trait-default-dispatch claim — this
  session)."

**Four-corrections lineage cited:** s025 ordering, s029 acquire, s037
dispatch — three named in the meta-rule + this session's re-verification
= the fourth. ✓

**Verdict: VERIFIED.** The erratum follows D-027-1/D-031-1 discipline
(annotate, never rewrite); the meta-rule is recorded with the
four-corrections lineage.

---

## Independently reproduced adverse-check result

**Throwaway copy** in `/tmp/opencode/tb-adv` (cloned at HEAD
`cac5d50`, deleted after):

| Step | Mutation | `cargo test` result |
|---|---|---|
| (a) | Remove override at `backlight.rs:305-307` | **75 passed; 1 failed** — ONLY `test_enable_write_through_trait_object_lands_on_sysfs` fails (`left="0" right="128"` — the WRITE assertion fires) |
| (b) | Restore override | **81 passed; 0 failed** (76 unit + 5 integration) |

**The guard is real:** the test is the SINGLE point of failure when
the trait override is removed, and it asserts the write landed on the
backing sysfs `brightness` file (file contents `"0"` → `"128"`), not
just call order. The s037 order-vs-write gap is closed. Throwaway
deleted (verified absent at end:
`docs/test-logs/041/host-state-and-adverse-check.log`).

---

## Gates (verbatim, all exit 0)

From `docs/test-logs/041/gates-verbatim.log`:

| Gate | Exit |
|---|---|
| `cargo fmt --check` | 0 |
| `cargo build --bin tbard` | 0 |
| `cargo clippy --all-targets -- -D warnings` | 0 |
| `cargo test` | 0 (76 unit + 5 integration = 81 passed; 0 failed) |
| `scripts/check-invariants.sh` | 0 (PASS — guard #8 `backlight.enable()` at `main.rs:547` present) |
| `scripts/ci-gate.sh` | 0 (CI gate: PASS) |
| `bash -n packaging/PKGBUILD` | 0 |
| `bash -n scripts/bench/interlock-preflight.sh` | 0 |
| `systemd-analyze verify packaging/systemd/tbard.service` | 0 (no warnings) |

**Commit hygiene (ADR-before-code within each):** the six-commit chain
`00a277d` → `2d764f6` → `3fdad79` → `5691150` → `3b69c3f` → `cac5d50`
matches the brief verbatim. ADR-044 commit `2d764f6` lands the ADR
file (`docs/adr/044-...md`, 523 lines) AND the `src/` guard-hardening
test in a SINGLE commit — the ADR document precedes the test in the
diff (the ADR is the rationale, the test is the implementation); this
is the same pattern as ADR-043 commit `38392ce` (ADR + code together,
ADR-as-rationale-for-code). ADR-045 commit `3fdad79` lands the ADR +
the one-line `Environment=RUST_LOG=info`. ADR-046 commit `5691150`
lands the ADR + the runbook revision. F4 commit `3b69c3f` is the
version bump ride-along. Docs-closure commit `cac5d50` is the devlog
+ self-assessment + Cargo.lock regen.

---

## Live audits (read-only)

- **Test binary:** `cargo test --no-run` builds all 6 test binaries
  (1 unit + 5 integration). The new trait-object test alone
  (`--nocapture`) → PASS with the tempdir write assertion visible
  (the test prints no capture output beyond the `... ok` line because
  the assertions pass silently; the panic message quoting `left="0"
  right="128"` is visible ONLY in the adverse run, where it fires).
  Evidence: `docs/test-logs/041/cargo-test-evidence.log`.
- **Host state at start AND end** (`docs/test-logs/041/host-state-and-adverse-check.log`):
  - Oracle `tiny-dfr-mbp142` (tgid 241900, uid 65534) SOLE master on
    dev 2 (card2/appletbdrm, the Touch Bar card) at start and end —
    UNCHANGED.
  - `/dev/input` count = 25 at end (unchanged from start; matches the
    s037 baseline).
  - `/etc` untouched by this session (only `resolv.conf` churned by
    system network activity, not this session).
- **Installed-binary delta:** `/usr/bin/tbard` remains the v0.2.4
  build, sha256 `f7297cf387b749923feddaa45bf88bb4e2568c7c60a86d73f488ee5cdcfb9b06`,
  mtime 2026-09-26 20:36:26 — **expected**; the v0.2.5 reinstall is
  the merge session's job (per ADR-038 D2: build from the verified
  tagged HEAD + behavioral verify before/after install). The R1 audit
  on the installed binary passes (`strings --service` = 7; unprivileged
  `--service` → exit 1 with the ADR-034 message — ADR-045 RUST_LOG=info
  is NOT yet in the installed unit, also expected; reinstall the unit
  file post-merge).

---

## New findings

None. All seven claims VERIFIED; the adverse check reproduced the
expected 75+1 → 81 transition; the erratum discipline matches the
D-027-1/D-031-1 precedent; the host safety invariants held
throughout. No ADR proposals from this session.

---

## Final

**CLEARED FOR MERGE (v0.2.5) + unit+binary reinstall + Stage-3 attempt #5 with the observationally faithful protocol.**

The branch is byte-clean against HEAD `cac5d50`: all gates green (81
tests, fmt/clippy/build/invariants/ci-gate/bash -n × 2/systemd-analyze
verify all exit 0); the ADR-044 guard-hardening test is the only
`src/` change and is adversarially verified (75+1 without the
override, 81 with); ADR-045 + ADR-046 are docs/packaging-only with no
`src/` impact; F4 is a version-string bump with consistent
Cargo.lock. The merge session owes: (1) reinstall the systemd UNIT
from `packaging/systemd/tbard.service` (so `RUST_LOG=info` takes
effect — ADR-045 NOTE for merge) + (2) rebuild + reinstall the BINARY
from the v0.2.5 tag (`/usr/bin/tbard` is still the v0.2.4 build at
`f7297cf3…`, behaviorally verified this session but NOT the v0.2.5
build — ADR-038 D2 applies), then (3) Stage-3 attempt #5 from P1
under the interlock with the ADR-046 value-within-1s probe + the
ADR-045 journal INFO witness + the HC2 ~30s-or-touch timing protocol.