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

# Build eavd on the remote host. Cargo's incremental build no-ops when
# nothing changed; only the first deploy after a daemon-source change
# does real work. We avoid cross-compiling from the Mac because
# visa-nonsoe and the local Mac can be different arches over time
# (visa is arm64 today, but the laptop has been both), and keeping the
# build local to the host removes that whole class of problem.
#
# The `--release` build is what the launchd plist references. We
# ad-hoc codesign afterwards so a freshly-built binary survives any
# macOS firewall / quarantine gates (this also matches what the
# postBuildScript does on the Mac path).
echo "==> Building eavd on ${REMOTE}…"
ssh "$REMOTE" "
  set -e
  export PATH=\"\$HOME/.cargo/bin:\$PATH\"
  if ! command -v cargo >/dev/null 2>&1; then
    echo '  (cargo not on PATH — skipping daemon build)' >&2
    exit 0
  fi
  cd $REMOTE_DIR/daemon
  cargo build --release -p eavd 2>&1 | tail -3
  codesign --force --sign - target/release/eavd
" || echo "  (eavd build failed — remote daemon may be stale)"

echo "==> Reloading eav.el on ${REMOTE}…"
ssh "$REMOTE" "emacsclient --eval '(load-file \"$REMOTE_EAV_EL\")'" >/dev/null 2>&1 \
  || echo "  (remote emacs not reachable — skipped)"

# Restart the eavd service. Two paths:
#   1. launchd-managed (`com.hermitsage.eavd`) — kickstart it so the new
#      binary picks up. This is what `install-daemon.sh` sets up and
#      what we recommend for headless hosts.
#   2. Not under launchd (manually-nohup'd from an earlier session) —
#      pkill it and respawn with the same args the plist would use,
#      reading the plist for the canonical args via plutil.
# The legacy Express-server kickstart stays as a no-op fallback for
# hosts that still run the Node baseline.
echo "==> Restarting eavd on ${REMOTE}…"
ssh "$REMOTE" "
  UID_=\$(id -u)
  if launchctl print gui/\$UID_/com.hermitsage.eavd >/dev/null 2>&1; then
    launchctl kickstart -k gui/\$UID_/com.hermitsage.eavd
    echo '  (launchd kickstart)'
  else
    pkill -f 'eavd --http-port' 2>/dev/null || true
    sleep 1
    cd $REMOTE_DIR/daemon
    nohup ./target/release/eavd --http-port 3001 --http-host 0.0.0.0 \
        --static-dir $REMOTE_DIR/dist --daemon \
        >>\$HOME/Library/Logs/eavd.log 2>&1 &
    disown
    echo '  (manual respawn — consider running install-daemon.sh for launchd persistence)'
  fi
" || echo "  (eavd restart failed)"

# Belt-and-suspenders for the legacy Express service. No-op on hosts
# that don't have it, which is now everywhere we deploy.
ssh "$REMOTE" "launchctl kickstart -k gui/\$(id -u)/com.hermitsage.emacs-agenda-viewer" 2>/dev/null \
  || true

echo -n "==> Waiting for remote server"
for i in $(seq 1 30); do
  # eavd's /api/debug is the right health probe; /api/config exists too
  # on both Express and eavd so we keep it as a fallback for hosts that
  # still run the legacy baseline.
  if ssh "$REMOTE" "curl -sf http://localhost:3001/api/debug || curl -sf http://localhost:3001/api/config" >/dev/null 2>&1; then
    echo " ready."
    break
  fi
  echo -n "."
  sleep 1
done

echo "==> Done."
