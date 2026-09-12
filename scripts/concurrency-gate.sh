#!/usr/bin/env bash
# concurrency-gate.sh — CI concurrency proof. Proves the same property the
# old local-only proof did — two concurrent full-suite
# runs each finish green with no shared-path interference — but as a GATE, not
# printed evidence, and deterministically: both runs are `wait`ed and judged on
# end state only (exit codes + RESULT lines), never wall-clock, so scheduler
# jitter under Actions cannot flake it. Per-run logs live in mktemp files (the
# old proof's fixed /tmp/conc-{a,b}.log paths were themselves a shared path).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="$(mktemp -d)" || exit 1
trap 'rm -rf "$BASE"' EXIT

( bash "$SCRIPT_DIR/stub-validation.sh" > "$BASE/a.log" 2>&1; echo "$?" > "$BASE/a.exit" ) &
( bash "$SCRIPT_DIR/stub-validation.sh" > "$BASE/b.log" 2>&1; echo "$?" > "$BASE/b.exit" ) &
wait

status=0
for s in a b; do
  echo "=== run $s ==="
  grep '^RESULT' "$BASE/$s.log" || echo "no RESULT line"
  rc="$(cat "$BASE/$s.exit" 2>/dev/null)"
  if [ ! -n "$rc" ] || [ "$rc" -ne 0 ]; then
    echo "run $s FAILED (exit ${rc:-missing — run killed before writing its exit code}) — full log:"
    cat "$BASE/$s.log"
    status=1
  else
    echo "run $s: green"
  fi
done

if [ "$status" -eq 0 ]; then
  echo "CONCURRENCY GATE: green — two parallel suites, both green, no interference"
else
  echo "CONCURRENCY GATE: red — a parallel suite run failed (see log above)"
fi
exit "$status"
