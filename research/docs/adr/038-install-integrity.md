# ADR 038: Install Integrity — PKGBUILD Repair + Build-from-Verified-HEAD Process Rule

## Status: Accepted

## Date: 2026-09-26

## Context

### NF-020-B (session 020, BLOCKER for Stage 3) — the stale-binary finding

The binary installed at `/usr/bin/tbard` during session 020 was a
**pre-ADR-019 build** (mtime 2026-09-25 23:34, ~13.5h before the
ADR-019 service-mode merge `26f3f3f` at 2026-09-26 13:11). It rejected
`--service` as an unknown argument (exit 2 in 5ms, "unknown argument
'--service'"; `strings /usr/bin/tbard | grep -- --service` → 0
matches). The source at v0.2.0 HEAD was correct (`src/main.rs:77` had
`"--service" => opts.service = true`); the BINARY was stale.

Critically, **every repo gate was green** at the time of the install:

- `cargo test` — 57 passed.
- `cargo clippy --all-targets` — clean.
- `scripts/check-invariants.sh` — PASS.
- `systemd-analyze verify /usr/lib/systemd/system/tbard.service` —
  exit 0 (it only checks the ExecStart path EXISTS, not the binary's
  args).

The stale binary was caught ONLY by the R1 behavioral check
(`tbard --service` unprivileged → expected: exit 1 with the ADR-034
"service mode requires root" message; got: exit 2 "unknown argument").
This is the proof point for the process rule in D2: **repo gates are
necessary but NOT sufficient — a behavioral check against the INSTALLED
binary is required to catch a stale/wrong build.**

### The rebuild evidence (session 021, outside a code session)

The human performed the rebuild OUTSIDE a code session (FREEZE RULE
D10) per the session 020 hand-off. The verbatim evidence is archived
at `docs/test-logs/021/rebuild-evidence.log` (data only). Summary:

- `git log --oneline -2` at rebuild time: `f853a65` (HEAD -> master,
  v0.2.0-1-gf853a65), `892b2d0` (tag: v0.2.0). The build was from the
  verified tagged HEAD.
