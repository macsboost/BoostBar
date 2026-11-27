#!/usr/bin/env bash
# Builds one of BoostBar's macOS screen savers at the path given.
#   ./scripts/build-saver.sh "<App>/Contents/Library/Screen Savers/BoostBar Flying Cars.saver" [version] [build] [cars|starships|starlink|jetrace]
# Downloads three.js r147 (and its GLTFLoader) once into build/saver/ — the savers run offline after that.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; VERSION="${2:-$(tr -d '[:space:]' < VERSION)}"; BUILD="${3:-1}"; SCENE="${4:-cars}"
W=build/saver
mkdir -p "$W"
[[ -s "$W/three.min.js" ]] || curl -fsSL https://cdn.jsdelivr.net/npm/three@0.147.0/build/three.min.js -o "$W/three.min.js"
[[ -s "$W/GLTFLoader.js" ]] || curl -fsSL https://cdn.jsdelivr.net/npm/three@0.147.0/examples/js/loaders/GLTFLoader.js -o "$W/GLTFLoader.js"

SOURCES=(Saver/BoostBarSaverView.swift Saver/native/GLB.swift Saver/native/Flock.swift)
case "$SCENE" in
  cars)      ID=com.macsboost.boostbar.saver;     NAME="BoostBar Flying Cars"; EXEC=BoostBarSaver;     CLASS=BoostBarSaverView
             MODULE=BoostBarSaver;     FLAGS=();             CREDIT="X1 SkyRacer model © X1 Racing." ;;
  starships) ID=com.macsboost.boostbar.starships; NAME="BoostBar Starships";   EXEC=BoostBarStarships; CLASS=BoostBarStarshipsView
             MODULE=BoostBarStarships; FLAGS=(-D STARSHIPS); CREDIT="Starship model from the X1 SkyRacer sim (Ship 42, built from code). Not affiliated with SpaceX." ;;
  starlink)  ID=com.macsboost.boostbar.starlink;  NAME="BoostBar Starlink";    EXEC=BoostBarStarlink;  CLASS=BoostBarStarlinkView
             MODULE=BoostBarStarlink;  FLAGS=(-D STARLINK);  CREDIT="Stylised Starlink V2 and V3 models by MacsBoost. Not affiliated with SpaceX." ;;
  jetrace)   ID=com.macsboost.boostbar.jetrace;   NAME="BoostBar Watercraft Racing";  EXEC=BoostBarWatercraftRacing; CLASS=BoostBarJetRaceView
             MODULE=BoostBarWatercraftRacing; FLAGS=();             CREDIT="Watercraft models by MacsBoost."
             SOURCES=(Saver/BoostBarJetRaceView.swift Saver/native/GLB.swift Saver/native/JetRace.swift) ;;
  *) echo "unknown scene $SCENE"; exit 1 ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
python3 tools/build_saver_html.py "$W/three.min.js" "$W/GLTFLoader.js" "$OUT/Contents/Resources/saver.html" "$SCENE"
cp Saver/thumbs/"$SCENE"/thumbnail*.png "$OUT/Contents/Resources/" 2>/dev/null || true
# models for the native (SceneKit) renderer; the car liveries are pre-painted by tools/bake_liveries.py
case "$SCENE" in
  cars)      cp Saver/native/X1_*.glb "$OUT/Contents/Resources/" ;;
  starships) cp Saver/src/Starship.glb Saver/src/Roadster.glb "$OUT/Contents/Resources/" ;;
  starlink)  cp Saver/src/Starlink.glb "$OUT/Contents/Resources/" ;;
  # the race itself is a script (run in JavaScriptCore, with three.js for its maths); SceneKit draws these models
  jetrace)   cp Saver/src/jetrace/*.glb Saver/src/jetrace/rigs.json Saver/src/jetrace.js "$W/three.min.js" "$OUT/Contents/Resources/" ;;
esac
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__ID__/$ID/" -e "s/__NAME__/$NAME/g" \
    -e "s/__EXEC__/$EXEC/" -e "s/__CLASS__/$CLASS/" -e "s/__CREDIT__/$CREDIT/" Saver/Info.plist > "$OUT/Contents/Info.plist"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCHS=(arm64 x86_64); else ARCHS=("$(uname -m)"); fi
BINS=()
for a in "${ARCHS[@]}"; do
  swiftc -O -target "$a-apple-macos13.0" -parse-as-library -module-name "$MODULE" ${FLAGS[@]+"${FLAGS[@]}"} \
    -emit-executable -Xlinker -bundle -framework ScreenSaver -framework SceneKit -framework JavaScriptCore \
    "${SOURCES[@]}" -o "$W/$EXEC-$a"
  BINS+=("$W/$EXEC-$a")
done
lipo -create "${BINS[@]}" -o "$OUT/Contents/MacOS/$EXEC"
file "$OUT/Contents/MacOS/$EXEC"
echo "Built $OUT"
