# ADR 036: Digitizer Input fd Is Pre-Drop — Confirm + Wire Into the Required-Fd Self-Check

## Status: Accepted

## Date: 2026-09-26

## Context

### Task 0 derivation (W-DIGITIZER): where is the digitizer input device
### opened in SERVICE mode — pre-drop or post-drop?

This is the derivation that determines whether ADR-036 is a code change
or a docs-only confirmation. The verdict, cited from code:

**The digitizer input device (`/dev/input/eventN`, opened by
`LibinputProvider` via the libinput `open_restricted` callback) is opened
PRE-DROP in SERVICE mode.**

The sequence in `src/main.rs` (SERVICE arm, `opts.service == true`):

1. `src/main.rs:246` — `let mut input = LibinputProvider::new(tb_dims);`
   constructs two `Libinput` contexts (`src/providers/input.rs:64-77`)
   and calls `udev_assign_seat("seat-touchbar")` / `udev_assign_seat
   ("seat0")` (`src/providers/input.rs:67-68`). `udev_assign_seat`
   schedules device enumeration but does NOT yet open device nodes
   (input-0.9.1 `context.rs:283-296`: "succeeds even if no input
   devices are currently available… or if devices are available but
   fail to open in `open_restricted`").
2. `src/main.rs:247-249` — `if let Err(e) = input.init() { warn!(...) }`
   calls `LibinputProvider::init` (`src/providers/input.rs:143-147`),
   which calls `self.tb_input.dispatch()` and `self.main_input.dispatch()`.
   `dispatch()` (`input-0.9.1 `context.rs:330-345`) drains the libinput
   fd and, during udev-based enumeration, invokes the
   `LibinputInterface::open_restricted` callback
   (`src/providers/input.rs:35-44`) for each matching device. That
   callback `OpenOptions::new().custom_flags(flags).read(...).open(path)`
   on the `/dev/input/eventN` node — **this is the open of the digitizer
   fd**. The fd is held inside the `Libinput` context for the daemon's
   lifetime.
3. `src/main.rs:293-336` — the pre-drop fd set is assembled:
   `required_fds.uinput` (`main.rs:311`), `required_fds.drm`
   (`main.rs:317`), `required_fds.backlight` (`main.rs:326`). **The
   digitizer fd is NOT recorded here** — `service::RequiredFds`
   (`src/service.rs:71-75`) has only `drm`, `uinput`, `backlight`.
4. `src/main.rs:350-353` — `service::privdrop_to_nobody()`. The process
   is now `nobody`/`nogroup`. Per NF-020-A, no `uaccess` ACL
   materializes on the Touch Bar input node (`ID_SEAT=seat-touchbar`
   moves it off `seat0`, and there is no `seat-touchbar` in logind),
   and `nobody` is not in the `input` group — so a `post-drop` open of
   the digitizer node would EACCES.
5. `src/main.rs:359-362` — `required_fds.self_check()` runs. It probes
   only `drm`, `uinput`, `backlight` (`src/service.rs:84-114`). The
   digitizer fd is NOT checked.
6. `src/main.rs:601` (inside `real_main`'s loop) — `input.poll()`
   (`src/providers/input.rs:149-219`). The `Event::Device` arm
   (`input.rs:157-162`) calls `self.is_digitizer(&dev)`
   (`input.rs:84-95`), which calls `read_abs_mt_maxima(&evdev)`
   (`input.rs:106-128`). `read_abs_mt_maxima` **opens the evdev path
   read-only a SECOND time** (`input.rs:114-118`,
   `OpenOptions::new().read(true).custom_flags(O_CLOEXEC).open(evdev)`)
   to issue `EVIOCGABS` ioctls. This second open is POST-DROP and
   would EACCES under NF-020-A (nobody ∉ input, no ACL).

### Verdict

- **Open of the libinput-held digitizer fd: PRE-DROP** (`init()` →
  `dispatch()` → `open_restricted`, `main.rs:247` before the drop at
  `main.rs:350`). ADR-036 is therefore NOT a "move the open pre-drop"
  change — the open is already pre-drop.
- **Gap 1: the digitizer fd is NOT in `RequiredFds` / `self_check`.**
  ADR-019 D2's "every required fd must be opened pre-drop and verified
  post-drop" contract is not fully met for the digitizer.
- **Gap 2: the digitizer IDENTIFICATION (`is_digitizer`) opens the
  evdev path a SECOND time, POST-DROP, in `poll()`.** Under NF-020-A
  (nobody ∉ input, no ACL), this second open EACCESes, so
  `is_digitizer` returns `false` for every device and `self.digitizer`
  stays `None` forever — the daemon would run but NEVER register touch
  events. This is a silent limp, exactly the failure mode ADR-019 D2
  forbids ("never limp on with a missing fd").

### Stage-3 / Stage-4 impact (required by the brief)

- **Stage 3** (first real `tbard --service` start under the interlock):
  an EAGER post-drop open of the digitizer would CRASH at startup —
  `init()` runs pre-drop, so the libinput-held fd is fine; but
  `is_digitizer`'s second open in `poll()` EACCESes silently. The
  daemon does NOT crash (EACCES is mapped to `None` → `false`); it
  LIMPS — no touch events ever register. The post-drop self-check
  (which does not cover the digitizer fd) passes, masking the limp.
  This is the "silent limp on a missing fd" anti-pattern.
- **Stage 4** (compositor integration): a LAZY post-drop open would
  BLOCK the first touch — the operator touches the bar, `poll()` runs
  `is_digitizer`, the evdev open EACCESes, the touch is dropped. Same
  limp, just deferred to first touch.
- **Either way, nobody CANNOT open the digitizer post-drop**
  (NF-020-A proof: no ACL materializes on `seat-touchbar`; nobody ∉
  `input`). The only safe path is: identify the digitizer PRE-DROP
  (during `init()`), hold the evdev fd used for the geometry probe
  across the drop, and add the digitizer fd to `RequiredFds` +
  `self_check` so a missing/unusable digitizer fd is a typed
  `PostDropFdCheck` failure (exit 1), never a silent limp.

## Decision

### D1 — Confirm the pre-drop open (docs; no code change for the open)

The libinput-held digitizer fd is opened PRE-DROP by `init()` →
`dispatch()` → `open_restricted` (`main.rs:247`, before the drop at
`main.rs:350`). This is documented here as the Task 0 confirmation. No
code change is needed for the open itself.

### D2 — Move digitizer IDENTIFICATION pre-drop (code)

Add `LibinputProvider::identify_digitizer(&mut self)` which runs the
`is_digitizer` geometry probe DURING `init()` (pre-drop), while the
process is still root. The probe opens the evdev path read-only to read
`ABS_MT` maxima (`read_abs_mt_maxima`, `input.rs:106-128`). To keep the
probe's evdev fd usable post-drop (the libinput context's own fd is
already held, but the probe opens a SEPARATE read-only fd for
`EVIOCGABS`), the probe's evdev fd is held inside `LibinputProvider`
for the daemon's lifetime. `is_digitizer` in `poll()` then reuses the
HELD evdev fd instead of re-opening — no post-drop open.

If the digitizer is not found during `init()` (no matching device on
`seat-touchbar`, or the geometry probe fails), `identify_digitizer`
returns a typed error. In SERVICE mode, this is a startup failure (exit
1) — the daemon must NOT limp without a digitizer. In dev/dry-run and
bare `tbard` mode, the failure is a `warn!` (preserve existing
behavior: `main.rs:247-249` already only warns on `init()` failure in
non-service paths).

### D3 — Add the digitizer fd to `RequiredFds` + `self_check` (code)

Extend `service::RequiredFds` (`src/service.rs:71-75`) with a
`digitizer: Option<RawFd>` field. The self-check
(`src/service.rs:84-114`) probes it with `fcntl(F_GETFL)` like the
other three. In `main.rs`, the service arm records the digitizer fd
into `required_fds.digitizer` after `init()` succeeds and before the
privdrop. The fd used is the libinput `tb_input` context's fd (the
seat-touchbar context that enumerates the digitizer) via `as_raw_fd()`
— this is the fd libinput holds open for the seat-touchbar devices.

### D4 — Preserve dev/sim behavior (hermetic tests)

- `--dry-run` uses `SimInputProvider` (no `LibinputProvider`, no
  privdrop, no `RequiredFds`). Unchanged.
- bare `tbard` (real, non-service) uses `LibinputProvider` but does
  NOT privdrop and does NOT build `RequiredFds`. `identify_digitizer`
  runs during `init()` (harmless — root or input-group user can open
  the evdev node); on failure it `warn!`s and the daemon continues
  (existing behavior).
- The service-path unit tests exercise the self-check LOGIC with
  mocked fd sets (no root, no real privdrop) — they continue to pass
  because the new `digitizer` field is `Option<RawFd>` and the tests
  that construct `RequiredFds` directly are updated to include it.

### D5 — Test (mocked)

Add a unit test in `src/service.rs` asserting the digitizer fd is in
the pre-drop required set: a `RequiredFds` with `digitizer: None` ⇒
`PostDropFdCheck { fd: "digitizer", … }`, and a `RequiredFds` with all
four fds present + valid ⇒ self-check OK. This is the Task 0 test.

## Alternatives considered

- **Docs-only (just confirm the pre-drop open).** Rejected: the
  digitizer fd is NOT in `self_check`, and `is_digitizer`'s second
  evdev open is post-drop. A docs-only ADR would leave the silent-limp
  gap open — exactly the failure mode NF-020-A exposes.
- **Move the libinput open itself pre-drop.** Not needed — it is
  already pre-drop. The change is the IDENTIFICATION + the self-check
  coverage, not the open.
- **Drop the `seat-touchbar` isolation to make `uaccess` materialize.**
  Rejected — that is ADR-037's trade-off, and the RECOMMENDED resolution
  there is to KEEP the isolation. ADR-036 must work WITH the isolation
  (nobody ∉ input), which is why the digitizer fd must be opened +
  identified + held pre-drop.

## Impact list

- `src/service.rs` — `RequiredFds` gains a `digitizer: Option<RawFd>`
  field; `self_check` probes it; new test for the missing-digitizer-fd
  case + the all-four-present case.
- `src/providers/input.rs` — `LibinputProvider::init` runs
  `identify_digitizer` pre-drop; `is_digitizer` reuses the held evdev
  fd (no post-drop open); `LibinputProvider` holds the evdev fd + the
  identified `InputDevice`; new accessor for the digitizer fd raw fd
  for the self-check.
- `src/main.rs` — service arm records `required_fds.digitizer` after
  `init()` succeeds, before the privdrop.
- `docs/adr/036-digitizer-fd-pre-drop.md` — this ADR.
- `docs/test-plan.md` — note the new self-check coverage.
- `CHANGELOG.md` / `devlog.md` — session 021.

## References

- `src/main.rs:246-249` (input.init() pre-drop), `:293-362`
  (RequiredFds + privdrop + self-check), `:601` (poll)
- `src/providers/input.rs:35-44` (open_restricted), `:64-77` (new),
  `:84-95` (is_digitizer), `:106-128` (read_abs_mt_maxima),
  `:143-147` (init), `:149-219` (poll)
- `src/service.rs:71-115` (RequiredFds + self_check)
- `docs/adr/019-production-service.md` (D2 — pre-drop fd contract)
- `docs/adr/009-digitizer-geometry.md` (geometry-based identification)
- `docs/test-logs/020/udev-migration.log` (NF-020-A: no ACL on
  seat-touchbar)
- `docs/adr/037-seat-uaccess-adjudication.md` (the seat/uaccess
  trade-off; keep the isolation)