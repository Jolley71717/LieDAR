#!/usr/bin/env bash
# mutation_check.sh proves the realism tests can fail.
#
# A test that passes is only evidence if it would have failed without the code it guards.
# This script mutates one line at a time (removes it, or replaces it with a broken version),
# runs the test that guards it, and demands that the test FAIL on the named assertion. Then it
# puts the line back and proves the file is byte-for-byte what it was, so a mutation cannot
# leak into a commit. (Generalised from Meshwise's tools/mutation_check_badge.sh.) Cases, each
# its own mutation and its own test:
#
#   A  remove `blocks[b].shift += translation` in AnchorChunker.applyLoopClosure
#      -> AnchorChunkerTests/testLoopClosureTranslatesEveryAnchorAtOnce must fail on
#         "loop closure translation"
#   B  remove `out[i] = MeshClassification.none.rawValue` in DegradationModel.degrade
#      (the model still runs, but relabels nothing)
#      -> DegradationTests/testUnlabelledFractionMatchesTheModelForASeed must fail on
#         "unlabelled fraction"
#   C  remove `guard moved || turned || stale else { return false }` in FrameGate.admit
#      (every normal frame is written)
#      -> SyntheticSourceTests/testThreeSecondCaptureWritesTheExpectedFolder must fail on
#         "frames written"
#   D  replace `mediumCosine: Float = 0.2` with `= 0.0` in Raycaster.ConfidenceModel.init
#      (every hit within mediumRange is at least medium; the low-by-grazing-angle band vanishes;
#      the canonical golden cannot see this, because that frame has no such pixel)
#      -> RaycasterTests/testConfidenceMatchesGoldenBytes must fail on "corridor pixel (105, 96)"
#   E  replace `seamTolerance: Float = 1e-5` with `= 0` in Raycaster (no second pass for a
#      ray on a shared edge; the tour's seam pixel reads depth 0 again)
#      -> RaycasterTests/testRayOnASharedEdgeStillHits must fail on "shared edge"
#   F  replace `let r = yv + 1.402 * cr` with `let r = yv` in JPEGEncoder (the red channel loses
#      its chroma term; every 420f colour image comes out wrong and the suite used to stay green,
#      because the only colour test fed uniform grey where Cb and Cr are both 128)
#      -> JPEGColorTests/testFourQuadrantColoursSurviveTheYCbCrConversion must fail on
#         "top left red: R at (16, 16)"
#   G  replace `mediumRange: Float = 5.0` with `= 3.5` in Raycaster.ConfidenceModel.init (the
#      medium-by-range band loses 30 % of its depth; the canonical golden cannot see this either,
#      because that frame holds no pixel between 3.5 and 5 m)
#      -> RaycasterTests/testConfidenceMatchesGoldenBytes must fail on "mid-range pixel (128, 155)"
#
# Before mutating, every guarded test is run once unmodified and must pass, so a red suite is
# reported as such rather than as a "successful" mutation.
#
# Usage: tools/mutation_check.sh          (takes no arguments; macOS `swift test`, no simulator)
# Prints exactly one final line: RESULT: PASS / FAIL / BLOCKED (exit 0 / 1 / 2).
#   PASS  = every case's test failed on its named assertion with its line mutated, and every
#           file was restored byte-identically.
#   FAIL  = a test still passed with its line mutated (it proves nothing), failed elsewhere, did
#           not compile, did not run, or a restore failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "RESULT: BLOCKED cannot cd to $ROOT"; exit 2; }
LOGDIR="${TMPDIR:-/tmp}/liedar-mutation-$$"
mkdir -p "$LOGDIR"

