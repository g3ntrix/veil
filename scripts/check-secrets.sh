#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
needles=()
add() { [ -n "$1" ] && [ ${#1} -ge 6 ] && needles+=("$1"); }
if [ -f "$HOME/vpn.sh" ]; then
  while IFS= read -r v; do add "$v"; done < <(grep -oE '"(auth|password|pass|pinnedPeerCertSha256)":"[^"<$]+"' "$HOME/vpn.sh" | sed -E 's/^"[^"]+":"(.*)"$/\1/')
  while IFS= read -r v; do add "$v"; done < <(sed -nE 's/^LANPW="([^"<]+)".*/\1/p' "$HOME/vpn.sh")
fi
needles+=("BEGIN RSA PRIVATE KEY" "BEGIN OPENSSH PRIVATE KEY")
if [ -f "$ROOT/.private/leak-needles.txt" ]; then
  while IFS= read -r v; do [[ -z "$v" || "$v" == \#* ]] && continue; add "$v"; done < "$ROOT/.private/leak-needles.txt"
fi
targets=("$ROOT/Sources" "$ROOT/Helpers" "$ROOT/Tests" "$ROOT/scripts" "$ROOT/Package.swift" "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$ROOT/docs/FIRST-LAUNCH.txt" "$ROOT/Server" "$ROOT/reference" "$ROOT/logo")
[ -d "$ROOT/dist" ] && targets+=("$ROOT/dist")
if [ "${ALL:-0}" = 1 ]; then
  while IFS= read -r f; do targets+=("$ROOT/$f"); done < <(git -C "$ROOT" ls-files docs logo reference)
fi
hits=0
for n in "${needles[@]}"; do
  for t in "${targets[@]}"; do
    [ -e "$t" ] || continue
    if grep -rFqa --exclude=check-secrets.sh -- "$n" "$t" 2>/dev/null; then
      f="$(grep -rFla --exclude=check-secrets.sh -- "$n" "$t" | head -3 | tr '\n' ' ')"
      echo "LEAK: a developer secret or IP (${#n} chars) appears in: $f"
      hits=$((hits + 1))
    fi
  done
done
for d in "$ROOT"/dist/*.dmg; do
  [ -f "$d" ] || continue
  m="$(mktemp -d)"; hdiutil attach -nobrowse -readonly -mountpoint "$m" "$d" -quiet || continue
  for n in "${needles[@]}"; do grep -rFqa -- "$n" "$m" 2>/dev/null && { echo "LEAK inside $(basename "$d")"; hits=$((hits + 1)); }; done
  hdiutil detach "$m" -quiet; rmdir "$m"
done
echo "checked ${#needles[@]} values across sources, scripts, tests and build products"
[ $hits -eq 0 ] && echo "✔ no leaks" || { echo "✘ $hits leak(s)"; exit 1; }
