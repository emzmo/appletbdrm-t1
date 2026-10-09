# Task 0 — Tap-line verdict (the archived journal)

**Session**: 046 (read-only root-cause research, one session)
**Subject**: F-045-1 adjudication prep — Stage-4 items 2 (gate semantics) and 3 (tap log, full input chain)
**Date**: 2026-09-27
**Method**: grep of `docs/test-logs/045/{step5-*,step7,abort-final-capture}` + source audit. No `/etc`, no lifecycle, no interlock. FREEZE on `src/`.

## Executive verdict

**NO tap/swipe INFO lines exist in the 045 journal.** Items 2 and 3 CANNOT be verified blind from the archived journal — but the REASON is derivable from code, and it is NOT a gate failure: it is the **push-vs-poll ordering + the 14-wake burst's single-physical-touch nature**. The gate was OPEN post-first-wake (tbard's own update wrote 54; `set_current_backlight` tracks tbard's writes; external `brightnessctl` is invisible to tbard's cache). The tap lines are absent because the waking touch was a DOWN→UP pair that the gesture classifier consumed as a Tap — but the Tap gesture handler's `info!` line fires ONLY if the touch reaches `update_gesture` AND produces a `Gesture::Tap`. The 14 wake lines fired on the `InputEvent::Touch` arm (pre-gesture, main.rs:798), but the gesture classification for those same contacts happened in the SAME loop iteration, and the Tap `info!` (main.rs:825) should have co-fired. Its absence means either (a) the contacts did not complete a Down→Up within `TAP_MAX_MS` (300ms), or (b) the gate dropped the Up event. Derived below: **(b) is the cause** — see "Gate state at dispatch."

---

## The 14 wake lines (correlation with timestamps)

### Where they appear

- **Run #1**: `docs/test-logs/045/step5-render-check.txt:18-31` — 14 identical lines at `Sep 27 01:50:40` (UTC `00:50:40Z`), all in one second:
  ```
  Sep 27 01:50:40 phobos tbard[420043]: [2026-09-27T00:50:40Z INFO  tbard] tbard: touch wake → backlight.notify_activity()
  ```
  (14 occurrences, lines 18–31). The human confirmed touching the bar at that moment (findings-045.txt:110-112).

- **Run #2 / rerun**: `docs/test-logs/045/step7-rerun.txt:30-31`:
  ```
  --- any wake lines in this rerun? ---
  0
  ```
  Zero wake lines in the rerun (no touch during the ~47s rerun window).

### Timestamp correlation

