#!/bin/bash
# Regenerates docs/images/ from the synthetic source, so the readme shows real output.
# The PNGs are committed; this only has to run when the renderer or the room changes.
# Ends in one RESULT: line and exits 0/1/2.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$PWD"
command -v swift >/dev/null 2>&1 || { echo "RESULT: BLOCKED no swift toolchain"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/pkg/Sources/Preview"
cp tools/preview/main.swift "$WORK/pkg/Sources/Preview/main.swift"
cat > "$WORK/pkg/Package.swift" <<PKG
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Preview", platforms: [.macOS(.v13)],
    dependencies: [.package(path: "$ROOT")],
    targets: [.executableTarget(name: "Preview", dependencies: [.product(name: "LieDAR", package: "liedar")])]
)
PKG
if ! OUT="$(cd "$WORK/pkg" && swift build -c release 2>&1)"; then
  echo "$OUT" | grep -E "error:" | head -5
  echo "RESULT: FAIL the preview renderer does not compile"; exit 1
fi
"$WORK/pkg/.build/release/Preview" "$ROOT/docs/images" || { echo "RESULT: FAIL the renderer exited non-zero"; exit 1; }
COUNT="$(ls "$ROOT/docs/images"/*.png 2>/dev/null | wc -l | tr -d ' ')"
[ "$COUNT" -ge 3 ] || { echo "RESULT: FAIL expected 3 images, found $COUNT"; exit 1; }
echo "RESULT: PASS $COUNT preview image(s) written to docs/images"
exit 0
