#!/usr/bin/env bash
# build-eavd-universal.sh — cross-compile eavd for both Apple architectures
# and lipo them into a single universal binary at ./build/eavd.
#
# Run from the repo root.
#
# Optionally signs the result if DEV_ID is set:
#   DEV_ID="Developer ID Application: Your Name (TEAMID)" \
#     ./scripts/build-eavd-universal.sh
#
# Without DEV_ID we ad-hoc sign so the binary still launches under SIP / hardened
# runtime in development; replace this with your actual Developer ID for
# distribution.
#
# This script is invoked by the Xcode Run-Script build phase before the
# `.app` bundle is assembled, so changing it forces a re-link of the helper.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON_DIR="$REPO_ROOT/daemon"
OUT_DIR="$REPO_ROOT/build"
mkdir -p "$OUT_DIR"

X86_TARGET=x86_64-apple-darwin
ARM_TARGET=aarch64-apple-darwin

if ! command -v rustup >/dev/null 2>&1; then
    echo "rustup not found — install via https://rustup.rs and re-run." >&2
    exit 1
fi

# Make sure both targets are installed; rustup target add is idempotent.
rustup target add "$X86_TARGET" >/dev/null
rustup target add "$ARM_TARGET" >/dev/null

echo "Building eavd for $X86_TARGET..."
cargo build --manifest-path "$DAEMON_DIR/Cargo.toml" \
    --release --target "$X86_TARGET" -p eavd

echo "Building eavd for $ARM_TARGET..."
cargo build --manifest-path "$DAEMON_DIR/Cargo.toml" \
    --release --target "$ARM_TARGET" -p eavd

X86_BIN="$DAEMON_DIR/target/$X86_TARGET/release/eavd"
ARM_BIN="$DAEMON_DIR/target/$ARM_TARGET/release/eavd"
UNIVERSAL_BIN="$OUT_DIR/eavd"

echo "Lipo-fusing into $UNIVERSAL_BIN..."
lipo -create -output "$UNIVERSAL_BIN" "$X86_BIN" "$ARM_BIN"

if [[ -n "${DEV_ID:-}" ]]; then
    echo "Signing with Developer ID: $DEV_ID"
    codesign --force --options runtime --timestamp --sign "$DEV_ID" "$UNIVERSAL_BIN"
else
    echo "Ad-hoc signing (set DEV_ID for Developer ID signing)"
    codesign --force --sign - "$UNIVERSAL_BIN"
fi

echo "Verifying signature..."
codesign --verify --verbose=2 "$UNIVERSAL_BIN" || true
file "$UNIVERSAL_BIN"
ls -lh "$UNIVERSAL_BIN"
echo
echo "Done. The Xcode Run-Script build phase should copy this and the elisp"
echo "files into the .app bundle's Contents/Resources/."
