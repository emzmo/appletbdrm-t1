# Documentation Index

This repo's documentation is deliberately extensive: the Touch Bar has no
public datasheet, so **the documentation IS the datasheet**. Everything
below is evidence-backed — written from live hardware captures, source
derivations, and 57 working sessions of verbatim logs.

## Start here

| Read this | When |
|---|---|
| [README](../README.md) | First visit — what this is, screenshots, quick start |
| [prior-art.md](prior-art.md) | You want the project landscape: who did what, T1 vs T2 stacks, the naming-instability evidence |
| [use-cases.md](use-cases.md) | You want to know what you can build on this |
| [CONTRIBUTING](../CONTRIBUTING.md) | You want to hack on it — **read the interlock protocol before any hardware work** |

## Hardware ground truth (the "datascript")

| Document | Contents |
|---|---|
| [research/touchbar-interaction-manual/](research/touchbar-interaction-manual/) | **The manual**: backlight coupling regimes, min-visible brightness (1), decay timing (128→1 @ ~30s, →0 @ ~60s), the sysfs mtime quirk, wake semantics, input protocol |
| [research/corpus/](research/corpus/) | Labeled gesture corpus: 10 real-gesture evdev captures (single/double tap, long press, slow drag, fast swipe, two-finger, palm, idle) — reference fixtures for input work |
| [research/hyprland-aq-devices.md](research/hyprland-aq-devices.md) | Aquamarine DRM-backend facts (AQ_DRM_DEVICES filter is init-only, version matrix) — relevant if your compositor grabs the vkms test card |

## Decision record (ADR corpus — 57 and counting)

[adr/](adr/) — every non-trivial decision, with root cause, evidence,
alternatives, and a regression guard. The notable entries:

- **ADR-010** — the privilege model (root-start → privdrop to nobody; why no ambient caps)
- **ADR-020/024/056** — the coordinate-space trilogy (fb portrait / logical / digitizer raw)
- **ADR-041** — structural digitizer identity (why name-matching breaks across units)
- **ADR-044/054** — the transposed-dims bug family (portrait/logical confusion in the port)
- **ADR-046** — why sysfs mtime is invalid evidence on appletbdrm
- **ADR-049** — interlock hardening (the oracle can self-restart under stop; mask it)
- **ADR-055** — atomic-replace-safe config watching (directory watch + IN_IGNORED)
- **ADR-057** — wake-before-gate (the macOS touch-wake semantics, ported correctly)

## Safety & operations

| Document | Contents |
|---|---|
| [dangers.md](dangers.md) | **Read before any hardware session.** T1 ACPI hard-freeze risks, single-writer rule, host-safety rules (written after an incident) |
| [test-plan.md](test-plan.md) | The staged hardware-validation protocol: preflight GO/NO-GO, interlock variants, human checkpoints, acceptance criteria per stage |
| [recovery.md](recovery.md) | Tier 0–4 recovery: daemon stop → backlight safe-state → USB config → modules → reboot |
| [architecture.md](architecture.md) | The engine's layers, providers, and coordinate spaces |

## The evidence base (append-only)

| Path | Contents |
|---|---|
| [test-logs/](test-logs/) | Every hardware session, verbatim: journals, debugfs captures, HC answers, photos — 57 sessions from first pixels to Stage-4 PASS |
| [../devlog.md](../devlog.md) | The session-by-session development log (396 KB of process record) |
| [../CHANGELOG.md](../CHANGELOG.md) | Release history, v0.1.x → v0.2.9 |
| review-report*.md | The 14 adversarial QA verdicts (self-assessments are claims; live audits are verdicts) |
| self-assessment*.md | The fixer's claims, archived as data for QA — never trusted on their own |

## Upstream & provenance

| Path | Contents |
|---|---|
| [seborider-pr1-issue.md](seborider-pr1-issue.md) | The drafted upstream issue: same-model digitizer name instability (with both-names evidence) |
| [../backup_old/README.md](../backup_old/README.md) | Third-party reference sources: the oracle (tiny-dfr fork, MIT) + the kernel driver source (appletbdrm, GPL-2.0) — licenses and why they're preserved |
| [../lineage-research.md](../lineage-research.md) | The pre-project lineage research: what existed, what was dead, what gap this project fills |