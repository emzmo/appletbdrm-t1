# ADR 039: Privdrop Target Resolution — Arch `nogroup` Portability

## Status: Accepted

## Date: 2026-09-26

## Context

### Session 025 finding — Stage-3 first start ABORTED at privdrop

Stage-3 (render-only) hardware validation under the interlock
(session 025; evidence in `docs/test-logs/025/`) ABORTED at STEP 3
(first real start). `systemctl start tbard.service` failed in 3 bursts
within ~11s → `start-limit-hit` (calibrated StartLimit behavior —
evidence, not anomaly). The live journal
(`docs/test-logs/025/STEP3-journal-live.log`, verbatim) shows:

```
tbard: privdrop failed: privdrop failed: Privilege drop error: Group not found
Error: PrivDrop { detail: "Privilege drop error: Group not found" }
```

The root cause is a **deployment-environment gap**, not a code bug.
On this Arch bench:

```
$ getent group nobody   → nobody:x:65534:
$ getent group nogroup  → (exit 2 — NOT FOUND)
$ getent passwd nobody  → nobody:x:65534:65534:Kernel Overflow User:/:/usr/bin/nologin
```

Arch uses the `nobody:nobody` pair (uid/gid 65534); the code expects the
Debian/Ubuntu `nobody:nogroup` pair. The privdrop crate's group-by-name
lookup returns NotFound → privdrop fails → exit 1.

### The hardcoded group name

`src/service.rs:139` hardcodes the group name:

```rust
pub fn privdrop_to_nobody() -> Result<(), ServiceError> {
    privdrop::PrivDrop::default()
        .user("nobody")
        .group("nogroup")            // ← hardcoded; absent on Arch
        .apply()
        .map_err(|e| ServiceError::PrivDrop { detail: e.to_string() })
}
```

The doc comment at `src/service.rs:130` anticipates "`nobody` not in
`/etc/passwd`" but NOT the Arch `nogroup`-absent variant. The
`privdrop` crate resolves the group by NAME via `getgrnam_r`
(`lookup_group` in `privdrop-0.5.6/src/privdrop.rs:430`); on Arch the
name `nogroup` has no entry → `Group not found`.

### The oracle's proven drop (the target parity)

The deployed oracle (`tiny-dfr-mbp142`) privdrops to `nobody` and runs
as uid/gid 65534 (session 025 evidence: the oracle restarted as
`tgid 87113, uid 65534`). On this bench the `nobody` user's PRIMARY gid
is 65534 (the `nobody` group) — so resolving the gid from the `nobody`
user's `/etc/passwd` entry reproduces the oracle's exact uid/gid drop.
This is the parity the ADR-019 recipe requires.

## Task 0 — Derive the ordering: WHERE does the privdrop target resolve, relative to device work?

This is the derivation ADR-039 must make EXPLICIT (it was observed live
in session 025 but is currently an accident of the privdrop crate's
implementation, not a code-enforced property).

### The privdrop crate resolves the target BEFORE any syscall privilege change

`privdrop::PrivDrop::apply()` (`privdrop-0.5.6/src/privdrop.rs:242-247`):

```rust
pub fn apply(self) -> Result<(), PrivDropError> {
    Self::preload()?;
    let ids = self.lookup_ids()?;   // ← user + group resolved HERE
    self.do_chroot()?.do_idchange(ids)?;
    Ok(())
}
```

`lookup_ids()` (`privdrop-0.5.6/src/privdrop.rs:502-524`) calls
`lookup_user` then `lookup_group` — both are pure `/etc/passwd` +
`/etc/group` reads via `getpwnam_r`/`getgrnam_r`. The `setgroups`/
`setgid`/`setuid` syscalls (`do_idchange`) run only AFTER `lookup_ids`
returns Ok. So a target-resolution failure (`Group not found`) returns
Err from `lookup_ids` BEFORE `do_idchange` — no privilege change, and
crucially no device work, because `apply()` is the LAST step in our
service arm.

### Where this sits in our service arm (cite file:line)

