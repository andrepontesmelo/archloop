#!/usr/bin/env bash
# stub-validation.sh — archloop run.sh stub dry-run suite (zero quota).
# Exercises the full state machine with a stub opencode binary:
# preflight (incl. horizon doctor drift check) -> provider ping -> scan -> implement -> gate -> merge -> push ->
# cleanup. 156 assertions across 16 scenarios. Run: bash stub-validation.sh
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
. "$SCRIPT_DIR/lib/harness.sh"
. "$SCRIPT_DIR/lib/lanes.sh"
jgetv(){ python3 -c 'import json,sys; print(json.load(open(sys.argv[2]))[sys.argv[1]])' "$1" "$2"; }

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
# Model precedence probe (test 7): record the --model id actually received.
if [ -n "${STUB_MODELS:-}" ]; then
  printf '%s\n' "$(printf '%s' "$*" | sed -n 's/.*--model \([^ ]*\).*/\1/p' | head -1)" >> "$STUB_MODELS"
fi
# status.json stage probe (test 9): the stage field as seen at the START of
# each session invocation — run.sh must have refined it before we launch.
# Preflight pings are not sessions (no stage expectation) — skip them.
if [ -n "${STUB_STATUS_SNAP:-}" ] && [[ "$*" != *preflight* ]]; then
  sed -n 's/.*"stage": "\([^"]*\)".*/\1/p' "$STUB_SCRATCH/.archloop/status.json" 2>/dev/null >> "$STUB_STATUS_SNAP"
fi
# PYTHONPATH probe (test 13): the worktree must be prepended to PYTHONPATH for
# sessions too — the implementer/gate run $ARCHLOOP_TEST_CMD in-session and
# must see worktree code, not an editable install's canonical checkout.
if [ -n "${STUB_PYTHONPATH:-}" ]; then
  printf '%s\n' "${PYTHONPATH:-UNSET}" >> "$STUB_PYTHONPATH"
fi
# provider-failure probe (tests 10-12): STUB_FAIL_STAGE is a substring matched
# against the invocation args; matching invocations fail like the real provider
# does — print STUB_FAIL_MSG (unset: the observed 2026-09-23 429 line; empty:
# silent non-zero death, the no-output provider class) and exit 1 —
# STUB_FAIL_TIMES times before passing through to the normal stage behavior.
if [ -n "${STUB_FAIL_STAGE:-}" ] && [[ "$*" == *"$STUB_FAIL_STAGE"* ]]; then
  n="$(cat "$STUB_FAIL_COUNT" 2>/dev/null || echo 0)"; n=$((n + 1))
  printf '%s\n' "$n" > "$STUB_FAIL_COUNT"
  if [ "$n" -le "${STUB_FAIL_TIMES:-99}" ]; then
    msg="${STUB_FAIL_MSG-Error: Rate limit reached for requests}"
    [ -n "$msg" ] && printf '%s\n' "$msg"
    exit 1
  fi
fi
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
    # add -A mirrors the real implementer prompt ("Commit all your work"):
    # any HTML the scan left in the worktree rides this commit (test 8).
    git -C "$WT" add -A
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
# HTML-drop probe (test 8): when STUB_EMIT_HTML is set, the scan stage acts
# like the real skill — it regenerates a tracked HTML file in the worktree
# AND drops a session HTML report into the night dir. run.sh's drop_html
# postlude must remove both before any implementer commit or merge.
if [ -n "${STUB_EMIT_HTML:-}" ] && [[ "$*" == *"scan-plan"* ]]; then
  printf 'generated report\n' > "$WT/archloop-workflow.html"
  printf 'session html report\n' > "$WORK/scan-report.html"
fi
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
    STUB_SCAN_VERDICT=NONE ARCHLOOP_NIGHT_LOG="$STUB_DIR/night-6.log" \
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
check "$(jgetv trigger "$LOOP_REPO/.archloop/status.json")" "manual" "status.json trigger=manual (no night log)"
check "$(jgetv round "$LOOP_REPO/.archloop/status.json")" "1" "status.json round=1"
check "$(jgetv max_rounds "$LOOP_REPO/.archloop/status.json")" "1" "status.json max_rounds=1"
check "$(jgetv stage "$LOOP_REPO/.archloop/status.json")" "done" "status.json stage=done (scan NONE exit)"
check "$(ls "$LOOP_REPO/.archloop"/status.json.tmp.* 2>/dev/null | wc -l)" "0" "no status.json tmp leftovers (atomic rename)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["pid"]>0 and d["updated_at"]>0' "$LOOP_REPO/.archloop/status.json" \
  && ok "status.json valid JSON, pid>0, updated_at>0" || bad "status.json malformed"
cd "$SCRIPT_DIR" || exit 1
rm -rf "$LOOP_WT_BASE"

