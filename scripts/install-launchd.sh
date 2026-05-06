#!/usr/bin/env bash
# Install the EAV server as a macOS launchd background service.
#
# Renders scripts/eav.server.plist.template into
# ~/Library/LaunchAgents/dev.eav.server.plist, then loads it via launchctl
# so the server starts at login and auto-restarts on crash.
#
# Usage: scripts/install-launchd.sh
#        scripts/install-launchd.sh --uninstall

set -euo pipefail

LABEL="dev.eav.server"
TARGET="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG="$HOME/Library/Logs/eav-server.log"

if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ -f "$TARGET" ]]; then
        launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
        rm -f "$TARGET"
        echo "Uninstalled ${LABEL}."
    else
        echo "Nothing to uninstall — ${TARGET} doesn't exist."
    fi
    exit 0
fi

# Resolve the project root (parent of this script's directory) so the plist
# can run regardless of where the user invokes the installer from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$SCRIPT_DIR/eav.server.plist.template"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "Template not found at $TEMPLATE" >&2
    exit 1
fi

NPX="$(command -v npx || true)"
if [[ -z "$NPX" ]]; then
    echo "npx not found on PATH. Install Node.js first." >&2
    exit 1
fi

# launchd processes start with a minimal PATH, so include the directory of
# npx (typically /opt/homebrew/bin or /usr/local/bin) plus the standard dirs.
NPX_DIR="$(dirname "$NPX")"
PATH_ENV="${NPX_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

mkdir -p "$(dirname "$TARGET")"
mkdir -p "$(dirname "$LOG")"

# Render the template. Using sed so we don't depend on envsubst.
sed -e "s|__NPX__|${NPX}|g" \
    -e "s|__PROJECT_DIR__|${PROJECT_DIR}|g" \
    -e "s|__PATH__|${PATH_ENV}|g" \
    -e "s|__LOG__|${LOG}|g" \
    "$TEMPLATE" > "$TARGET"

# Reload: bootout the old service (no-op if it wasn't loaded), then bootstrap.
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$TARGET"

echo "Installed ${LABEL}."
echo "  plist: $TARGET"
echo "  log:   $LOG"
echo "  url:   http://localhost:3001"
echo
echo "Status:    launchctl print gui/\$(id -u)/${LABEL}"
echo "Restart:   launchctl kickstart -k gui/\$(id -u)/${LABEL}"
echo "Stop:     scripts/install-launchd.sh --uninstall"
