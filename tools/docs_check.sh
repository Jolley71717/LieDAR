#!/bin/bash
# Compiles every Swift example in the documentation against the package.
#
# Why: an example that does not compile is worse than no example, because the
# reader assumes the mistake is theirs. Documentation drifts silently otherwise,
# since nothing else reads it.
#
# A fenced ```swift block is compiled. Put "// docs-check: skip" on the block's
# first line for fragments that are not whole programs, such as the dependency
# line for a Package.swift.
#
# Ends in one RESULT: line and exits 0/1/2.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$PWD"

command -v swift >/dev/null 2>&1 || { echo "RESULT: BLOCKED no swift toolchain"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Split each file into numbered swift blocks under $WORK/blocks.
mkdir -p "$WORK/blocks"
python3 - "$WORK/blocks" README.md docs/*.md <<'PY'
import io, os, sys
out = sys.argv[1]
n = 0
for path in sys.argv[2:]:
    if not os.path.exists(path): continue
    lines = io.open(path, encoding='utf-8').read().split('\n')
    i = 0
    while i < len(lines):
        if lines[i].strip() == '```swift':
            j = i + 1
            body = []
            while j < len(lines) and lines[j].strip() != '```':
                body.append(lines[j]); j += 1
            n += 1
            io.open(os.path.join(out, f"{n:03d}.swift"), 'w', encoding='utf-8').write('\n'.join(body))
            io.open(os.path.join(out, f"{n:03d}.src"), 'w', encoding='utf-8').write(f"{path}:{i+1}")
            i = j
        i += 1
print(n)
PY

COUNT="$(ls "$WORK/blocks"/*.swift 2>/dev/null | wc -l | tr -d ' ')"
[ "$COUNT" -eq 0 ] && { echo "RESULT: FAIL no Swift examples found in the documentation"; exit 1; }

mkdir -p "$WORK/pkg/Sources/DocsCheck"

# SwiftPM identifies a path dependency by the checkout directory's name, lowercased, which is
# "liedar" in a normal clone and the branch name in a git worktree. Hardcoding "liedar" made this
# script fail in every worktree with "unknown package", which reads like a broken example and is
# not one.
# Hardcoding "liedar" made every example fail in a worktree with one misleading error.
PKG_ID="$(basename "$ROOT" | tr '[:upper:]' '[:lower:]')"

# Every library product, so an example can import LieDARUI as readily as LieDAR. Taken from
# Package.swift rather than listed here, so a new product does not need this script edited.
DEPS=""
for p in $(grep -oE '\.library\(name: *"[^"]+"' Package.swift | sed -E 's/.*"([^"]+)"/\1/'); do
  DEPS="$DEPS.product(name: \"$p\", package: \"$PKG_ID\"), "
done
[ -n "$DEPS" ] || { echo "RESULT: BLOCKED found no .library products in Package.swift to compile examples against"; exit 2; }

cat > "$WORK/pkg/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "DocsCheck", platforms: [.iOS(.v16), .macOS(.v13)],
    dependencies: [.package(path: "$ROOT")],
    targets: [.executableTarget(name: "DocsCheck", dependencies: [$DEPS])]
)
EOF

CHECKED=0; SKIPPED=0; FAILED=0
for f in "$WORK/blocks"/*.swift; do
  src="$(cat "${f%.swift}.src")"
  if head -1 "$f" | grep -q "docs-check: skip"; then
    SKIPPED=$((SKIPPED + 1)); continue
  fi
  cp "$f" "$WORK/pkg/Sources/DocsCheck/main.swift"
  if OUT="$(cd "$WORK/pkg" && swift build 2>&1)"; then
    CHECKED=$((CHECKED + 1))
  else
    FAILED=$((FAILED + 1))
    echo "  $src does not compile:"
    echo "$OUT" | grep -E "error:" | head -4 | sed 's/^/      /'
  fi
done

echo "  examples compiled: $CHECKED, skipped: $SKIPPED, failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
  echo "RESULT: FAIL $FAILED documentation example(s) do not compile"
  exit 1
fi
echo "RESULT: PASS $CHECKED documentation example(s) compile against the package, $SKIPPED skipped"
exit 0
