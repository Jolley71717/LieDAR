#!/usr/bin/env bash
# timing_check.sh: assert the raycaster's release-build frame time, outside the default suite.
#
# RaycasterTests/testRenderTimeIsWithinBudget is a wall-clock test: it skips unless
# LIEDAR_ASSERT_TIMING=1 is set, so a loaded CI runner cannot fail a correctness run. This script
# sets the variable and runs that one test in a release build (`-c release`, with
# `-enable-testing` so `@testable import` still resolves), where the budget is 20 ms per
# 256 × 192 frame (PLAN, RT-9). The test also demands that the timed frames actually hit the
# room (> 0 hits, ≥ 99 % of pixels), so a raycaster that returns nothing cannot post a fast time.
#
# Usage: tools/timing_check.sh          (takes no arguments; macOS `swift test`, no simulator)
# Environment: LIEDAR_TIMEOUT_SECONDS for the whole run (default 1500).
# Prints exactly one final RESULT: PASS / FAIL / BLOCKED line and exits 0 / 1 / 2.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "RESULT: BLOCKED cannot cd to $ROOT"; exit 2; }
LOGDIR="${TMPDIR:-/tmp}/liedar-timing-$$"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/timing.log"
TIMEOUT="${LIEDAR_TIMEOUT_SECONDS:-1500}"
TEST="RaycasterTests/testRenderTimeIsWithinBudget"

[ $# -eq 0 ] || { echo "RESULT: BLOCKED usage: tools/timing_check.sh (takes no arguments)"; exit 2; }
command -v swift >/dev/null || { echo "RESULT: BLOCKED swift not on PATH"; exit 2; }
case "$(uname -m)" in
  arm64) ;;
  *) echo "RESULT: BLOCKED the 20 ms budget is an arm64 (M-series) figure; this host is $(uname -m)"; exit 2 ;;
esac

echo "== swift test -c release, $TEST, LIEDAR_ASSERT_TIMING=1 =="
swift --version 2>&1 | head -1 | sed 's/^/   /'
# macOS has no GNU timeout; perl's alarm is always there. Exit 142 means the deadline hit.
LIEDAR_ASSERT_TIMING=1 perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
  swift test -c release -Xswiftc -enable-testing --filter "$TEST" > "$LOG" 2>&1
rc=$?
if [ "$rc" -eq 142 ]; then echo "RESULT: BLOCKED TIMEOUT after ${TIMEOUT}s (log: $LOG)"; exit 2; fi

TIMING="$(grep -m1 'RAYCASTER_TIMING:' "$LOG" | sed 's/^RAYCASTER_TIMING: //')"
PASSED="$(grep -c "Test Case .* passed" "$LOG" || true)"
FAILED="$(grep -c "Test Case .* failed" "$LOG" || true)"
SKIPPED="$(grep -c "Test Case .* skipped" "$LOG" || true)"
echo "   passed: $PASSED  failed: $FAILED  skipped: $SKIPPED  swift test rc=$rc  log: $LOG"
[ -n "$TIMING" ] && echo "   $TIMING"

if grep -qE '^.*error: .*(cannot find|expected|use of unresolved|value of type|missing)' "$LOG"; then
  grep -E 'error:' "$LOG" | head -5 | sed 's/^/   /'
  echo "RESULT: FAIL the release test build did not compile (log: $LOG)"; exit 1
fi
if [ "$SKIPPED" -ne 0 ]; then
  grep -m1 'Test skipped' "$LOG" | sed 's/^/   /'
  echo "RESULT: FAIL the timing test skipped although LIEDAR_ASSERT_TIMING=1 was set (log: $LOG)"; exit 1
fi
if [ "$PASSED" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
  echo "RESULT: FAIL $TEST did not run at all. Check the --filter path (log: $LOG)"; exit 1
fi
if [ "$FAILED" -ne 0 ] || [ "$rc" -ne 0 ]; then
  grep -E 'XCTAssert.*failed' "$LOG" | head -3 | sed -E 's/^.*error: -\[[^]]*\] : //' | sed 's/^/   /'
  echo "RESULT: FAIL $TEST failed in release: ${TIMING:-no RAYCASTER_TIMING line} (log: $LOG)"; exit 1
fi
if ! grep -q 'RAYCASTER_TIMING:' "$LOG"; then
  echo "RESULT: FAIL the test passed but printed no RAYCASTER_TIMING line (log: $LOG)"; exit 1
fi
MS="$(printf '%s' "$TIMING" | sed -E 's/^([0-9.]+) ms\/frame.*/\1/')"
HITS="$(printf '%s' "$TIMING" | grep -oE '[0-9]+ hits' | head -1)"
echo "RESULT: PASS raycaster $MS ms/frame in release (256×192, ceiling 20 ms), $HITS over 5 frames"
exit 0
