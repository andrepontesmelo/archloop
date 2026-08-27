#!/usr/bin/env bash
# andre-archloop v2 — architecture-improvement loop.
# Usage: run.sh /path/to/repo [max_items]
#
# ---------------------------------------------------------------------------
# DESIGN DECISIONS (the only ones not readable off the code below)
# ---------------------------------------------------------------------------
# * The orchestrator is a script, not a model. The sequence is a fixed state
#   machine, so the driver is deterministic, free, restartable and immune to
#   overnight context rot. A model "orchestrator session" would add a failure
#   mode without adding judgment. Models think inside stages; the script
#   sequences them and greps one-word verdict files.
#
# * One fresh session = one `opencode run` invocation. That IS the whole
#   session-boundary mechanism.
#
# * ONE scan per run (v2 change). v1 re-scanned the whole repo before every
#   candidate — 25% of wall clock — and each scan discarded its own runner-up
#   Strong findings (2026-07-28 threw away a Strong `render.py` candidate that
#   was never seen again). Now: one scan, one plan covering EVERY Strong item,
#   then loop implement->gate per item.
#
# * Plan once, but implement+gate PER ITEM. The reset-to-base park path is the
#   safety property that makes unattended refactoring survivable: a bad item
#   costs one item, not the night. A single implement session across all items
#   would also produce a diff too large to adversarially review.
#
# * Isolation via worktree (v3 change). The canonical checkout is never
#   touched: the run works in a linked worktree under ~/.cache/archloop/,
#   artifacts stay canonical and are hidden via .git/info/exclude, and the run
#   aborts unless the canonical checkout is clean and on main. Every session,
#   test run, and park reset happens inside the worktree; the branch survives
#   worktree removal so the morning review still reads main..<branch>.
#
# * Auto-merge (v3 change). SHIPped items are merged --no-ff back into main and
#   pushed at the end of the run (ARCHLOOP_MERGE=0 / ARCHLOOP_PUSH=0 disable).
#   The gate is the final reviewer; parks never enter the merge because park
#   resets the branch to base. Nothing is ever force-pushed.
#
# * Authoring chains, reviewing does not. Scan -> pick -> plan is one session
#   (same mental model, no self-review, so no anchoring risk). The gate never
#   shares a session with what it reviews — fresh context is the mechanism
#   that makes the loop worth running.
#
# * The implementer gets a lean session fed the plan artifact, not the
#   planning debate. Smaller context, fewer ways for a cheap model to drift.
#
# * No refine stage (v2 change). Across 9 candidates it returned GREEN in
#   round 1 every time while passing a plan whose "behavior-preserving" header
#   its own body contradicted, and passing cross-item scope creep. Its
#   checklist now lives in the gate prompt, where the reviewer can check the
#   plan against the actual diff instead of against itself.
#
# * No fast-review stage (v2 change). 9/9 PASS, never once triggered its fix
#   loop, and it ran on the most expensive model. The gate reviews the same
#   diff against the same plan and caught what fast-review missed.
#
# * Model allocation follows leverage, not price. The scan decides whether the
#   whole run is worth anything and cannot be recovered from downstream, so it
#   gets the strongest model, once. The gate is the only reviewer left, so it
#   gets the same strong model. Implementation is transcription when the plan
#   is good, so it keeps the cheapest model (DeepSeek V4 Flash).
#
# * Green is the gate everywhere. Baseline must be green before the run starts
#   (else abort); every stage that touches code must end green; a red item is
#   `git reset --hard` back to its base and parked.
#
# * Artifacts, not memory. Every stage reads/writes files under
#   .archloop/night-<date>/ — the run is crash-restartable and fully auditable.
#
# ---------------------------------------------------------------------------
# WARNINGS
# ---------------------------------------------------------------------------
# * First run on a new repo: supervise it. Non-interactive `opencode run`
#   sessions that hit a permission prompt hang until the idle watchdog fires.
#   Add ARCHLOOP_TEST_CMD / ARCHLOOP_LINT_CMD to opencode's bash allowlist
#   before trusting this unattended.
# * Never wire the loop to skip the gate. It is the only reviewer left.
# * SHIP is auto-merged into main and pushed at the end of the run (disable
#   with ARCHLOOP_MERGE=0 / ARCHLOOP_PUSH=0). The gate is the final reviewer —
#   do not wire the loop to skip it. Review REPORT.md and the merged diff in
#   the morning anyway; a bad run costs one `git reset --hard` + branch delete.
# * Do not run against a dirty tree or a red baseline. The script aborts on
#   both — keep it that way. The canonical checkout must be on main; it is
#   never left, never tested, never committed to by this script.
# ---------------------------------------------------------------------------

