# History browser (`archloop ui`)

A static HTML browser over the `.archloop/` history of any set of checkouts:
nights, derived run status, ledger item rows, LLM-written summaries, gate
excerpts. Zero runtime — no server, no JS, no external fonts. History is
regenerate-on-demand, not live: every page is a plain file you can open with
a browser or commit alongside docs.

## Install

Nothing to install — the browser ships with archloop. The only setup is
telling it which repos to browse (next section).

## Repo discovery

Sources, in precedence order:

1. CLI: `--repo <path>` (repeatable). When given, nothing else is consulted.
2. `$ARCHLOOP_REPOS_CONF`, if set: names a repos.conf file (format below).
   Set means required — a missing file is a hard error (exit 2), and the
   per-line format rules are enforced exactly as always.
3. Auto-discovery (default): a one-level walk of `$ARCHLOOP_REPO_ROOT`
   (default `~/git`), mirroring the nightly launcher's fleet walk
   (`archloop-night-cron.sh` in hermes-kanban-recovery-controller):

   - a directory directly under the root qualifies when it has a
     `.archloop/` dir;
   - paths containing `/.worktrees/` are skipped (non-canonical checkouts);
   - a directory named `archive` is skipped (retired content);
   - the launcher's board check, applied when `~/.hermes/kanban/boards`
     exists: a repo whose board is archived
     (`boards/_archived/<name>`) is a retired project and is skipped; a
     repo with no board at all, or a live board, is included. No boards
     dir → the check is skipped entirely.
   - display name = basename; the fleet is rendered in alphabetical order.

Discovery finding nothing is an error (exit 2) whose message names the root
searched plus the `--repo` / `$ARCHLOOP_REPOS_CONF` alternatives.

### repos.conf format (for `$ARCHLOOP_REPOS_CONF`)

One checkout path per line; `#` comments and blank lines are ignored:

    # archloop UI repos — one checkout path per line
    /home/you/git/project-a
    /home/you/git/project-b

Rules: paths must be absolute and must contain a `.archloop/` dir. A line
naming a path without `.archloop/` is a hard error (exit 2, the offending
line is named). Duplicates collapse. The display name of a repo is the
basename of its path.

A ready-to-copy example lives at
[examples/repos.conf.example](examples/repos.conf.example) — use it together
with `ARCHLOOP_REPOS_CONF`.

### Migration note (breaking change)

`~/.config/archloop/repos.conf` is no longer auto-read: a bare `archloop ui`
now auto-discovers the fleet instead. To keep using an existing list, point
the variable at it:

    export ARCHLOOP_REPOS_CONF="$HOME/.config/archloop/repos.conf"

Explicit `--repo` flags and the conf-file parsing behave exactly as before.

## Usage

    archloop ui [--repo PATH]... [--out DIR] [--format html|text]
                [--no-summarize] [--summarize-only] [--force-summarize]
                [--model ID] [--screenshot [--out-image PATH]] [--no-open]

Defaults: summarize missing sidecars, then render HTML into an ephemeral
view dir — `${TMPDIR:-/tmp}/archloop-ui`, wiped and rebuilt on every run —
and open it in your browser. `--out DIR` renders in place and never opens;
that is the scriptable path (README screenshots, CI).

- `--no-summarize` — parse + render only. Offline, zero sessions, works on
  a corpus with no sidecars at all (fallback titles are used).
- `--summarize-only` — write sidecars only, no site.
- `--force-summarize` — rewrite valid sidecars too (default skips them).
- `--format text` — terminal ledger to stdout instead of HTML.
- `--screenshot [--out-image PATH]` — after rendering, capture
  `DIR/index.html` at 1280x800 as a PNG (default `ui-index.png`).
- `--no-open` — render the bare view but skip the browser step.

Exit codes: 0 success (warnings allowed on stderr); 2 usage/config errors;
1 only when a summarize session failed (sidecars of succeeded items are
still written and the rendered output is still usable).

## LLM summaries (sidecars)

For every item in every night dir the summarize step writes a JSON sidecar
at `<night-dir>/ui/<item>.json`:

    {
      "schema": 1,
      "item": "<kebab item name>",
      "title": "<3-60 chars, human, no trailing period>",
      "details": "<1-3 sentences, <= 500 chars, plain text>",
      "model": "<model id that wrote it>",
      "generated_at": "<ISO 8601>"
    }

Behavior:

- One session per missing sidecar; a valid existing sidecar is never
  rewritten unless `--force-summarize`.
- Output is validated in bash (keys, lengths, item match, raw JSON object
  only — no markdown fence). An invalid sidecar is renamed
  `<item>.json.rejected`, a warning goes to stderr, and the item renders
  with a humanized fallback title and a "no summary" marker. The pipeline
  never fails on bad model output.
- The model follows the archloop precedence chain: `--model` flag >
  `ARCHLOOP_MODEL_SUMMARY` env > repo `.archloop/config` >
  `LANE_BIG` from `scripts/lib/lanes.sh` (single source, no duplicated ids).

## Screenshot backends

`--screenshot` renders the site, then captures the index page via the first
available backend:

1. `$ARCHLOOP_CAPTURE_CMD` — override. Contract: the command is invoked as

       <cmd> <url> <out-image> <width> <height>

   with `url` a `file://` URL of the rendered index page, `out-image` the
   absolute destination path, and dimensions `1280 800`. Write the image to
   `<out-image>` and exit 0.
2. `chromium`, `chromium-browser`, or `google-chrome` (headless
   `--screenshot`).
3. `wkhtmltoimage`.

None found → exit 2 listing what was tried.

## Opening the view

A bare `archloop ui` (no `--out`) opens the rendered index in your browser
after rendering. The opener chain, first that applies:

1. `$ARCHLOOP_OPEN_CMD` — override. Contract: a single command, invoked as

       <cmd> <url>

   with `url` a `file://` URL of the rendered index page. Exit 0 on
   success; on failure the chain continues.
2. The default web browser (named by `xdg-settings`, resolved via its
   .desktop `Exec=` line), launched directly with `--new-window`. This is
   the primary path: the desktop remote openers below are known to
   intermittently exit 0 without opening anything.
3. `gio open`, then `xdg-open`.

Whatever happens, the `file://` URL is always the last stdout line of the
command, so a missed open is one click away. An open failure is never an
error: the render itself succeeded, so exit stays 0. The view dir is
disposable: wiped and rebuilt on every run, so nothing there survives to
the next render. `--out DIR`, `--format text`, and `--summarize-only`
runs never open a browser.

## Regeneration workflow

History is not live — nothing updates the site on its own. When you want a
fresh view (or a fresh README screenshot), re-run the tool:

    archloop ui                                  # summarize + tmp view, opens browser
    archloop ui --no-summarize                   # offline tmp view, opens browser
    archloop ui --repo ~/git/your-repo --screenshot --out-image docs/images/ui-history.png

Output is deterministic for a given corpus + sidecar set: regenerating into
a different dir and diffing yields byte-identical files.