echo "== Test 7: model precedence — launch env > .archloop/config > DEFAULT_* =="
# Full scan->implement->gate flow so every role's --model is exercised; the
# stub records the ids it received in order: scan, i1-implement, i1-gate
# (spec 2, card A).
fresh_clone
# run.sh's dirty-tree preflight runs BEFORE it git-excludes .archloop/, and a
# fresh clone has no info/exclude entry yet — add it exactly as the engine
# would have on any repo that has run before, or the config file reads dirty.
printf '.archloop/\n' >> "$SCRATCH/.git/info/exclude"
mkdir -p "$SCRATCH/.archloop"
printf 'ARCHLOOP_MODEL_SCAN="cfg/scan-model"\nARCHLOOP_MODEL_IMPL="cfg/impl-model"\nARCHLOOP_MODEL_GATE="cfg/gate-model"\n' > "$SCRATCH/.archloop/config"
rm -f "$STUB_DIR/models-7a.env"
run_loop "STUB_MODELS=$STUB_DIR/models-7a.env"
# The file also records the preflight ping (same resolved scan model, one
# extra first line) — the last three invocations are the three roles.
check "$(tail -n 3 "$STUB_DIR/models-7a.env" | sed -n 1p)" "cfg/scan-model" "config model beats DEFAULT_* (scan)"
check "$(tail -n 3 "$STUB_DIR/models-7a.env" | sed -n 2p)" "cfg/impl-model" "config model beats DEFAULT_* (impl)"
check "$(tail -n 3 "$STUB_DIR/models-7a.env" | sed -n 3p)" "cfg/gate-model" "config model beats DEFAULT_* (gate)"
fresh_clone
printf '.archloop/\n' >> "$SCRATCH/.git/info/exclude"
mkdir -p "$SCRATCH/.archloop"
printf 'ARCHLOOP_MODEL_SCAN="cfg/scan-model"\nARCHLOOP_MODEL_IMPL="cfg/impl-model"\nARCHLOOP_MODEL_GATE="cfg/gate-model"\n' > "$SCRATCH/.archloop/config"
rm -f "$STUB_DIR/models-7b.env"
run_loop "STUB_MODELS=$STUB_DIR/models-7b.env ARCHLOOP_MODEL_SCAN=env/scan-model ARCHLOOP_MODEL_IMPL=env/impl-model ARCHLOOP_MODEL_GATE=env/gate-model"
check "$(tail -n 3 "$STUB_DIR/models-7b.env" | sed -n 1p)" "env/scan-model" "launch env beats config (scan)"
check "$(tail -n 3 "$STUB_DIR/models-7b.env" | sed -n 2p)" "env/impl-model" "launch env beats config (impl)"
check "$(tail -n 3 "$STUB_DIR/models-7b.env" | sed -n 3p)" "env/gate-model" "launch env beats config (gate)"
rm -f "$STUB_DIR/models-7a.env" "$STUB_DIR/models-7b.env"

echo "== Test 7b: lane policy single-source (scripts/lib/lanes.sh) =="
# The lane ids live ONLY in scripts/lib/lanes.sh: two lanes reference the
# big-lane id, and no production file outside lanes.sh hardcodes a lane id —
# the drift that forced four lockstep repoint commits (bfc8b35, 2e643f5,
# e71ed61, fc3c5c7) can no longer happen silently.
check "$(grep -c "zai/glm-5.3\b" "$SCRIPT_DIR/lib/lanes.sh")" "2" "lanes.sh: exactly two lanes reference the big-lane id"
check "$(grep -c 'zai/glm' "$SCRIPT_DIR/../run.sh")" "0" "run.sh carries no hardcoded lane id"
check "$(grep -c 'zai/glm' "$SCRIPT_DIR/../bin/archloop")" "0" "bin/archloop carries no hardcoded lane id"
check "$LANE_BIG" "zai/glm-5.3" "sourced LANE_BIG resolves"
check "$LANE_FLASH" "zai/glm-5.3-flash" "sourced LANE_FLASH resolves"

echo "== Test 8: scan-emitted HTML dropped (night dir + worktree + merge) =="
# The scan skill asks for an HTML report; run.sh must drop it. STUB_EMIT_HTML
# makes the scan stub regenerate a TRACKED archloop-workflow.html in the
# worktree (overwriting real content) and drop scan-report.html into the night
# dir. drop_html must: delete the night-dir HTML, revert the worktree HTML to
# its tracked content, and the merge must carry no HTML diff.
fresh_clone
printf 'tracked diagram\n' > "$SCRATCH/archloop-workflow.html"
git -C "$SCRATCH" add archloop-workflow.html && git -C "$SCRATCH" commit -qm "diagram"
git -C "$SCRATCH" push -q origin main
rm -f "$STUB_DIR/models-8.env"
run_loop "STUB_EMIT_HTML=$SCRATCH STUB_MODELS=$STUB_DIR/models-8.env"
NIGHT_DIR="$(ls -d "$SCRATCH"/.archloop/night-*/ | head -1)"
check "$(find "$NIGHT_DIR" -maxdepth 1 -name '*.html' | wc -l)" "0" "night dir has no HTML"
check "$(cat "$SCRATCH/archloop-workflow.html" 2>/dev/null)" "tracked diagram" "canonical HTML untouched by run"
check "$(git -C "$SCRATCH" diff HEAD~1..HEAD --name-only -- '*.html' | wc -l)" "0" "merge commit carries no HTML"
check "$(grep -c 'dropped session HTML' "$NIGHT_DIR/driver.log")" "1" "driver logs the night-dir drop"
check "$(grep -c 'scan touched HTML in worktree' "$NIGHT_DIR/driver.log")" "1" "driver logs the worktree revert"
rm -f "$STUB_DIR/models-8.env"

