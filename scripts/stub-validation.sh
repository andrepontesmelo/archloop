#!/usr/bin/env bash
# stub-validation.sh — archloop run.sh stub dry-run suite (zero quota).
# Exercises the full state machine with a stub opencode binary:
# preflight -> scan -> implement -> gate -> merge -> push -> cleanup.
# 19 assertions across 5 scenarios. Run: bash stub-validation.sh
# Lives in this repo (scripts/) — the skill references it, it is NOT a skill.
# Concurrency-safe since 2026-08-12 (t_5029f44a): every run owns a unique
# mktemp -d dir (STUB_DIR); scratch, remote, worktrees and logs all live under
# it, so parallel runs never collide on shared paths (the old fixed
# /tmp/archloop-scratch + /tmp/archloop-remote raced under the 3-repo nightly
# launcher: one run's fresh_clone rm -rf destroyed another's scratch/remote).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="${ARCHLOOP_RUN:-$SCRIPT_DIR/../run.sh}"
[ -f "$RUN" ] || { echo "ABORT: run.sh not found at $RUN (set ARCHLOOP_RUN)"; exit 1; }
STUB_DIR="$(mktemp -d)"
STUB="$STUB_DIR/stub-opencode"
# Unique per run (STUB_DIR is a fresh mktemp -d) — never shared /tmp paths.
# WT_BASE is a sibling of the repo dir: run.sh's stale-worktree prune filters
# worktrees by WORKTREE_BASE prefix, and putting the base above the repo would
# match the main checkout too (it did — t_5029f44a test 5).
SCRATCH="$STUB_DIR/scratch"
REMOTE="$STUB_DIR/remote"
WT_BASE="$STUB_DIR/wt"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Test stub for opencode: drives verdict files + makes a real commit on the
# archloop branch so the merge stage has work to merge. Zero quota cost.
# Env (set by stub-validation.sh): STUB_GATE_VERDICT (default SHIP — set PARK
# to test the park path), STUB_SCRATCH (canonical checkout), STUB_WT_BASE
# (worktree base dir; worktrees are $STUB_WT_BASE/scratch-night-*).
[ -n "${STUB_SCRATCH:-}" ] || { echo "stub: STUB_SCRATCH not set" >&2; exit 1; }
[ -n "${STUB_WT_BASE:-}" ] || { echo "stub: STUB_WT_BASE not set" >&2; exit 1; }
WORK="$(printf '%s' "$*" | grep -oE "$STUB_SCRATCH/\.archloop/night-[0-9-]+" | head -1)"
WT="$(ls -dt "$STUB_WT_BASE"/*-night-* 2>/dev/null | head -1)"
[ -n "$WORK" ] || { echo "stub: no WORK path in args" >&2; exit 1; }
[ -n "$WT" ] || { echo "stub: no worktree under $STUB_WT_BASE" >&2; exit 1; }
case "$*" in
  *"scan-plan"*)
    if [ "${STUB_SCAN_VERDICT:-PLANNED}" = "NONE" ]; then
      printf 'NONE\n' > "$WORK/verdict"
    else
      printf '## Item: test-item\n\n## Item: test-item2\n' > "$WORK/plan.md"
      printf 'PLANNED\n' > "$WORK/verdict"
    fi
    ;;
  *"i1-implement"*)
    printf 'change\n' >> "$WT/f.txt"
    git -C "$WT" add f.txt
    git -C "$WT" commit -qm "archloop: test-item"
    printf 'DONE\n' > "$WORK/verdict"
    ;;
  *"i1-gate"*)
    printf '%s\n' "${STUB_GATE_VERDICT:-SHIP}" > "$WORK/verdict"
    ;;
  *)
    printf 'FAILED\n' > "$WORK/verdict"
    ;;
esac
exit 0
STUBEOF
chmod +x "$STUB"

fresh_clone() {
  # leave any deleted-cwd state behind before rm -rf below (run_loop cd's in)
  cd "$SCRIPT_DIR" || exit 1
  rm -rf "$SCRATCH" "$REMOTE" "$WT_BASE"/scratch-night-* 2>/dev/null
  mkdir -p "$WT_BASE"
  git init -q -b main "$REMOTE" --bare
  git clone -q "$REMOTE" "$SCRATCH"
  cd "$SCRATCH" || exit 1
  git config user.email t@t && git config user.name t
  echo a > f.txt && mkdir -p a b && cp f.txt a/ && cp f.txt b/ && git add . && git commit -qm init
  git push -q origin main
}

run_loop() { # $1=extra env assignments (optional)
  cd "$SCRATCH" || exit 1
  # ARCHLOOP_WORKTREE_BASE=$WT_BASE keeps worktrees per-run (basename of
  # $SCRATCH is always "scratch", so the default $HOME/.cache/archloop base
  # would collide across parallel runs). Stub gets its paths via env too.
  env ARCHLOOP_OPENCODE="$STUB" ARCHLOOP_TEST_CMD=true ARCHLOOP_LINT_CMD=true \
      ARCHLOOP_MAX_ITEMS=1 ARCHLOOP_WORKTREE_BASE="$WT_BASE" \
      STUB_SCRATCH="$SCRATCH" STUB_WT_BASE="$WT_BASE" $1 \
      bash "$RUN" "$SCRATCH" > "$STUB_DIR/test-run.log" 2>&1
  echo "exit=$?"
}