set -uo pipefail

# --- defaults (overridable via env or <repo>/.archloop/config) ---------------
DEFAULT_MAX_ITEMS=5
DEFAULT_SESSION_TIMEOUT=7200
DEFAULT_GATE_TIMEOUT=7200
DEFAULT_IDLE_TIMEOUT=600
# Routing (2026-08-26, Andre): all three roles use one model,
# zai/glm-5.3-flash — verified live-routable opencode id:
# openrouter/z-ai/glm-5.3-flash.
# Per-role override via ARCHLOOP_MODEL_* env or <repo>/.archloop/config.
# Models are defined here only; do not duplicate them elsewhere.
DEFAULT_MODEL_SCAN="openrouter/z-ai/glm-5.3-flash"
# Cheapest model: implementing a good plan is transcription.
DEFAULT_MODEL_IMPL="openrouter/z-ai/glm-5.3-flash"
DEFAULT_MODEL_GATE="openrouter/z-ai/glm-5.3-flash"
DEFAULT_WORKTREE_BASE="$HOME/.cache/archloop"
DEFAULT_BASE_BRANCH="main"

REPO="${1:?usage: run.sh /path/to/repo [max_items]}"
REPO="$(realpath "$REPO")"

# --- knobs (env, or sourced <repo>/.archloop/config) ------------------------
[ -f "$REPO/.archloop/config" ] && . "$REPO/.archloop/config"
MAX_ITEMS="${2:-${ARCHLOOP_MAX_ITEMS:-$DEFAULT_MAX_ITEMS}}"
M_SCAN="${ARCHLOOP_MODEL_SCAN:-$DEFAULT_MODEL_SCAN}"
M_IMPL="${ARCHLOOP_MODEL_IMPL:-$DEFAULT_MODEL_IMPL}"
M_GATE="${ARCHLOOP_MODEL_GATE:-$DEFAULT_MODEL_GATE}"
OC="${ARCHLOOP_OPENCODE:-}"
if [ -z "$OC" ]; then
  # resolve opencode: $HOME path first, then the real user home (survives
  # sandboxed shells whose HOME points at a profile dir), then PATH
  for cand in "$HOME/.opencode/bin/opencode" "$(getent passwd "$(id -un)" | cut -d: -f6)/.opencode/bin/opencode" "$(command -v opencode 2>/dev/null)"; do
    [ -n "$cand" ] && [ -x "$cand" ] && { OC="$cand"; break; }
  done
fi
[ -n "$OC" ] || { echo "ABORT: opencode binary not found — set ARCHLOOP_OPENCODE"; exit 1; }
SESSION_TIMEOUT="${ARCHLOOP_SESSION_TIMEOUT:-$DEFAULT_SESSION_TIMEOUT}"
GATE_TIMEOUT="${ARCHLOOP_GATE_TIMEOUT:-$DEFAULT_GATE_TIMEOUT}"
IDLE_TIMEOUT="${ARCHLOOP_IDLE_TIMEOUT:-$DEFAULT_IDLE_TIMEOUT}"
WORKTREE_BASE="${ARCHLOOP_WORKTREE_BASE:-$DEFAULT_WORKTREE_BASE}"
BASE_BRANCH="${ARCHLOOP_BASE_BRANCH:-$DEFAULT_BASE_BRANCH}"
MERGE_ENABLED="${ARCHLOOP_MERGE:-1}"
PUSH_ENABLED="${ARCHLOOP_PUSH:-1}"
SKILLS="$HOME/.claude/skills"
: "${ARCHLOOP_TEST_CMD:?set ARCHLOOP_TEST_CMD — no test command, no unattended refactor run}"
: "${ARCHLOOP_LINT_CMD:?set ARCHLOOP_LINT_CMD}"

