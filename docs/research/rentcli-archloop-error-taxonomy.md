# rentcli archloop error taxonomy

Research resolution for dex ticket `4jkmzq2p` (Taxonomy of rentcli archloop
errors), wayfinder map `ilph0j0d`. Gathered 2026-09-26 by a dispatched
research subagent from `/home/andre/git/rentcli/.archloop/` (status.json,
ledger.md, loop-driver.log, night dirs) and `~/.hermes/logs/archloop-night.log`.

## Current state

Idle, not alive (`alive: false, stage: idle`). Last run Sep 25 02:18: shipped
2 items, then the round-2 scan died on provider credits. Nothing queued or
running.

## Inventory

36 night dirs: 19 plain dates, 17 suffixed. Most `-roundN` suffixes are
successful multi-round continuations (Sep 4 rounds 2–3, Aug 13 rounds 2–4 all
shipped); `night-2026-07-28.v1` is the legacy v1 driver format. Genuinely
failed dirs: 07-24.stale, 07-28.abort1, four 08-08 variants, 08-17 (round1),
08-27, 09-25 (round2).

## Error taxonomy

1. **Provider auth/credits (2 runs)** — Aug 8, Sep 25 (latest failure).
   `Error: [401]: Missing API key.` (deepseek-401 dir)
   `Error: [openrouter/z-ai/glm-5.3-flash] [402]: This request would exceed your available credits given your current in-flight requests. Retry after in-flight requests settle, or add credits. (reset after 2m)`
   Root cause: operational — expired key / exhausted openrouter credits
   mid-night. Not a code problem.

2. **Scan/plan hang → 600s kill (3 runs)** — Jul 24 (exit 124 after 2h),
   Aug 17, Aug 27.
   `session scan-plan: no output for 600s — killing` →
   `ABORT: scan/plan verdict MISSING` (exit 143).
   Root cause: provider stall via openrouter/opencode-proxy; no streaming
   output, watchdog fires.

3. **Baseline red at preflight (5 runs)** — Jul 24 02:16, Aug 8 ×3
   (15:37/15:41/15:46), Sep 23 22:39.
   `green preflight FAILED after 1 attempt(s)` /
   `ABORT: baseline red — fix tests/lint before an unattended run`.
   Root cause: main's tests/lint already broken before the loop started; the
   loop correctly refuses.

4. **Implement output breaks tests → items PARKED (2 runs, 3 items)** —
   Jul 28, Aug 17.
   `green i1-impl FAILED after 3 attempt(s)` →
   `PARK: remove-dead-filter-settings-filtering at implement`.
   Verbatim: `ImportError: cannot import name 'apply_filters' from
   'rentcli.application.filter_settings'`. rootdir was the worktree but the
   import resolved to `/home/andre/git/rentcli/...` — the green env imports
   the canonical checkout, not the worktree, so agent renames are invisible to
   the check. Also: retries fired 1s apart (instant, not real re-runs).

5. **Plan unparseable (1 run)** — Jul 28.abort1:
   `ABORT: no items parsed from plan.md` — minimax-m3 omitted `## Item:`
   sections.

~19 further nights were skipped without running (`SKIP rentcli: dirty
canonical checkout` Sep 12–23; `no new commits` Aug 28–Sep 3, Sep 5–11) —
this explains the Aug 27 → Sep 24 gap; skips, not failures.

## Timeline

Rough start (Jul 24–28: baseline red, timeouts, plan-parse failures on
minimax/deepseek), a disastrous Aug 8 afternoon (6 dirs: 3 baseline-red,
2 instant MISSING, 1 auth 401), then a strong stretch (Aug 13–16 clean
multi-round shipping; Sep 4 shipped 9 items over 3 rounds). Recent failures
(Aug 27, Sep 25) are provider-side (hang, 402), not code-side. Trend is
improving; provider reliability is now the weak link.

## Top 3 preventable causes

1. **Provider health checks** — the 401/402 and both 600s hangs are one bad
   provider layer. Add a cheap pre-run model ping and automatic failover to a
   second configured provider/creds.
2. **Baseline red** — 5 aborts found main already broken. Run the green check
   in CI/pre-commit so main can't go red unnoticed between runs.
3. **Green-check environment** — the Aug 17 park traces to pytest importing
   the canonical checkout from inside a worktree. Fix the venv/sys.path in the
   worktree, make implement run tests before handing off, and make green
   retries actually re-execute.

Key evidence files: `.archloop/loop-driver.log`,
`.archloop/night-2026-09-25/scan-plan.log` (402),
`.archloop/night-2026-08-08-171504-deepseek-401/scan-plan.log` (401),
`.archloop/night-2026-08-17-0140-round2/green-i1-impl.log` (ImportError),
`~/.hermes/logs/archloop-night.log` (skip history).
