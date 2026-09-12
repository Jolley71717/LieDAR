#!/usr/bin/env bash
# make_fixture.sh <seed> — write Fixtures/synthetic-<seed>/ from the parametric room + scripted camera.
#
# Runs `liedar-fixture` (Sources/LieDARFixtureTool, a thin command line over
# SyntheticCaptureSource + ScriptedCapture + CaptureRecorder): RoomSpec.random(seed), a 3 s tour
# at 30 Hz, depth 48 × 36, no colour, the suite's default degradation (30 % unlabelled) and a
# loop closure at 2.25 s. Dates and device strings are fixed synthetic values, so the output is a
# pure function of the seed: the script generates twice and demands byte-identical folders.
#
# Fails when the folder exceeds LIEDAR_FIXTURE_MAX_KB (default 300) so a committed fixture stays
# small; run tools/fixture_audit.sh afterwards for the privacy rules.
#
# Usage: tools/make_fixture.sh <seed>        (LIEDAR_FIXTURE_SECONDS, LIEDAR_FIXTURE_DEPTH=WxH override the tour)
# Prints exactly one final RESULT: PASS / FAIL / BLOCKED line; exits 0 / 1 / 2.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "RESULT: BLOCKED cannot cd to $ROOT"; exit 2; }

[ $# -eq 1 ] || { echo "RESULT: BLOCKED usage: tools/make_fixture.sh <seed>"; exit 2; }
SEED="$1"
case "$SEED" in ''|*[!0-9]*) echo "RESULT: BLOCKED seed must be a non-negative integer, got '$SEED'"; exit 2 ;; esac
OUT="$ROOT/Fixtures/synthetic-$SEED"
SECONDS_ARG="${LIEDAR_FIXTURE_SECONDS:-3}"
DEPTH_ARG="${LIEDAR_FIXTURE_DEPTH:-48x36}"
MAX_KB="${LIEDAR_FIXTURE_MAX_KB:-300}"
LOGDIR="${TMPDIR:-/tmp}/liedar-fixture-$$"
mkdir -p "$LOGDIR"

echo "== build liedar-fixture (release) =="
swift build -c release --product liedar-fixture > "$LOGDIR/build.log" 2>&1 \
  || { grep -E 'error' "$LOGDIR/build.log" | head -5 | sed 's/^/   /'; echo "RESULT: FAIL swift build failed (log: $LOGDIR/build.log)"; exit 1; }
BIN="$(swift build -c release --show-bin-path 2>/dev/null)/liedar-fixture"
[ -x "$BIN" ] || { echo "RESULT: BLOCKED built binary not found at $BIN"; exit 2; }

folder_bytes() { find "$1" -type f -print0 | xargs -0 stat -f '%z' | awk '{ s += $1 } END { print s + 0 }'; }

echo "== generate seed $SEED ($SECONDS_ARG s, depth $DEPTH_ARG) =="
"$BIN" --seed "$SEED" --out "$OUT" --seconds "$SECONDS_ARG" --depth "$DEPTH_ARG" > "$LOGDIR/run1.log" 2>&1 \
  || { cat "$LOGDIR/run1.log" | sed 's/^/   /'; echo "RESULT: FAIL liedar-fixture failed for seed $SEED (log: $LOGDIR/run1.log)"; exit 1; }
sed 's/^/   /' "$LOGDIR/run1.log"

echo "== generate again to a scratch folder and compare =="
"$BIN" --seed "$SEED" --out "$LOGDIR/again" --seconds "$SECONDS_ARG" --depth "$DEPTH_ARG" > "$LOGDIR/run2.log" 2>&1 \
  || { echo "RESULT: FAIL second generation failed (log: $LOGDIR/run2.log)"; exit 1; }
if ! diff -rq "$OUT" "$LOGDIR/again" > "$LOGDIR/diff.log" 2>&1; then
  head -5 "$LOGDIR/diff.log" | sed 's/^/   /'
  echo "RESULT: FAIL seed $SEED is not deterministic: two runs differ (see $LOGDIR/diff.log)"
  exit 1
fi
echo "   two runs byte-identical"

FILES="$(find "$OUT" -type f | wc -l | tr -d ' ')"
BYTES="$(folder_bytes "$OUT")"
FRAMES="$(find "$OUT/frames" -name '*.json' | wc -l | tr -d ' ')"
ANCHORS="$(find "$OUT/mesh" -name '*.vertices' | wc -l | tr -d ' ')"
KB=$(( (BYTES + 1023) / 1024 ))
echo "   $OUT: $FILES files, $BYTES bytes ($KB KB), $FRAMES frames, $ANCHORS anchors"
[ -f "$OUT/capture.json" ] || { echo "RESULT: FAIL no capture.json in $OUT"; exit 1; }
[ "$FRAMES" -gt 0 ] || { echo "RESULT: FAIL no complete frames were written"; exit 1; }
[ "$ANCHORS" -gt 0 ] || { echo "RESULT: FAIL no anchors were written"; exit 1; }
if [ "$KB" -ge "$MAX_KB" ]; then
  echo "RESULT: FAIL fixture is $KB KB, limit $MAX_KB KB — shorten the tour or the depth map"
  exit 1
fi
rm -rf "$LOGDIR"
echo "RESULT: PASS Fixtures/synthetic-$SEED: $FRAMES frames, $ANCHORS anchors, $FILES files, $BYTES bytes ($KB KB < $MAX_KB KB), deterministic"
exit 0
