# archloop fleet status — 2026-09-26

Research resolution for dex ticket `3lpbxtjw` (Fleet-wide archloop status and
cross-repo failure patterns), wayfinder map `ilph0j0d`. Gathered 2026-09-26 by
a dispatched research subagent from per-repo `.archloop/` state and
`~/.hermes/logs/archloop-night.log`.

## Fleet table (canonical repos)

| repo | last run | alive/stage | health | key signal |
|---|---|---|---|---|
| campcli | 09-25 (2 rounds) | no — `stage: "done"` r2/8 | ok | "scan found no Strong candidates — DONE"; 19 night dirs, zero failure suffixes |
| rentcli | 09-25 | no — `stage: "idle"` | ok (noisy) | 36 night dirs; round2 merged 3 commits, then `run.sh failed (exit 1)` after "run complete"; old `night-2026-07-24.stale`, `night-2026-07-28.abort1` |
| ynab-pilot | 09-25 (aborted r1) | no — `idle` | errors | ABORT: baseline red — black: "2 files would be reformatted" (`tests/test_op_runs.py`, `tests/test_sync.py`) |
| andre-archloop | 09-24 (aborted) | no — no status.json | errors | `night-2026-09-24-failed-429x2`: "Error: Rate limit reached for requests" → "ABORT: scan/plan verdict MISSING"; same-night retry failed identically |
| casa-gungalilin | 09-06 | no — no status.json | stale | last line `run.sh failed (exit 1) — stopping loop`; dirty checkout (M site/src/data/availability.json) blocks every night since 09-12 |
| rentcli-wt-realtorca | never | never | never | 0 night dirs; always "on 'feat/realtorca-source' not main" (55×) |

Worktree configs (t_*/...) under rentcli (~32), ynab-pilot (~14), campcli (2)
are inherited copies, not separate repos. Retired: cockpit, show-dex,
night-run-explorer, vtcli (under `~/git/archive/`, skipped "board archived
(retired)").

## Nightly launcher decisions (log ~09-01→09-26, 833 lines)

- STARTs: rentcli 17, andre-archloop 12, campcli 11, ynab-pilot 8,
  casa-gungalilin 3.
- All-time skips: "no new commits" 150, "dirty canonical checkout" 127,
  "not main" 55, retired boards 96.
- Since 09-12: **66 dirty-checkout skips, 16 not-main, 8 no-new-commits;
  nothing ran 09-08→09-22** — the fleet was fully dark for two weeks. Runs
  resumed only via manual off-schedule launches (09-23 22:35, 09-25 night).
- Tonight (09-26): all 6 skipped; no loop alive (all status PIDs dead).

## Cross-fleet patterns

1. **`.horizon/` artifacts dirty every repo at once** — skip listings show
   `?? .horizon/` verbatim in andre-archloop, campcli, rentcli, ynab-pilot
   (plus `?? .env.bak-20260911-151827` in ynab-pilot). One tooling artifact
   caused the 09-12→09-23 fleet-wide blackout. Not gitignored anywhere.
2. **Provider 429 rate limits** — andre-archloop's `failed-429x2` dir, and
   the 09-23 22:38–22:39 wave where andre-archloop, rentcli, ynab-pilot all
   hit `run.sh exit 1` within 51 seconds (shared API quota).
3. **Preflight/lint gates abort pre-run** — ynab-pilot's black reformat
   failure mirrors rentcli's baseline-red class; worktree branch policy
   permanently sidelines rentcli-wt-realtorca.

## Worst offenders

1. **andre-archloop** — only repo with repeated hard failures (429 ×2,
   verdict MISSING ×2); its own loop can't refactor itself.
2. **ynab-pilot** — preflight abort 09-25, exit 1 on 09-23; produced nothing
   since 09-02.
3. **rentcli** — 36 dirs with .stale/.abort1 history and exit-1 endings,
   though it ships the most (2 items SHIPPED 09-25).
