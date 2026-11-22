#!/usr/bin/env bash
# Builds dist/BoostBar.app and dist/BoostBar.zip.
#   ./scripts/build-app.sh            # native arch, version from VERSION file
#   UNIVERSAL=1 ./scripts/build-app.sh 1.2.0   # arm64 + x86_64 (needs full Xcode)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

ARGS=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARGS+=(--arch arm64 --arch x86_64); fi

swift build "${ARGS[@]}"
BIN_DIR="$(swift build "${ARGS[@]}" --show-bin-path)"

APP="dist/BoostBar.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BoostBar" "$APP/Contents/MacOS/BoostBar"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Signing: ad-hoc by default. Set SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" to sign for distribution.
IDENTITY="${SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --options runtime --entitlements Resources/BoostBar.entitlements --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

(cd dist && ditto -c -k --keepParent BoostBar.app BoostBar.zip)
echo "Built $APP  (version $VERSION, build $BUILD)"