echo "== Test 1: happy path (PLANNED -> DONE -> SHIP -> merge -> push -> cleanup) =="
fresh_clone
run_loop ""
check "$(git -C "$SCRATCH" status --porcelain)" "" "canonical checkout stays clean"
check "$(git -C "$SCRATCH" branch --show-current)" "main" "canonical never leaves main"
check "$(ls -d "$WT_BASE"/scratch-night-* 2>/dev/null | wc -l)" "0" "worktree removed at end"
check "$(git -C "$SCRATCH" branch --list 'archloop/*' | wc -l)" "1" "branch survives worktree removal"
check "$(git -C "$SCRATCH" log --oneline -1 | grep -c 'archloop: merge night-')" "1" "merge --no-ff commit on main"
check "$(git -C "$REMOTE" log --oneline main -1 | grep -c 'archloop: merge night-')" "1" "push reached remote main"
REPORT="$(ls "$SCRATCH"/.archloop/night-*/REPORT.md)"
check "$(grep -c '\*\*merge\*\*' "$REPORT")" "1" "REPORT has merge line"
check "$(grep -c '\*\*push\*\*' "$REPORT")" "1" "REPORT has push line"

echo "== Test 2: dirty canonical aborts, no worktree =="
fresh_clone
echo junk >> "$SCRATCH/f.txt"
run_loop ""
check "$(grep -c 'ABORT: dirty tree' "$STUB_DIR/test-run.log")" "1" "aborts on dirty tree"
check "$(ls -d "$WT_BASE"/scratch-night-* 2>/dev/null | wc -l)" "0" "no worktree created"

echo "== Test 3: wrong branch aborts =="
fresh_clone
git -C "$SCRATCH" checkout -qb feature
run_loop ""
check "$(grep -c 'ABORT: must run on main' "$STUB_DIR/test-run.log")" "1" "aborts off main"
check "$(git -C "$SCRATCH" branch --show-current)" "feature" "canonical branch untouched"

echo "== Test 4: gate parks -> no merge =="
fresh_clone
run_loop "STUB_GATE_VERDICT=PARK"
check "$(git -C "$SCRATCH" log --oneline main -1 | grep -c 'archloop: merge')" "0" "no merge commit when nothing shipped"
check "$(grep -c 'nothing shipped; no merge' "$SCRATCH"/.archloop/night-*/REPORT.md)" "1" "REPORT says nothing shipped"
check "$(grep -c 'PARKED' "$SCRATCH"/.archloop/ledger.md)" "1" "ledger records the park"
check "$(git -C "$SCRATCH" status --porcelain)" "" "canonical still clean after park"

echo "== Test 5: stale worktree pruned at preflight =="
fresh_clone
git -C "$SCRATCH" worktree add "$WT_BASE/scratch-night-1970-01-01" -b archloop/stale HEAD >/dev/null 2>&1
check "$(ls -d "$WT_BASE"/scratch-night-* 2>/dev/null | wc -l)" "1" "stale worktree exists before run"
run_loop ""
check "$(grep -c 'prune stale worktree' "$SCRATCH"/.archloop/night-*/driver.log)" "1" "preflight prunes stale worktree"
check "$(ls -d "$WT_BASE"/scratch-night-* 2>/dev/null | wc -l)" "0" "no worktrees left after run"

echo "== Test 6: loop driver first run on a fresh repo (no .archloop dir) =="
# archloop-loop.sh must create $REPO/.archloop before its first log write and
# before run.sh's dirty-tree preflight (DEF-1). NONE scan -> loop exits 0.
# The loop driver forces its own per-attempt worktree base under the REAL home
# ($HOME/.cache/archloop/<repo-basename>-aN), so clone the repo under a unique
# basename (mktemp token) to keep parallel runs from colliding on that path.
fresh_clone
LOOP_TAG="$(basename "$STUB_DIR")"
LOOP_REPO="$STUB_DIR/$LOOP_TAG"
# The loop driver re-resolves HOME to the real user home (getent) and forces
# ARCHLOOP_WORKTREE_BASE there — the stub must look in the SAME place.
REAL_HOME="$(getent passwd "$(id -un)" | cut -d: -f6)"
LOOP_WT_BASE="$REAL_HOME/.cache/archloop/$LOOP_TAG-a1"
git clone -q "$REMOTE" "$LOOP_REPO"
cd "$LOOP_REPO" || exit 1
git config user.email t@t && git config user.name t
env ARCHLOOP_OPENCODE="$STUB" ARCHLOOP_TEST_CMD=true ARCHLOOP_LINT_CMD=true \
    ARCHLOOP_MAX_ITEMS=1 STUB_SCRATCH="$LOOP_REPO" STUB_WT_BASE="$LOOP_WT_BASE" \
    STUB_SCAN_VERDICT=NONE \
    bash "$SCRIPT_DIR/../archloop-loop.sh" "$LOOP_REPO" 1 1 > "$STUB_DIR/test-loop.log" 2>&1
loop_rc=$?
check "$loop_rc" "0" "loop exits 0 on NONE verdict"
if [ -f "$LOOP_REPO/.archloop/loop-driver.log" ]; then
  ok "loop-driver.log created on first run (no pre-existing .archloop)"
else
  bad "loop-driver.log missing — .archloop not created"
fi
check "$(grep -c 'archloop loop driver v3 start' "$LOOP_REPO/.archloop/loop-driver.log")" "1" "driver start logged"
check "$(grep -c 'scan found no Strong candidates — DONE after 1 round(s)' "$LOOP_REPO/.archloop/loop-driver.log")" "1" "NONE verdict -> DONE logged"
check "$(git -C "$LOOP_REPO" status --porcelain)" "" "repo stays clean (.archloop excluded)"
check "$(ls -d "$LOOP_WT_BASE"/*-night-* 2>/dev/null | wc -l)" "0" "worktree cleaned up"
cd "$SCRIPT_DIR" || exit 1
rm -rf "$LOOP_WT_BASE"
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
