#!/usr/bin/env bash
# journey_mutation.sh proves journey 1 is load-bearing.
#
# Meshwise's Card 17 pattern, applied to the Example app. Remove the ONE line that publishes a
# finished capture to the home list, demand journey 1 fail on its named assertion, restore the
# file byte-identical, and demand journey 1 pass again. A journey that still passes with the save
# signal gone proves nothing, and that is the failure this script is here to find.
#
# Prints exactly one final RESULT: PASS / FAIL / BLOCKED line; exits 0 / 1 / 2.
#
# Environment: LIEDAR_TIMEOUT_SECONDS is forwarded to tools/journeys.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "RESULT: BLOCKED cannot cd to $ROOT"; exit 2; }

TARGET_REL="Example/ExampleApp/CaptureStore.swift"
TARGET="$ROOT/$TARGET_REL"
# The save signal. Also named in a comment directly above it in the source.
SIGNAL='captures.insert(capture, at: 0)'
JOURNEY="JourneyTests/testCaptureSavesARowWithSizeAndFiles"
# The assertion message the mutated run must fail on. Not "it failed somehow", this one.
EXPECTED_ASSERTION='Stop & Save did not add a row to the list'

WORK="${TMPDIR:-/tmp}/liedar-journey-mutation-$$"
mkdir -p "$WORK"
BACKUP="$WORK/CaptureStore.swift.orig"
restored=0

restore() {
  if [ "$restored" -eq 0 ] && [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$TARGET"
    restored=1
    echo "   (restored $TARGET_REL)"
  fi
}
trap restore EXIT

[ -f "$TARGET" ] || { echo "RESULT: BLOCKED no $TARGET_REL"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "RESULT: BLOCKED git not on PATH"; exit 2; }

# An uncommitted target makes "git diff --stat is empty" meaningless as a restoration proof.
if [ -n "$(git -C "$ROOT" status --porcelain -- "$TARGET_REL")" ]; then
  echo "   git status: $(git -C "$ROOT" status --porcelain -- "$TARGET_REL")"
  echo "RESULT: BLOCKED $TARGET_REL has uncommitted changes; commit them first so restoration can be proven"
  exit 2
fi

grep -qF "$SIGNAL" "$TARGET" || { echo "RESULT: BLOCKED the save signal '$SIGNAL' is not in $TARGET_REL"; exit 2; }
BEFORE_SHA="$(shasum -a 256 "$TARGET" | awk '{print $1}')"
cp "$TARGET" "$BACKUP"
echo "== target =="
echo "   $TARGET_REL"
echo "   signal: $SIGNAL"
echo "   sha256 before: $BEFORE_SHA"

echo "== 1/2 removing the save signal and running $JOURNEY =="
grep -vF "$SIGNAL" "$BACKUP" > "$TARGET"
if grep -qF "$SIGNAL" "$TARGET"; then echo "RESULT: BLOCKED could not remove the save signal"; exit 2; fi
echo "   removed 1 line ($(wc -l < "$BACKUP" | tr -d ' ') -> $(wc -l < "$TARGET" | tr -d ' ') lines)"

MUTATED_LOG="$WORK/mutated.log"
LIEDAR_JOURNEY_ONLY="$JOURNEY" LIEDAR_JOURNEY_RETRY=0 LIEDAR_JOURNEY_LOG="$MUTATED_LOG" \
  bash "$ROOT/tools/journeys.sh" > "$WORK/mutated-journeys.out" 2>&1
mutated_rc=$?
mutated_result="$(grep -E "^RESULT: " "$WORK/mutated-journeys.out" | tail -1)"
echo "   journeys.sh exit $mutated_rc: $mutated_result"

restore
AFTER_SHA="$(shasum -a 256 "$TARGET" | awk '{print $1}')"
DIFFSTAT="$(git -C "$ROOT" diff --stat -- "$TARGET_REL")"
echo "== restoration =="
echo "   sha256 after:  $AFTER_SHA"
echo "   git diff --stat -- $TARGET_REL: ${DIFFSTAT:-(no change)}"
if [ "$BEFORE_SHA" != "$AFTER_SHA" ] || [ -n "$DIFFSTAT" ]; then
  echo "RESULT: FAIL $TARGET_REL was not restored byte-identical"
  exit 1
fi

if [ "$mutated_rc" -eq 2 ]; then
  echo "RESULT: BLOCKED the mutated run could not execute: $mutated_result"
  exit 2
fi
if [ "$mutated_rc" -eq 0 ]; then
  echo "RESULT: FAIL 0/1 journey 1 passed with the save signal removed, so it does not test the save path"
  exit 1
fi
if [ ! -f "$MUTATED_LOG" ]; then
  sed 's/^/      /' "$WORK/mutated-journeys.out"
  echo "RESULT: BLOCKED the mutated run produced no test log: $mutated_result"
  exit 2
fi
if ! grep -qF "$EXPECTED_ASSERTION" "$MUTATED_LOG"; then
  echo "   the mutated run failed, but not on the expected assertion. What it said:"
  grep -E 'XCTAssert|error:' "$MUTATED_LOG" | head -10 | sed 's/^/      /'
  echo "RESULT: FAIL journey 1 failed for the wrong reason; expected: $EXPECTED_ASSERTION"
  exit 1
fi
echo "   failed on the expected assertion:"
grep -F "$EXPECTED_ASSERTION" "$MUTATED_LOG" | head -2 | sed 's/^/      /'

echo "== 2/2 re-running $JOURNEY against the restored file =="
RESTORED_LOG="$WORK/restored.log"
LIEDAR_JOURNEY_ONLY="$JOURNEY" LIEDAR_JOURNEY_LOG="$RESTORED_LOG" \
  bash "$ROOT/tools/journeys.sh" > "$WORK/restored-journeys.out" 2>&1
restored_rc=$?
restored_result="$(grep -E "^RESULT: " "$WORK/restored-journeys.out" | tail -1)"
echo "   journeys.sh exit $restored_rc: $restored_result"
if [ "$restored_rc" -ne 0 ]; then
  grep -E 'XCTAssert|error:' "$RESTORED_LOG" | head -10 | sed 's/^/      /'
  echo "RESULT: FAIL journey 1 does not pass against the restored file (exit $restored_rc)"
  exit 1
fi

echo "RESULT: PASS 1/1 removing '$SIGNAL' fails journey 1 on its named assertion; restored byte-identical (sha256 $AFTER_SHA)"
exit 0
