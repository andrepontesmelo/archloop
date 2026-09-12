# Contributing

Thanks for looking at archloop. PRs welcome.

## Workflow

1. Fork / branch from `main`.
2. Make the change with a scenario that pins it in
   `scripts/stub-validation.sh`.
3. Run the local gate:

   ```bash
   bash scripts/stub-validation.sh
   ```

   For harness-path changes, also run the concurrency gate (same one CI
   runs):

   ```bash
   bash scripts/concurrency-gate.sh
   ```

4. Open a PR describing what changed and why.

CI runs the same gate (`bash scripts/stub-validation.sh`, no setup steps); a
PR is mergeable when it is green.

## Ground rules

- Bash with `set -uo pipefail`; no dependencies beyond bash, git, and a
  session runner on PATH. No new runtime dependencies without discussion.
- Model defaults live in `run.sh` only — do not duplicate them elsewhere.
- `verdict` files are the only model output contract; never grep REPORT prose
  from the script.
- Green is the gate everywhere; red items reset `--hard` and park — keep it
  that way.
- Update [docs/](docs/index.md) when stage behavior, knobs, or the verdict
  contract changes.
- Never commit home paths, IPs/hostnames, session IDs, tokens, or
  credentials — grep the diff and OCR any images before pushing.

## Reporting bugs

Open a GitHub issue with: archloop commit, target-repo layout (test/lint
commands), the relevant section of `.archloop/night-<date>/driver.log`, and
the verdict file contents. Redact anything private — artifacts contain repo
paths and model output, never credentials.

## Security

See [SECURITY.md](SECURITY.md) — please do not open public issues for
security reports.
