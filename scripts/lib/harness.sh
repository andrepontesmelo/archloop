# harness.sh — the assertion contract every archloop suite shares (sourced).
# scripts/concurrency-gate.sh greps the RESULT line this file prints, so the
# format below is a machine contract: do not reword it per suite.
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
contains(){ if grep -qF -- "$1" <<<"$2"; then ok "$3"; else bad "$3 (missing '$1' in: $2)"; fi; }
lacks(){ if grep -qF -- "$1" <<<"$2"; then bad "$3 (unexpected '$1' in: $2)"; else ok "$3"; fi; }
finish(){ echo; echo "RESULT: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; }