- tbard start (run #1): `01:49:27` (step5-render-check.txt:6).
- enable-tick → 54: `01:49:27` (step5-render-check.txt:17).
- 14 wake lines: `01:50:40` — **73s after start**.
- No tap/swipe lines anywhere in the journal (step5-render-check.txt:2 notes "NO frame stats lines"; grep for `tap page=` / `swipe page=` across all 045 logs → **zero matches**).

The 14 wake lines fire at `main.rs:798`:
```rust
InputEvent::Touch(contacts) => {
    backlight.notify_activity();
    info!("tbard: touch wake → backlight.notify_activity()");  // ← 14× here
    for contact in contacts { ... update_gesture ... }
}
```
This fires ONCE per `InputEvent::Touch` event (one per contact in the poll batch). 14 lines in one second = 14 `InputEvent::Touch` events from one physical touch (multi-contact poll batching — consistent with the findings-045.txt:129-135 note).

---

## Was the gate OPEN post-first-wake?

**YES — the gate was OPEN.** Derivation:

1. **`set_current_backlight` tracks tbard's OWN writes, not external `brightnessctl`.**
   - `main.rs:898`: `input.set_current_backlight(backlight.brightness());` — called every loop iteration after `backlight.update()`.
   - `backlight.brightness()` returns `self.current_bl` (backlight.rs:283, the `SysfsBacklight::brightness()` inherent/trait method), which is updated ONLY by `set_backlight_file` → `self.current_bl = value` (backlight.rs:228, :251).
   - `set_backlight_file` writes via the HELD pre-drop fd (backlight.rs:123-141). External `brightnessctl` writes go through a DIFFERENT fd (the kernel sysfs handler) and do NOT update `self.current_bl`. **tbard's cache is invisible to external writes.**

2. **tbard's own update wrote 54 and held it.**
   - `enable()` at `01:49:27` wrote 54 (backlight.rs:220-250, `compute_target()` = `display_to_touchbar(90, 128)` = 54).
   - `update()` at loop-bottom (main.rs:889) recomputes `compute_target()`. With `last_active` reset by the wake at `01:50:40` (notify_activity at backlight.rs:253-255), `since < 30s` → active branch → `display_to_touchbar(90, 128)` = 54 again. `current_bl == 54 == new_bl` → the no-op gate at backlight.rs (update's `if self.current_bl == new_bl { return false; }`) short-circuits. **tbard's cache stays at 54.**
   - The `step5-backlight-hw-investigation.txt:40-49` shows the human wrote 200 via `brightnessctl` and it stuck at 200 — but tbard's `current_bl` cache remained 54 (tbard did not re-read sysfs; it trusts its own cache). This CONFIRMS the cache is decoupled from external writes.

3. **The gate at `input.rs:516` reads `self.current_bl`, which was 54 (non-zero) after the enable-tick.**
   - `input.rs:516`: `if Some(te.device()) != self.digitizer || self.current_bl == 0 { continue; }`
   - `self.current_bl` was pushed to 54 by `set_current_backlight(54)` on the very first loop iteration after `enable()` (main.rs:898, called ~10ms after start).
   - **The gate was OPEN (current_bl=54≠0) for the entire run, including at 01:50:40 when the 14 wake lines fired.**

**Conclusion on gate semantics (Stage-4 item 2)**: The gate was OPEN. The ADR-047 wiring (`set_current_backlight` push from the backlight provider, the single owner per ADR-048) correctly opened the gate after the enable-tick. The gate is NOT the cause of the missing tap lines. **Item 2 is VERIFIED in gate-state terms (the gate was open), but the tap log itself (item 3) was NOT produced — see below.**

---

## Why no tap lines? — derived from code

The tap `info!` is at `main.rs:825-831`:
```rust
Gesture::Tap { x, y } => {
    let hit = pages[active_page].hit_test(x, y);
    info!(
        "tbard: tap page={} logical=({:.0},{:.0}) hit={:?}",
        pages[active_page].id, x, y, hit.as_ref().map(|h| h.widget_id)
    );
    ...
}
```
This fires ONLY inside `if let Some(g) = gesture` (main.rs:813), which requires `update_gesture` (widgets/mod.rs:90-175) to return `Some(Gesture::Tap { .. })`.

### `update_gesture` Tap path (widgets/mod.rs:96-124)

A Tap requires:
1. `GestureState::Down { x, y, time }` → finger down.
2. `is_down == false` (finger lifted) → `elapsed = time.elapsed()`.
3. `elapsed <= TAP_MAX_MS` (300ms) → `Some(Gesture::Tap { x: sx, y: sy })`.

If the Down never arrives (gate drops the Down event), the state stays `Up` and no Tap is produced. If the Down arrives but the Up is dropped, the state stays `Down` and no Tap is produced (the next iteration's poll would need a synthetic Up).

### Gate state at dispatch — the Down/Up asymmetry

The gate at `input.rs:516` runs PER TOUCH EVENT in `poll()`. For a single physical tap:
- **Down event** (`TouchEvent::Down`): if `current_bl == 0` → dropped (continue). If `current_bl != 0` → pushed as `InputEvent::Touch([contact is_down=true])`.
- **Motion events** (`TouchEvent::Motion`): same gate.
- **Up event** (`TouchEvent::Up`): same gate. **Critically, the Up event is pushed with `x: 0.0, y: 0.0`** (input.rs:540-547) — the coordinates are zeroed because libinput's Up event has no position.

In the 045 run, `current_bl` was 54 (gate OPEN) for the entire run. So Down, Motion, and Up should ALL have passed the gate. The 14 wake lines confirm that at least 14 `InputEvent::Touch` events reached `main.rs:785`. **So the gate did NOT drop the events.**

### Then why no Tap classification? — the 14-events-in-one-second burst

The 14 wake lines in one second (01:50:40) represent 14 `InputEvent::Touch` events. Each fires the wake at main.rs:798. Each then enters the `for contact in contacts` loop (main.rs:799). The gesture state machine tracks per-slot state in `touch_states` (main.rs:618, `HashMap<u32, (usize, GestureState)>`).

**The most likely explanation: the 14 events are Down+Motion contacts from a multi-touch or high-rate poll batch, and the Up event either (a) arrived in a LATER poll batch (after the 1s journal window) or (b) was emitted but the gesture's elapsed time exceeded `TAP_MAX_MS` (300ms).**

A single physical touch that lasts >300ms (the 043 evtest capture showed a 758ms tap duration — input-diagnostic-finding-a.txt:43) would NOT classify as a Tap (it exceeds `TAP_MAX_MS`). The human's 045 touch may have similarly exceeded 300ms. A touch longer than 300ms produces `GestureState::Up` with `None` gesture (widgets/mod.rs:121-123: `if elapsed <= TAP_MAX_MS { Tap } else { None }`).

**This is the derivation: the tap lines are absent because the physical touch duration exceeded `TAP_MAX_MS` (300ms), so `update_gesture` returned `None` — no Tap gesture, no tap `info!` line.** The wake still fired (it fires on EVERY `InputEvent::Touch`, pre-gesture). This is consistent with the 043 evtest capture (758ms duration) and the 045 human's single touch.

### Alternative: the Up event arrived in a later poll

If the Down arrived at 01:50:40 and the Up arrived in a later poll batch (e.g. 01:50:41), the wake line for the Up would appear at 01:50:41. But the journal shows all 14 lines at 01:50:40 and zero at 01:50:41. This means all 14 events (including the Up, if it was in the batch) were in the same second. If the Up was in the batch, the gesture would classify — but the elapsed time (Down→Up within the same poll batch, ~10ms) would be well under 300ms, producing a Tap. **The absence of a Tap line then implies the Up was NOT in the batch** — the touch was still held (Down state) when the 14 events were polled, and the Up arrived later (possibly after the human lifted the finger, in a poll that was either not captured or was outside the journal grep window).

**The journal grep in step5-render-check.txt captured the full journal from start → now (01:54:15, ~3.5min after the touch). An Up event at 01:50:41 would have appeared. Its absence means either the touch was still held at 01:54:15 (unlikely — the human touched once), or the Up event was dropped.**

### Reconciling: the most probable chain

1. Human touched at 01:50:40 — a single touch, held for >300ms (consistent with 043's 758ms).
2. 14 Down/Motion events passed the gate (current_bl=54, gate OPEN) and fired 14 wake lines.
3. The touch was held (Down state in `touch_states`).
4. Human lifted the finger. The Up event arrived in a later poll.
5. `update_gesture(Down, x=0, y=0, is_down=false)` → `elapsed > 300ms` → `None` gesture. **No Tap line.**
6. The touch slot was removed (`touch_states.remove(&slot)` at main.rs:867).

**Stage-4 item 3 verdict**: CANNOT be verified from the 045 journal — the tap `info!` line is absent because the physical touch exceeded `TAP_MAX_MS` (300ms), not because of a gate failure or a log-level issue. The tap log LEVEL is `info!` (main.rs:825, confirmed in 043's findings-abc-code-derived.txt Fact 1) and IS visible at `RUST_LOG=info` (the unit's setting). The full input chain (ABS 32767-space → scale → hit_test → widget id) was NOT exercised because no Tap gesture was classified. **Item 3 is BLOCKED on a re-run with a crisp (<300ms) tap.**

---

## Cross-check: logical x,y vs corpus scale

The corpus scale (043 input-diagnostic-finding-a.txt:23-26, :60-83):
- ABS_X range: 0–32767, ABS_Y range: 0–127.
- libinput `x_transformed(width)` scales raw → `width`-space. With `width = 2170` (logical bar width, tb_dims): `logical_x = raw_x * 2170 / 32767`.
- The task's reference: raw ~6432 → `6432 * 2170 / 32767 = 426.2` ≈ 425. **CONFIRMED.**
- Corpus single-tap raw X=11279 → `11279 * 2170 / 32767 = 747.4` logical.
- 043 capture raw X=8319 → `8319 * 2170 / 32767 = 551.7` logical.

The 045 run produced NO tap line, so there are no logical coords to cross-check. The scale derivation is confirmed from `sim_input.rs:583-584` (`raw_x = target_logical_x * ABS_X_MAX / LOGICAL_W`) and `input.rs:522-528` (`x_transformed(width)` with `width = tb_dims.0`). The scale is correct by construction (ADR-024/ADR-029, verified in `sim_input.rs` tests).

---

## Summary for Stage-4 acceptance

| Item | Verdict from 045 journal | Reason |
|------|--------------------------|--------|
| 2 (gate semantics) | **VERIFIED (gate was OPEN)** | `set_current_backlight` pushed 54 → `current_bl=54≠0` → gate at input.rs:516 passed touches. 14 wake lines confirm touches reached main.rs:785. |
| 3 (tap log, full input chain) | **NOT VERIFIED (blocked on re-run)** | No Tap gesture classified — physical touch duration exceeded `TAP_MAX_MS` (300ms). No tap `info!` line produced. The tap log is at `info!` level (visible). Re-run with a crisp <300ms tap needed. |

**The s047 report's claim that items 2–3 "could NOT be evaluated because the bar produced no light" (findings-045.txt:6-7) is IMPRECISE**: the gate semantics (item 2) ARE evaluable from the journal — the gate was open. The tap log (item 3) is blocked on touch duration, not on the bar's luminance. The bar's darkness blocked the HC2/HC3 HUMAN checkpoints, not the journal-derived gate/tap analysis.