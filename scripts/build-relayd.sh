#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Helpers/relayd"
OUT="$ROOT/vendor"
mkdir -p "$OUT"
( cd "$SRC" && go vet ./... && go test -count=1 ./... )
for arch in arm64 amd64; do
  ( cd "$SRC" && CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -trimpath -ldflags "-s -w" -o "$OUT/relayd-$arch" . )
done
lipo -create "$OUT/relayd-arm64" "$OUT/relayd-amd64" -output "$OUT/relayd"
rm -f "$OUT/relayd-arm64" "$OUT/relayd-amd64"
chmod +x "$OUT/relayd"
echo "✔ $OUT/relayd ($("$OUT/relayd" version))"
