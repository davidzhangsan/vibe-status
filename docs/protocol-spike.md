# Codex 0.145.0 protocol spike

Validated on 2026-07-27 against two representative SSH-configured remote
hosts. Host-specific names and paths are intentionally omitted.

## Confirmed

- Both hosts resolved a Codex 0.145.0 executable through their user
  environments.
- One existing daemon returned `alreadyRunning`.
- One stale/refused control socket was recovered with the supported
  `app-server daemon start` command.
- Both daemons and CLIs report version 0.145.0.
- `app-server proxy` performs a standard HTTP 101 WebSocket upgrade over
  stdin/stdout.
- Minimal `initialize` and `initialized` negotiation succeeds.
- `thread/loaded/list` requires an explicit object in `params`.
- Version 0.145.0 returns loaded task IDs as `[String]`; metadata is obtained
  with `thread/read`.
- `thread/read` with `includeTurns: false` exposes the fields needed for root
  filtering and status rendering.
- One live sample contained one root task and three spawned tasks, confirming
  the defensive `parentThreadId`/`sessionId` filter.
- `thread/unsubscribe` succeeds per connection.
- Neither the Python nor Swift transport probe answered a server-originated
  request.
- SSH and Codex warnings stay on stderr and do not corrupt the proxy stream.

## Passive-observer behavior

The client immediately unsubscribes every identifier before rendering it and
also unsubscribes each `thread/started` notification. A 20-second passive
observation produced no approval/input request and no status transition. The
15-second metadata reconciliation remains authoritative even when no status
notification is emitted during an observation window.

Phone Remote Control continuity cannot be automated from this repository. The
daemon was not restarted or reconfigured by the probe; testers should confirm
phone visibility as part of manual acceptance when changing Codex versions.