echo "== Test 9: status.json through a full loop (nightly trigger, stage transitions) =="
# Same recipe as test 6 but a SHIP flow (PLANNED -> DONE -> SHIP -> merge) so
# run.sh's status_stage fires at every session boundary, and a fresh START
# line in the night log so the loop self-detects trigger=nightly. The stub
# snapshots status.json's stage at each session start (STUB_STATUS_SNAP):
# the sequence must read scan-plan -> i1-implement -> i1-gate.
fresh_clone
LOOP9_TAG="$(basename "$STUB_DIR")-r9"
LOOP9_REPO="$STUB_DIR/$LOOP9_TAG"
LOOP9_WT_BASE="$REAL_HOME/.cache/archloop/$LOOP9_TAG-a1"
git clone -q "$REMOTE" "$LOOP9_REPO"
cd "$LOOP9_REPO" || exit 1
git config user.email t@t && git config user.name t
printf '%s START %s: launching loop driver\n' "$(date '+%F %T')" "$LOOP9_TAG" > "$STUB_DIR/night-9.log"
rm -f "$STUB_DIR/status-snap-9.txt"
env ARCHLOOP_OPENCODE="$STUB" ARCHLOOP_TEST_CMD=true ARCHLOOP_LINT_CMD=true \
    ARCHLOOP_MAX_ITEMS=1 STUB_SCRATCH="$LOOP9_REPO" STUB_WT_BASE="$LOOP9_WT_BASE" \
    STUB_STATUS_SNAP="$STUB_DIR/status-snap-9.txt" \
    ARCHLOOP_NIGHT_LOG="$STUB_DIR/night-9.log" \
    bash "$SCRIPT_DIR/../archloop-loop.sh" "$LOOP9_REPO" 1 1 > "$STUB_DIR/test-loop9.log" 2>&1
check "$?" "2" "loop exits 2 when MAX_ROUNDS hit (items still suggested)"
check "$(cat "$STUB_DIR/status-snap-9.txt")" "scan-plan
i1-implement
i1-gate" "stage refined at every session start (loop-written file)"
check "$(jgetv trigger "$LOOP9_REPO/.archloop/status.json")" "nightly" "status.json trigger=nightly (fresh START line)"
check "$(jgetv stage "$LOOP9_REPO/.archloop/status.json")" "done" "status.json stage=done after run complete"
check "$(jgetv round "$LOOP9_REPO/.archloop/status.json")" "1" "status.json round=1"
check "$(jgetv max_rounds "$LOOP9_REPO/.archloop/status.json")" "1" "status.json max_rounds=1"
check "$(git -C "$LOOP9_REPO" log --oneline -1 | grep -c 'archloop: merge night-')" "1" "full loop path merged into main"
# ARCHLOOP_TRIGGER (what `archloop start` exports) beats self-detection even
# against a fresh nightly START line in the night log.
printf '%s START %s: launching loop driver\n' "$(date '+%F %T')" "$LOOP9_TAG" > "$STUB_DIR/night-9.log"
env ARCHLOOP_OPENCODE="$STUB" ARCHLOOP_TEST_CMD=true ARCHLOOP_LINT_CMD=true \
    ARCHLOOP_MAX_ITEMS=1 STUB_SCRATCH="$LOOP9_REPO" STUB_WT_BASE="$LOOP9_WT_BASE" \
    ARCHLOOP_TRIGGER=manual ARCHLOOP_NIGHT_LOG="$STUB_DIR/night-9.log" \
    STUB_SCAN_VERDICT=NONE \
    bash "$SCRIPT_DIR/../archloop-loop.sh" "$LOOP9_REPO" 1 1 > "$STUB_DIR/test-loop9b.log" 2>&1
check "$?" "0" "second loop run (scan NONE) exits 0"
check "$(jgetv trigger "$LOOP9_REPO/.archloop/status.json")" "manual" "ARCHLOOP_TRIGGER=manual beats fresh nightly START line"
check "$(jgetv stage "$LOOP9_REPO/.archloop/status.json")" "done" "status.json stage=done after NONE round"
cd "$SCRIPT_DIR" || exit 1
rm -rf "$LOOP9_WT_BASE"

echo "== Test 10: provider preflight ping — dead provider aborts before the scan =="
# 2026-09-23: two repos died 6s apart on provider 429s — each burned a scan
# session before the driver aborted on verdict MISSING. run.sh must ping the
# resolved scan model first; on double failure abort with a one-line reason
# and WITHOUT launching the scan session.
fresh_clone
rm -f "$STUB_DIR/models-10.env"
check "$(run_loop "STUB_MODELS=$STUB_DIR/models-10.env STUB_FAIL_STAGE=preflight STUB_FAIL_COUNT=$STUB_DIR/failcount-10.env ARCHLOOP_RETRY_BACKOFF=1")" "exit=1" "dead provider: preflight aborts the run"
check "$(grep -c 'ABORT: provider preflight failed:' "$SCRATCH"/.archloop/night-*/driver.log)" "1" "one-line abort reason in driver.log"
check "$(grep -c 'provider preflight ping failed (exit 1)' "$SCRATCH"/.archloop/night-*/driver.log)" "2" "ping retried once (two failures logged)"
check "$(grep -c 'session start: scan-plan' "$SCRATCH"/.archloop/night-*/driver.log)" "0" "scan session never launched — night not burned"
check "$(wc -l < "$STUB_DIR/models-10.env")" "2" "exactly two ping invocations"
check "$(sed -n 1p "$STUB_DIR/models-10.env")" "$LANE_BIG" "ping uses the resolved scan model"

echo "== Test 11: provider-class session failure — retry once, real re-run, failover model =="
fresh_clone
rm -f "$STUB_DIR/models-11.env"
check "$(run_loop "STUB_MODELS=$STUB_DIR/models-11.env STUB_FAIL_STAGE=scan-plan STUB_FAIL_TIMES=1 STUB_FAIL_COUNT=$STUB_DIR/failcount-11.env ARCHLOOP_MODEL_FALLBACK=fb/model ARCHLOOP_RETRY_BACKOFF=1")" "exit=0" "run completes after provider retry (429 on scan attempt 1)"
check "$(grep -c 'provider-class failure' "$SCRATCH"/.archloop/night-*/driver.log)" "1" "provider-class failure detected and logged"
check "$(grep -c 'session start: scan-plan' "$SCRATCH"/.archloop/night-*/driver.log)" "2" "retry is a real re-run: two scan sessions"
check "$(sed -n 2p "$STUB_DIR/models-11.env")" "$LANE_BIG" "attempt 1 ran on the scan model"
check "$(sed -n 3p "$STUB_DIR/models-11.env")" "fb/model" "attempt 2 ran on ARCHLOOP_MODEL_FALLBACK"
check "$(sed -n 4p "$STUB_DIR/models-11.env")" "$LANE_BIG" "later stages keep their own models"
ls "$SCRATCH"/.archloop/night-*/scan-plan.log.provider-failed >/dev/null 2>&1 \
  && ok "failed attempt's log kept for the morning audit" || bad "provider-failed log missing"

