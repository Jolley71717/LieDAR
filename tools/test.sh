#!/usr/bin/env bash
# test.sh builds and tests LieDAR on macOS, then tests it on a throwaway iOS simulator.
#
# Legs, in order:
#   1. swift build -Xswiftc -warnings-as-errors   (macOS, warnings are errors)
#   2. swift test                                  (macOS)
#   3. xcodebuild test -scheme LieDAR-Package on a simulator this script creates and deletes
# Prints exactly one final RESULT: PASS / FAIL / BLOCKED line with test counts; exits 0 / 1 / 2.
# The simulator is created fresh (never an existing device) and deleted on every exit path.
#
# A skip is not a pass, so both legs assert which tests skipped, not just how many. With
# LIEDAR_GOLDEN_OUT exported the two golden tests write their golden files and skip, and the run
# still reported 0 failures and exit 0: a green run that pinned nothing and rewrote what it was
# supposed to be checked against. That variable is now refused outright, and any skip outside the
# expected set fails the run by name.
#
# Environment: LIEDAR_SIM_NAME (simulator name), LIEDAR_DEVICE_TYPE (default: newest iPhone Pro Max/Pro type available),
#              LIEDAR_TIMEOUT_SECONDS per leg (default 1500), LIEDAR_SKIP_SIMULATOR=1 to run only
#              the macOS legs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "RESULT: BLOCKED cannot cd to $ROOT"; exit 2; }
LOGDIR="${TMPDIR:-/tmp}/liedar-test-$$"
mkdir -p "$LOGDIR"
TIMEOUT="${LIEDAR_TIMEOUT_SECONDS:-1500}"
UDID=""
NAME="${LIEDAR_SIM_NAME:-LieDAR-test-$$}"

cleanup() {
  if [ -n "$UDID" ]; then
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1
    xcrun simctl delete "$UDID" >/dev/null 2>&1 && echo "   (deleted simulator $UDID)"
  fi
}
trap cleanup EXIT

