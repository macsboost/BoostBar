#!/usr/bin/env bash
# Builds dist/BoostBar.app.
#
#   ./scripts/build-app.sh [version]
#
# Environment:
#   UNIVERSAL=1          arm64 + x86_64 (needs full Xcode)
#   EDITION=direct       (default) Developer ID build with every feature → dist/BoostBar.zip
#   EDITION=appstore     sandboxed Mac App Store build → dist/BoostBar.pkg
#   SIGN_IDENTITY        codesign identity ("-" = ad-hoc). App Store: "Apple Distribution: …"
#   INSTALLER_IDENTITY   App Store only: "3rd Party Mac Developer Installer: …" / "Mac Installer Distribution"
#   PROVISION_PROFILE    App Store only: path to the Mac App Store .provisionprofile
#   TEAM_ID              App Store only: e.g. S6K8YB57AB
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
EDITION="${EDITION:-direct}"

ARGS=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARGS+=(--arch arm64 --arch x86_64); fi
if [[ "$EDITION" == "appstore" ]]; then ARGS+=(-Xswiftc -DAPPSTORE); fi

swift build "${ARGS[@]}"
BIN_DIR="$(swift build "${ARGS[@]}" --show-bin-path)"

APP="dist/BoostBar.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BoostBar" "$APP/Contents/MacOS/BoostBar"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/SupportBanner.jpg "$APP/Contents/Resources/"

# App icon (.icns) from the 1024 px master
if [[ -f Resources/AppIcon-1024.png ]] && command -v iconutil >/dev/null; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

IDENTITY="${SIGN_IDENTITY:--}"

# Screen savers (direct edition), shipped inside the app and installed from Settings ▸ Screen Saver
if [[ "$EDITION" != "appstore" && "${SKIP_SAVER:-0}" != "1" ]]; then
  SAVER_ARGS=(--force --options runtime --sign "$IDENTITY")
  [[ "$IDENTITY" != "-" ]] && SAVER_ARGS+=(--timestamp)
  for pair in "cars:BoostBar Flying Cars" "starships:BoostBar Starships" "starlink:BoostBar Starlink" "jetrace:BoostBar Jet Racers"; do
    SAVER="$APP/Contents/Library/Screen Savers/${pair#*:}.saver"
    ./scripts/build-saver.sh "$SAVER" "$VERSION" "$BUILD" "${pair%%:*}"
    codesign "${SAVER_ARGS[@]}" "$SAVER"
  done
fi

if [[ "$EDITION" == "appstore" ]]; then
  : "${TEAM_ID:?TEAM_ID is required for the App Store edition}"
  [[ -n "${PROVISION_PROFILE:-}" ]] && cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
  ENT="$(mktemp -d)/BoostBar-AppStore.entitlements"
  sed "s/__TEAM_ID__/$TEAM_ID/g" Resources/BoostBar-AppStore.entitlements.in > "$ENT"
  codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
    productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" dist/BoostBar.pkg
  else
    productbuild --component "$APP" /Applications dist/BoostBar.pkg
  fi
  echo "Built App Store package dist/BoostBar.pkg (version $VERSION, build $BUILD)"
else
  SIGN_ARGS=(--force --options runtime --entitlements Resources/BoostBar.entitlements --sign "$IDENTITY")
  [[ "$IDENTITY" != "-" ]] && SIGN_ARGS+=(--timestamp)
  codesign "${SIGN_ARGS[@]}" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  (cd dist && ditto -c -k --keepParent BoostBar.app BoostBar.zip)
  echo "Built $APP  (version $VERSION, build $BUILD)"
fi