echo "== Test 12: non-provider failure keeps today's abort semantics; silent death is provider-class =="
fresh_clone
check "$(run_loop "STUB_FAIL_STAGE=scan-plan STUB_FAIL_MSG=nonprovider-refused STUB_FAIL_COUNT=$STUB_DIR/failcount-12a.env ARCHLOOP_RETRY_BACKOFF=1")" "exit=1" "non-provider session failure aborts (today's semantics)"
check "$(grep -c 'provider-class failure' "$SCRATCH"/.archloop/night-*/driver.log)" "0" "no retry for non-provider failures"
check "$(grep -c 'session start: scan-plan' "$SCRATCH"/.archloop/night-*/driver.log)" "1" "exactly one attempt"
check "$(grep -c 'ABORT: scan/plan verdict' "$SCRATCH"/.archloop/night-*/driver.log)" "1" "verdict abort preserved (stub's ping pass-through leaves FAILED, not MISSING)"
fresh_clone
check "$(run_loop "STUB_FAIL_STAGE=scan-plan STUB_FAIL_MSG= STUB_FAIL_TIMES=1 STUB_FAIL_COUNT=$STUB_DIR/failcount-12b.env ARCHLOOP_RETRY_BACKOFF=1")" "exit=0" "non-zero exit with NO output is provider-class (retried)"
check "$(grep -c 'provider-class failure' "$SCRATCH"/.archloop/night-*/driver.log)" "1" "silent death retried once, then completed"

echo "== Test 13: green + sessions see the worktree on PYTHONPATH (editable-install shadowing) =="
# 2026-08-17 rentcli: pytest ran with rootdir = the worktree but imports
# resolved to the CANONICAL checkout (editable install pointing there) —
# implementer renames were invisible and good items got PARKED. run.sh must
# prepend the worktree to PYTHONPATH for the green checks AND for the sessions
# that run the test cmd themselves.
fresh_clone
rm -f "$STUB_DIR/session-pypath.txt"
cd "$SCRATCH" || exit 1
WT13="$WT_BASE/scratch-night-$(date +%F)"
env ARCHLOOP_OPENCODE="$STUB" ARCHLOOP_WORKTREE_BASE="$WT_BASE" \
    ARCHLOOP_TEST_CMD="env > $STUB_DIR/green-env.txt" ARCHLOOP_LINT_CMD=true \
    ARCHLOOP_MAX_ITEMS=1 STUB_SCRATCH="$SCRATCH" STUB_WT_BASE="$WT_BASE" \
    STUB_SCAN_VERDICT=NONE STUB_PYTHONPATH="$STUB_DIR/session-pypath.txt" \
    bash "$RUN" "$SCRATCH" > "$STUB_DIR/test-run13.log" 2>&1
check "$?" "0" "run completes with PYTHONPATH probes (scan NONE)"
check "$(sed -n 's/^PYTHONPATH=\([^:]*\).*/\1/p' "$STUB_DIR/green-env.txt")" "$WT13" "green check sees worktree first on PYTHONPATH"
check "$(head -1 "$STUB_DIR/session-pypath.txt" | cut -d: -f1)" "$WT13" "session inherits PYTHONPATH=worktree-first (c18270b prepends worktree, preserves inherited entries)"

echo "== Test 14: horizon doctor FAIL — reported with fix hint, run NOT aborted =="
# t_5c3ecd27/t_bc915e44: a drifted store .gitignore must surface in preflight
# output with its one-line fix hint, REPORTING-ONLY (never auto-fix, never abort
# on the doctor failure alone). Stub horizon on PATH (never the real binary in
# CI) mimics the real doctor's seeded-drift behavior verified 2026-09-28:
# prints the store: FAIL line and exits 1. Scratch repo gets a .horizon store
# whose .gitignore is missing the hooks.log line (the seeded drift).
fresh_clone
mkdir -p "$SCRATCH/.horizon"
printf 'gaps.md\n' > "$SCRATCH/.horizon/.gitignore"   # hooks.log missing = seeded drift
git -C "$SCRATCH" add .horizon && git -C "$SCRATCH" commit -qm "seed horizon store (drifted)"
HSTUB="$STUB_DIR/horizon-bin"; mkdir -p "$HSTUB"
cat > "$HSTUB/horizon" <<'HZEOF'
#!/usr/bin/env bash
echo "store: FAIL $PWD/.horizon/.gitignore missing: hooks.log — run: horizon doctor --fix"
exit 1
HZEOF
chmod +x "$HSTUB/horizon"
# prepend the stub dir to PATH (exported: run_loop's env passes it through);
# restored after — later tests see the original PATH again.
SAVED_PATH="$PATH"; export PATH="$HSTUB:$PATH"
check "$(run_loop "")" "exit=0" "doctor FAIL alone does not abort the run"
PATH="$SAVED_PATH"; export PATH
grep -q 'PREFLIGHT: horizon doctor FAILED (exit 1)' "$STUB_DIR/test-run.log" \
  && ok "doctor FAIL line with exit status in preflight output" || bad "doctor FAIL line missing"
