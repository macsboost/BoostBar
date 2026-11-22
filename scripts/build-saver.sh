#!/usr/bin/env bash
# Builds "BoostBar Flying Cars.saver" (a macOS screen saver) at the path given.
#   ./scripts/build-saver.sh "dist/BoostBar.app/Contents/Library/Screen Savers/BoostBar Flying Cars.saver" [version] [build]
# Downloads three.js r147 (and its GLTFLoader) once into build/saver/ — the saver runs offline after that.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; VERSION="${2:-$(tr -d '[:space:]' < VERSION)}"; BUILD="${3:-1}"
W=build/saver
mkdir -p "$W"
[[ -s "$W/three.min.js" ]] || curl -fsSL https://cdn.jsdelivr.net/npm/three@0.147.0/build/three.min.js -o "$W/three.min.js"
[[ -s "$W/GLTFLoader.js" ]] || curl -fsSL https://cdn.jsdelivr.net/npm/three@0.147.0/examples/js/loaders/GLTFLoader.js -o "$W/GLTFLoader.js"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
python3 tools/build_saver_html.py "$W/three.min.js" "$W/GLTFLoader.js" "$OUT/Contents/Resources/saver.html"
cp Saver/thumbnail*.png "$OUT/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Saver/Info.plist > "$OUT/Contents/Info.plist"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCHS=(arm64 x86_64); else ARCHS=("$(uname -m)"); fi
BINS=()
for a in "${ARCHS[@]}"; do
  swiftc -O -target "$a-apple-macos13.0" -parse-as-library -module-name BoostBarSaver \
    -emit-executable -Xlinker -bundle -framework ScreenSaver -framework WebKit \
    Saver/BoostBarSaverView.swift -o "$W/BoostBarSaver-$a"
  BINS+=("$W/BoostBarSaver-$a")
done
lipo -create "${BINS[@]}" -o "$OUT/Contents/MacOS/BoostBarSaver"
file "$OUT/Contents/MacOS/BoostBarSaver"
echo "Built $OUT"
