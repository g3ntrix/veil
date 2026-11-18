#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Veil"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="com.g3ntrix.veil"

[[ "${SKIP_HELPERS:-0}" == "1" ]] || "$ROOT/scripts/build-relayd.sh"
[[ -x "$ROOT/vendor/xray/xray" ]] || "$ROOT/scripts/fetch-xray-vendor.sh"
if [[ ! -f "$ROOT/Sources/Veil/Resources/Media/Veil.icns" || "$ROOT/logo/veil.png" -nt "$ROOT/Sources/Veil/Resources/Media/Veil.icns" ]]; then
  "$ROOT/scripts/make-icns.sh"
fi

build_arch() {  # $1 = arm64 | x86_64; separate scratch paths so the two builds never share an output folder
  local scratch="$ROOT/.build/$1"
  echo "→ swift build ($1)" >&2
  swift build --package-path "$ROOT" --scratch-path "$scratch" -c release --triple "$1-apple-macosx13.0" --product "$APP_NAME" >&2
  swift build --package-path "$ROOT" --scratch-path "$scratch" -c release --triple "$1-apple-macosx13.0" --show-bin-path
}
ARM_DIR="$(build_arch arm64)"
X86_DIR="$(build_arch x86_64)"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$ARM_DIR/$APP_NAME" "$X86_DIR/$APP_NAME" -output "$APP/Contents/MacOS/$APP_NAME"
cp -R "$ARM_DIR/${APP_NAME}_${APP_NAME}.bundle" "$APP/Contents/Resources/"
[[ -f "$APP/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle/Contents/Resources/Server/install.sh" && ! -L "$APP/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle/Contents/Resources/Server" ]] \
  || { echo "error: Server templates missing from the resource bundle" >&2; exit 1; }
cp "$ROOT/vendor/relayd" "$APP/Contents/Resources/relayd"
cp "$ROOT/vendor/xray/xray" "$APP/Contents/Resources/xray"
cp "$ROOT/Sources/Veil/Resources/Media/Veil.icns" "$APP/Contents/Resources/Veil.icns"
cp "$ROOT/vendor/xray/LICENSE" "$APP/Contents/Resources/XRAY-LICENSE" 2>/dev/null || true
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>Veil</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSAppleEventsUsageDescription</key><string>Veil opens Terminal with the SSH command ready for you.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Veil shares its proxy with your phone on the local network when you turn on phone sharing.</string>
  <key>NSHumanReadableCopyright</key><string>Veil by g3ntrix. GPL-3.0. Not notarized; ad-hoc signed.</string>
</dict>
</plist>
PLIST

echo "→ ad-hoc signing"
ENT="$ROOT/scripts/entitlements.plist"
for bin in relayd xray; do
  codesign --force --sign - --options runtime --timestamp=none "$APP/Contents/Resources/$bin"
done
codesign --force --sign - --options runtime --entitlements "$ENT" --timestamp=none "$APP/Contents/MacOS/$APP_NAME"
codesign --force --sign - --options runtime --entitlements "$ENT" --timestamp=none "$APP"
xattr -cr "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP"
for f in "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/Resources/relayd" "$APP/Contents/Resources/xray"; do
  archs="$(lipo -archs "$f")"; echo "  $(basename "$f"): $archs"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "error: $(basename "$f") is not universal" >&2; exit 1; }
done
echo "✔ built $APP ($VERSION)"
