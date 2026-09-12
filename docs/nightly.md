# Nightly runs

The loop is built to run unattended on a schedule: `archloop-loop.sh` scans,
implements, gates and merges until the scan reports no Strong candidates or
`MAX_ROUNDS` (default 8) caps the night. All a scheduled run needs is the
command itself — the driver writes all logs and artifacts into the **target
repo's** `.archloop/`: `loop-driver.log` at the top, per-round artifacts under
`.archloop/night-<date>/`, and `.archloop/ledger.md` as the durable
SHIPPED/PARKED record. Nothing is written into archloop itself, and the
driver excludes `.archloop/` from the target's git status itself.

## One-command install (cron)

Run once, with your real paths substituted:

```bash
( crontab -l 2>/dev/null; echo "17 2 * * * /path/to/archloop/archloop-loop.sh /path/to/target-repo" ) | crontab -
```

- `17 2 * * *` — 02:17 every night; pick an off-peak minute.
- The driver resolves its own location from `$0`, so the cron entry needs no
  `cd` and no wrapper script.
- cron runs with a minimal PATH (`/usr/bin:/bin`); if `git` or any tool a
  round shells out to lives elsewhere (e.g. `~/.local/bin`), prefix the
  entry: `17 2 * * * PATH=$HOME/.local/bin:$PATH /path/to/...`.
- Verify with `crontab -l`; after the first fire, read
  `/path/to/target-repo/.archloop/loop-driver.log` — every round, run.sh
  stage line, and verdict lands there.

## Alternative: systemd user timer

`~/.config/systemd/user/archloop-nightly.service`:

```ini
[Unit]
Description=archloop nightly improvement loop

[Service]
Type=oneshot
WorkingDirectory=%h/path/to/archloop
ExecStart=%h/path/to/archloop/archloop-loop.sh %h/path/to/target-repo
```

`~/.config/systemd/user/archloop-nightly.timer`:

```ini
[Unit]
Description=run archloop nightly

[Timer]
OnCalendar=*-*-* 02:17:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable once:

```bash
systemctl --user daemon-reload
systemctl --user enable --now archloop-nightly.timer
systemctl --user list-timers archloop-nightly.timer   # verify
```

`Persistent=true` catches up a missed 02:17 (laptop was off); logs land in
the target's `.archloop/loop-driver.log` exactly as with cron. Add
`[max_items] [max_rounds]` after the repo path, or export
`ARCHLOOP_MAX_ITEMS` / `ARCHLOOP_MAX_LOOPS` in the service unit.

## Before you let it run unattended

- The target repo must define `ARCHLOOP_TEST_CMD` and `ARCHLOOP_LINT_CMD`
  (env or `<repo>/.archloop/config`); `run.sh` aborts without them.
- Model credentials must work non-interactively for the session runner.
- Cron/systemd run headless: any stage that hits a permission prompt hangs
  until the idle watchdog fires. Supervise the first night on a new repo —
  after that the state machine is deterministic and crash-restartable.
- Re-runs are safe: a previous same-night directory is moved aside as an
  audit copy, so a manual or catch-up run never aborts on old artifacts.
