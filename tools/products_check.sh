#!/usr/bin/env bash
# products_check.sh: every library product a consumer can depend on has to contain something.
#
# Why: `LieDARARKit` and `LieDARUI` shipped as products in v0.1.0 while their sources held one
# comment and `@_exported import LieDAR`. Someone who added the `LieDARARKit` product expecting an
# ARKit capture source got a re-export of the core module and no error anywhere. A placeholder
# target is fine, because it keeps compiling as the real thing is written; a placeholder *product*
# is a promise the package cannot keep.
#
# For each `.library(name: X, targets: [...])` in Package.swift, this counts the lines in each
# named target that are not blank, not a comment and not an import. A target with none of those is
# empty, and a product made of only empty targets fails the check.
#
# Usage: tools/products_check.sh          (takes no arguments)
# Prints exactly one final RESULT: PASS / FAIL / BLOCKED line; exits 0 / 1 / 2.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "RESULT: BLOCKED cannot cd to $ROOT"; exit 2; }

[ $# -eq 0 ] || { echo "RESULT: BLOCKED usage: tools/products_check.sh (takes no arguments)"; exit 2; }
[ -f Package.swift ] || { echo "RESULT: BLOCKED no Package.swift in $ROOT"; exit 2; }

# Lines that carry code, as opposed to comments, blanks and imports.
substantive_lines() {
  local dir="$1"
  [ -d "$dir" ] || { echo 0; return; }
  find "$dir" -name '*.swift' -type f -print0 \
    | xargs -0 cat 2>/dev/null \
    | sed -E 's/[[:space:]]+$//' \
    | grep -vE '^[[:space:]]*$' \
    | grep -vE '^[[:space:]]*(//|/\*|\*)' \
    | grep -cvE '^[[:space:]]*(@_exported[[:space:]]+)?(public[[:space:]]+)?import[[:space:]]+[A-Za-z_]' \
    || true
}

# ".library(name: "X", targets: ["A", "B"])" -> "X A B", one product per line.
PRODUCTS="$(grep -oE '\.library\(name: *"[^"]+", *targets: *\[[^]]*\]' Package.swift \
  | sed -E 's/\.library\(name: *"([^"]+)", *targets: *\[(.*)\]/\1 \2/' \
  | tr -d '",')"
[ -n "$PRODUCTS" ] || { echo "RESULT: BLOCKED found no .library products in Package.swift"; exit 2; }

echo "== library products declared in Package.swift =="
EMPTY=0
COUNT=0
while read -r line; do
  [ -n "$line" ] || continue
  PRODUCT="${line%% *}"
  TARGETS="${line#* }"
  COUNT=$((COUNT + 1))
  TOTAL=0
  DETAIL=""
  for t in $TARGETS; do
    N="$(substantive_lines "Sources/$t")"
    TOTAL=$((TOTAL + N))
    DETAIL="$DETAIL $t=$N"
  done
  if [ "$TOTAL" -eq 0 ]; then
    echo "  $PRODUCT: EMPTY ($DETAIL code lines). Remove the product until the target has something in it"
    EMPTY=$((EMPTY + 1))
  else
    echo "  $PRODUCT:$DETAIL code lines"
  fi
done <<< "$PRODUCTS"

if [ "$EMPTY" -gt 0 ]; then
  echo "RESULT: FAIL $EMPTY of $COUNT library product(s) are empty, so a consumer can depend on nothing"
  exit 1
fi
echo "RESULT: PASS $COUNT library product(s), each with code in its target"
exit 0
