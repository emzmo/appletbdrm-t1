# F-045-3 runbook amendment: /etc-deployed unit move-aside + mask

**Status**: Proposed amendment to ADR-049
**Date**: 2026-09-27
**Origin**: F-045-3 (docs/test-logs/045/findings-045.txt:138-153), F-045-1 adjudication session 046

## Context

ADR-049 (`docs/adr/049-interlock-hardening-mask-oracle.md`) hardens the interlock by masking the oracle during validation windows. The runbook commands assume the oracle's unit is at `/usr/lib/systemd/system/` (the package-installed location) — `systemctl mask` creates a `/dev/null` symlink at `/etc/systemd/system/<unit>` which overrides the `/usr/lib/` unit.

On this bench (and possibly other operator deployments), the oracle's unit is a REAL FILE at `/etc/systemd/system/tiny-dfr-mbp142.service` (not a symlink, not at `/usr/lib/`). `systemctl mask` fails:
```
Failed to mask unit: File '/etc/systemd/system/tiny-dfr-mbp142.service' already exists
```
(F-045-3, findings-045.txt:141-143). `systemctl mask` cannot overwrite a real file.

The deployed unit is byte-identical to the repo's `backup_old/systemd/tiny-dfr-mbp142.service` reference (sha256 `5310c917...`, diff empty — findings-045.txt:145-146). It is an operator-installed copy, not a package artifact.

## Decision

Amend ADR-049's runbook with a `/etc-deployed unit` section: for units deployed as real files at `/etc/systemd/system/`, use a MOVE-ASIDE + mask instead of a direct `systemctl mask`.

### Move-aside + mask procedure

**Mask**:
```bash
# Back up the real file.
sudo cp /etc/systemd/system/tiny-dfr-mbp142.service \
        /etc/systemd/system/tiny-dfr-mbp142.service.bak
# Remove the real file and replace with a /dev/null symlink (the mask).
sudo rm /etc/systemd/system/tiny-dfr-mbp142.service
sudo ln -s /dev/null /etc/systemd/system/tiny-dfr-mbp142.service
sudo systemctl daemon-reload
sudo systemctl stop tiny-dfr-mbp142.service 2>/dev/null || true
```

**Verify**:
```bash
systemctl is-enabled tiny-dfr-mbp142.service   # → masked
systemctl is-active tiny-dfr-mbp142.service     # → inactive
# Wait +60s, verify no auto-restart.
sleep 60 && systemctl is-active tiny-dfr-mbp142.service  # → still inactive
```

**Restore** (reverse the move-aside — do at STEP 8):
```bash
sudo rm /etc/systemd/system/tiny-dfr-mbp142.service
sudo mv /etc/systemd/system/tiny-dfr-mbp142.service.bak \
        /etc/systemd/system/tiny-dfr-mbp142.service
sudo systemctl daemon-reload
sudo systemctl start tiny-dfr-mbp142.service
```

**Verify restore**:
```bash
# Byte-identical to pre-session (sha256 must match the backup).
sha256sum /etc/systemd/system/tiny-dfr-mbp142.service
systemctl is-active tiny-dfr-mbp142.service   # → active
# Verify the backup file is GONE (cleanup).
ls /etc/systemd/system/tiny-dfr-mbp142.service.bak 2>/dev/null  # → No such file
```

## Consequences

- The ADR-049 runbook covers BOTH deployment shapes: `/usr/lib/systemd/system/` (package-installed, direct `systemctl mask` works) and `/etc/systemd/system/` (operator-installed, move-aside + mask required).
- The move-aside is reversible + verified byte-identical (sha256 match). The backup is cleaned up after restore — `/etc` returns to pre-session state.
- The 045 session operator authorized this move-aside (findings-045.txt:148-149) and verified the restore (findings-045.txt:152-153). This amendment DOCUMENTS the procedure so future sessions do not need to derive it on the fly.

## Relation to F-045-1

F-045-3 is a runbook defect, not a root cause of F-045-1 (the bar being dark). It is a PROCEDURAL finding: the ADR-049 interlock commands failed on this deployment shape, requiring a move-aside workaround. The workaround was applied successfully in 045. This amendment codifies it for future sessions.

**For the Task 3 A/B plan**: the pre-condition "oracle masked (ADR-049 move-aside mask for /etc-deployed units)" refers to THIS amendment. The A/B experiment requires the oracle to be masked (not just stopped) so it does not auto-restart and compete for the card during the observation window.