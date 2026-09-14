#!/usr/bin/env bash
# layering_check.sh: the core module must not reach into the synthetic one.
#
# Why: README.md tells a reader "You can stop at replay. If you only want your existing recorded
# captures to run in tests, use CaptureRecorder and CaptureReader and ignore the rest." Before
# 0.2.0 that was false at the link level, because a Swift package builds as one object file and
# the room, the raycaster and the virtual camera were in the same target as the format. Meshwise's
# release binary grew by 306,432 bytes and the link map named Raycaster.render and
# SyntheticCaptureSource.produce among the symbols it kept, none of which a release build can run.
#
# Splitting the target is what makes the promise true. This script is what keeps it true. A
# layering rule nothing checks lasts about a week.
#
# Three things are checked:
#   1. SwiftPM's own view of the graph: the LieDAR target declares no dependency on any other
#      target, and LieDARSynthetic depends on LieDAR. Read from `swift package dump-package`, so
#      reformatting Package.swift cannot fool it.
#   2. No file in Sources/LieDAR imports LieDARSynthetic, LieDARUI or LieDARARKit.
#   3. No type declared in Sources/LieDARSynthetic is named in Sources/LieDAR. Comments are
#      stripped first, so the check is about code and not about prose.
#
# The reverse direction is allowed and expected: synthetic is built on core.
#
# Usage: bash tools/layering_check.sh     (takes no arguments)
# Prints exactly one final RESULT: PASS / FAIL / BLOCKED line; exits 0 / 1 / 2.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "RESULT: BLOCKED cannot cd to $ROOT"; exit 2; }

[ $# -eq 0 ] || { echo "RESULT: BLOCKED usage: bash tools/layering_check.sh (takes no arguments)"; exit 2; }

CORE="Sources/LieDAR"
SYNTHETIC="Sources/LieDARSynthetic"
[ -d "$CORE" ] || { echo "RESULT: BLOCKED no $CORE directory"; exit 2; }
[ -d "$SYNTHETIC" ] || { echo "RESULT: BLOCKED no $SYNTHETIC directory"; exit 2; }
command -v swift >/dev/null 2>&1 || { echo "RESULT: BLOCKED no swift toolchain to dump the package with"; exit 2; }

FAILURES=0

# 1. The declared graph, from SwiftPM rather than from a grep over Package.swift.
DUMP="$(swift package dump-package 2>&1)"
if [ $? -ne 0 ]; then
  echo "$DUMP" | head -5 | sed 's/^/   /'
  echo "RESULT: BLOCKED swift package dump-package failed, so the declared graph cannot be read"
  exit 2
fi
GRAPH="$(printf '%s' "$DUMP" | python3 -c '
import json, sys
try:
    package = json.load(sys.stdin)
except Exception as exc:
    print("PARSE %s" % exc)
    raise SystemExit(0)
wanted = {"LieDAR": [], "LieDARSynthetic": ["LieDAR"]}
by_name = {t["name"]: t for t in package.get("targets", [])}
for name, expected in wanted.items():
    target = by_name.get(name)
    if target is None:
        print("MISSING %s" % name)
        continue
    deps = []
    for dep in target.get("dependencies", []):
        for kind in ("byName", "target", "product"):
            if kind in dep and dep[kind]:
                deps.append(str(dep[kind][0]))
    if sorted(deps) != sorted(expected):
        print("DEPS %s declares [%s], expected [%s]" % (name, ", ".join(sorted(deps)), ", ".join(sorted(expected))))
    else:
        print("OK %s -> [%s]" % (name, ", ".join(deps)))
')"

echo "== declared graph =="
while read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    OK*) echo "   ${line#OK }" ;;
    PARSE*) echo "   cannot parse dump-package output: ${line#PARSE }"; FAILURES=$((FAILURES + 1)) ;;
    *) echo "   $line"; FAILURES=$((FAILURES + 1)) ;;
  esac
done <<< "$GRAPH"

# 2. Imports in the core target.
echo "== imports in $CORE =="
BAD_IMPORTS="$(grep -rnE '^[[:space:]]*(@_exported[[:space:]]+)?(public[[:space:]]+)?import[[:space:]]+(LieDARSynthetic|LieDARUI|LieDARARKit)\b' "$CORE" 2>/dev/null || true)"
if [ -n "$BAD_IMPORTS" ]; then
  printf '%s\n' "$BAD_IMPORTS" | sed 's/^/   /'
  FAILURES=$((FAILURES + 1))
else
  echo "   none of LieDARSynthetic, LieDARUI, LieDARARKit"
fi

# 3. Synthetic type names used in core code.
#
# Only real type declarations count. An `extension Float` in the synthetic target would otherwise
# put "Float" on the list and fail every file in the package.
NAMES="$(grep -hE '^(public |package |open |final )*(struct|class|enum|protocol|actor|typealias) ' "$SYNTHETIC"/*/*.swift 2>/dev/null \
  | sed -E 's/^([a-z]+ )*(struct|class|enum|protocol|actor|typealias) +([A-Za-z_][A-Za-z_0-9]*).*/\3/' \
  | sort -u)"
[ -n "$NAMES" ] || { echo "RESULT: BLOCKED found no type declarations in $SYNTHETIC, so there is nothing to check for"; exit 2; }

# A name the core declares too is the core's own and cannot be a leak.
CORE_NAMES="$(grep -rhE '^(public |package |open |final )*(struct|class|enum|protocol|actor|typealias) ' "$CORE" 2>/dev/null \
  | sed -E 's/^([a-z]+ )*(struct|class|enum|protocol|actor|typealias) +([A-Za-z_][A-Za-z_0-9]*).*/\3/' \
  | sort -u)"
NAMES="$(comm -23 <(printf '%s\n' "$NAMES") <(printf '%s\n' "$CORE_NAMES"))"

echo "== $(printf '%s\n' "$NAMES" | grep -cv '^$') synthetic type(s) must not appear in $CORE =="
STRIPPED="$(mktemp -d)"
trap 'rm -rf "$STRIPPED"' EXIT
LEAKS=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  # Drop whole-line comments and any trailing `// ...`, so prose about the synthetic module in a
  # core doc comment is not reported as a code dependency.
  sed -E -e 's#([^:])//.*$#\1#' -e 's#^[[:space:]]*(//|/\*|\*).*$##' "$file" > "$STRIPPED/body.swift"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    HITS="$(grep -nw "$name" "$STRIPPED/body.swift" || true)"
    if [ -n "$HITS" ]; then
      printf '%s\n' "$HITS" | sed "s|^|   $file:|"
      LEAKS=$((LEAKS + 1))
    fi
  done <<< "$NAMES"
done <<< "$(find "$CORE" -name '*.swift' -type f | sort)"

if [ "$LEAKS" -gt 0 ]; then
  echo "   $LEAKS reference(s) from the core into the synthetic module"
  FAILURES=$((FAILURES + 1))
else
  echo "   none: $(printf '%s\n' "$NAMES" | tr '\n' ' ')"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "RESULT: FAIL $FAILURES layering check(s) failed: the core reaches into the synthetic module, so a replay-only consumer links the fake sensor"
  exit 1
fi
echo "RESULT: PASS the core declares no dependency on the synthetic module, imports none of the other modules, and names none of its types"
exit 0
