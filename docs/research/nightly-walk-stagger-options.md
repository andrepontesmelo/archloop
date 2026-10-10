# Nightly walk topology and stagger options

Research resolution for dex ticket `ut883hhl` (Nightly walk topology and
stagger options), wayfinder map `ilph0j0d`. Gathered 2026-09-27 by a
dispatched research subagent from the launcher script, the nightly log, and
per-repo driver logs.

## Topology

Launcher: `hermes-kanban-recovery-controller/scripts/archloop-night-cron.sh`
(shim `~/.hermes/scripts/archloop-night-cron.sh` execs it). Cron: hermes job
`5b3a912e5b3e` "hkrc archloop nightly", schedule `30 0 * * *` (00:30 local,
`no_agent: true`), enabled, ~45 completions.

- Iteration: `for cfg in "$REPO_ROOT"/*/.archloop/config` (line 458) — bash
  glob, **alphabetical** over `~/git`. Gates per repo: board-archived,
  `pgrep` already-running (line 477), dirty checkout (484), not on main
  (494), new-commits-vs-ledger-mtime (501-509).
- Launch: `setsid nohup ... bash "$LOOP_DRIVER" "$repo" >>"$NIGHT_LOG" 2>&1 &`
  then `sleep 15  # stagger launches so the proxy isn't thundering-herded`
  (lines 515-516). **All loops run fully in parallel**, launches merely 15s
  apart. Line 16 comment: "No max repos per night".
- No flock, queue, or concurrency cap anywhere (grep-confirmed across
  launcher and engine). Half-mechanisms: the 15s sleep, per-repo pgrep guard,
  `DRY_RUN`, env knobs (`ARCHLOOP_RUNNER/NIGHT_LOG/TRIGGER/MAX_ITEMS/
  MAX_LOOPS/MODEL_SCAN/IMPL/GATE` in `run.sh` 121-128, `ARCHLOOP_WORKTREE_BASE`
  in `archloop-loop.sh` 113-114).

## Durations (~/.hermes/logs/archloop-night.log)

- Scan-only nights: 5-20 min, 1 round.
- Productive nights: 1-4 rounds, round = 5-95 min; typical successful loop
  ≈ **1-5 h**.
- Worst cases: campcli 09-04 4h44m (4 rounds); rentcli 09-04 4h48m (3
  rounds); rentcli 08-13 4h25m (4 rounds). Cap: 8 rounds.
- Overlap on busy nights: 3-5 loops concurrent for hours. Before the 15s
  sleep existed, 08-09 21:51:14 shows 6 STARTs in one second.

## Collision evidence

09-23 wave confirmed: launched 15s apart (22:35:48 / 22:36:03 / 22:36:18),
all round 1 in parallel. Deaths: ynab-pilot 22:38:33 and andre-archloop
22:38:39, both `scan-plan` on `zai/glm-5.3-flash`, ending in
`Error: Rate limit reached for requests`. rentcli died 22:39:25 at green
preflight (baseline red) — collateral timing, not provider. Two of three LLM
sessions on the same flash model died 6 seconds apart.

Prior remediation exists: `andre-archloop/.archloop/config` (2026-09-24) —
"scan/impl on glm-5.3 (flash 429s on scan bursts); gate already glm-5.3" —
but `run.sh` defaults (lines 100-104) are still `zai/glm-5.3-flash` for
scan/impl, so other repos remain exposed. Models are single-provider (`zai`),
no failover chain in `run.sh`.

## Option space

| Mechanism | Lives in | Change | Failure modes | Gate interaction |
|---|---|---|---|---|
| (a) Fixed offsets | launcher line 516 | replace `sleep 15` with per-repo `sleep $((15*N))` or config-index offsets | none serious; still parallel if runs exceed gap×N | none — gate is pre-launch |
| (b) Sequential queue | launcher line 515 | drop `&`/setsid → foreground run | a 5h loop delays repos behind it; night ≈ sum of runs; digest prints before runs end | identical |
| (c) Concurrency cap N | launcher | track child PIDs, `wait -n` | ~15 lines bash; zombie/wait pitfalls; detaching is less clean | pgrep guard still dedupes |
| (d) Jittered starts | launcher line 516 | `sleep $((RANDOM % 3600))` | probabilistic collisions; harder to reason about | none |
| (e) Existing knobs | both | per-repo `ARCHLOOP_MODEL_*` in `.archloop/config` (already proven), `ARCHLOOP_MAX_LOOPS` | softens overlap, doesn't prevent it | none |

## Recommendation

**(a) fixed per-repo offsets sized to typical loop duration** — replace the
`sleep 15` with a per-repo interval of 60-90 min (configurable via
`ARCHLOOP_NIGHT_GAP`), keeping setsid. Single-line-class change in one file;
preserves "loops survive cron exit"; spaces even a full 5-repo night across
~00:30-06:00 within the observed 5h worst case; deterministic and
digest-friendly. Mitigate residual overlap cheaply with the already-proven
per-repo model override (bump remaining repos off `glm-5.3-flash` the way
andre-archloop's config did). Pure (b) is the fallback if a hard cap is
demanded, at the cost of serializing multi-hour nights.
