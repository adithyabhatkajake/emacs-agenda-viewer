#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Agenda"
SCHEME="EmacsAgendaViewerMac"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/apps/macos"
DEST="$HOME/Applications/${APP_NAME}.app"
EAV_EL="$PROJECT_DIR/elisp/eav.el"

echo "==> Running elisp tests…"
emacs -batch -l ert -l "$PROJECT_DIR/elisp/eav-tests.el" -f ert-run-tests-batch-and-exit

echo "==> Running web unit tests…"
cd "$PROJECT_DIR"
npx vitest run --reporter=dot

echo "==> Running Swift tests…"
cd "$BUILD_DIR"
swift test 2>&1 | grep -E '(error:|Test run)'

echo "==> Building ${APP_NAME}…"
xcodebuild -scheme "$SCHEME" -configuration Release -destination 'platform=macOS' build -quiet

BUILT=$(xcodebuild -scheme "$SCHEME" -configuration Release -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $3}')
BUILT_APP="${BUILT}/${APP_NAME}.app"

if [[ ! -d "$BUILT_APP" ]]; then
  echo "ERROR: Built app not found at $BUILT_APP"
  exit 1
fi

echo "==> Killing existing ${APP_NAME}…"
pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true

echo "==> Deploying to ~/Applications…"
rm -rf "$DEST"
cp -R "$BUILT_APP" "$DEST"

echo "==> Reloading eav.el in Emacs…"
emacsclient --eval "(load-file \"${EAV_EL}\")" >/dev/null 2>&1 || echo "  (emacs not reachable — skipped)"

echo "==> Restarting EAV server…"
launchctl kickstart -k "gui/$(id -u)/com.hermitsage.emacs-agenda-viewer" 2>/dev/null || echo "  (launchd service not found — skipped)"

echo -n "==> Waiting for server"
for i in $(seq 1 30); do
  if curl -sf http://localhost:3001/api/config >/dev/null 2>&1; then
    echo " ready."
    break
  fi
  echo -n "."
  sleep 1
done

echo "==> Launching ${APP_NAME}…"
open "$DEST"

# ── Remote deploy (visa-nonsoe) ──────────────────────────────────────────
REMOTE="visa-nonsoe"
REMOTE_DIR="/Users/adithyabhat/Github/Emacs-Agenda-Viewer"
REMOTE_EAV_EL="$REMOTE_DIR/elisp/eav.el"

echo "==> Syncing to ${REMOTE}…"
if ! ssh -o ConnectTimeout=5 "$REMOTE" true 2>/dev/null; then
  echo "  ($REMOTE unreachable — skipping remote deploy)"
  echo "==> Done."
  exit 0
fi

rsync -az --delete \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude 'dist' \
  --exclude 'build' \
  --exclude 'apps/macos/build' \
  --exclude 'apps/macos/.build' \
  --exclude '.build' \
  "$PROJECT_DIR/" "$REMOTE:$REMOTE_DIR/"

echo "==> Installing dependencies on ${REMOTE}…"
ssh "$REMOTE" "cd $REMOTE_DIR && npm install --silent"

echo "==> Building web frontend on ${REMOTE}…"
ssh "$REMOTE" "cd $REMOTE_DIR && npm run build --silent"

echo "==> Reloading eav.el on ${REMOTE}…"
ssh "$REMOTE" "emacsclient --eval '(load-file \"$REMOTE_EAV_EL\")'" >/dev/null 2>&1 \
  || echo "  (remote emacs not reachable — skipped)"

echo "==> Restarting EAV server on ${REMOTE}…"
ssh "$REMOTE" "launchctl kickstart -k gui/\$(id -u)/com.hermitsage.emacs-agenda-viewer" 2>/dev/null \
  || echo "  (remote launchd service not found — skipped)"

echo -n "==> Waiting for remote server"
for i in $(seq 1 30); do
  if ssh "$REMOTE" "curl -sf http://localhost:3001/api/config" >/dev/null 2>&1; then
    echo " ready."
    break
  fi
  echo -n "."
  sleep 1
done

echo "==> Done."
