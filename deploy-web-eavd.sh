#!/usr/bin/env bash
# deploy-web-eavd.sh — replace `deploy-web.sh` once eavd takes over from the
# Express stack on the headless macOS host.
#
# What this does on the remote:
#   1. rsync the repo, excluding build artefacts.
#   2. Build a release `eavd` natively on the remote (avoids cross-compile
#      complexity; visa-nonsoe has the toolchain after one-time `rustup-init`).
#   3. `npm install && npm run build` so `dist/` is up to date.
#   4. Stop and remove the old `com.hermitsage.emacs-agenda-viewer` (Express)
#      launchd plist if it's still installed.
#   5. Run `scripts/install-daemon.sh` with --static-dir and --host 0.0.0.0
#      so the daemon serves both `/api/*` and the SPA on $REMOTE_PORT.
#   6. Smoke-test: GET $REMOTE_URL/api/config and GET $REMOTE_URL/.
#
# Prerequisites on the remote (one-time):
#   - Rust stable: `curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh`
#   - Emacs server running with eav.el agenda configured (already true on
#     visa-nonsoe — Express used the same Emacs).
#
# After this works for one cycle, retire the old `deploy-web.sh`.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE="${REMOTE:-visa-nonsoe}"
REMOTE_DIR="${REMOTE_DIR:-/Users/adithyabhat/Github/Emacs-Agenda-Viewer}"
REMOTE_PORT="${REMOTE_PORT:-3001}"
REMOTE_URL="${REMOTE_URL:-http://${REMOTE}:${REMOTE_PORT}}"
REMOTE_HOST_BIND="${REMOTE_HOST_BIND:-0.0.0.0}"

echo "==> Checking ${REMOTE} reachability…"
if ! ssh -o ConnectTimeout=5 "$REMOTE" true 2>/dev/null; then
  echo "  ${REMOTE} unreachable. Aborting." >&2
  exit 1
fi

echo "==> Verifying remote toolchain…"
if ! ssh "$REMOTE" 'command -v cargo >/dev/null'; then
  cat >&2 <<'EOF'
  cargo not found on the remote. One-time setup:
    ssh visa-nonsoe
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source $HOME/.cargo/env
  Then re-run this script.
EOF
  exit 1
fi
if ! ssh "$REMOTE" 'command -v emacsclient >/dev/null'; then
  echo "  emacsclient missing on remote. Install Emacs and start the server." >&2
  exit 1
fi

echo "==> Syncing repo to ${REMOTE}:${REMOTE_DIR}…"
rsync -az --delete \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude 'dist' \
  --exclude 'build' \
  --exclude 'apps/macos/build' \
  --exclude 'apps/macos/.build' \
  --exclude '.build' \
  --exclude 'daemon/target' \
  --exclude 'test-results' \
  "$PROJECT_DIR/" "$REMOTE:$REMOTE_DIR/"

echo "==> Building eavd on ${REMOTE}…"
ssh "$REMOTE" "cd $REMOTE_DIR && cargo build --manifest-path daemon/Cargo.toml --release -p eavd"

echo "==> Building SPA on ${REMOTE}…"
ssh "$REMOTE" "cd $REMOTE_DIR && npm install --silent && npm run build --silent"

echo "==> Stopping legacy Express service if present…"
ssh "$REMOTE" '
  set -e
  PLIST="$HOME/Library/LaunchAgents/com.hermitsage.emacs-agenda-viewer.plist"
  if [ -f "$PLIST" ]; then
    launchctl bootout "gui/$(id -u)/com.hermitsage.emacs-agenda-viewer" 2>/dev/null || true
    rm -f "$PLIST"
    echo "  removed $PLIST"
  else
    echo "  legacy plist already gone"
  fi
'

echo "==> Reloading eav.el on ${REMOTE} (in case daemon is already running)…"
ssh "$REMOTE" "emacsclient --eval '(load-file \"$REMOTE_DIR/elisp/eav.el\")'" >/dev/null 2>&1 \
  || echo "  (remote emacs not reachable — eavd will load it on first connect)"

echo "==> Installing eavd launchd service on ${REMOTE}…"
ssh "$REMOTE" "cd $REMOTE_DIR && \
  ./scripts/install-daemon.sh \
    --port ${REMOTE_PORT} \
    --host ${REMOTE_HOST_BIND} \
    --static-dir $REMOTE_DIR/dist"

echo -n "==> Waiting for ${REMOTE_URL}/api/config "
ready=0
for i in $(seq 1 30); do
  if ssh "$REMOTE" "curl -sf http://localhost:${REMOTE_PORT}/api/config" >/dev/null 2>&1; then
    ready=1; echo "ready."; break
  fi
  echo -n "."
  sleep 1
done
if [[ $ready -ne 1 ]]; then
  echo
  echo "  Daemon did not respond on localhost:${REMOTE_PORT} after 30s." >&2
  echo "  Check ${REMOTE}:~/Library/Logs/eavd.log" >&2
  exit 1
fi

echo "==> Verifying SPA at ${REMOTE_URL}/ from this host…"
status=$(curl -s -o /tmp/eav-deploy-web.html -w '%{http_code}' --max-time 10 "${REMOTE_URL}/" || echo 000)
if [[ "$status" != "200" ]]; then
  echo "  GET ${REMOTE_URL}/ returned HTTP ${status}. Aborting." >&2
  exit 1
fi
if ! grep -qi '<div id="root"' /tmp/eav-deploy-web.html; then
  echo "  Response from ${REMOTE_URL}/ does not look like the EAV app." >&2
  echo "  See /tmp/eav-deploy-web.html for the body." >&2
  exit 1
fi

echo "==> Verifying API at ${REMOTE_URL}/api/files…"
files_count=$(curl -s --max-time 10 "${REMOTE_URL}/api/files" | jq 'length' 2>/dev/null || echo 0)
echo "  ${files_count} agenda files visible."

echo "==> OK — eavd is serving ${REMOTE_URL}/ (SPA) and /api/* (daemon)."