grep -q 'fix hint: horizon doctor --fix' "$STUB_DIR/test-run.log" \
  && ok "one-line fix hint printed" || bad "--fix hint missing"
check "$([ -f "$SCRATCH/.archloop/doctor-preflight.log" ] && echo yes)" "yes" "doctor output captured to .archloop/doctor-preflight.log"
check "$(git -C "$SCRATCH" status --porcelain)" "" "canonical stays clean (doctor log excluded)"

echo "== Test 15: horizon doctor PASS — clean store =="
# Stub horizon prints the store: PASS line and exits 0 (real doctor on a
# clean store, verified 2026-09-28): preflight must print the PASS line.
fresh_clone
mkdir -p "$SCRATCH/.horizon"
printf 'gaps.md\nhooks.log\n' > "$SCRATCH/.horizon/.gitignore"   # complete = no drift
git -C "$SCRATCH" add .horizon && git -C "$SCRATCH" commit -qm "seed horizon store (clean)"
cat > "$HSTUB/horizon" <<'HZEOF2'
#!/usr/bin/env bash
echo "store: PASS $PWD/.horizon/.gitignore covers every store-written file"
exit 0
HZEOF2
chmod +x "$HSTUB/horizon"
SAVED_PATH="$PATH"; export PATH="$HSTUB:$PATH"
check "$(run_loop "")" "exit=0" "run completes with doctor PASS"
PATH="$SAVED_PATH"; export PATH
check "$(grep -c 'PREFLIGHT: horizon doctor PASS (store .gitignore drift check clean)' "$STUB_DIR/test-run.log")" "1" "doctor PASS line in preflight output"
check "$(grep -c 'horizon doctor FAILED' "$STUB_DIR/test-run.log")" "0" "no FAIL line on the clean-store stub"

echo "== Test 16: archloop ui — parse, summarize (stub), render, screenshot =="
# Spec t_95a2c885 §9: fixture corpus + stub session/capture binaries. The
# fixture tree is COPIED into STUB_DIR because summarize writes sidecars into
# night dirs — the checked-in tree must stay clean and parallel suite runs
# (concurrency gate) must not fight over it.
FIXTURES="$STUB_DIR/fixtures"
cp -r "$SCRIPT_DIR/../tests/ui-fixtures/repos" "$FIXTURES"
DEMO_A="$FIXTURES/demo-a"
DEMO_B="$FIXTURES/demo-b"
UI="$SCRIPT_DIR/../bin/archloop"
UIOUT="$STUB_DIR/uisite"
UICAP="$STUB_DIR/ui-capture.sh"
UIMODELS="$STUB_DIR/ui-models.txt"
UICALLS="$STUB_DIR/ui-calls.txt"

# stub session runner: writes a sidecar at the path embedded in the prompt.
# STUB_SIDECAR_MODE drives invalid-output variants for the reject path.
cat > "$STUB" <<'STUBEOF2'
#!/usr/bin/env bash
# Stub opencode for the ui summarize step (test 10). Contract (docs/ui.md):
#   run --dir <repo> --model <id> --title <t> <prompt>
# The prompt embeds the absolute sidecar target path (ends .json).
model="$(printf '%s' "$*" | sed -n 's/.*--model \([^ ]*\).*/\1/p' | head -1)"
printf '%s\n' "$model" >> "${STUB_UI_MODELS:-/dev/null}"
printf 'call\n' >> "${STUB_UI_CALLS:-/dev/null}"
target="$(printf '%s' "$*" | grep -oE '[^ ]*/ui/[a-z0-9-]+\.json' | head -1)"
[ -n "$target" ] || { echo "stub-ui: no sidecar path in prompt" >&2; exit 1; }
item="$(basename "$target" .json)"
case "${STUB_SIDECAR_MODE:-ok}" in
  fence)
    printf '```json\n{"schema": 1, "item": "%s", "title": "Fenced Title", "details": "d.", "model": "%s", "generated_at": "2026-05-01T00:00:00"}\n```\n' "$item" "$model" > "$target"
    ;;
  nokey)
    printf '{"schema": 1, "item": "%s", "title": "Missing Details", "model": "%s", "generated_at": "2026-05-01T00:00:00"}\n' "$item" "$model" > "$target"
    ;;
  long)
    printf '{"schema": 1, "item": "%s", "title": "%s", "details": "way over the cap", "model": "%s", "generated_at": "2026-05-01T00:00:00"}\n' "$item" "$(printf 'T%.0s' {1..80})" "$model" > "$target"
    ;;
  fail)
    exit 3 ;;
  *)
    printf '{"schema": 1, "item": "%s", "title": "Stub Summary Of %s", "details": "The stub wrote this sidecar. It folds duplicated logic into one owner.", "model": "%s", "generated_at": "2026-05-01T00:00:00"}\n' "$item" "$item" "$model" > "$target"
    ;;
esac
exit 0
STUBEOF2
chmod +x "$STUB"

# stub capture backend: records its argv, writes a PNG-magic file
cat > "$UICAP" <<'CAPEOF'
#!/usr/bin/env bash
printf '%s\n' "$1 $2 $3 $4" >> "${STUB_CAP_ARGS:-/dev/null}"
printf '\x89PNG\r\n\x1a\nstub-image' > "$2"
exit 0
CAPEOF
chmod +x "$UICAP"

