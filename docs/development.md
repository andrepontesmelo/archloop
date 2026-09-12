# Development

## Layout

```
run.sh                     single-round driver (preflight → scan → implement → gate → merge → push)
archloop-loop.sh           loop-until-NONE driver (re-runs run.sh, MAX_ROUNDS cap, default 8)
scripts/stub-validation.sh the local gate — zero-quota stub harness (THE gate, also what CI runs)
scripts/concurrency-gate.sh  CI concurrency gate: two parallel suite runs, both must finish green
archloop-workflow.json     source data for the workflow diagram
archloop-workflow.html     generated diagram (do not edit by hand)
docs/                      index.md (start-here) · architecture.md · development.md (this file)
```

## The local gate

Everything must pass before a commit is considered done:

```bash
bash scripts/stub-validation.sh   # currently 25 assertions across 6 scenarios
```

The harness drives the full state machine with a stub session binary (zero
model quota): happy path (ship → merge → push → cleanup), dirty-tree abort,
wrong-branch abort, gate-park (no merge, ledger records PARK), stale-worktree
prune, and first-run-on-fresh-repo via `archloop-loop.sh`. Concurrency-safe
via per-run `mktemp -d` dirs — parallel runs never collide on shared paths.

CI (`.github/workflows/ci.yml`) runs exactly this gate plus the concurrency
gate: checkout, then `bash scripts/stub-validation.sh`, then
`bash scripts/concurrency-gate.sh` — no setup steps, no test-framework
install, nothing else. CI must equal the local gate; drift is a defect.

`scripts/concurrency-gate.sh` double-runs the whole suite in parallel and
gates on end state only — both runs exit green, no wall-clock assertions — so
it is deterministic and timing-insensitive under Actions. Run it before
releases that touch the harness paths; CI runs it on every push.

## Conventions

- Bash with `set -uo pipefail`; no dependencies beyond bash, git, and a
  session runner on PATH.
- Model defaults live in `run.sh` only — do not duplicate them elsewhere.
- `verdict` files are the only model output contract; REPORT prose is for
  humans and must never be grepped by the script.
- Green is the gate everywhere: baseline green before a run, green after
  every stage that touches code, red items reset `--hard` and park.
- Keep `archloop-workflow.html` generated-only — never edit it by hand;
  regenerate from `archloop-workflow.json`.

## Before you push

- [ ] `bash scripts/stub-validation.sh` green
- [ ] New behavior covered by a scenario in `scripts/stub-validation.sh`
- [ ] Docs updated if stage behavior, knobs, or the verdict contract changed
- [ ] `git status --porcelain` clean on the canonical checkout
- [ ] No committed file contains home paths, IPs/hostnames, session IDs,
      tokens, or credentials (grep the diff, OCR any images)
