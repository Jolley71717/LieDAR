#!/usr/bin/env bash
# ci_smoke.sh — can this machine run LieDAR's simulator tests at all?
# Creates and boots a throwaway iPhone simulator and checks the host has a Metal device.
# The in-simulator Metal probe lives in Tests/LieDARTests/MetalAvailabilityTests.swift and
# reports XCTSkip("no Metal device") rather than failing; this script is the pre-check.
# Prints exactly one final line: RESULT: PASS / RESULT: FAIL / RESULT: BLOCKED (exit 0 / 1 / 2).
set -uo pipefail
NAME="liedar-ci-smoke-$$"
UDID=""
cleanup() { [ -n "$UDID" ] && xcrun simctl delete "$UDID" >/dev/null 2>&1 && echo "   (deleted $UDID)"; }
trap cleanup EXIT

echo "== xcode =="; xcodebuild -version | tr '\n' ' '; echo
echo "== runtimes =="; xcrun simctl list runtimes | grep -E "^iOS" | sed 's/^/   /'
TYPE="$(xcrun simctl list devicetypes | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-1[5-9][^ )]*' | tail -1)"
[ -n "$TYPE" ] || { echo "RESULT: BLOCKED no iPhone 15+ device type on this runner"; exit 2; }
echo "== creating $NAME ($TYPE) =="
UDID="$(xcrun simctl create "$NAME" "$TYPE" 2>/dev/null | tail -1)"
[ -n "$UDID" ] || { echo "RESULT: BLOCKED simctl create failed"; exit 2; }
echo "   $UDID"
echo "== booting =="
xcrun simctl boot "$UDID" >/dev/null 2>&1 || { echo "RESULT: BLOCKED simctl boot failed"; exit 2; }
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || { echo "RESULT: BLOCKED simulator never reported booted"; exit 2; }
echo "   booted"
echo "== host Metal device =="
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/liedar-metal-probe.XXXXXX")" || { echo "RESULT: BLOCKED mktemp failed"; exit 2; }
trap 'cleanup; rm -rf "$PROBE_DIR"' EXIT
cat > "$PROBE_DIR/probe.swift" <<'SWIFT'
import Metal
if let d = MTLCreateSystemDefaultDevice() { print("METAL_DEVICE=\(d.name)") } else { print("METAL_DEVICE=none") }
SWIFT
OUT="$(swiftc -O "$PROBE_DIR/probe.swift" -o "$PROBE_DIR/probe" 2>&1 && "$PROBE_DIR/probe" 2>&1 || echo METAL_DEVICE=compile-failed)"
echo "   $OUT"
case "$OUT" in
  *METAL_DEVICE=none*|*compile-failed*) echo "RESULT: BLOCKED simulator boots but the host has no Metal device — GPU-dependent tests will skip; CPU-raycaster tests still valid"; exit 2 ;;
esac
echo "RESULT: PASS simulator boots and host Metal device present ($TYPE)"
exit 0
