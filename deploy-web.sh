#!/usr/bin/env bash
# Sync this repo to visa-nonsoe, reload eav.el on its Emacs, restart the
# EAV server, and verify the page is reachable at http://visa-nonsoe:3001/.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE="${REMOTE:-visa-nonsoe}"
REMOTE_DIR="${REMOTE_DIR:-/Users/adithyabhat/Github/Emacs-Agenda-Viewer}"
REMOTE_URL="${REMOTE_URL:-http://${REMOTE}:3001}"

echo "==> Checking ${REMOTE} reachability…"
if ! ssh -o ConnectTimeout=5 "$REMOTE" true 2>/dev/null; then
  echo "  ${REMOTE} unreachable. Aborting." >&2
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
  --exclude 'test-results' \
  "$PROJECT_DIR/" "$REMOTE:$REMOTE_DIR/"

echo "==> Installing dependencies on ${REMOTE}…"
ssh "$REMOTE" "cd $REMOTE_DIR && npm install --silent"

echo "==> Building web frontend on ${REMOTE}…"
ssh "$REMOTE" "cd $REMOTE_DIR && npm run build --silent"

echo "==> Reloading eav.el on ${REMOTE}…"
ssh "$REMOTE" "emacsclient --eval '(load-file \"$REMOTE_DIR/elisp/eav.el\")'" >/dev/null 2>&1 \
  || echo "  (remote emacs not reachable — skipped)"

echo "==> Restarting EAV server on ${REMOTE}…"
ssh "$REMOTE" "launchctl kickstart -k gui/\$(id -u)/com.hermitsage.emacs-agenda-viewer" 2>/dev/null \
  || { echo "  launchd service not found on ${REMOTE}. Aborting." >&2; exit 1; }

echo -n "==> Waiting for remote server"
ready=0
for i in $(seq 1 30); do
  if ssh "$REMOTE" "curl -sf http://localhost:3001/api/config" >/dev/null 2>&1; then
    ready=1
    echo " ready."
    break
  fi
  echo -n "."
  sleep 1
done
if [[ $ready -ne 1 ]]; then
  echo
  echo "  Server did not respond on localhost:3001 after 30s." >&2
  echo "  Check ${REMOTE}:~/Library/Logs/emacs-agenda-viewer.log" >&2
  exit 1
fi

echo "==> Verifying ${REMOTE_URL}/ from this host…"
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

echo "==> OK — ${REMOTE_URL}/ is serving the app."
