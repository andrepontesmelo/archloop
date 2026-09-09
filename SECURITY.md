# Security Policy

## Scope

archloop is a local automation driver: it sequences model sessions that read
and write code in an isolated worktree, then merges reviewed results. It does
not hold credentials — model keys live in the session runner's config, not
here.

## Supported versions

Only the latest commit on `main` receives security fixes.

## Reporting a vulnerability

Email the owner via the contact on the GitHub profile (andrepontesmelo)
rather than opening a public issue. Include: affected commit, the driver
script and stage involved, and expected vs actual behavior. You will get an
acknowledgement within 7 days and a fix or a documented mitigation for
anything confirmed.

## What is NOT a vulnerability

- The loop executing agent-written code in a worktree — that is the product's
  purpose. Review configs before unattended overnight runs; the loop never
  touches the canonical tree but it does run what the sessions wrote.
- A SHIPped change that turns out to be wrong — that is a review-quality
  issue, not a security issue. Read `gate-<item>.md` and the morning diff;
  a bad run costs one `git reset --hard` plus branch delete.
- Driver logs containing repo paths or model output — artifacts by design,
  never credentials. Do not paste unredacted logs into public issues.