# macOS has no GNU timeout; perl's alarm is always there. Exit 142 means the deadline hit.
with_deadline() { perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$@"; }

# "Executed N tests, with M failures". The last such line is the suite total.
counts() {
  grep -E 'Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?[0-9]+ failures?' "$1" | tail -1 \
    | sed -E 's/.*Executed ([0-9]+) tests?, with ([0-9]+ tests? skipped and )?([0-9]+) failures?.*/\1 \3/'
}
skips() { grep -cE "Test Case .* skipped" "$1" 2>/dev/null || true; }

# Skipped tests as "Suite/testName", sorted and unique.
skipped_names() {
  grep -E "^Test Case .* skipped" "$1" 2>/dev/null \
    | sed -E "s/^Test Case '-\[[A-Za-z_0-9]+\.([A-Za-z_0-9]+) ([A-Za-z_0-9]+)\]'.*/\1\/\2/" \
    | sort -u
}

# Tests that must skip on this run, and why:
#   RaycasterTests/testRenderTimeIsWithinBudget    a wall-clock budget, asserted only by
#                                                  tools/timing_check.sh in a release build.
#   LayoutParityTests/*                            read a consumer capture from outside the repo;
#                                                  they skip only when LIEDAR_PARITY_CAPTURE is
#                                                  unset, and must run when it is set.
# Nothing else may skip. If this list has to change, find out which test moved first.
required_skips() {
  echo "RaycasterTests/testRenderTimeIsWithinBudget"
  if [ -z "${LIEDAR_PARITY_CAPTURE:-}" ]; then
    echo "LayoutParityTests/testFirstAnchorBinariesMatchTheirMeta"
    echo "LayoutParityTests/testFirstFrameMetaAndBinariesAgree"
    echo "LayoutParityTests/testManifestParsesAndAgreesWithTheFolder"
    echo "LayoutParityTests/testMergedPLYHeaderIsTheASCIIFormatWeWrite"
  fi
}

# Allowed but not required, because the host decides: a simulator may have no Metal device, while
# every macOS host this package supports has one, so on macOS this skip is a real failure.
optional_skips() {
  [ "$1" = "simulator" ] && echo "MetalAvailabilityTests/testDeviceShaderAndDepthReadback"
  return 0
}

# Prints what is wrong and returns 1 when the skips are not exactly the expected set.
assert_skips() {
  local leg="$1" log="$2" bad=0
  local actual unexpected missing
  actual="$(skipped_names "$log")"
  unexpected="$(comm -23 <(printf '%s\n' "$actual" | grep -v '^$') <({ required_skips; optional_skips "$leg"; } | grep -v '^$' | sort -u))"
  missing="$(comm -13 <(printf '%s\n' "$actual" | grep -v '^$') <(required_skips | sort -u))"
  if [ -n "$unexpected" ]; then
    echo "   $leg: these tests skipped and should have run:"
    printf '%s\n' "$unexpected" | sed 's/^/      /'
    bad=1
  fi
  if [ -n "$missing" ]; then
    echo "   $leg: these tests were expected to skip and did not:"
    printf '%s\n' "$missing" | sed 's/^/      /'
    bad=1
  fi
  return "$bad"
}

# LIEDAR_GOLDEN_OUT makes the two golden tests overwrite Goldens/ and skip instead of comparing.
# That is a deliberate regeneration step, not a test run, and it must never be what this script
# reports on.
if [ -n "${LIEDAR_GOLDEN_OUT:-}" ]; then
  echo "RESULT: BLOCKED LIEDAR_GOLDEN_OUT=$LIEDAR_GOLDEN_OUT is set, which would rewrite Tests/LieDARTests/Goldens and skip both golden tests. Unset it to test; regenerate a golden with swift test --filter directly, on purpose"
  exit 2
fi

# Layout-parity tests read a consumer capture that lives outside the repo. Point the tests at it
# only when it is really there; otherwise they skip with a named reason.
PARITY_CANDIDATE="${LIEDAR_PARITY_CAPTURE:-$HOME/git/meshwise/samples/full}"
if [ -f "$PARITY_CANDIDATE/capture.json" ]; then
  export LIEDAR_PARITY_CAPTURE="$PARITY_CANDIDATE"
  echo "== parity capture: $LIEDAR_PARITY_CAPTURE =="
else
  unset LIEDAR_PARITY_CAPTURE
  echo "== parity capture: none (LayoutParityTests will skip) =="
fi

echo "== xcode =="; xcodebuild -version | tr '\n' ' '; echo
swift --version 2>&1 | head -1 | sed 's/^/   /'

echo "== 1/3 swift build -Xswiftc -warnings-as-errors (macOS) =="
with_deadline swift build -Xswiftc -warnings-as-errors > "$LOGDIR/build.log" 2>&1
rc=$?
if [ "$rc" -eq 142 ]; then echo "RESULT: BLOCKED macOS build TIMEOUT after ${TIMEOUT}s (log: $LOGDIR/build.log)"; exit 2; fi
if [ "$rc" -ne 0 ]; then grep -E 'error:|warning:' "$LOGDIR/build.log" | head -20 | sed 's/^/   /'; echo "RESULT: FAIL macOS build exit $rc (log: $LOGDIR/build.log)"; exit 1; fi
echo "   build clean (exit 0, $(grep -c 'warning:' "$LOGDIR/build.log") warnings)"

echo "== 2/3 swift test (macOS) =="
with_deadline swift test > "$LOGDIR/swift-test.log" 2>&1
rc=$?
if [ "$rc" -eq 142 ]; then echo "RESULT: BLOCKED macOS swift test TIMEOUT after ${TIMEOUT}s (log: $LOGDIR/swift-test.log)"; exit 2; fi
read -r mac_total mac_failed <<< "$(counts "$LOGDIR/swift-test.log")"
mac_skipped=$(skips "$LOGDIR/swift-test.log")
if [ "$rc" -ne 0 ] || [ -z "${mac_total:-}" ] || [ "${mac_failed:-1}" -ne 0 ]; then
  grep -E 'error:|failed|XCTAssert' "$LOGDIR/swift-test.log" | head -20 | sed 's/^/   /'
  echo "RESULT: FAIL macOS swift test exit $rc, ${mac_total:-?} tests, ${mac_failed:-?} failures (log: $LOGDIR/swift-test.log)"
  exit 1
fi
echo "   macOS: $mac_total tests, $mac_failed failures, $mac_skipped skipped"
if ! assert_skips macOS "$LOGDIR/swift-test.log"; then
  echo "RESULT: FAIL macOS $mac_total tests, 0 failures, but the skips are not the expected set (log: $LOGDIR/swift-test.log)"
  exit 1
fi

if [ "${LIEDAR_SKIP_SIMULATOR:-0}" = "1" ]; then
  echo "RESULT: PASS macOS $mac_total tests/$mac_failed failures/$mac_skipped skipped (the expected set); simulator leg skipped by LIEDAR_SKIP_SIMULATOR"
  exit 0
fi

echo "== 3/3 xcodebuild test (iOS Simulator) =="
TYPE="${LIEDAR_DEVICE_TYPE:-}"
if [ -z "$TYPE" ]; then
  TYPE="$(xcrun simctl list devicetypes | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-1[5-9]-Pro(-Max)?' | sort -V | tail -1)"
fi
[ -n "$TYPE" ] || { echo "RESULT: BLOCKED no iPhone 15+ Pro device type on this machine"; exit 2; }
RUNTIME="$(xcrun simctl list runtimes | grep -E '^iOS' | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+' | sort -V | tail -1)"
[ -n "$RUNTIME" ] || { echo "RESULT: BLOCKED no iOS simulator runtime installed"; exit 2; }
UDID="$(xcrun simctl create "$NAME" "$TYPE" "$RUNTIME" 2>"$LOGDIR/create.err" | tail -1)"
[ -n "$UDID" ] || { cat "$LOGDIR/create.err" | sed 's/^/   /'; echo "RESULT: BLOCKED simctl create failed for $TYPE / $RUNTIME"; exit 2; }
echo "   created $NAME ($TYPE, $RUNTIME) $UDID"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || { echo "RESULT: BLOCKED simctl boot failed for $UDID"; exit 2; }
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || { echo "RESULT: BLOCKED simulator $UDID never reported booted"; exit 2; }

# xcodebuild forwards TEST_RUNNER_* variables to the test process with the prefix stripped.
PARITY_ENV=()
if [ -n "${LIEDAR_PARITY_CAPTURE:-}" ]; then PARITY_ENV=("TEST_RUNNER_LIEDAR_PARITY_CAPTURE=$LIEDAR_PARITY_CAPTURE"); fi
with_deadline env ${PARITY_ENV[@]+"${PARITY_ENV[@]}"} xcodebuild test -scheme LieDAR-Package -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$LOGDIR/DerivedData" -parallel-testing-enabled NO > "$LOGDIR/xcodebuild.log" 2>&1
rc=$?
if [ "$rc" -eq 142 ]; then echo "RESULT: BLOCKED simulator xcodebuild test TIMEOUT after ${TIMEOUT}s (log: $LOGDIR/xcodebuild.log)"; exit 2; fi
read -r sim_total sim_failed <<< "$(counts "$LOGDIR/xcodebuild.log")"
sim_skipped=$(skips "$LOGDIR/xcodebuild.log")
if grep -q 'no Metal device' "$LOGDIR/xcodebuild.log"; then echo "   simulator: MetalAvailabilityTests skipped: no Metal device"; fi
if [ "$rc" -ne 0 ] || [ -z "${sim_total:-}" ] || [ "${sim_failed:-1}" -ne 0 ]; then
  grep -E 'error:|failed|\*\* TEST' "$LOGDIR/xcodebuild.log" | head -20 | sed 's/^/   /'
  echo "RESULT: FAIL simulator xcodebuild test exit $rc, ${sim_total:-?} tests, ${sim_failed:-?} failures (log: $LOGDIR/xcodebuild.log)"
  exit 1
fi
echo "   simulator: $sim_total tests, $sim_failed failures, $sim_skipped skipped"
if ! assert_skips simulator "$LOGDIR/xcodebuild.log"; then
  echo "RESULT: FAIL simulator $sim_total tests, 0 failures, but the skips are not the expected set (log: $LOGDIR/xcodebuild.log)"
  exit 1
fi

echo "RESULT: PASS macOS $mac_total tests/$mac_failed failures/$mac_skipped skipped; simulator $sim_total tests/$sim_failed failures/$sim_skipped skipped ($TYPE); skips are the expected set on both legs"
exit 0