ui_run() { # $1=outdir, extra env via current STUB_* exports
  env ARCHLOOP_OPENCODE="$STUB" STUB_UI_MODELS="$UIMODELS" STUB_UI_CALLS="$UICALLS" \
    "$UI" ui --repo "$DEMO_A" --repo "$DEMO_B" --no-summarize --out "$1" >/dev/null 2>"$STUB_DIR/ui-stderr.log"
  echo "exit=$?"
}

# --- 9a: parse + render (offline, zero sessions) -----------------------------
rm -f "$UICALLS"
check "$(ui_run "$UIOUT")" "exit=0" "ui renders fixture corpus, exit 0"
check "$(grep -c 'call' "$UICALLS" 2>/dev/null || echo 0)" "0" "--no-summarize runs zero sessions"
check "$([ -f "$UIOUT/index.html" ] && echo yes)" "yes" "index.html exists"
check "$(find "$UIOUT/night" -name '*.html' | wc -l)" "12" "12 night pages (demo-a incl .stale; demo-b empty)"
check "$(grep -c 'class="item-row"' "$UIOUT/index.html")" "8" "8 index item rows (ledger + backfill)"
for st in PUSHED PARKED QUEUED HARD_ABORT PREFLIGHT_RED SCAN_FAILED GATED_NOT_MERGED IMPLEMENTED_NO_GATE CLEAN_NO_CANDIDATES; do
  grep -q "derived-status ds-$st" "$UIOUT/index.html" && ok "index shows $st" || bad "index missing $st"
done
check "$(grep -c 'class="derived-status ds-MERGED_LOCAL"' "$UIOUT/index.html")" "0" "no MERGED_LOCAL chip (no fixture)"
grep -q 'Shipped 4' "$UIOUT/index.html" && ok "summary bar: Shipped 4 (.stale excluded)" || bad "Shipped count wrong"
grep -q 'Parked 2' "$UIOUT/index.html" && ok "summary bar: Parked 2 (PARKED + QUEUED)" || bad "Parked count wrong"
grep -q 'Clean 1' "$UIOUT/index.html" && ok "summary bar: Clean 1" || bad "Clean count wrong"
grep -q 'Failed 4' "$UIOUT/index.html" && ok "summary bar: Failed 4" || bad "Failed count wrong"
grep -q 'legacy-tag">LEGACY' "$UIOUT/index.html" && ok "LEGACY tag rendered (QUEUED + candidate eras)" || bad "LEGACY tag missing"
grep -q 'stale-tag">STALE' "$UIOUT/index.html" && ok "STALE tag rendered" || bad "STALE tag missing"
grep -qF 'href="item/demo-a/2026-05-01/fold-validators-into-schema.html"' "$UIOUT/index.html" \
  && ok "ledger row links item page" || bad "ledger row link wrong"
grep -qF '>Fold Validators Into Schema<' "$UIOUT/index.html" \
  && ok "sidecar title used on index row" || bad "sidecar title missing on index"
grep -qF '>Drop Dead Cache Key<' "$UIOUT/index.html" \
  && ok "fallback humanized title (no sidecar)" || bad "fallback title missing"
ITEMPG="$UIOUT/item/demo-a/2026-05-01/fold-validators-into-schema.html"
grep -qF '&lt;script&gt;alert(&quot;&amp;&quot;)&lt;/script&gt;' "$ITEMPG" \
  && ok "gate excerpt HTML-escaped (& < > \")" || bad "escaping broken in gate excerpt"
check "$(grep -c '<script>' "$ITEMPG")" "0" "no raw script tag leaked into item page"
grep -qF 'truncated at 40 of' "$UIOUT/item/demo-a/2026-05-01/drop-dead-cache-key.html" \
  && ok "gate excerpt capped at 40 lines with marker" || bad "40-line cap missing"
grep -q 'no-summary' "$UIOUT/item/demo-a/2026-05-01/drop-dead-cache-key.html" \
  && ok "no-summary marker on sidecar-less item" || bad "no-summary marker missing"
grep -q 'llm-badge' "$ITEMPG" && ok "LLM badge on sidecar item page" || bad "LLM badge missing"
check "$(grep -c '{{' "$UIOUT/index.html")" "0" "zero unresolved placeholders in index"
# every internal link resolves
BROKEN=0
while IFS= read -r f; do
  d="$(dirname "$f")"
  while IFS= read -r href; do
    case "$href" in file://*|http*) ;; *) [ -e "$d/$href" ] || BROKEN=$((BROKEN+1)) ;; esac
  done < <(grep -oE 'href="[^"#]*"' "$f" | sed 's/href="//;s/"//')
done < <(find "$UIOUT" -name '*.html')
check "$BROKEN" "0" "every internal link resolves to a file"
# determinism: two runs, byte-identical
UIOUT2="$STUB_DIR/uisite2"
ui_run "$UIOUT2" >/dev/null 2>&1
diff -r "$UIOUT" "$UIOUT2" >/dev/null 2>&1 && ok "deterministic: diff -r clean across runs" || bad "render not deterministic"
# empty .archloop repo only: empty index, exit 0
UIOUTB="$STUB_DIR/uisite-b"
env "$UI" ui --repo "$DEMO_B" --no-summarize --out "$UIOUTB" >/dev/null 2>&1
check "$?" "0" "empty .archloop repo: exit 0"
check "$(grep -c 'class="night-section"' "$UIOUTB/index.html")" "0" "empty repo renders empty index"
# text format
"$UI" ui --repo "$DEMO_A" --repo "$DEMO_B" --no-summarize --format text > "$STUB_DIR/ui-text.out" 2>/dev/null
grep -qE '^== 2026-05-01 demo-a PUSHED ==' "$STUB_DIR/ui-text.out" && ok "text format night header" || bad "text header missing"
grep -qE '^ *SHIP +fold-validators-into-schema' "$STUB_DIR/ui-text.out" && ok "text format item row" || bad "text row missing"
grep -qE '^ *PARK +centralize-parked-thing' "$STUB_DIR/ui-text.out" && ok "text format park row" || bad "text park row missing"

