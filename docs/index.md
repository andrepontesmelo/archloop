# archloop docs

Unattended overnight architecture-improvement loop: a deterministic bash state
machine that scans a repo for architecture debt, implements each Strong find,
and gates every change with a fresh-context review before merge.

## Start here

1. [README](../README.md) — what it does, install, quick start.
2. [Architecture](architecture.md) — pipeline, pieces, verdict contract, sequence.
3. [Development](development.md) — layout, the local gate
   (`bash scripts/stub-validation.sh`), conventions, pre-push checklist.

## Reference in this repo

- [run.sh](../run.sh) — the single-round driver: preflight, scan, plan,
  implement, gate, merge, push. Design decisions live in its header comment.
- [archloop-loop.sh](../archloop-loop.sh) — loop-until-NONE driver; re-runs
  `run.sh` until the scan verdict is `NONE` or `MAX_ROUNDS` is hit.
- [scripts/stub-validation.sh](../scripts/stub-validation.sh) — the local gate:
  zero-quota stub harness, 25 assertions across 6 scenarios.
- [scripts/concurrency-proof.sh](../scripts/concurrency-proof.sh) — local-only
  evidence that two parallel gate runs do not interfere (too slow for CI,
  not a CI step).
- [archloop-workflow.json](../archloop-workflow.json) — source data for the
  workflow diagram ([archloop-workflow.html](../archloop-workflow.html),
  generated, do not edit by hand).

## FAQ

**What does a night cost me?**
Nothing unattended except model quota: the script itself is deterministic bash.
Supervise the first run on a new repo — sessions that hit a permission prompt
hang until the idle watchdog fires.

**What are the per-repo requirements?**
The target repo must define `ARCHLOOP_TEST_CMD` and `ARCHLOOP_LINT_CMD` (env
or `<repo>/.archloop/config`). `run.sh` refuses to run without them. Both
commands must be in the session runner's bash allowlist or stages hang.

**What counts as a Strong candidate?**
Duplication or a split contract spanning 3+ sites, or a silent failure mode —
and the fix must remove more code than it adds. Everything else is Weak and
never planned.

**Where do artifacts live?**
Under the target repo's `.archloop/night-<date>/` — `scan.md`, `plan.md`,
per-item gate reports (`gate-<item>.md`), `REPORT.md`, `driver.log`, and the
structured `verdict` file the script greps. `.archloop/ledger.md` is the
durable SHIPPED/PARKED record. The loop excludes `.archloop/` from git status
itself via `.git/info/exclude`.

**Can I re-run a night?**
Yes — `archloop-loop.sh` moves the previous night dir aside (audit suffix) so
`REPORT.md` never aborts the next run, and each attempt gets its own worktree
base so a stray cleanup trap cannot delete the live worktree.

**Why did my item PARK?**
A PARK resets the branch to the item base and costs one item, not the night.
Read `gate-<item>.md` in the night dir for the reviewer's rationale.
