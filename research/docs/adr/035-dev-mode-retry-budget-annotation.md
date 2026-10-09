# ADR 035: Annotate ADR-019 D3 + ADR-033 Impact List — Dev-Mode Retry Budget (NF-A4 closure)

## Status: Accepted

## Date: 2026-09-26

## Context

QA v6.5 (`docs/review-report-v6-5.md`) raised **NF-A4** (a
documentation finding, not a code defect):

> Bare `tbard` (dev/real-non-service, no `--service`) on a missing or
> occupied Touch Bar card now waits ~90s (`RETRY_BUDGET`) before exit 1
> — the same budget as `--service`. ADR-019 D3 mentions that "main's
> real-mode path already calls this loop" (line 122-123), so the
> behavior is implicit, but NEITHER ADR-019 D3 NOR ADR-033 explicitly
> documents that a developer running bare `tbard` against an occupied
> card (e.g. on this bench with the oracle running) will wait ~90s
> before the typed "card never appeared" error. Pre-ADR-033 this was
> ~30min (NF-A1); post-ADR-033 it is ~90s — an improvement, but the
> dev-mode wait time was not called out as a documented behavior.

### Why this is a documentation gap, not a code defect

ADR-033 flattened the retry by removing the outer `for attempt in
1..=30` loop in `main.rs` and budgeting `DrmProvider::acquire()` with
a single system-level wall-clock `RETRY_BUDGET` (~90s). The fix is
correct: a single bounded budget is strictly better than nested/
unbounded (bounded × bounded = effectively unbounded, NF-A1).

The shared `DrmProvider::acquire()` is called by BOTH the `--service`
arm AND the bare dev/real-non-service arm (the `else` real arm at
`main.rs`). ADR-033's impact list lists `src/main.rs` and
`src/providers/drm_backend.rs` as the touched files, and ADR-019 D3
notes that "main's real-mode path already calls this loop" — but
neither ADR explicitly calls out that the ~90s budget therefore also
bounds the bare/dev-mode retry. A developer running `tbard` bare
against an occupied card (the normal bench state with the oracle
running) will wait ~90s where they previously waited ~30min. This is
intended (bounded is better than unbounded), but it was not
documented.

## Decision

**Annotate, do not rewrite.** Add annotation blockquotes to two
existing ADRs — no decision text is changed.

1. **ADR-019 D3** (`docs/adr/019-production-service.md`, after the
   existing ADR-033 correction blockquote) — a new annotation
   blockquote stating that the ADR-033 flattening applies to
   `DrmProvider::acquire()`, which is shared by both the `--service`
   and bare dev/real-non-service arms, so a bare `tbard` on a missing
   or occupied card now waits the same ~90s `RETRY_BUDGET` before the
   typed "card never appeared" exit 1. Previously nested ~30min
   (NF-A1); now bounded ~90s. Intended behavior; documented here.

2. **ADR-033 impact list** (`docs/adr/033-flatten-retry-budget.md`,
   "Impact list" section) — a new bullet citing this ADR-035 and
   stating that the ~90s `RETRY_BUDGET` also bounds the bare/dev-mode
   retry (previously the nested ~30min case). Intended behavior,
   previously undocumented. No code change.

No code, test, packaging, or script changes. This ADR is docs-only.

## Alternatives considered

- **Rewrite ADR-019 D3 and ADR-033 to inline the dev-mode
  consequence.** Rejected: both ADRs are Accepted and describe
  decisions that were correct at the time; rewriting their prose
  would muddy the audit trail. The annotation pattern (blockquote
  appended after the relevant section) is already established by
  ADR-019 D3's ADR-033 correction blockquote and is the project
  convention for documenting consequences discovered later.

- **Add a separate ADR-035 that re-derives the dev-mode retry
  behavior from scratch.** Rejected: the behavior is a direct
  consequence of ADR-033, not a new decision. A short annotation ADR
  that points at the two annotated ADRs is the minimal honest record.

## Impact list

- `docs/adr/019-production-service.md` — D3 gains an ADR-035
  annotation blockquote (after the ADR-033 correction blockquote).
- `docs/adr/033-flatten-retry-budget.md` — impact list gains an
  ADR-035 bullet.
- `docs/adr/035-dev-mode-retry-budget-annotation.md` — this file.
- No code, test, packaging, or script changes.

## References

- `docs/review-report-v6-5.md` — NF-A4 finding (QA v6.5)
- `docs/adr/019-production-service.md` — D3 (boot race / bounded retry)
- `docs/adr/033-flatten-retry-budget.md` — the flattening decision
  (system-level wall-clock budget)
- `docs/adr/022-sigterm-retry.md` — the SIGTERM-responsive retry
  machinery (preserved by ADR-033)
- `docs/adr/025-exit-code.md` — exit-code contract (exit 1 on
  budget exhaustion; exit 0 on SIGTERM-during-retry)