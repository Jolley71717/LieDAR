#!/bin/bash
# Parses every GitHub Actions workflow and lists the jobs it found.
#
# Why: a workflow GitHub cannot parse fails the whole run in zero seconds with
# no jobs and no log, which reads like an infrastructure problem and is not one.
# That has happened twice here. The second time, a plain scalar contained a
# colon followed by a space, which YAML reads as a mapping key.
#
# Ends in one RESULT: line and exits 0/1/2.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v ruby >/dev/null 2>&1 || { echo "RESULT: BLOCKED no ruby to parse YAML with"; exit 2; }

shopt -s nullglob
FILES=(.github/workflows/*.yml .github/workflows/*.yaml)
[ ${#FILES[@]} -gt 0 ] || { echo "RESULT: BLOCKED no workflow files under .github/workflows"; exit 2; }

BAD=0
for f in "${FILES[@]}"; do
  OUT="$(ruby -ryaml -e '
    d = YAML.load_file(ARGV[0])
    jobs = (d["jobs"] || {})
    abort("no jobs key") if jobs.empty?
    puts jobs.keys.join(", ")
  ' "$f" 2>&1)"
  if [ $? -ne 0 ]; then
    echo "  $f: UNPARSEABLE"
    echo "$OUT" | head -3 | sed 's/^/      /'
    BAD=$((BAD + 1))
  else
    echo "  $f: $OUT"
  fi
done

if [ "$BAD" -gt 0 ]; then
  echo "RESULT: FAIL $BAD workflow file(s) will not parse, so the run would fail with zero jobs"
  exit 1
fi
echo "RESULT: PASS ${#FILES[@]} workflow file(s) parse and declare jobs"
exit 0
