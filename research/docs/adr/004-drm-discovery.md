# ADR 004: Single-Writer DRM Discovery — Read-Only Scan, Master Only on the Matched Touch Bar Card

## Status: Accepted

## Date: 2026-09-25

## Context

Pre-flight review §2.2 (`docs/review-report.md`) found two defects in the
DRM discovery path:

- **Defect A — discovery grabs master on every card.** `discover_touchbar_drm`
  (`src/providers/mod.rs`) iterated all `/dev/dri/card*` entries and called
  `probe_drm_device` on each, which opened the card read+write and called
  `card.acquire_master_lock()` during the scan. On the review bench that
  means the daemon momentarily took DRM master on `/dev/dri/card1` (the
  i915 eDP laptop panel) while probing it. On a live compositor this can
  race the compositor's KMS master and black-blink the laptop display
  (danger D4 in `docs/dangers.md`).

- **Defect B — the Touch Bar card is opened twice.** Discovery opened the
  matched card (master taken and dropped when the probe `Card` was
  dropped), then `try_open_card` re-opened the same path and took master
  again. Between the two opens there was a window where no process held
  master on the Touch Bar card.

The review's invariant (corrected for the bench, where the Touch Bar IS
`card0`): **only the geometry-matched card is ever opened for write / master;
the eDP/GPU card and any decoy desktop card (e.g. vkms) are opened
read-only during the scan and never granted master.**

## Root cause

`probe_drm_device` combined three concerns in one function: (1) opening the
card, (2) acquiring DRM master, and (3) reading connector/mode geometry.
`DRM_IOCTL_MODE_GETRESOURCES` (the `drm` crate's `resource_handles()`) and
`drmModeGetConnector` do **not** require DRM master — only modesetting
ioctls do. Master was being acquired solely to read geometry that is
available without it.

## Decision

Split discovery into a **read-only geometry scan** that never takes master,
and a **single master-acquiring open** on the matched candidate only.

### 1. Read-only scan (`discover_touchbar_drm`)

- Enumerate `/dev/dri/card*` entries.
- Open each card with `O_RDONLY | O_CLOEXEC` (no write, no master). The
  `drm` crate's control-device trait works on a read-only fd for
  `resource_handles()` and `get_connector()`.
- **Never call `acquire_master_lock()` during the scan.**
- For each connected connector, read the first mode and apply the
  geometry gate: `(height * 100) / width > 30` (aspect ratio > 30, i.e.
  a Touch Bar 2170×60 → 36.2). Note: strictly greater than 30 (was `>=
  3000` in the old `>= 3000` hundredths check, i.e. `>= 30`; this ADR
  tightens the gate to `> 30` per the wave spec, which still accepts
  36.2 and still rejects the eDP 0.625 and vkms 0.75).
- **Log every card + verdict** at `info` level: path, driver (when
  available), connector state, mode size, ratio, and the verdict
  (`ACCEPTED` / `rejected: aspect ratio` / `rejected: no connected
  connector` / `rejected: open error`). This gives an audit trail that
  no non-Touch-Bar card was promoted.
- Return the path of the first `ACCEPTED` candidate, or bail with the
  full verdict list if none match.

### 2. Single master-acquiring open (`DrmProvider::acquire`)

- After discovery returns a path, `try_open_card` opens that one path
  read+write and calls `acquire_master_lock()` **once**. The fd is kept
  for the lifetime of the `DrmProvider` (held, not closed-and-reopened),
  so there is no master gap on the Touch Bar card.

### 3. Regression test (vkms decoy)

A regression test loads a vkms module instance as a decoy "desktop" card
(ratio ≈ 0.75, never a Touch Bar) and asserts the daemon's scan never
requests master on it. Because the scan is now read-only by construction,
the test asserts the observable contract: scanning `/dev/dri/` with a
vkms card present produces a verdict log that marks the vkms card
`rejected: aspect ratio` and returns no path that would cause a master
acquisition on it. The test guards against any future regression that
re-introduces a master call during the scan by running the read-only scan
function directly and checking it does not promote the decoy.

When vkms cannot be loaded (no root, no module), the test is skipped with
a clear message — it is a hardware-environment guard, not a pure unit
test.

## Alternatives considered

- **Open every card read+write but skip master on non-matches.** Rejected:
  opening a DRM card read+write can fail with `EPERM`/`EACCES` on cards
  the user does not own, and the write fd is not needed for geometry.
  Read-only is the minimal privilege.

- **Use `drmModeSetMaster` only inside `try_open_card`.** This is what we
  do, but alone it does not fix Defect A — discovery also has to avoid
  master. Both halves are required.

- **Cache the matched path across restarts.** Rejected for now: card
  enumeration order is not stable across reboots on multi-GPU machines,
  and a stale cache could point at the wrong card. Geometry scan per
  startup is cheap and safe.

## Impact list

- `src/providers/mod.rs` — `discover_touchbar_drm` rewritten to a
  read-only scan with per-card verdict logging; `probe_drm_device`
  removed (replaced by a read-only `scan_card` helper that does not take
  master).
- `src/providers/drm_backend.rs` — `try_open_card` unchanged in spirit
  (it already takes master once on the matched path); the double-open
  is removed because discovery no longer opens the matched card for
  write.
- No public trait change; `DisplayProvider::acquire` contract unchanged.
- Logging dependency (`log`) already present.

## Regression test

`src/providers/mod.rs` tests module: `test_scan_never_promotes_vkms_decoy`.
Loads vkms (or detects an existing vkms card), runs the read-only scan,
and asserts (a) the scan returns `Err` (no Touch Bar present in the test
env) or a path whose geometry passes the gate, and (b) no verdict marks
the vkms card `ACCEPTED`. The test documents that master is never
requested during the scan by construction. See the test source for the
skip condition.

## References

- `docs/review-report.md` §2.2 (the FAIL being fixed)
- `docs/dangers.md` D4 (eDP master contention)
- `src/providers/mod.rs` — revised discovery
- `src/providers/drm_backend.rs` — `try_open_card` (single master open)