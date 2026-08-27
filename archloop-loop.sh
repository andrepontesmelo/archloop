#!/usr/bin/env bash
# archloop-loop.sh — loop-until-NONE driver for archloop (single home: this repo).
# Re-runs run.sh until the scan reports no Strong candidates (verdict file says
# NONE), or MAX_ROUNDS is hit (safety cap against PARKED re-proposals).
# Usage: bash archloop-loop.sh /path/to/repo [max_items] [max_rounds]
# Env: HOME must be the REAL user home (Hermes sandboxes it) — overridden via
#      getent fallback, same as run.sh does for opencode.
#
# v3 (2026-08-03): consolidated into the repo as the single loop driver.
#   - NONE detection reads the structured verdict file ($WORK/verdict == NONE)
#     instead of grepping REPORT.md prose ("No Strong candidates"). The runner
#     writes the verdict; prose is for humans and can drift. A shipped run
#     overwrites verdict with the last gate's SHIP/PARK, so a surviving NONE
#     unambiguously means the scan found nothing.
#   - Runner resolved relative to this script first (it lives beside run.sh);
#     ARCHLOOP_RUNNER overrides; real-home fallback last.
# v2 (2026-08-03, ynab-pilot): per-attempt worktree base + orphan kill.
#   The race that killed the first loop: the driver was SIGTERM'd but its run.sh +
#   opencode child survived orphaned; the relaunch recreated the worktree at the
#   SAME date-scoped path; when the orphan finally exited, its `trap cleanup EXIT`
#   ran `git worktree remove --force` on that path -> the live worktree was deleted
#   mid-scan, every file access silently failed (opencode.log: NotFound
#   FileSystem.access), and the idle watchdog killed the session 600s later looking
#   like a model hang. Each attempt now gets its OWN ARCHLOOP_WORKTREE_BASE so a
#   stray trap can only remove its own attempt's path, and any orphaned run.sh
#   for THIS repo is killed before relaunching (repo-scoped pkill — never broad).
set -uo pipefail

REPO="$(realpath "${1:?usage: archloop-loop.sh /path/to/repo [max_items] [max_rounds]}")"

# Export HOME BEFORE resolving RUNNER: run.sh lives in the real user home, and
# any path resolved against the sandboxed HOME (or via cwd-relative ../ chains,
# which break the moment the driver cd's elsewhere) misses it — verified
# 2026-08-03 on campcli: `./run.sh: No such file or directory`, rc=127.
HOME="$(getent passwd "$(id -un)" | cut -d: -f6)"
export HOME
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="${ARCHLOOP_RUNNER:-$SCRIPT_DIR/run.sh}"
[ -f "$RUNNER" ] || RUNNER="$HOME/git/andre-archloop/run.sh"
[ -f "$RUNNER" ] || { echo "ABORT: run.sh not found (set ARCHLOOP_RUNNER)"; exit 1; }

MAX_ITEMS="${2:-${ARCHLOOP_MAX_ITEMS:-5}}"
MAX_ROUNDS="${3:-${ARCHLOOP_MAX_LOOPS:-8}}"

NIGHT="$(date +%F)"
WORK="$REPO/.archloop/night-$NIGHT"
LOGFILE="$REPO/.archloop/loop-driver.log"

log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOGFILE"; }

log "archloop loop driver v3 start — repo=$REPO max_items=$MAX_ITEMS max_rounds=$MAX_ROUNDS runner=$RUNNER"
for i in $(seq 1 "$MAX_ROUNDS"); do
  log "=== round $i/$MAX_ROUNDS: starting run.sh ==="

  # Kill orphaned run.sh from a PREVIOUS attempt of THIS repo only. Exact repo
  # path in the pattern — never matches a foreign loop on another repo.
  pkill -f "andre-archloop/run.sh $REPO" 2>/dev/null \
    && log "killed orphaned run.sh from previous attempt" || true

  # Per-attempt worktree base (v2 fix): a stray cleanup trap from a killed
  # attempt can only remove ITS OWN attempt's path, never the live worktree.
  ARCHLOOP_WORKTREE_BASE="$HOME/.cache/archloop/$(basename "$REPO")-a$i"
  export ARCHLOOP_WORKTREE_BASE

  # Move the previous night dir aside (keep as audit) so REPORT.md does not
  # abort the next run (same-night re-run rule). Ledger persists outside it.
  if [ -d "$WORK" ]; then
    mv "$WORK" "$WORK-$(date +%H%M)-round$i" && log "moved $WORK aside (audit)"
  fi

  bash "$RUNNER" "$REPO" "$MAX_ITEMS" >> "$LOGFILE" 2>&1
  rc=$?
  log "=== round $i: run.sh exit $rc ==="
  if [ $rc -ne 0 ]; then
    log "run.sh failed (exit $rc) — stopping loop"
    exit $rc
  fi
  # v3: read the structured verdict. NONE survives only if the scan found
  # nothing (a shipped run overwrites verdict with the last gate's SHIP/PARK).
  if [ -f "$WORK/verdict" ] && [ "$(tr -d '[:space:]' < "$WORK/verdict")" = "NONE" ]; then
    log "scan found no Strong candidates — DONE after $i round(s)"
    exit 0
  fi
  log "round $i: items shipped — continuing"
done
log "MAX_ROUNDS=$MAX_ROUNDS reached — stopping (still had suggestions)"
exit 2