# --- 9b: summarize with the stub session --------------------------------------
rm -f "$UICALLS" "$UIMODELS"
env ARCHLOOP_OPENCODE="$STUB" STUB_UI_MODELS="$UIMODELS" STUB_UI_CALLS="$UICALLS" \
  "$UI" ui --repo "$DEMO_A" --repo "$DEMO_B" --out "$UIOUT" >/dev/null 2>&1
check "$?" "0" "summarize + render exits 0"
SC="$DEMO_A/.archloop/night-2026-05-01/ui/drop-dead-cache-key.json"
[ -f "$SC" ] && ok "stub wrote missing sidecar" || bad "sidecar not written"
grep -qF 'Stub Summary Of drop-dead-cache-key' "$UIOUT/index.html" \
  && ok "stub sidecar title rendered on index row" || bad "stub title missing on index row"
grep -qF 'Stub Summary Of drop-dead-cache-key' "$UIOUT/item/demo-a/2026-05-01/drop-dead-cache-key.html" \
  && ok "stub sidecar title rendered on item page" || bad "stub title not rendered"
grep -qF 'It folds duplicated logic into one owner' "$UIOUT/item/demo-a/2026-05-01/drop-dead-cache-key.html" \
  && ok "stub sidecar details rendered" || bad "stub details not rendered"
N1=$(grep -c 'call' "$UICALLS" 2>/dev/null || echo 0)
[ "$N1" -gt 0 ] && ok "stub ran ($N1 session(s))" || bad "stub never invoked"
# idempotency: second run performs zero sessions
rm -f "$UICALLS"
env ARCHLOOP_OPENCODE="$STUB" STUB_UI_CALLS="$UICALLS" \
  "$UI" ui --repo "$DEMO_A" --repo "$DEMO_B" --out "$UIOUT" >/dev/null 2>&1
check "$(grep -c 'call' "$UICALLS" 2>/dev/null || echo 0)" "0" "second summarize run: zero sessions (idempotent)"
# force rewrites
rm -f "$UICALLS"
env ARCHLOOP_OPENCODE="$STUB" STUB_UI_CALLS="$UICALLS" \
  "$UI" ui --repo "$DEMO_A" --repo "$DEMO_B" --out "$UIOUT" --force-summarize >/dev/null 2>&1
[ "$(grep -c 'call' "$UICALLS" 2>/dev/null || echo 0)" -gt 0 ] \
  && ok "--force-summarize rewrites sidecars" || bad "--force-summarize did not rewrite"
# failed session: exit 1, sidecars from other items intact, render still usable
rm -f "$UICALLS"
rm -f "$DEMO_A/.archloop/night-2026-05-01/ui/drop-dead-cache-key.json"
env ARCHLOOP_OPENCODE="$STUB" STUB_UI_CALLS="$UICALLS" STUB_SIDECAR_MODE=fail \
  "$UI" ui --repo "$DEMO_A" --summarize-only >/dev/null 2>&1
check "$?" "1" "failed summarize session: exit 1"
check "$([ -s "$DEMO_A/.archloop/night-2026-05-01/ui/fold-validators-into-schema.json" ] && echo yes)" "yes" "pre-existing sidecar survives failed session"
# invalid sidecar variants -> .rejected + fallback, exit 0 (force: every variant
# rewrites the target with invalid content; --summarize-only is retried over
# the fixture copy, so the checked-in corpus stays clean)
for mode in fence nokey long; do
  rm -f "$DEMO_A/.archloop/night-2026-05-01/ui/"*rejected
  rm -f "$DEMO_A/.archloop/night-2026-05-01/ui/drop-dead-cache-key.json"
  env ARCHLOOP_OPENCODE="$STUB" STUB_UI_CALLS="$UICALLS" STUB_SIDECAR_MODE="$mode" \
    "$UI" ui --repo "$DEMO_A" --summarize-only --force-summarize >/dev/null 2>&1
  check "$?" "0" "invalid sidecar ($mode): exit 0"
  ls "$DEMO_A/.archloop/night-2026-05-01/ui/"*.rejected >/dev/null 2>&1 \
    && ok "invalid sidecar ($mode) renamed .rejected" || bad "($mode) not rejected"
  # re-render offline: the rejected item must fall back to the humanized title
  ui_render_one() { # $1=out
    env ARCHLOOP_OPENCODE="$STUB" "$UI" ui --repo "$DEMO_A" --no-summarize --out "$1" >/dev/null 2>&1
  }
  ui_render_one "$STUB_DIR/uisite-$mode"
  grep -qF '>Drop Dead Cache Key<' "$STUB_DIR/uisite-$mode/item/demo-a/2026-05-01/drop-dead-cache-key.html" \
    && ok "fallback title rendered after $mode rejection" || bad "($mode) fallback missing"
done
# model precedence: --model > env ARCHLOOP_MODEL_SUMMARY > repo config > default
rm -f "$UIMODELS"; rm -f "$DEMO_A/.archloop/night-2026-05-01/ui/"*.json.rejected 2>/dev/null
env ARCHLOOP_OPENCODE="$STUB" STUB_UI_MODELS="$UIMODELS" STUB_UI_CALLS="$UICALLS" \
  "$UI" ui --repo "$DEMO_A" --summarize-only --force-summarize >/dev/null 2>&1