- Pre-rebuild: `sha256sum target/release/tbard` =
  `d1279e1f…` (the stale pre-ADR-019 build, matching the installed
  binary's hash from session 020).
- `cargo build --release` → finished in 5.74s.
- Post-rebuild: `sha256sum target/release/tbard` =
  `a6f9a57d42e442d1f9e0af18811447872c8de61e7584a6fcc9ff20fc5d13276f`.
- `sudo install -Dv -m 0755 target/release/tbard /usr/bin/tbard`
  (re-install).
- **R1 behavioral re-check (the gate that caught NF-020-B):**
  - `strings /usr/bin/tbard | grep -c -- '--service'` → 6 (was 0
    pre-rebuild).
  - `/usr/bin/tbard --service` (uid 1000) → exit 1 with
    `service mode requires root (euid=1000); start as root or via the
    systemd unit (tbard.service) — exit 1` (the ADR-034 message; was
    exit 2 "unknown argument" pre-rebuild).
- `sudo systemd-analyze verify /usr/lib/systemd/system/tbard.service`
  → exit 0 (unchanged — it only checks the path exists; this is the
  gate that DID NOT catch NF-020-B).
- `sh scripts/bench/interlock-preflight.sh` → NO-GO (oracle active,
  correct pre-Stage-3 baseline — unchanged from session 020).
- `sudo cat /sys/kernel/debug/dri/2/clients` → `tiny-dfr-mbp142` PID
  542, uid 65534, master=y on card2 (oracle untouched).

The rebuild closes the NF-020-B blocker's binary half: the installed
`/usr/bin/tbard` is now a v0.2.0 build that accepts `--service` and
fast-fails correctly when unprivileged.

### PKGBUILD staleness (session 020, packaging hygiene)

The shipped `packaging/PKGBUILD` has two issues that session 020
worked around by hand (`install -Dv`):

1. `pkgver=0.1.3` — stale vs. the v0.2.0 tag. The package version
   must match the tagged release.
2. `source=()` does not match the repo layout. The PKGBUILD expects
   `tbard.service`, `69-touchbar-seat.rules`, `config.yaml.example`
   flat in `$srcdir`, but they live in `packaging/systemd/`,
   `packaging/udev/`, and `packaging/` respectively. A clean
   `makepkg -si` would fail at the source stage without manual
   source staging.

## Decision

### D1 — Repair `packaging/PKGBUILD`

- **`pkgver=0.2.0`** (match the tagged release).
- **`source=()` matching the repo layout.** The PKGBUILD is shipped in
  `packaging/` alongside the repo, so the source array references the
  actual paths relative to the repo root:
  - `packaging/systemd/tbard.service`
  - `packaging/udev/69-touchbar-seat.rules`
  - `packaging/config.yaml.example`
  - the Cargo project source (the PKGBUILD builds `cargo build
    --release --bin tbard` from the repo root, so the source array
    must include the repo source; for an in-tree PKGBUILD the simplest
    correct approach is `source=()` empty with the build done in-place
    from `$srcdir` pointing at the repo, OR a `source=("$pkgname-
    $pkgver.tar.gz")` pointing at a release tarball. For the
    deploy-hardening scope, the PKGBUILD is repaired to build in-place
    from the repo layout, with the `source=()` array listing the
    actual packaging files at their repo paths so `makepkg` can stage
    them, and the `build()`/`package()` functions cd to the repo root.
- **`bash -n` syntax validation** (already done in session 015; the
  repaired PKGBUILD is re-validated).
- **`check()` function** — if cheap. A full `cargo test` in `check()`
  is expensive (needs the sim harness + a tty with DRM master); it is
  NOT cheap and is NOT suitable for a `makepkg` check() on the target
  machine. The cheaper behavioral check (R1: `strings --service` > 0 +
  unprivileged `--service` → exit 1) IS cheap and IS the check that
  caught NF-020-B. The repaired PKGBUILD adds a `check()` that runs
  the R1 behavioral audit on the built binary (no root, no DRM, no
  sim harness — just `strings` + an unprivileged `--service` invocation
  expecting exit 1 with the ADR-034 message).

### D2 — PROCESS RULE: deployment/install sessions build from the verified tagged HEAD and verify binary identity BEHAVIORALLY before and after install

**Rule.** Every deployment/install session (any session that places a
`tbard` binary on a target machine, whether via `makepkg -si` or
manual `install`) MUST:

1. **Build from the verified tagged HEAD.** Record `git describe
   --tags` + `git rev-parse HEAD` + `git log --oneline -1` at build
   time. The HEAD MUST be the tagged release (e.g. `v0.2.0`) or a
   documented commit on a fix branch off it; the build is NEVER from
   an unverified working tree.
2. **Verify binary identity BEHAVIORALLY BEFORE install.** On the
   built binary (in `target/release/tbard`):
   - `strings <binary> | grep -c -- '--service'` > 0 (the binary
     accepts `--service` — catches a pre-ADR-019 stale build).
   - `<binary> --service` as an unprivileged user → exit 1 with the
     ADR-034 "service mode requires root" message (the fast-fail is
     the regression target; a stale build exits 2 "unknown argument"
     or spins).
   - Record the `sha256` of the built binary.
3. **Verify binary identity BEHAVIORALLY AFTER install.** On the
   INSTALLED binary (`/usr/bin/tbard`):
   - `strings /usr/bin/tbard | grep -c -- '--service'` > 0.
   - `/usr/bin/tbard --service` unprivileged → exit 1 with the
     ADR-034 message.
   - `sha256sum /usr/bin/tbard` matches the built binary's `sha256`
     from step 2 (the install copied the right file).
4. **Record all evidence** in the session's `docs/test-logs/NNN/`
   directory: the `git describe` + `git log` output, the pre-install
   behavioral checks, the `sha256` of the built + installed binary,
   the post-install behavioral checks.

**Why behavioral + sha256, not just sha256.** `sha256` catches a
wrong-file install (the installed hash does not match the built hash).
It does NOT catch a stale-but-correct-file install (the built binary
is the wrong BUILD — e.g. a pre-ADR-019 build sitting in
`target/release/` from an earlier session). The behavioral check
(`strings --service` + the unprivileged `--service` fast-fail) catches
the stale-build case because it probes the binary's ACTUAL behavior,
not just its bytes. NF-020-B is the proof point: the stale binary had
a `sha256` that matched itself (trivially) and passed
`systemd-analyze verify` (path exists), but FAILED the R1 behavioral
check.

**Evidence.** NF-020-B (session 020): the installed binary was a
pre-ADR-019 build; every repo gate was green (`cargo test`, `cargo
clippy`, `check-invariants.sh`, `systemd-analyze verify`); ONLY the
R1 behavioral check (`strings --service` + unprivileged `--service`
→ expected exit 1, got exit 2) caught it. The rebuild evidence
(`docs/test-logs/021/rebuild-evidence.log`) shows the behavioral
check passing after the rebuild (`strings --service` → 6;
`--service` unprivileged → exit 1 with the ADR-034 message).

### D3 — Close the loop in docs

- **R1 evidence archived.** The session 020 R1 regression log
  (`docs/test-logs/020/regression.log`) is the original NF-020-B
  discovery. The session 021 rebuild evidence
  (`docs/test-logs/021/rebuild-evidence.log`) is the rebuild + R1
  re-check. Both are referenced in the CHANGELOG + devlog.
- **Rebuild evidence archived.** `docs/test-logs/021/rebuild-
  evidence.log` (data only — verbatim capture of the human's rebuild
  + re-verify session).
- **Annotate session 020's install method note.** The session 020
  devlog entry + the `docs/test-plan.md` Stage-3 note already
  document the manual-`install` method (because the PKGBUILD was
  stale) and the NF-020-B blocker. ADR-038's PKGBUILD repair makes
  `makepkg -si` work for FUTURE installs; the session 020 manual
  install remains the record of what happened. The
  `docs/test-plan.md` Stage-3 note is updated to reference ADR-038's
  process rule for future install sessions.

## Alternatives considered

- **Docs-only (no PKGBUILD repair).** Rejected: the stale `pkgver` +
  wrong `source=()` would cause the next `makepkg -si` to fail or
  install the wrong version, which is exactly the class of bug
  NF-020-B exposed. The PKGBUILD is part of the install integrity
  surface.
- **Full `cargo test` in `check()`.** Rejected: not cheap (needs the
  sim harness + a tty with DRM master); not suitable for a `makepkg`
  check() on the target machine. The R1 behavioral audit is cheaper
  and is the check that caught NF-020-B.
- **`sha256`-only verification (no behavioral check).** Rejected:
  `sha256` catches a wrong-file install but NOT a stale-but-correct-
  file install (the wrong BUILD). NF-020-B is the proof point.
- **A reproducible-builds effort (byte-identical binaries).** Out of
  scope. ADR 010 already records that builds are not reproducible
  (embedded paths/timestamps differ); the behavioral + sha256 check
  is the pragmatic gate.

## Impact list

- `packaging/PKGBUILD` — `pkgver=0.2.0`; `source=()` matches the repo
  layout; `build()` / `package()` cd to the repo root and reference
  the packaging files at their repo paths; new `check()` runs the R1
  behavioral audit on the built binary; `bash -n` re-validated.
- `docs/adr/038-install-integrity.md` — this ADR.
- `docs/test-plan.md` — Stage-3 note references ADR-038's process
  rule for future install sessions.
- `CHANGELOG.md` / `devlog.md` — session 021.

## References

- `docs/test-logs/020/regression.log` §R1 (NF-020-B discovery: the
  behavioral check that caught the stale binary)
- `docs/test-logs/021/rebuild-evidence.log` (the rebuild + R1 re-check)
- `docs/test-logs/020/install-evidence.log` (the manual install +
  sha256 records)
- `docs/adr/010-master-acquisition-input.md` (builds not reproducible;
  the root+privdrop recipe)
- `docs/adr/019-production-service.md` (the service mode + packaging)
- `docs/adr/034-hard-root-guard-service.md` (the ADR-034 fast-fail
  message the R1 check probes for)
- `packaging/PKGBUILD` (the repaired PKGBUILD)