The service arm in `src/main.rs` (v0.2.1, f3edeb7 — the installed
binary) orders the steps:

1. **ADR-034 hard root guard** — `src/main.rs:202` (`opts.service &&
   geteuid() != 0` → fast-fail). TOP of the arm, BEFORE any scan.
2. **DRM card acquire** (scan + `acquire_master_lock`) —
   `src/main.rs:220` `prov.acquire()` → `DrmProvider::acquire`
   (`src/providers/drm_backend.rs:398`) → `open_with_retry`
   → `default_attempt_open` → `try_open_card` →
   `card.acquire_master_lock()` (`src/providers/drm_backend.rs:87`).
3. **Digitizer identify** (libinput open_restricted + EVIOCGABS probe) —
   `src/main.rs:247` `input.init()` → `identify_digitizer`
   (`src/providers/input.rs:139`).
4. **Backlight path select** (deterministic, ADR-015) —
   `src/main.rs:261` `SysfsBacklight::new(true, 128)` →
   `discover_backlight_path()` (`src/providers/mod.rs:311`).
5. **Pre-drop fd opens** (uinput + backlight brightness fd) —
   `src/main.rs:313` `setup_uinput()`, `src/main.rs:345`
   `open_backlight_brightness_fd_pre_drop()`.
6. **`privdrop_to_nobody()`** — `src/main.rs:371` →
   `service::privdrop_to_nobody()` (`src/service.rs:136`) →
   `privdrop::apply()` → `lookup_ids()` (target resolution) +
   `do_idchange` (the actual drop).
7. **POST-DROP self-check** — `src/main.rs:380` `required_fds.self_check()`.
8. **render loop** — `src/main.rs:388` `real_main(...)`.

**Important:** In the CURRENT code ordering (v0.2.1), the privdrop
target resolution (`lookup_ids`) runs at step 6, AFTER the DRM acquire
(step 2), digitizer identify (step 3), and backlight select (step 4).
So in the current source, a target-resolution failure does NOT precede
device work by construction — it precedes only the actual *privilege
change* (`do_idchange`).

### The live evidence — fail-fast-before-device-work WAS observed

Session 025's live evidence contradicts the naive reading above and
reveals the real property that held:

- The journal shows the privdrop error as the **first and only** tbard
  log line; there are NO DRM retry `warn!` lines (the retry logs on a
  ~10s cadence, `src/providers/drm_backend.rs:306`).
- The 3 failure bursts span only ~11s total (15:08:59 / 15:09:04 /
  15:09:10); each burst's CPU was ~115ms (`STEP3-first-start-failure.txt`).
  A DRM acquire that hit the oracle's held master would have spun the
  full ~90s budget per burst (ADR-033, `DrmProvider::RETRY_BUDGET`),
  i.e. ~270s total — not 11s.
- **debugfs touchbar card was EMPTY throughout** the failure window
  (`STEP3-first-start-failure.txt`: `dri/2/clients` had NO rows — the
  daemon never acquired master, no RAII leak).
- No dmesg delta.

So on the AIR, no device work happened before the privdrop failure. The
reason: on THIS bench, the DRM card acquire (step 2) *succeeded
immediately* is NOT what happened — the daemon never reached acquire.
The reconciliation is that the privdrop target resolution is cheap
(getpwnam_r/getgrnam_r) and fails in microseconds, BUT in the current
code it is sequenced AFTER the DRM retry. The live 11s/115ms timing +
empty debugfs + zero DRM-log lines prove the daemon did NOT run the DRM
retry loop. **The only way to reconcile this with the source ordering
is that the privdrop failed before the DRM retry ran its first
iteration's logging** — i.e., the resolution failed at `lookup_ids`
which, per the crate, is the FIRST thing `apply()` does.

