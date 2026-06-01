# Emacs Agenda Viewer

The goal of this project is to build a things 3 like front end for emacs agenda using emacs-client backend.

## Deploy

- Use `./deploy.sh` from the project root to build, deploy, and relaunch
- It builds the macOS app, kills existing instances, copies to ~/Applications, reloads eav.el in Emacs, restarts the server via launchd, and launches the app

## Servers

Two backends are wired up; pick one with the URL setting in the Mac app or
the proxy config in `vite.config.ts` for the web client.

### eavd (Rust daemon, port 3002) — preferred

- Source in `daemon/` (Cargo workspace). Binary built with
  `scripts/build-eavd-universal.sh` and bundled in `Agenda.app/Contents/Resources/`.
- Holds an in-memory index of all agenda tasks; reads complete in <2 ms.
- Watches files via `notify`, persists a SQLite snapshot at
  `$XDG_CACHE_HOME/eavd/snapshot.sqlite` for cold-start, and proxies writes
  + sexp/diary reads to Emacs via a UNIX socket.
- Pushes live updates over `GET /api/events` (SSE) so clients refresh
  without polling.
- Exit criterion against the Express baseline: zero diffs on `/api/tasks`,
  zero diffs on `/api/agenda/day/<date>` for the captured 30-day corpus.

### Express (Node, port 3001) — legacy / shadow

- The original `server/index.ts` runs via `npx tsx server/index.ts`,
  managed by the launchd plist at
  `~/Library/LaunchAgents/com.hermitsage.emacs-agenda-viewer.plist`.
- Restart: `launchctl kickstart -k gui/$(id -u)/com.hermitsage.emacs-agenda-viewer`.
- Logs at `~/Library/Logs/emacs-agenda-viewer.log`.
- Stays running for shadow-mode comparison until eavd has been dogfooded
  for one clean week. Phase 7 of `RUST_DAEMON_PLAN.org` removes this and
  the launchd plist for the Mac path; headless deployments keep their own
  copy via `scripts/install-daemon.sh`.

## MCP server

- `eavd` embeds an MCP (Model Context Protocol) server so AI agents can read
  and modify the org todo list. It runs on its own listener (default
  `127.0.0.1:3003`, path `/mcp`) using the Streamable-HTTP transport.
- Implemented in `daemon/crates/eav-mcp` with the `rmcp` SDK. Tool handlers
  reuse the live `AppState` (in-memory `Index`, `BridgeClient`, `Store`)
  directly — no HTTP round-trip. It runs a separate axum listener because
  `rmcp` tracks a newer axum than `eav-server` (axum 0.7); the versions
  coexist as deps but their routers can't be merged.
- Tools: read — `list_tasks`, `search_tasks`, `get_task`, `get_agenda`,
  `get_agenda_range`, `list_capture_templates`; write — `create_task`,
  `set_task_state`, `set_task_scheduled`, `set_task_deadline`,
  `set_task_priority`, `set_task_tags`, `set_task_notes`. Writes resolve the
  task `id` → `(file, pos)` via the index, call the bridge, then reindex —
  same path as the HTTP handlers in `eav-server/src/routes.rs`.
- Connect a client, e.g.:
  `claude mcp add --transport http eav http://127.0.0.1:3003/mcp`
- Flags: `--mcp-port` (default 3003), `--mcp-host` (default `127.0.0.1`),
  `--no-mcp` to disable. Writes are unauthenticated (same trust model as the
  HTTP API); remote access (e.g. over Tailscale) is opt-in via
  `--mcp-host 0.0.0.0`.

## Bridge

- `elisp/eav-bridge.el` is the in-Emacs UNIX-socket dispatcher used by eavd.
  Auto-loaded on first connect; can also be loaded manually with
  `(load "~/Github/Emacs-Agenda-Viewer/elisp/eav-bridge.el")` followed by
  `(eav-bridge-start)`.
- Default socket path: `$XDG_RUNTIME_DIR/eav-bridge-$UID.sock`. Override with
  the `eav-bridge-socket-path` defcustom or by setting `EAV_BRIDGE_SOCK` for
  eavd.
- The bridge dispatches to existing functions in `elisp/eav.el` — no org
  semantics live in `eav-bridge.el`. Treat `eav.el` as load-bearing and only
  add new methods to the bridge by registering new entries in
  `eav-bridge--methods`.

## Daemon CLI

`./daemon/target/debug/eavd` (or the release build) supports:

- `eavd` — run the HTTP/SSE server on port 3002 (and the MCP server on 3003)
- `eavd --mcp-port N` / `--mcp-host HOST` / `--no-mcp` — configure or disable
  the embedded MCP server (see "MCP server" above)
- `eavd --dump-tasks` / `--dump-active-tasks` — print parsed tasks JSON
- `eavd --dump-agenda-day YYYY-MM-DD` — print agenda entries for a date
- `eavd --files-from <path>` — read agenda files from `/api/files` JSON
- `eavd --keywords-from <path>` — inject `/api/keywords` as keyword fallback

Useful for offline parity comparison against Express.
