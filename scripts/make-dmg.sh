#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
APP="$ROOT/dist/Veil.app"
DMG="$ROOT/dist/Veil-$VERSION.dmg"
STAGE="$ROOT/dist/dmg-staging"
[[ -d "$APP" ]] || { echo "error: run scripts/build-app.sh first" >&2; exit 1; }
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/FIRST-LAUNCH.txt" "$STAGE/If macOS blocks Veil.txt"
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
hdiutil detach "/Volumes/Veil" -quiet >/dev/null 2>&1 || true
hdiutil create -volname "Veil" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✔ $DMG"
