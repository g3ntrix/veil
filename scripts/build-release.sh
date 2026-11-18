#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
REPO="${RELEASES_REPO:-g3ntrix/veil}"
"$ROOT/scripts/build-app.sh"
"$ROOT/scripts/make-dmg.sh"
DMG="$ROOT/dist/Veil-$VERSION.dmg"
SHA="$(cut -d' ' -f1 < "$DMG.sha256")"
NOTES="$ROOT/dist/CHANGELOG-entry.md"
awk -v v="## $VERSION" '$0 ~ "^## " { p = ($0 ~ "^"v) } p' "$ROOT/CHANGELOG.md" > "$NOTES"
cat >> "$NOTES" <<NOTE

Download the DMG, drag Veil to Applications. Veil is not notarized (no Apple Developer ID); if macOS blocks it,
open System Settings, Privacy & Security, and click **Open Anyway** next to the message about Veil.

SHA-256 of \`Veil-$VERSION.dmg\`: \`$SHA\`
NOTE
echo; cat "$NOTES"; echo
read -r -p "Publish v$VERSION to github.com/$REPO now? Type yes: " ok
[[ "$ok" == "yes" ]] || { echo "Not published. The DMG is in dist/."; exit 0; }
gh release create "v$VERSION" --repo "$REPO" "$DMG" --title "Veil $VERSION" --notes-file "$NOTES"
