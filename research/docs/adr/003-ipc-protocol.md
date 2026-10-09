# ADR 003: IPC Protocol v1 — Unix Socket + JSON

## Status: Accepted

## Date: 2026-09-24

## Context

External clients (volume control, media players, IDEs) must be able to push
UI to the Touch Bar without recompiling the daemon. The architecture decision
requires a single-writer daemon: clients never draw directly; they send UI
definitions over IPC.

## Decision

### Transport

- **Primary**: Unix domain socket at `$XDG_RUNTIME_DIR/touchbar/engine.sock`,
  mode `0600`. The daemon listens for line-delimited JSON.
- **Future** (Phase 3): WebSocket on `localhost:9170` for browser-based mirrors.
  Same JSON protocol.

### Protocol

All messages are JSON objects with a `"type"` field for dispatch.

**Incoming (client → engine):**

| Type | Purpose |
|------|---------|
| `set_pages` | Replace the current page layout |
| `update_widget` | Update a widget value (slider, dial) |
| `switch_page` | Switch active page by ID |
| `get_state` | Request current state snapshot |
| `shutdown` | Graceful daemon shutdown |

**Outgoing (engine → client):**

| Type | Purpose |
|------|---------|
| `ok` | Command acknowledged |
| `state` | Full state snapshot (pages + active page) |
| `widget_event` | Widget was tapped/swiped |
| `error` | Error message |

### Example: Set volume page

```json
{"type": "set_pages", "pages": [
  {"id": "volume", "widgets": [
    {"type": "button", "label": "🔇", "action": ["Mute"]},
    {"type": "slider", "label": "Volume", "value": 0.75}
  ]}
]}
```

### Example: Update slider value

```json
{"type": "update_widget", "page_id": "volume", "widget_index": 1, "update": {"type": "slider_value", "value": 0.5}}
```

### Example: Widget event broadcast

```json
{"type": "widget_event", "page_id": "volume", "widget_index": 0, "event": {"type": "tap", "x": 100.0, "y": 30.0}}
```

### Security

- Socket mode `0600` — only the owner can connect (same user, no root needed).
- WebSocket binds `localhost` by default (not `0.0.0.0`).
- Untrusted config values (icon paths, exec commands) are sanitized in
  Phase 2 (YAML schema validation).

## Consequences

- **Positive**: JSON over Unix socket is debuggable with `socat`, `nc`, or
  any language with a JSON library. No protobuf compilation step needed.
- **Positive**: The same protocol will serve WebSocket clients unchanged.
- **Negative**: JSON framing requires newline-delimited or length-prefixed
  messages. Phase 1 uses newline-delimited (simple, testable).
- **Future**: Binary protocol (e.g. CBOR or MessagePack) could reduce
  overhead for high-frequency slider updates, but JSON is sufficient for
  the ~10Hz update rate of the Touch Bar.

## References

- `src/ipc/protocol.rs` — Rust types for IPC messages with serde roundtrip tests
- `src/ipc/server.rs` — Unix socket server (Phase 1, single-thread)
- `proto/protocol.md` — Human-readable protocol specification