NIGHT="$(date +%F)"
REPO_BASE="$(basename "$REPO")"
WORKTREE="$WORKTREE_BASE/$REPO_BASE-night-$NIGHT"
WORK="$REPO/.archloop/night-$NIGHT"
LEDGER="$REPO/.archloop/ledger.md"
REPORT="$WORK/REPORT.md"
log()    { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$WORK/driver.log"; }
report() { printf '%s\n' "$*" >> "$REPORT"; }

# One fresh session = one `opencode run` invocation. That IS the boundary.
session() { # $1=model $2=logname $3=prompt [$4=timeout-override]
  local model="$1" name="$2" prompt="$3" tmo="${4:-$SESSION_TIMEOUT}"
  local out="$WORK/$name.log"
  log "session start: $name ($model)"
  : > "$out"
  timeout "$tmo" "$OC" run --dir "$WORKTREE" --model "$model" \
    --title "archloop-$NIGHT-$name" "$prompt" > "$out" 2>&1 &
  local pid=$!
  # ponytail: watchdog polls log mtime — an API error (quota, auth) leaves
  # opencode alive but silent, which otherwise burns the full SESSION_TIMEOUT.
  # Poll interval 30s; swap for event plumbing only if 30s granularity hurts.
  ( while kill -0 "$pid" 2>/dev/null; do
      sleep 30
      kill -0 "$pid" 2>/dev/null || exit 0
      if [ $(( $(date +%s) - $(stat -c %Y "$out") )) -ge "$IDLE_TIMEOUT" ]; then
        log "session $name: no output for ${IDLE_TIMEOUT}s — killing"
        kill -TERM "$pid" 2>/dev/null
        exit 0
      fi
    done ) &
  local dog=$!
  wait "$pid"; local rc=$?
  kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
  log "session end: $name (exit $rc)"
  return "$rc"
}

verdict() {
  [ -f "$1" ] || { echo "MISSING"; return; }
  grep -oiE '^(SHIP|PARK|DONE|FAILED|PLANNED|NONE)$' "$1" | tail -1 | tr 'a-z' 'A-Z'
}

green() { # $1=label [$2=retries] — full suite + lint; logs; returns status
  local label="$1" retries="${2:-1}" attempt=0
  while [ "$attempt" -lt "$retries" ]; do
    ( cd "$WORKTREE" && eval "$ARCHLOOP_TEST_CMD" && eval "$ARCHLOOP_LINT_CMD" ) \
      > "$WORK/green-$label.log" 2>&1 && return 0
    attempt=$((attempt + 1))
    log "green $label retry $attempt/$retries"
  done
  log "green $label FAILED after $retries attempt(s)"
  return 1
}

prune_stale_worktrees() {
  # Remove any leftover archloop worktree for this repo so `add -B` cannot fail.
  local wt
  git -C "$REPO" worktree list --porcelain \
    | awk '/^worktree /{print $2}' \
    | grep -F "$WORKTREE_BASE" \
    | while read -r wt; do
        log "prune stale worktree: $wt"
        git -C "$REPO" worktree remove --force "$wt" 2>/dev/null \
          || git -C "$REPO" worktree prune
      done
}

park() { # $1=item-name $2=stage $3=base-sha
  # ponytail: park MUST hit driver.log — without this an unattended run shows
  # "session end" then "run complete" with no trace of a discarded item, and
  # any log-tailing monitor stays silent through it (happened 2026-07-29).
  log "PARK: $1 at $2 — resetting to $3"
  echo "- $NIGHT $1: PARKED at $2" >> "$LEDGER"
  report "- **$1** — parked at $2"
  if ! git -C "$WORKTREE" reset --hard "$3" || ! git -C "$WORKTREE" clean -fd; then
    log "CRITICAL: park failed to reset tree to $3 — aborting run"
    exit 1
  fi
}

# --- preflight ---------------------------------------------------------------
cd "$REPO" || { echo "ABORT: cannot cd to $REPO"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "ABORT: dirty tree"; exit 1; }
[ "$(git branch --show-current)" = "$BASE_BRANCH" ] || { echo "ABORT: must run on $BASE_BRANCH (on $(git branch --show-current))"; exit 1; }
[ ! -f "$REPORT" ] || { echo "ABORT: $REPORT already exists — move or remove it before re-running"; exit 1; }
mkdir -p "$WORK"; touch "$LEDGER"
# keep canonical tree clean without a .gitignore commit (a gitignore commit would
# only land on main if the branch merges; info/exclude is repo-local and instant)
grep -qx '.archloop/' "$REPO/.git/info/exclude" 2>/dev/null \
  || printf '.archloop/\n' >> "$REPO/.git/info/exclude"
prune_stale_worktrees
# ponytail: time suffix so a second run on the same date cannot `worktree add -B`
# over the first one's commits and orphan them (happened 2026-07-24).
BRANCH="archloop/$NIGHT-$(date +%H%M)"
git -C "$REPO" worktree add -B "$BRANCH" "$WORKTREE" HEAD >/dev/null 2>&1 \
  || { log "ABORT: cannot create worktree $WORKTREE ($BRANCH)"; exit 1; }
cleanup() { git -C "$REPO" worktree remove --force "$WORKTREE" 2>/dev/null || true; }
trap cleanup EXIT
green preflight || { log "ABORT: baseline red — fix tests/lint before an unattended run"; exit 1; }
report "# archloop $NIGHT — $(basename "$REPO") (worktree $WORKTREE, branch $BRANCH)"
report ""

# --- Stage 1 — one scan, one plan covering every Strong item ------------------
session "$M_SCAN" "scan-plan" "FIRST, THE OUTPUT CONTRACT — a later automated step parses your plan file with a regex and the run is ABORTED if it does not match. This contract overrides any output format specified by any skill you read, and overrides the format of any existing plan.md you may find under .archloop/ from previous runs. Those older files use a different, obsolete format — do NOT imitate them.

$WORK/plan.md must contain one section per item, each starting with a line of EXACTLY this form, at the left margin, with two hashes:

## Item: some-kebab-case-name

Not '# Plan', not '## Candidate 1', not a 'Candidate:' frontmatter block, not three hashes. The literal string '## Item: ' followed by a short kebab-case name. Example of a valid plan.md skeleton for two items:

    ## Item: fold-foo-into-bar
    ...full self-contained plan for this item...

    ## Item: drop-dead-alias
    ...full self-contained plan for this item...

BEFORE you write PLANNED to the verdict file, run this exact check and confirm it prints one line per Strong candidate:
    grep -c '^## Item: ' $WORK/plan.md
If it prints 0, your plan.md is malformed — rewrite it in the required format.

NOW THE TASK. Read and follow the skill at $SKILLS/improve-codebase-architecture/SKILL.md to scan THIS repo for deepening opportunities, with these overrides.

OUTPUT: write the full candidate list as plain markdown to $WORK/scan.md (NO html report, NO browser). Never edit source code in this session.

EXCLUDE every candidate the ledger at $LEDGER marks SHIPPED — that work is already in the tree.

Ledger entries marked PARKED are NOT excluded. A park often means the session ran out of turn or hit a collateral test break, not that the candidate was bad. Re-propose a PARKED candidate if it still qualifies as Strong, and say in scan.md that you are retrying it and what you think went wrong last time. Do not re-propose one that parked because the refactor itself was judged not worth its risk.

CALIBRATE 'Strong' strictly. Strong means BOTH: (a) the duplication or split contract spans 3+ sites, or has a silent failure mode where drift produces no error and no test failure; AND (b) the fix removes more code than it adds. A tidy-up under ~20 lines with no failure mode is Speculative, not Strong. Do not inflate strength to give yourself work — an honest NONE is a valid and useful outcome.

If NO candidate is Strong under that bar, write the single word NONE to $WORK/verdict and stop.

Otherwise write ONE plan to $WORK/plan.md covering EVERY Strong candidate, at most $MAX_ITEMS of them, best first. Structure it as one section per item, each beginning with a header line of exactly this form:

## Item: <short-kebab-name>

Each item section MUST be self-contained — a separate implementer session will be given the plan and told to implement that ONE section without reading the others. Each section needs: the problem and why it is worth fixing, concrete ordered steps, the exact files and symbols involved, the test strategy, and an explicit 'Behavior delta' subsection.

RULES for every item:
- Behavior-preserving refactors only. If an item DOES change observable behavior (e.g. fixing a latent bug the refactor exposes), say so plainly in its Behavior delta — do NOT label it 'behavior-preserving' anyway.
- No cross-item smuggling. An item's steps must not implement another item's change. Every Strong candidate gets its own section.
- No open decisions: no 'or', no 'TBD', no two live options. Decide in the plan.
- Prefer deleting code to adding it. If a step leaves dead code behind (a now-unused constant, alias, or field), the step deletes it rather than deferring it as 'out of scope'.

Then write the single word PLANNED to $WORK/verdict."

V="$(verdict "$WORK/verdict")"
if [ "$V" = "NONE" ]; then
  report "No Strong candidates — nothing to do."
  echo "- $NIGHT scan: NONE (no Strong candidates)" >> "$LEDGER"
  log "scan found nothing Strong — run complete"
  exit 0
fi
if [ "$V" != "PLANNED" ]; then
  report "Scan/plan failed ($V) — nothing shipped."
  log "ABORT: scan/plan verdict $V"
  exit 1
fi

# ponytail: trailing space would leak into commit messages and gate-<item>.md
mapfile -t ITEMS < <(sed -n 's/^## Item: *\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$WORK/plan.md" | head -n "$MAX_ITEMS")
if [ "${#ITEMS[@]}" -eq 0 ]; then
  # ponytail: dump the headers it DID write — otherwise diagnosing a format
  # drift means re-reading plan.md by hand every time (happened 2026-07-28).
  log "ABORT: no '## Item:' sections in plan.md — headers found were:"
  grep -n '^#' "$WORK/plan.md" 2>/dev/null | head -20 | tee -a "$WORK/driver.log"
  report "Plan contained no '## Item:' sections — nothing shipped. See driver.log for the headers it emitted."
  exit 1
fi
log "plan contains ${#ITEMS[@]} item(s): ${ITEMS[*]}"
report "Plan: $WORK/plan.md — ${#ITEMS[@]} item(s)"
report ""

# --- Stage 2 — per item: implement -> gate -----------------------------------
N=0
for ITEM in "${ITEMS[@]}"; do
  N=$((N + 1))
  BASE="$(git -C "$WORKTREE" rev-parse HEAD)"

  session "$M_IMPL" "i$N-implement" "Implement EXACTLY ONE item from the plan at $WORK/plan.md in this repo: the section headed '## Item: $ITEM'. Ignore every other item section — another session owns those.

Implement it exactly as written. No scope additions, no drive-by refactors, no changes the section does not call for.

EVERY numbered step is mandatory, including the test steps. If the section says to add a test — especially if it hands you the test body as a snippet — you add that test. A passing suite does NOT mean you are done: the suite passes today, before your change, so green proves nothing about the steps you skipped. Skipping a test step is the single most common way this stage fails review.

Before finishing run: $ARCHLOOP_TEST_CMD && $ARCHLOOP_LINT_CMD — both must pass.

Then, BEFORE writing your verdict, self-check: list the section's numbered steps and, for each, name the file you changed to implement it. If any step has no corresponding change, go back and do it. Commit all your work with message 'archloop: $ITEM'. Then write the single word DONE to $WORK/verdict (or FAILED if you cannot reach green)."

  if [ "$(verdict "$WORK/verdict")" != "DONE" ] || ! green "i$N-impl" 3; then
    park "$ITEM" "implement" "$BASE"; continue
  fi

  session "$M_GATE" "i$N-gate" "You are the ONLY reviewer of this change, and you have fix authority. Review the diff DIRECTLY yourself — do NOT invoke skills (no code-review) and do NOT spawn sub-agents; those fan out into parallel model sessions that burn quota.

Review 'git diff $BASE..HEAD' in this repo against the '## Item: $ITEM' section of $WORK/plan.md. Do not praise. Do not summarise the diff back to me.

Hunt for, in order:
0. PLAN STEPS NOT IMPLEMENTED. Do this check FIRST and explicitly. Enumerate the item section's numbered steps one by one, and for each, name the hunk of the diff that implements it. A step the diff does not implement is a BLOCKER — most often a test the plan specified and the implementer skipped. Note that the test suite passing does NOT prove the plan's tests were written: a diff that adds an untested field is green precisely BECAUSE nothing pins it. If the plan supplied a test snippet and the diff has no test changes, that is a blocker, and the fix is to add the test the plan already wrote for you.
1. Behavior changes hiding inside the refactor — anything observable that the section's 'Behavior delta' does not declare.
2. A dishonest 'behavior-preserving' claim — the section says behavior-preserving but the diff (or the section's own body) changes behavior.
3. Broken, missed, or silently-diverging callers of anything the diff touched.
4. Weakened, vacuous, or redundant tests — a test that would pass without the change; a test that only asserts a field exists; two tests that are now the same scenario.
5. Scope invention — code in the diff that no step of THIS item asked for, including work belonging to another item.
6. Shallow-module smell — a pass-through layer added instead of behavior behind a small interface. Apply the deletion test.
7. Dead leftovers — a constant, alias, parameter, or field the refactor just orphaned and did not delete.

Write your findings to $WORK/gate-$ITEM.md.

VERDICT RULES — these are binding:
- Anything you find above the level of a typo is a BLOCKER. There is no 'minor note' escape hatch: either FIX it yourself, or write PARK.
- Fix by preference. After any fix run $ARCHLOOP_TEST_CMD && $ARCHLOOP_LINT_CMD and commit with message 'archloop: gate fixes $ITEM'.
- Write PARK when a finding cannot be fixed within this item's scope, or when the item turned out not to be worth its risk.
- Write SHIP only when the diff is clean or you have fixed it clean. SHIP asserts you found nothing outstanding — not that a human could clean it up later.

Before you review, state in gate-$ITEM.md what specific finding WOULD make you PARK this item. Then review. A gate that never parks is not a gate.

Finally write to $WORK/verdict the single word SHIP or PARK." "$GATE_TIMEOUT"

  if [ "$(verdict "$WORK/verdict")" = "SHIP" ] && green "i$N-gate" 3; then
    echo "- $NIGHT $ITEM: SHIPPED on $BRANCH ($(git -C "$WORKTREE" rev-parse --short HEAD))" >> "$LEDGER"
    report "- **$ITEM** — SHIPPED: $(git -C "$WORKTREE" rev-parse --short "$BASE")..$(git -C "$WORKTREE" rev-parse --short HEAD) — see $WORK/gate-$ITEM.md"
  else
    park "$ITEM" "gate" "$BASE"
  fi
done

# --- Stage 3 — merge shipped work back to $BASE_BRANCH ------------------------
SHIPPED="$(git -C "$REPO" rev-list --count "$BASE_BRANCH".."$BRANCH" 2>/dev/null || echo 0)"
if [ "$SHIPPED" -gt 0 ] && [ "$MERGE_ENABLED" = "1" ]; then
  log "merging $BRANCH ($SHIPPED commit(s)) into $BASE_BRANCH"
  git -C "$REPO" merge --no-ff "$BRANCH" -m "archloop: merge night-$NIGHT ($BRANCH)" \
    > "$WORK/merge.log" 2>&1 \
    || { report "MERGE FAILED — see $WORK/merge.log; branch $BRANCH kept for manual merge"; log "ABORT: merge failed"; exit 1; }
  MERGE_SHA="$(git -C "$REPO" rev-parse --short HEAD)"
  report "- **merge** — $BRANCH → $BASE_BRANCH at $MERGE_SHA ($SHIPPED commit(s))"
  if [ "$PUSH_ENABLED" = "1" ]; then
    git -C "$REPO" push origin "$BASE_BRANCH" > "$WORK/push.log" 2>&1 \
      || { report "PUSH FAILED — see $WORK/push.log; local merge $MERGE_SHA kept, remote behind"; log "ABORT: push failed"; exit 1; }
    report "- **push** — origin/$BASE_BRANCH updated to $MERGE_SHA"
  fi
else
  [ "$SHIPPED" -gt 0 ] && report "- **merge** — disabled (ARCHLOOP_MERGE=0); branch $BRANCH left for manual merge"
  [ "$SHIPPED" -eq 0 ] && report "- **merge** — nothing shipped; no merge"
fi

report ""
report "Scan (full candidate pool, incl. non-Strong): $WORK/scan.md"
report "Ledger: $LEDGER"
log "run complete — report: $REPORT"
