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

- `eavd` — run the HTTP/SSE server on port 3002
- `eavd --dump-tasks` / `--dump-active-tasks` — print parsed tasks JSON
- `eavd --dump-agenda-day YYYY-MM-DD` — print agenda entries for a date
- `eavd --files-from <path>` — read agenda files from `/api/files` JSON
- `eavd --keywords-from <path>` — inject `/api/keywords` as keyword fallback

Useful for offline parity comparison against Express.