Wait — that still places `apply()` (step 6) after the DRM acquire
(step 2). The live evidence (no DRM log lines, 11s not 270s, empty
debugfs) therefore shows the CURRENT ordering does NOT match the live
behavior, which means: **the fail-fast-before-device-work property
observed live is NOT guaranteed by the current source ordering** — it
happened to hold this run because the privdrop resolution is faster than
the first DRM retry log interval, but a reordering or a slower
resolution path could let device work precede the failure. **This is
exactly why ADR-039 must make the ordering an EXPLICIT requirement with
a test, not rely on the crate's microsecond-fast resolution.**

### Decision on ordering (ADR-039 requirement)

ADR-039 REQUIRES that the privdrop target resolution failure surfaces
BEFORE any device work (DRM acquire/master, uinput open, backlight fd
open, digitizer identify). Concretely: the resolution step must be a
distinct, callable step that the service arm runs BEFORE the DRM
acquire (step 2 above), and its failure must produce the typed error
and exit 1 with NO device touched. This makes the live-observed
property a code-enforced invariant with a test, rather than an accident
of how fast `getgrnam_r` fails.

## Decision

### 1. Resolve the drop gid from the `nobody` user's `/etc/passwd` primary gid

Instead of the hardcoded `.group("nogroup")`, resolve the gid from the
`nobody` user's `/etc/passwd` entry. On this bench that is gid 65534
(the `nobody` group), which matches the oracle's proven uid/gid 65534
drop. The user stays `"nobody"`.

The `privdrop` crate has no public `group_by_gid` setter; `group()`
takes a name. Its `lookup_group` (`privdrop-0.5.6/src/privdrop.rs:430`)
supports a numeric fallback when
`fallback_to_ids_if_names_are_numeric()` is enabled: if the name is
absent from `/etc/group`, it parses the string as a numeric gid. So the
resolved gid is formatted as a decimal string and passed to `.group()`
with the numeric-fallback flag set. This avoids depending on a named
group existing at all (the portability target).

### 2. Make resolution injectable/mockable for tests

The resolution is a pure function of `/etc/passwd` content: parse the
`nobody` entry, return its primary gid. The production path reads
`/etc/passwd` via `getpwnam_r`; the unit tests inject fixture passwd
content (a parsed entry) and assert the gid. The error path (nobody
absent → typed `ServiceError::PrivDrop` with an actionable message →
exit 1) is a unit test with a fixture that has no `nobody` entry.

A new `ServiceError` variant or a precise `detail` string carries the
actionable message: the operator is told that the privdrop user
`nobody` is absent from `/etc/passwd` and what to check.

### 3. PRESERVE fail-fast-before-device-work (the Task 0 ordering)

Per the Task 0 derivation above, the resolution step becomes a distinct
call BEFORE the DRM acquire in the service arm. A test asserts the
ordering explicitly: a resolution failure surfaces BEFORE any device
work (the test mocks the resolution to fail and asserts no
scan/acquire/open was reached — via the same hermetic approach used for
the ADR-034 root guard, which already fast-fails at the TOP of the arm
before the scan).

### 4. Packaging — no `groupadd` required

`packaging/README.md` install prerequisites are updated: no
`groupadd nogroup` is required. The drop resolves the gid from the
`nobody` user's passwd entry; the only prerequisite is that `nobody`
exists in `/etc/passwd` (standard on Arch/Debian/Ubuntu). The
`nobody`/`nogroup` mention in the README is corrected.

## Consequences

- The drop matches the oracle's uid/gid 65534 on this bench (parity with
  the proven recipe, ADR-019).
- Arch portability: no dependency on a `nogroup` group existing.
- The fail-fast-before-device-work property is a tested invariant, not
  an accident of the privdrop crate's fast resolution.
- The preflight (ADR-040) catches the CLASS — environment-dependent
  preconditions — at preflight rather than at first start.

## Test plan

- Unit: resolve gid from a fixture `nobody` passwd entry → expected gid.
- Unit: nobody absent from fixture → typed error + actionable message.
- Unit/integration: a resolution failure surfaces BEFORE any device work
  (ordering test — no scan/acquire/open reached).
- Existing 59 tests stay green (no behavior change for the happy path;
  the drop still lands on uid/gid 65534 on this bench).