#!/usr/bin/env bash
# Concurrency proof for stub-validation.sh (t_5029f44a verification 2).
# Launches two full suites in parallel; each must report 19/19 with no
# interference. Prints both RESULT lines and any failures.
cd "$(dirname "$0")/.." || exit 1
rm -f /tmp/conc-a.log /tmp/conc-b.log
( bash scripts/stub-validation.sh > /tmp/conc-a.log 2>&1; echo "A_EXIT=$?" >> /tmp/conc-a.log ) &
A_PID=$!
( bash scripts/stub-validation.sh > /tmp/conc-b.log 2>&1; echo "B_EXIT=$?" >> /tmp/conc-b.log ) &
B_PID=$!
wait "$A_PID"
wait "$B_PID"
echo "=== A ==="
grep -E '^(RESULT|A_EXIT)' /tmp/conc-a.log
echo "=== B ==="
grep -E '^(RESULT|B_EXIT)' /tmp/conc-b.log
echo "=== A failures ==="
grep '❌' /tmp/conc-a.log || echo none
echo "=== B failures ==="
grep '❌' /tmp/conc-b.log || echo none
