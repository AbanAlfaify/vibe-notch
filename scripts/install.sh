#!/bin/bash
# Build Vibe Notch (Release), install it to /Applications and launch it.
# Signs for team L2Z9AQ34Q3 with automatic signing. No DMG, no notarizing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DERIVED_DATA="$PROJECT_DIR/build/DerivedData"

TEAM_ID="L2Z9AQ34Q3"
APP_NAME="Vibe Notch"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"

echo "=== Building $APP_NAME (Release) ==="
cd "$PROJECT_DIR"
if ! xcodebuild build \
    -project ClaudeIsland.xcodeproj \
    -scheme ClaudeIsland \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    -quiet \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic; then
    echo "ERROR: build failed. If the errors above are about signing, open the" >&2
    echo "project in Xcode and check that an account for team $TEAM_ID is signed in." >&2
    exit 1
fi

if [ ! -d "$BUILT_APP" ]; then
    echo "ERROR: built app not found at $BUILT_APP" >&2
    exit 1
fi

echo "=== Checking signature ==="
codesign --verify --deep --strict "$BUILT_APP"
SIGNED_TEAM="$(codesign -dv "$BUILT_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [ "$SIGNED_TEAM" != "$TEAM_ID" ]; then
    echo "ERROR: app is signed for team '$SIGNED_TEAM', expected $TEAM_ID" >&2
    exit 1
fi
echo "Signed for team $SIGNED_TEAM"

echo "=== Quitting any running copy ==="
if pgrep -x "$APP_NAME" > /dev/null; then
    pkill -x "$APP_NAME" || true
    for _ in $(seq 1 50); do
        pgrep -x "$APP_NAME" > /dev/null || break
        sleep 0.1
    done
    if pgrep -x "$APP_NAME" > /dev/null; then
        pkill -9 -x "$APP_NAME" || true
    fi
fi

echo "=== Installing to $INSTALLED_APP ==="
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"

echo "=== Launching ==="
open "$INSTALLED_APP"
echo "Done."
