#!/usr/bin/env bash
# install-daemon.sh — install eavd as a long-lived service on a *headless*
# host (no Mac app to babysit it).
#
# Two scenarios:
#   1. macOS server (e.g. visa-nonsoe): generate and load a launchd plist.
#   2. Linux server: generate and enable a systemd user unit.
#
# The Mac app uses the helper-process pattern (DaemonHost.swift) and does
# NOT need this script. Don't run it on a workstation that already has the
# .app installed; you'll end up with two daemons fighting over the bridge
# socket.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: install-daemon.sh [--uninstall] [options]

  --uninstall         Stop and remove the service.
  --port PORT         TCP port for the HTTP server (default: 3002).
  --host HOST         Bind address (default: 127.0.0.1; use 0.0.0.0 for LAN).
  --static-dir DIR    Serve a built SPA from DIR (replaces Express's
                      static-file role on a headless deploy).
  --bridge-sock PATH  Override the bridge socket path.

Without --uninstall the script:
  1. Builds the daemon (release mode) if it doesn't already exist.
  2. Installs a launchd plist (macOS) or systemd unit (Linux).
  3. Starts the service.
EOF
}

UNINSTALL=0
PORT=3002
HOST="127.0.0.1"
STATIC_DIR=""
BRIDGE_SOCK=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall) UNINSTALL=1; shift ;;
        --port) PORT="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        --static-dir) STATIC_DIR="$2"; shift 2 ;;
        --bridge-sock) BRIDGE_SOCK="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

OS="$(uname -s)"
case "$OS" in
    Darwin)
        PLIST_DIR="$HOME/Library/LaunchAgents"
        PLIST="$PLIST_DIR/com.hermitsage.eavd.plist"
        SERVICE="gui/$(id -u)/com.hermitsage.eavd"

        if [[ "$UNINSTALL" -eq 1 ]]; then
            echo "Stopping launchd service..."
            launchctl bootout "$SERVICE" 2>/dev/null || true
            rm -f "$PLIST"
            echo "Removed $PLIST"
            exit 0
        fi

        EAVD_BIN="$REPO_ROOT/daemon/target/release/eavd"
        if [[ ! -x "$EAVD_BIN" ]]; then
            echo "Building eavd (release)..."
            cargo build --manifest-path "$REPO_ROOT/daemon/Cargo.toml" --release -p eavd
        fi

        # Build the ProgramArguments array. We assemble it as XML strings so
        # the heredoc stays straightforward.
        EXTRA_ARGS=""
        if [[ "$HOST" != "127.0.0.1" ]]; then
            EXTRA_ARGS="$EXTRA_ARGS    <string>--http-host</string>
    <string>$HOST</string>
"
        fi
        if [[ -n "$STATIC_DIR" ]]; then
            EXTRA_ARGS="$EXTRA_ARGS    <string>--static-dir</string>
    <string>$STATIC_DIR</string>
"
        fi

        mkdir -p "$PLIST_DIR"
        cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.hermitsage.eavd</string>
  <key>ProgramArguments</key>
  <array>
    <string>$EAVD_BIN</string>
    <string>--http-port</string>
    <string>$PORT</string>
    <string>--daemon</string>
${EXTRA_ARGS}  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <!-- launchd starts services with a minimal PATH; eavd shells out to
         emacsclient on first connect and needs Homebrew on the search
         list. Adjust if the user's emacs lives elsewhere. -->
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
$( [[ -n "$BRIDGE_SOCK" ]] && cat <<INNEREOF
    <key>EAV_BRIDGE_SOCK</key>
    <string>$BRIDGE_SOCK</string>
INNEREOF
)
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/eavd.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/eavd.log</string>
</dict>
</plist>
PLISTEOF
        echo "Installed plist at $PLIST"
        launchctl bootout "$SERVICE" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$PLIST"
        launchctl kickstart -k "$SERVICE"
        echo "Started service $SERVICE on port $PORT"
        ;;

    Linux)
        UNIT_DIR="$HOME/.config/systemd/user"
        UNIT="$UNIT_DIR/eavd.service"

        if [[ "$UNINSTALL" -eq 1 ]]; then
            systemctl --user stop eavd 2>/dev/null || true
            systemctl --user disable eavd 2>/dev/null || true
            rm -f "$UNIT"
            systemctl --user daemon-reload
            echo "Removed $UNIT"
            exit 0
        fi

        EAVD_BIN="$REPO_ROOT/daemon/target/release/eavd"
        if [[ ! -x "$EAVD_BIN" ]]; then
            echo "Building eavd (release)..."
            cargo build --manifest-path "$REPO_ROOT/daemon/Cargo.toml" --release -p eavd
        fi

        EXEC_ARGS="--http-port $PORT --daemon"
        if [[ "$HOST" != "127.0.0.1" ]]; then
            EXEC_ARGS="$EXEC_ARGS --http-host $HOST"
        fi
        if [[ -n "$STATIC_DIR" ]]; then
            EXEC_ARGS="$EXEC_ARGS --static-dir $STATIC_DIR"
        fi

        mkdir -p "$UNIT_DIR"
        cat > "$UNIT" <<UNITEOF
[Unit]
Description=Emacs Agenda Viewer daemon
After=default.target

[Service]
Type=simple
ExecStart=$EAVD_BIN $EXEC_ARGS
Restart=on-failure
$( [[ -n "$BRIDGE_SOCK" ]] && echo "Environment=EAV_BRIDGE_SOCK=$BRIDGE_SOCK" )

[Install]
WantedBy=default.target
UNITEOF
        systemctl --user daemon-reload
        systemctl --user enable --now eavd.service
        echo "Started systemd user service eavd on port $PORT"
        ;;

    *)
        echo "Unsupported OS: $OS" >&2
        exit 1
        ;;
esac