check "$(head -1 "$UIMODELS")" "cfg/summary-model" "repo config model beats DEFAULT_* (summary)"
rm -f "$UIMODELS"
env ARCHLOOP_OPENCODE="$STUB" STUB_UI_MODELS="$UIMODELS" ARCHLOOP_MODEL_SUMMARY="env/summary-model" \
  "$UI" ui --repo "$DEMO_A" --summarize-only --force-summarize >/dev/null 2>&1
check "$(head -1 "$UIMODELS")" "env/summary-model" "env beats repo config (summary)"
rm -f "$UIMODELS"
env ARCHLOOP_OPENCODE="$STUB" STUB_UI_MODELS="$UIMODELS" ARCHLOOP_MODEL_SUMMARY="env/summary-model" \
  "$UI" ui --repo "$DEMO_A" --summarize-only --force-summarize --model "flag/summary-model" >/dev/null 2>&1
check "$(head -1 "$UIMODELS")" "flag/summary-model" "--model flag beats env (summary)"
# default: config removed -> LANE_BIG from scripts/lib/lanes.sh
rm -f "$UIMODELS"
DEFDIR="$STUB_DIR/demo-a-nodefault"; cp -r "$DEMO_A" "$DEFDIR"; rm -f "$DEFDIR/.archloop/config"
env ARCHLOOP_OPENCODE="$STUB" STUB_UI_MODELS="$UIMODELS" \
  "$UI" ui --repo "$DEFDIR" --summarize-only --force-summarize >/dev/null 2>&1
check "$(head -1 "$UIMODELS")" "$LANE_BIG" "default = LANE_BIG (single source in scripts/lib/lanes.sh)"
# --summarize-only writes no site
rm -rf "$STUB_DIR/sumonly"
env ARCHLOOP_OPENCODE="$STUB" "$UI" ui --repo "$DEMO_B" --summarize-only --out "$STUB_DIR/sumonly" >/dev/null 2>&1
check "$([ -f "$STUB_DIR/sumonly/index.html" ] && echo yes || echo no)" "no" "--summarize-only renders no site"

# --- 9c: screenshot + exit-2 paths -------------------------------------------
env ARCHLOOP_OPENCODE="$STUB" ARCHLOOP_CAPTURE_CMD="$UICAP" STUB_CAP_ARGS="$STUB_DIR/ui-cap-args.txt" \
  "$UI" ui --repo "$DEMO_A" --repo "$DEMO_B" --no-summarize --out "$UIOUT" --screenshot --out-image "$STUB_DIR/ui-shot.png" >/dev/null 2>&1
check "$?" "0" "screenshot via ARCHLOOP_CAPTURE_CMD stub: exit 0"
grep -qF "file://$UIOUT/index.html $STUB_DIR/ui-shot.png 1280 800" "$STUB_DIR/ui-cap-args.txt" \
  && ok "capture stub received url + out + 1280x800" || bad "capture argv wrong"
[ -s "$STUB_DIR/ui-shot.png" ] && ok "screenshot image written non-empty" || bad "screenshot image missing"
# no backend: PATH contains failing fakes for every candidate -> exit 2 + list
FAKEBIN="$STUB_DIR/fakebin"; mkdir -p "$FAKEBIN"
for b in chromium chromium-browser google-chrome wkhtmltoimage; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/$b"; chmod +x "$FAKEBIN/$b"
done
env ARCHLOOP_OPENCODE="$STUB" PATH="$FAKEBIN:/usr/bin:/bin" \
  "$UI" ui --repo "$DEMO_B" --no-summarize --out "$UIOUTB" --screenshot 2>"$STUB_DIR/ui-nobackend.err"
check "$?" "2" "no capture backend: exit 2"
grep -qF "chromium, chromium-browser, google-chrome, wkhtmltoimage" "$STUB_DIR/ui-nobackend.err" \
  && ok "no-backend error lists tried backends" || bad "backend list missing from error"
# exit-2 paths
env ARCHLOOP_REPOS_CONF=/nonexistent/repos.conf "$UI" ui --no-summarize 2>"$STUB_DIR/ui-norepo.err"
check "$?" "2" "no repo source: exit 2"
grep -qF "docs/ui.md" "$STUB_DIR/ui-norepo.err" && ok "no-repo error points at docs/ui.md" || bad "docs hint missing"
grep -qF "/nonexistent/repos.conf" "$STUB_DIR/ui-norepo.err" && ok "no-repo error names the expected path" || bad "expected path missing"
BADCONF="$STUB_DIR/bad-repos.conf"; printf '# comment\n\nrelative/path\n' > "$BADCONF"
env ARCHLOOP_REPOS_CONF="$BADCONF" "$UI" ui --no-summarize 2>"$STUB_DIR/ui-badconf.err"
check "$?" "2" "relative path in repos.conf: exit 2"
grep -qF "path must be absolute: relative/path" "$STUB_DIR/ui-badconf.err" && ok "bad conf line named" || bad "bad conf line not named"
NOARCH="$STUB_DIR/no-archloop"; mkdir -p "$NOARCH/.archloop-not"
printf '%s\n' "$NOARCH" > "$BADCONF"
env ARCHLOOP_REPOS_CONF="$BADCONF" "$UI" ui --no-summarize 2>"$STUB_DIR/ui-noarch.err"
check "$?" "2" "repo without .archloop/: exit 2"
grep -qF "no .archloop/ dir in $NOARCH" "$STUB_DIR/ui-noarch.err" && ok "missing .archloop named" || bad "missing .archloop not named"
# --repo works with no config file present at all
check "$(ui_run "$UIOUT2" 2>/dev/null)" "exit=0" "--repo works with no repos.conf anywhere"

finish