blocked() { echo "RESULT: BLOCKED $*"; exit 2; }
[ $# -eq 0 ] || blocked "usage: tools/mutation_check.sh (takes no arguments)"
command -v swift >/dev/null || blocked "swift not on PATH"

# file ~ exact line to mutate ~ replacement line (empty = delete the line) ~ test ~ assertion text that must appear in the failure ~ label
# (~ never occurs in a line)
CASES=(
  "Sources/LieDAR/Anchors/AnchorChunker.swift~            blocks[b].shift += translation~~AnchorChunkerTests/testLoopClosureTranslatesEveryAnchorAtOnce~loop closure translation~A: loop-closure translation"
  "Sources/LieDAR/Realism/DegradationModel.swift~                out[i] = MeshClassification.none.rawValue~~DegradationTests/testUnlabelledFractionMatchesTheModelForASeed~unlabelled fraction~B: degradation model"
  "Sources/LieDAR/Source/FrameGate.swift~            guard moved || turned || stale else { return false }~~SyntheticSourceTests/testThreeSecondCaptureWritesTheExpectedFolder~frames written~C: gating threshold"
  "Sources/LieDAR/Render/Raycaster.swift~        public init(highRange: Float = 3.0, mediumRange: Float = 5.0, highCosine: Float = 0.5, mediumCosine: Float = 0.2) {~        public init(highRange: Float = 3.0, mediumRange: Float = 5.0, highCosine: Float = 0.5, mediumCosine: Float = 0.0) {~RaycasterTests/testConfidenceMatchesGoldenBytes~corridor pixel (105, 96)~D: confidence mediumCosine 0.2 -> 0.0"
  "Sources/LieDAR/Render/Raycaster.swift~    private static let seamTolerance: Float = 1e-5~    private static let seamTolerance: Float = 0~RaycasterTests/testRayOnASharedEdgeStillHits~shared edge~E: shared-edge pass seamTolerance 1e-5 -> 0"
  "Sources/LieDAR/Recorder/JPEGEncoder.swift~                            let r = yv + 1.402 * cr~                            let r = yv~JPEGColorTests/testFourQuadrantColoursSurviveTheYCbCrConversion~top left red: R at (16, 16)~F: red channel loses its chroma term"
  "Sources/LieDAR/Render/Raycaster.swift~        public init(highRange: Float = 3.0, mediumRange: Float = 5.0, highCosine: Float = 0.5, mediumCosine: Float = 0.2) {~        public init(highRange: Float = 3.0, mediumRange: Float = 3.5, highCosine: Float = 0.5, mediumCosine: Float = 0.2) {~RaycasterTests/testConfidenceMatchesGoldenBytes~mid-range pixel (128, 155)~G: confidence mediumRange 5.0 -> 3.5"
)

# Snapshot every file up front; restore all of them on every exit path and prove it.
declare -a FILES=() BACKUPS=()
for CASE in "${CASES[@]}"; do
  FILE="${CASE%%~*}"
  [ -f "$FILE" ] || blocked "missing $FILE"
  BACKUP="$LOGDIR/$(basename "$FILE").before"
  cp "$FILE" "$BACKUP"
  FILES+=("$FILE"); BACKUPS+=("$BACKUP")
done
# Quiet on success so the RESULT: line stays last; loud (and exit 1) if a restore fails.
restore_all() {
  local i
  for i in "${!FILES[@]}"; do
    cp "${BACKUPS[$i]}" "${FILES[$i]}"
    if ! cmp -s "${BACKUPS[$i]}" "${FILES[$i]}"; then
      echo "RESTORE FAILED: ${FILES[$i]} differs from its backup ${BACKUPS[$i]}. Inspect it before committing anything"
      exit 1
    fi
  done
}
trap restore_all EXIT

# Test counts from a swift test log.
passed() { grep -c "Test Case .* passed" "$1" 2>/dev/null || true; }
failed() { grep -c "Test Case .* failed" "$1" 2>/dev/null || true; }

echo "== baseline: the guarded tests must pass unmodified =="
# One test per run: SwiftPM narrows correctly for a single --filter and not for several.
for CASE in "${CASES[@]}"; do
  REST="${CASE#*~}"; REST="${REST#*~}"; REST="${REST#*~}"; TEST="${REST%%~*}"
  swift test --filter "$TEST" > "$LOGDIR/baseline.log" 2>&1
  P="$(passed "$LOGDIR/baseline.log")"; F="$(failed "$LOGDIR/baseline.log")"
  echo "   $TEST: passed $P, failed $F"
  if [ "$P" -ne 1 ] || [ "$F" -ne 0 ]; then
    grep -E 'error:' "$LOGDIR/baseline.log" | head -5 | sed 's/^/   /'
    echo "RESULT: FAIL baseline: $TEST must pass exactly once before any mutation, got $P passed / $F failed (log: $LOGDIR/baseline.log)"
    exit 1
  fi
done

PASSED_CASES=0
for CASE in "${CASES[@]}"; do
  FILE="${CASE%%~*}"; REST="${CASE#*~}"
  LINE="${REST%%~*}"; REST="${REST#*~}"
  REPLACEMENT="${REST%%~*}"; REST="${REST#*~}"
  TEST="${REST%%~*}"; REST="${REST#*~}"
  NEEDLE="${REST%%~*}"; LABEL="${REST#*~}"
  CASELOG="$LOGDIR/case-${LABEL%%:*}.log"

  echo
  echo "== case $LABEL =="
  N="$(grep -cxF "$LINE" "$FILE")"
  [ "$N" -eq 1 ] || { echo "RESULT: FAIL expected exactly one line '$(echo "$LINE" | sed 's/^ *//')' in $FILE, found $N. Script needs updating"; exit 1; }
  LINENO_IN_FILE="$(grep -nxF "$LINE" "$FILE" | cut -d: -f1)"

  if [ -z "$REPLACEMENT" ]; then
    echo "   removing '$(echo "$LINE" | sed 's/^ *//')' from $FILE"
    awk -v n="$LINENO_IN_FILE" 'NR != n' "$FILE" > "$FILE.mutated" && mv "$FILE.mutated" "$FILE"
    [ "$(grep -cxF "$LINE" "$FILE")" -eq 0 ] || { echo "RESULT: FAIL mutation did not apply to $FILE"; exit 1; }
    echo "   running $TEST WITHOUT it (expecting it to fail)"
  else
    echo "   replacing '$(echo "$LINE" | sed 's/^ *//')'"
    echo "        with '$(echo "$REPLACEMENT" | sed 's/^ *//')' in $FILE"
    # awk -v would interpret backslashes in the replacement; neither case text has any, and
    # the ENVIRON route keeps it literal regardless.
    REPL="$REPLACEMENT" awk -v n="$LINENO_IN_FILE" 'NR == n { print ENVIRON["REPL"]; next } { print }' "$FILE" > "$FILE.mutated" \
      && mv "$FILE.mutated" "$FILE"
    [ "$(grep -cxF "$LINE" "$FILE")" -eq 0 ] && [ "$(grep -cxF "$REPLACEMENT" "$FILE")" -eq 1 ] \
      || { echo "RESULT: FAIL mutation did not apply to $FILE"; exit 1; }
    echo "   running $TEST WITH the broken line (expecting it to fail)"
  fi
  swift test --filter "$TEST" > "$CASELOG" 2>&1
  RC=$?
  P="$(passed "$CASELOG")"; F="$(failed "$CASELOG")"
  echo "   passed: $P  failed: $F  swift test rc=$RC  log: $CASELOG"

  if grep -qE "error: (cannot find|expected|use of unresolved|value of type|missing)" "$CASELOG"; then
    grep -E "error:" "$CASELOG" | head -5 | sed 's/^/   /'
    echo "RESULT: FAIL case $LABEL: the mutated build did not compile. A build error, not a test verdict"; exit 1
  fi
  if [ "$P" -eq 0 ] && [ "$F" -eq 0 ]; then
    echo "RESULT: FAIL case $LABEL: the test did not run at all. Check the --filter path"; exit 1
  fi
  if [ "$F" -eq 0 ]; then
    echo "RESULT: FAIL case $LABEL: the test PASSED with the line removed, so it cannot detect this bug"; exit 1
  fi
  if ! grep -q "$NEEDLE" "$CASELOG"; then
    grep -E "XCTAssert.*failed" "$CASELOG" | head -3 | sed 's/^/   /'
    echo "RESULT: FAIL case $LABEL: the test failed, but not on the '$NEEDLE' assertion"; exit 1
  fi
  echo "   failed on: $(grep -m1 "$NEEDLE" "$CASELOG" | sed -E 's/^.*error: -\[[^]]*\] : //' | cut -c1-140)"
  echo "   case $LABEL proven"
  PASSED_CASES=$((PASSED_CASES + 1))

  # Put the line back before the next case so each mutation is applied alone.
  for i in "${!FILES[@]}"; do [ "${FILES[$i]}" = "$FILE" ] && cp "${BACKUPS[$i]}" "$FILE"; done
done

trap - EXIT
restore_all
echo
echo "   (all ${#FILES[@]} files restored, byte-identical to before)"
echo "RESULT: PASS $PASSED_CASES/${#CASES[@]} tests fail on their named assertion when their line is mutated, files restored"
exit 0
