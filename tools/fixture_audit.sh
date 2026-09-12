#!/usr/bin/env bash
# fixture_audit.sh: nothing recorded from a real place, and nothing large, under Fixtures/.
#
# Fails on: any .jpg/.jpeg; any worldmap.bin; any manifest (capture.json or any .json) carrying a
# real device model string (iPhoneN,N / iPadN,N) or an iOS version string; any single file over
# 2 MB. Passes on an empty Fixtures/. Prints exactly one final RESULT: line; exits 0 / 1 / 2.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/Fixtures"
MAX_BYTES=$((2 * 1024 * 1024))
problems=0
checked=0

fail() { echo "   FAIL: $1"; problems=$((problems + 1)); }

if [ ! -d "$FIXTURES" ]; then
  echo "RESULT: BLOCKED Fixtures/ directory not found at $FIXTURES"
  exit 2
fi

echo "== auditing $FIXTURES =="
while IFS= read -r -d '' file; do
  checked=$((checked + 1))
  rel="${file#"$FIXTURES"/}"
  name="$(basename "$file")"
  lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

  case "$lower" in
    *.jpg|*.jpeg) fail "$rel: colour image (no recorded imagery may be committed)" ;;
    worldmap.bin) fail "$rel: ARKit world map (device-only, never a fixture)" ;;
  esac

  size=$(stat -f '%z' "$file" 2>/dev/null || stat -c '%s' "$file" 2>/dev/null || echo 0)
  if [ "$size" -gt "$MAX_BYTES" ]; then
    fail "$rel: $size bytes exceeds the 2 MB limit"
  fi

  case "$lower" in
    *.json)
      if grep -Eq 'iPhone[0-9]+,[0-9]+|iPad[0-9]+,[0-9]+' "$file"; then
        fail "$rel: carries a real device model string"
      fi
      if grep -Eq '"iosVersion"[[:space:]]*:[[:space:]]*"[0-9]+(\.[0-9]+)+"' "$file"; then
        fail "$rel: carries a real iOS version string"
      fi
      ;;
  esac
done < <(find "$FIXTURES" -type f ! -name '.gitkeep' ! -name '.DS_Store' -print0)

echo "   files checked: $checked, problems: $problems"
if [ "$problems" -gt 0 ]; then
  echo "RESULT: FAIL $problems problem(s) in $checked file(s) under Fixtures/"
  exit 1
fi
echo "RESULT: PASS $checked file(s) under Fixtures/, no recorded imagery, world map, device strings or files over 2 MB"
exit 0
