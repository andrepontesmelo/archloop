# archloop

Unattended overnight architecture-improvement loop for a git repository. A
deterministic bash state machine drives a fixed scan -> plan -> implement ->
gate pipeline until the codebase scan reports no Strong candidates left.

## What it does

`archloop-loop.sh` is the loop-until-NONE driver. It re-runs `run.sh` against a
target repo until the scan reports no Strong candidates, or the `MAX_ROUNDS`
safety cap is hit (default 8; PARKED items can be re-proposed, so the cap stops
a night that never converges).

Each round of `run.sh` walks a fixed state machine:

1. Preflight: abort unless the canonical checkout is clean, on `main`, and the
   baseline tests + lint are green. The canonical tree is never touched.
2. Scan (one session): read the architecture-scan skill, list Strong candidates
   (duplication or split contracts spanning 3+ sites, or a silent failure
   mode; the fix must remove more code than it adds). Write one plan covering
   every Strong candidate, best first. If nothing qualifies, write `NONE` to
   the verdict file and stop.
3. Implement (one session per item): apply that item's plan section in an
   isolated worktree, keep tests + lint green.
4. Gate (one session per item): fresh-context review of the diff against the
   plan. SHIP or PARK per item. A PARK resets the branch to base and costs one
   item, not the night.
5. Merge + push: SHIPped items merge `--no-ff` back into `main` and push at the
   end of the run (`ARCHLOOP_MERGE=0` / `ARCHLOOP_PUSH=0` disable).

Every stage reads and writes files under the repo's `.archloop/` directory
(artifacts, not memory): the run is crash-restartable and fully auditable.

The orchestrator is a script, not a model: the sequence is a fixed state
machine, deterministic, free, restartable, and immune to overnight context rot.
Models think inside stages; the script sequences them and greps one-word
verdict files. One fresh `opencode run` session is one stage boundary.

## When to reach for it

- You have a repo with a green test suite and lint, and a backlog of
  architecture debt (duplication, split contracts) that nobody gets time to
  attack during the day.
- You want the night to produce a small, adversarially reviewed diff you can
  read in the morning, not a big-bang refactor.
- You can supervise the first run: non-interactive opencode sessions that hit a
  permission prompt hang until the idle watchdog fires. Add
  `ARCHLOOP_TEST_CMD` / `ARCHLOOP_LINT_CMD` to opencode's bash allowlist before
  trusting this unattended.

Do not reach for it when the tree is dirty, the baseline is red, or the repo's
tests are flaky enough that a PARK would be a false negative.

## Install

Prerequisites:

- bash (the scripts are `set -uo pipefail` bash)
- git (worktrees, branches, merge)
- [opencode](https://opencode.ai) CLI on PATH or at `$HOME/.opencode/bin/opencode`
  (`ARCHLOOP_OPENCODE` overrides)
- A test command and a lint command for the target repo, passed via
  `ARCHLOOP_TEST_CMD` and `ARCHLOOP_LINT_CMD` or the repo's
  `.archloop/config`; the script refuses to run without both.

The repo is self-contained (the single home design): `archloop-loop.sh` and
`run.sh` live beside each other, the loop resolves the runner relative to
itself, `ARCHLOOP_RUNNER` overrides, and `$HOME/git/andre-archloop/run.sh` is
the fallback. Runtime state (`.archloop/`, worktrees under
`~/.cache/archloop/`) stays untracked via `.gitignore` and
`.git/info/exclude`.

Run one loop round against a target repo:

```bash
bash archloop-loop.sh /path/to/repo [max_items] [max_rounds]
```

or a single pass (scan through merge) with:

```bash
bash run.sh /path/to/repo [max_items]
```

HOME must be the real user home. Hermes-style sandboxes point HOME at a profile
directory, which breaks opencode resolution, the scan skill path, and the
worktree base; both scripts resolve the real home via
`getent passwd "$(id -un)"` and export it. Run the loop driver from a real
shell and it handles this for you.

Per-repo knobs (env or `<repo>/.archloop/config`; the positional `max_items`
argument wins over both): `ARCHLOOP_MAX_ITEMS`, `ARCHLOOP_MAX_LOOPS`,
`ARCHLOOP_MODEL_SCAN` / `ARCHLOOP_MODEL_IMPL` / `ARCHLOOP_MODEL_GATE`,
`ARCHLOOP_OPENCODE`, `ARCHLOOP_WORKTREE_BASE`, `ARCHLOOP_BASE_BRANCH`,
`ARCHLOOP_MERGE`, `ARCHLOOP_PUSH`, `ARCHLOOP_SESSION_TIMEOUT`,
`ARCHLOOP_GATE_TIMEOUT`, `ARCHLOOP_IDLE_TIMEOUT`. `run.sh` sources the repo
config file after reading the environment, so a conflicting config assignment
wins over a launch-time env var.

## It's working if

- After a run the verdict file `.archloop/night-<date>/verdict` says `NONE`
  (a shipped run overwrites it with the last gate's SHIP/PARK, so a surviving
  `NONE` unambiguously means the scan found nothing), and the loop driver
  logged `scan found no Strong candidates — DONE after N round(s)` and exited 0.
- `REPORT.md` was written under `.archloop/night-<date>/` with each item's
  SHIP/PARK line plus the merge and push lines.
- The canonical checkout is still clean and on `main`, the worktree is gone,
  and shipped items are on `main` as an `archloop: merge night-*` commit
  (`git log --oneline -10`).

## License

MIT. See [LICENSE](LICENSE).