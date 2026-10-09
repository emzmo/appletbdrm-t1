# ADR-055: Config watcher re-arm — atomic-replace survival

Status: ACCEPTED (session 053)
Date: 2026-09-27

## Context (session-051 evidence)

Three consecutive config edits produced exactly ONE reload (docs/test-logs/051/
STEP6-*): the watcher "does not re-fire after the first reload".

## Root cause (cited)

src/config/manager.rs (pre-fix): the inotify watch was armed on the CONFIG
FILE'S INODE (`add_watch(path, IN_MOVED_TO | IN_CLOSE_WRITE)`). An atomic
config replace (`sed -i`, `mv`, `install`, editors' write-temp+rename) replaces
the inode — the kernel invalidates the file watch (IN_IGNORED) and the pre-fix
code never handled it: the stale WatchDescriptor sits dead, all later edits go
to a new inode the watch never sees. First-reload-then-silence matches the
session-051 evidence exactly.

## Decision

Watch the PARENT DIRECTORY (`add_watch(parent, IN_MOVED_TO | IN_CLOSE_WRITE)`)
and filter events by the config file's NAME (`evt.name == watch_name`).
A directory watch survives file replacement. IN_IGNORED is still handled
defensively (watch=None → re-arm next iteration). ADR-021's semantics
(persistent watch, drain-to-EAGAIN, 200ms debounce, one write ⇒ one reload)
are unchanged.

## Considered alternative

Re-arm-on-IN_IGNORED with a FILE watch alone: the session-053 adversarial
demo accidentally implemented this (a planted revert that still passed the
survival test). It works in principle, but requires re-arming after every
atomic replace and has a watch-dead window between IN_IGNORED and the next
check_reload call. The directory watch has no dead window; chosen.

## Regression guard (non-vacuity, demonstrated)

`test_adr055_watch_survives_atomic_replace`: TWO atomic replaces must BOTH
reload (the second is the pre-fix killer — verified: the TRUE pre-fix
implementation fails this test; docs/test-logs/053/adversarial-demos.log).
`test_adr055_name_filter_ignores_other_files`: directory events for OTHER
files must not trigger a reload (guards the new false-positive surface).
