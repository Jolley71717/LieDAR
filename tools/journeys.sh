#!/usr/bin/env bash
# journeys.sh runs the Example app's black-box journeys on a throwaway iOS simulator.
#
# Builds Example/Example.xcodeproj, the committed project, with no xcodegen anywhere, and runs
# the ExampleUITests bundle on a simulator this script creates and deletes. Tests run serially
# with one retry per failing test, because a UI test that fails twice in a row is a real failure
# and one that fails once is usually the simulator.
#
# Prints exactly one final RESULT: PASS / FAIL / BLOCKED line with passed/failed/skipped counts,
# and exits 0 / 1 / 2. A run in which zero tests executed is a FAIL, never a pass. An empty test
# bundle is the failure this script exists to catch.
#
# Environment:
#   LIEDAR_JOURNEY_DEVICE_TYPE  simctl device type (default: newest iPhone 15+ Pro available)
#   LIEDAR_JOURNEY_RUNTIME      simctl iOS runtime (default: newest installed)
#   LIEDAR_JOURNEY_ONLY         restrict to one test, e.g. JourneyTests/testEmptyCapture...
#   LIEDAR_JOURNEY_RETRY        1 (default) to pass -retry-tests-on-failure, 0 to run once
#   LIEDAR_JOURNEY_LOG          where to write the xcodebuild log (default: a temp file)
#   LIEDAR_TIMEOUT_SECONDS      deadline for the test run (default 2400)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "RESULT: BLOCKED cannot cd to $ROOT"; exit 2; }
PROJECT="$ROOT/Example/Example.xcodeproj"
[ -d "$PROJECT" ] || { echo "RESULT: BLOCKED no committed project at $PROJECT"; exit 2; }

WORK="${TMPDIR:-/tmp}/liedar-journeys-$$"
mkdir -p "$WORK"
LOG="${LIEDAR_JOURNEY_LOG:-$WORK/xcodebuild.log}"
mkdir -p "$(dirname "$LOG")"
TIMEOUT="${LIEDAR_TIMEOUT_SECONDS:-2400}"
NAME="LieDAR-journeys-$$"
UDID=""

# Called explicitly before every RESULT line so the RESULT line is always the last thing this
# script prints, and left on the trap for the paths that do not reach one.
cleanup() {
  if [ -n "$UDID" ]; then
    echo "   deleting simulator $UDID"
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1
    xcrun simctl delete "$UDID" >/dev/null 2>&1
    UDID=""
  fi
}
trap cleanup EXIT

# macOS has no GNU timeout; perl's alarm is always there. Exit 142 means the deadline hit.
with_deadline() { perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$@"; }

# The last "Executed N tests, with S tests skipped and M failures" line is the suite total.
counts() {
  grep -E 'Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?[0-9]+ failures?' "$1" | tail -1 \
    | sed -E 's/.*Executed ([0-9]+) tests?, with ([0-9]+ tests? skipped and )?([0-9]+) failures?.*/\1 \3/'
}
skips() { grep -cE "Test Case .* skipped" "$1" 2>/dev/null || true; }

echo "== xcode =="; xcodebuild -version | tr '\n' ' '; echo

TYPE="${LIEDAR_JOURNEY_DEVICE_TYPE:-}"
if [ -z "$TYPE" ]; then
  TYPE="$(xcrun simctl list devicetypes | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-1[5-9]-Pro(-Max)?' | sort -V | tail -1)"
fi
[ -n "$TYPE" ] || { echo "RESULT: BLOCKED no iPhone 15+ Pro device type on this machine"; exit 2; }
RUNTIME="${LIEDAR_JOURNEY_RUNTIME:-}"
if [ -z "$RUNTIME" ]; then
  RUNTIME="$(xcrun simctl list runtimes | grep -E '^iOS' | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+' | sort -V | tail -1)"
fi
[ -n "$RUNTIME" ] || { echo "RESULT: BLOCKED no iOS simulator runtime installed"; exit 2; }

echo "== creating $NAME ($TYPE, $RUNTIME) =="
UDID="$(xcrun simctl create "$NAME" "$TYPE" "$RUNTIME" 2>"$WORK/create.err" | tail -1)"
[ -n "$UDID" ] || { sed 's/^/   /' "$WORK/create.err"; echo "RESULT: BLOCKED simctl create failed for $TYPE / $RUNTIME"; exit 2; }
echo "   $UDID"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || { cleanup; echo "RESULT: BLOCKED simctl boot failed for $UDID"; exit 2; }
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || { cleanup; echo "RESULT: BLOCKED simulator $UDID never reported booted"; exit 2; }
echo "   booted"

ONLY="ExampleUITests"
[ -n "${LIEDAR_JOURNEY_ONLY:-}" ] && ONLY="ExampleUITests/${LIEDAR_JOURNEY_ONLY}"
RETRY=()
[ "${LIEDAR_JOURNEY_RETRY:-1}" = "1" ] && RETRY=(-retry-tests-on-failure -test-iterations 2)

echo "== xcodebuild test -only-testing:$ONLY =="
with_deadline xcodebuild test \
  -project "$PROJECT" \
  -scheme ExampleApp \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$WORK/DerivedData" \
  -parallel-testing-enabled NO \
  ${RETRY[@]+"${RETRY[@]}"} \
  -only-testing:"$ONLY" \
  CODE_SIGNING_ALLOWED=NO > "$LOG" 2>&1
rc=$?
if [ "$rc" -eq 142 ]; then
  cleanup
  echo "RESULT: BLOCKED journeys TIMEOUT after ${TIMEOUT}s (log: $LOG)"
  exit 2
fi

read -r total failed <<< "$(counts "$LOG")"
skipped=$(skips "$LOG")
total="${total:-0}"; failed="${failed:-0}"; skipped="${skipped:-0}"
passed=$(( total - failed - skipped ))
[ "$passed" -lt 0 ] && passed=0

if [ "$total" -eq 0 ]; then
  grep -E 'error:|Testing cancelled|\*\* TEST' "$LOG" | head -20 | sed 's/^/   /'
  cleanup
  echo "RESULT: FAIL zero tests executed, the journeys did not run (log: $LOG)"
  exit 1
fi
if [ "$rc" -ne 0 ] || [ "$failed" -ne 0 ]; then
  grep -E 'error:|XCTAssert|failed \(' "$LOG" | head -20 | sed 's/^/   /'
  cleanup
  echo "RESULT: FAIL $passed passed/$failed failed/$skipped skipped, xcodebuild exit $rc (log: $LOG)"
  exit 1
fi
grep -E "^Test Case .* (passed|failed)" "$LOG" | tail -10 | sed 's/^/   /'
cleanup
echo "RESULT: PASS $passed passed/$failed failed/$skipped skipped ($TYPE, $RUNTIME)"
exit 0
