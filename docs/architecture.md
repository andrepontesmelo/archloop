# Architecture

How archloop turns one scan into reviewed, merged refactors without an
orchestrator model. Read [run.sh](../run.sh) alongside — its header comment
is the design-decision log; this file maps the moving parts.

## One diagram

```
 canonical checkout (main, clean, green — NEVER touched)
        │  preflight aborts unless clean + main + green
        ▼
 linked worktree ($WORKTREE_BASE/<repo>-night-<date>, branch archloop/...)
        │
 ┌──────┴──────────────────────────────────────────────┐
 │ Stage 0  SCAN — one session reads the scan skill    │
 │          writes scan.md + plan.md, verdict PLANNED  │
 │          (or NONE → stop, exit 0)                   │
 ├─────────────────────────────────────────────────────┤
 │ Stage 1  IMPLEMENT — one session PER ITEM           │
 │          lean prompt fed the plan artifact, tests + │
 │          lint green, commit, verdict DONE           │
 ├─────────────────────────────────────────────────────┤
 │ Stage 2  GATE — one FRESH-CONTEXT session PER ITEM  │
 │          reviews diff vs plan, may fix + commit,    │
 │          verdict SHIP or PARK (park = reset --hard) │
 ├─────────────────────────────────────────────────────┤
 │ Stage 3  MERGE + PUSH — SHIPped items merge --no-ff │
 │          into main and push (toggles disable)       │
 └──────┬──────────────────────────────────────────────┘
        ▼
 .archloop/night-<date>/REPORT.md + driver.log + ledger.md
```

## Pieces

- **`run.sh` — the single-round driver.** Owns preflight (clean tree, on
  `main`, baseline green, stale-worktree prune), worktree creation, every
  stage invocation, the `green` retry helper, `park`, merge `--no-ff` and
  push. Knobs via env or `<repo>/.archloop/config` (config wins over env):
  `ARCHLOOP_TEST_CMD` / `ARCHLOOP_LINT_CMD` (required),
  `ARCHLOOP_MAX_ITEMS` (default 5), `ARCHLOOP_WORKTREE_BASE`,
  `ARCHLOOP_BASE_BRANCH` (default `main`), `ARCHLOOP_MERGE` /
  `ARCHLOOP_PUSH` (default 1), per-role models `ARCHLOOP_MODEL_SCAN` /
  `_IMPL` / `_GATE`, timeouts `ARCHLOOP_SESSION_TIMEOUT` / `GATE_TIMEOUT` /
  `IDLE_TIMEOUT`. Model defaults live in `run.sh` only — never duplicate
  them elsewhere.
- **`archloop-loop.sh` — loop-until-NONE driver.** Re-runs `run.sh` until the
  `verdict` file still says `NONE` after a round (a shipped round overwrites
  it with the last gate's SHIP/PARK, so a surviving NONE unambiguously means
  the scan found nothing) or `MAX_ROUNDS` (default 8) is hit. Per-attempt
  worktree base defeats the orphaned-cleanup-trap race; repo-scoped `pkill`
  kills orphans of this repo only; `.archloop/` is created and git-excluded
  before the first log write so first runs on fresh repos do not abort.
- **Model sessions — one `opencode run` per stage boundary.** Routing is
  independent per stage: scan decides whether the run is worth anything and
  is unrecoverable downstream, so it gets the strongest model, once; the
  gate is the only reviewer left, so it gets the same strong model;
  implementation is transcription of a good plan, so it keeps the cheapest.
  Scan→pick→plan share ONE session (same mental model, no self-review);
  the gate NEVER shares a session with what it reviews — fresh context is
  the mechanism that makes the loop worth running.
- **Verdict files — the only model output contract.** `scan.md`/`plan.md`
  are prose for humans; `$WORK/verdict` is what the script greps
  (`NONE` / `PLANNED` / `DONE` / `FAILED` / `SHIP` / `PARK`). Prose can
  drift; the single word cannot.
- **Artifacts, not memory.** Every stage reads/writes
  `.archloop/night-<date>/`: `scan.md`, `plan.md`, `gate-<item>.md`,
  `REPORT.md`, `driver.log`, `verdict`. `.archloop/ledger.md` is the
  durable SHIPPED/PARKED record that survives night-dir moves. Crash the
  driver mid-run and the morning audit still reads what shipped.
- **Isolation via worktree.** The canonical checkout is never left, tested,
  or committed to. Every session, test run, and park reset happens inside
  the linked worktree; the branch survives worktree removal so the morning
  review still reads `main..<branch>`.

## Sequence (one shipped item)

1. Preflight: `git status` clean, branch is `main`, baseline test+lint green
   (else abort — keep it that way). Prune stale worktrees under the base.
2. Create worktree + branch `archloop/<repo>-night-<date>`; exclude
   `.archloop/` from git status.
3. Scan session → `scan.md`, `plan.md` (`## Item:` sections, best first),
   verdict `PLANNED`. No Strong → verdict `NONE`, stop, exit 0.
4. Per item: implement session → code + tests, green, commit, verdict `DONE`
   (else park: `git reset --hard` to base). Gate session → review diff vs
   plan section, fix-by-preference with green re-check, verdict `SHIP`
   (else park).
5. SHIP appends to ledger + REPORT; PARK appends to ledger + REPORT and
   resets the branch to base.
6. Merge `--no-ff` into `main`, push (unless disabled). Nothing is ever
   force-pushed. Parks never enter the merge because park reset the branch.
