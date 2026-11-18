#!/usr/bin/env bash
set -euo pipefail

XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/vendor/xray"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/veil-xray.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
URL_BASE="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"

resolve_zip() {
  local envpath="$1" asset="$2"
  for c in "${envpath:-}" "$ROOT/assets/$asset"; do
    [[ -n "$c" && -f "$c" ]] && { echo "$c"; return; }
  done
  echo "Downloading $URL_BASE/$asset" >&2
  curl -fsSL --retry 5 --retry-delay 2 "$URL_BASE/$asset" -o "$WORK/$asset"
  echo "$WORK/$asset"
}

ARM_ZIP="$(resolve_zip "${LOCAL_XRAY_ZIP_ARM64:-}" Xray-macos-arm64-v8a.zip)"
X86_ZIP="$(resolve_zip "${LOCAL_XRAY_ZIP_X86:-}" Xray-macos-64.zip)"
mkdir -p "$WORK/a" "$WORK/x" "$OUT"
unzip -oq "$ARM_ZIP" -d "$WORK/a"
unzip -oq "$X86_ZIP" -d "$WORK/x"
lipo -create "$WORK/a/xray" "$WORK/x/xray" -output "$OUT/xray"
chmod +x "$OUT/xray"
cp "$WORK/a/LICENSE" "$OUT/LICENSE" 2>/dev/null || true
echo "$XRAY_VERSION" > "$OUT/VERSION"
ver="$("$OUT/xray" version | head -1)"
echo "✔ $OUT/xray: $ver"
case "$ver" in *"${XRAY_VERSION#v}"*) ;; *) echo "error: unexpected version" >&2; exit 1 ;; esac
