# common.sh — shared helpers for the archloop ui subcommand (sourced).
# Spec t_95a2c885 §2-4: repo discovery, model chain, escaping, record IO.
# Lane ids (single source for the whole repo) come from scripts/lib/lanes.sh.
. "${UI_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/lanes.sh"

# ---- config / paths -------------------------------------------------------

UI_REAL_HOME="$(getent passwd "$(id -un)" | cut -d: -f6)"
# Auto-discovery walk root — same env name the nightly launcher
# (archloop-night-cron.sh) honors, same default: the real home's ~/git.
# ARCHLOOP_BOARDS_DIR feeds the launcher's retired-project check; the
# override exists so tests can point both away from the real machine.
UI_REPO_ROOT="${ARCHLOOP_REPO_ROOT:-$UI_REAL_HOME/git}"
UI_BOARDS_DIR="${ARCHLOOP_BOARDS_DIR:-$UI_REAL_HOME/.hermes/kanban/boards}"
# Bare `archloop ui` (no --out) renders an ephemeral view here — wiped and
# rebuilt on every run — then opens it in the browser (ui_open below).
UI_OUT_DEFAULT="${TMPDIR:-/tmp}/archloop-ui"

# ---- messages -------------------------------------------------------------

ui_die() { echo "archloop ui: $*" >&2; exit 2; }
ui_warn() { echo "archloop ui: warning: $*" >&2; }

# ---- repo discovery (spec §2) ----------------------------------------------
# Fills UI_REPOS (newline-separated absolute paths, alphabetical). --repo
# flags arrive as $1 (newline-separated, may be empty). Precedence:
#   1. --repo flags (highest — nothing else is consulted)
#   2. $ARCHLOOP_REPOS_CONF, when set: the file must exist and parse in the
#      classic format (bad line = hard error, exactly as before)
#   3. auto-discovery: the nightly launcher's walk (ui_discover_walk below)
# ~/.config/archloop/repos.conf is intentionally NOT auto-read anymore —
# set ARCHLOOP_REPOS_CONF to keep using a list (see docs/ui.md).
ui_discover_repos() {
  local cli_repos="$1" line path
  UI_REPOS=""
  if [ -n "$cli_repos" ]; then
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      path="$(realpath -m "$path")"
      ui_add_repo "$path" "archloop ui --repo"
    done <<<"$cli_repos"
    return 0
  fi
  if [ -n "${ARCHLOOP_REPOS_CONF:-}" ]; then
    [ -f "$ARCHLOOP_REPOS_CONF" ] \
      || ui_die "ARCHLOOP_REPOS_CONF set but file not found: $ARCHLOOP_REPOS_CONF (see docs/ui.md)"
    local conf="$ARCHLOOP_REPOS_CONF" lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
      lineno=$((lineno+1))
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in
        /*) : ;;
        *) ui_die "$conf:$lineno: path must be absolute: $line" ;;
      esac
      ui_add_repo "$line" "$conf:$lineno"
    done < "$conf"
    return 0
  fi
  ui_discover_walk
}

# ui_discover_walk — one-level walk of $UI_REPO_ROOT, mirroring the nightly
# launcher's fleet walk (hermes-kanban-recovery-controller
# scripts/archloop-night-cron.sh): every checkout directly under the root
# that has .archloop/config, minus the launcher's exclusions —
#   - /.worktrees/ paths (non-canonical checkouts),
#   - any directory named archive (retired),
#   - a repo whose kanban board is archived (retired project; ui_board_archived).
# Nothing found → exit 2 naming the root and the --repo/ARCHLOOP_REPOS_CONF
# alternatives. Deterministic output: alphabetical by path (LC_ALL=C).
ui_discover_walk() {
  local root cfg repo
  root="$(realpath -m "$UI_REPO_ROOT")"
  local -a found=()
  for cfg in "$root"/*/.archloop/config; do
    [ -f "$cfg" ] || continue
    repo="$(dirname "$(dirname "$cfg")")"
    case "$repo" in
      */.worktrees | */.worktrees/*) continue ;;
      */archive | */archive/*) continue ;;
    esac
    ui_board_archived "$repo" && continue
    found+=("$repo")
  done
  if [ "${#found[@]}" -eq 0 ]; then
    ui_die "no archloop repos discovered under $root — pass --repo PATH or set ARCHLOOP_REPOS_CONF to a repos.conf (see docs/ui.md)"
  fi
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    UI_REPOS="${UI_REPOS:+$UI_REPOS$'\n'}$p"
  done < <(printf '%s\n' "${found[@]}" | LC_ALL=C sort)
}

# ui_board_archived <repo> — the launcher's retired-project rule, board-dir
# flavor: a repo is retired when its board is archived under
# $UI_BOARDS_DIR/_archived/<basename>. Semantics mirrored from the launcher:
# no board at all or a live board → include (return 1); archived board →
# exclude (return 0); no boards dir at all → the check is skipped entirely
# (include). Archived wins over a live board of the same name — the launcher
# layers the _archived scan over its live board listing the same way.
ui_board_archived() { # returns 0 = exclude, 1 = include
  [ -d "$UI_BOARDS_DIR" ] || return 1
  [ -d "$UI_BOARDS_DIR/_archived/$(basename "$1")" ] && return 0
  return 1
}

# ui_add_repo <path> <source-label> — validate + dedupe into UI_REPOS
ui_add_repo() {
  local path="$1" src="$2"
  [ -d "$path/.archloop" ] || ui_die "$src: no .archloop/ dir in $path"
  grep -qxF "$path" <<<"${UI_REPOS:-}" && return 0
  UI_REPOS="${UI_REPOS:+$UI_REPOS$'\n'}$path"
}

# ---- browser open (bare view flow) -------------------------------------------
# $1 = rendered html file. Chain: $ARCHLOOP_OPEN_CMD override (single
# command, invoked as "<cmd> <url>") > direct launch of the default browser
# with --new-window > gio open > xdg-open. The direct launch comes first
# because the desktop remote (gio/xdg-open) intermittently exits 0 without
# opening anything; a browser we spawn ourselves always gets the URL. The
# file:// URL is always the last stdout line so a missed open stays one
# click away.
ui_open() {
  local url="file://$(realpath -m "$1")" bin
  if [ -n "${ARCHLOOP_OPEN_CMD:-}" ]; then
    if "$ARCHLOOP_OPEN_CMD" "$url" >/dev/null 2>&1; then
      echo "archloop ui: opened $url" >&2; echo "$url"; return 0
    fi
    ui_warn "ARCHLOOP_OPEN_CMD failed — trying the built-in openers"
  fi
  bin="$(ui_default_browser_bin)"
  if [ -n "$bin" ]; then
    setsid nohup "$bin" --new-window "$url" >/dev/null 2>&1 &
    echo "archloop ui: opened $url" >&2; echo "$url"; return 0
  fi
  if command -v gio >/dev/null 2>&1 && gio open "$url" >/dev/null 2>&1; then
    echo "archloop ui: opened $url" >&2; echo "$url"; return 0
  fi
  if command -v xdg-open >/dev/null 2>&1 && xdg-open "$url" >/dev/null 2>&1; then
    echo "archloop ui: opened $url" >&2; echo "$url"; return 0
  fi
  ui_warn "no browser opened — view the site at: $url"
  echo "$url"
}

# ui_default_browser_bin — Exec binary of the default web browser, or empty.
# xdg-settings names the .desktop; the file is looked up along the XDG data
# dirs so tests can point it at fixtures via XDG_DATA_HOME.
ui_default_browser_bin() {
  local desktop f bin
  command -v xdg-settings >/dev/null 2>&1 || return 0
  desktop="$(xdg-settings get default-web-browser 2>/dev/null)" || return 0
  [ -n "$desktop" ] || return 0
  local -a cands=("${XDG_DATA_HOME:-$UI_REAL_HOME/.local/share}/applications/$desktop")
  local d
  while IFS= read -r d; do
    [ -n "$d" ] && cands+=("$d/applications/$desktop")
  done <<<"$(tr ':' '\n' <<<"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}")"
  for f in "${cands[@]}"; do
    [ -f "$f" ] || continue
    bin="$(sed -n 's/^Exec=//p' "$f" | head -1 | awk '{print $1}')"
    [ -n "$bin" ] || continue
    case "$bin" in
      /*) [ -x "$bin" ] && { printf '%s\n' "$bin"; return 0; } ;;
      *)  command -v "$bin" >/dev/null 2>&1 && { command -v "$bin"; return 0; } ;;
    esac
  done
  return 0
}

# ---- model chain (spec §4): env > config > LANE_BIG (scripts/lib/lanes.sh) --
# $1=repo  $2=--model flag value (may be empty)
ui_resolve_model() {
  local repo="$1" flag="$2"
  if [ -n "$flag" ]; then
    UI_MODEL="$flag"
    return 0
  fi
  if [ -n "${ARCHLOOP_MODEL_SUMMARY:-}" ]; then
    UI_MODEL="$ARCHLOOP_MODEL_SUMMARY"
    return 0
  fi
  if [ -f "$repo/.archloop/config" ]; then
    UI_MODEL="$(bash -c '. "$1" >/dev/null 2>&1; printf %s "${ARCHLOOP_MODEL_SUMMARY:-}"' _ "$repo/.archloop/config")"
    [ -n "$UI_MODEL" ] && return 0
  fi
  # single source of truth: LANE_BIG from scripts/lib/lanes.sh (sourced, not
  # parsed — never duplicated here)
  UI_MODEL="$LANE_BIG"
}

# ---- HTML escaping ---------------------------------------------------------

ui_esc() { # stdin->stdout: & < > "
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# ui_json_get <file> <key> — value for a flat top-level key (no nested JSON).
# Handles quoted strings and bare number scalars (spec section 4: "schema": 1).
# awk index/substr: no regex escaping, robust across pretty-printed JSON.
ui_json_get() {
  local file="$1" key="$2"
  awk -v k="$key" '
    { buf = buf $0 }
    END {
      i = index(buf, "\"" k "\"")
      if (i == 0) { print ""; exit }
      s = substr(buf, i + length(k) + 2)
      sub(/^[ \t]*:[ \t]*/, "", s)
      if (substr(s, 1, 1) == "\"") {
        s = substr(s, 2)
        j = index(s, "\"")
        print (j > 0 ? substr(s, 1, j - 1) : "")
      } else {
        sub(/[^0-9].*$/, "", s)
        print s
      }
    }' "$file"
}

# ui_humanize <kebab> — "fold-foo-into-bar" -> "Fold Foo Into Bar"
ui_humanize() {
  echo "$1" | sed -e 's/-/ /g' -e 's/\b\(.\)/\u\1/g'
}

# ui_validate_sidecar <file> <item> — strict schema check (spec §4).
# Lives in common.sh: both summarize (writer) and render (reader) call it.
ui_validate_sidecar() {
  local f="$1" item="$2" v first last
  [ -f "$f" ] || return 1
  # raw JSON object only: no fences, no prose — check boundary characters,
  # not whole lines (single-line JSON is the normal case)
  first="$(grep -m1 -v '^[[:space:]]*$' "$f" | head -c 1)"
  [ "$first" = '{' ] || return 1
  last="$(grep -v '^[[:space:]]*$' "$f" | tail -1 | tr -d '[:space:]' | tail -c 1)"
  [ "$last" = '}' ] || return 1
  v="$(ui_json_get "$f" schema)"; [ "$v" = "1" ] || return 1
  v="$(ui_json_get "$f" item)";  [ "$v" = "$item" ] || return 1
  v="$(ui_json_get "$f" title)"
  [ "${#v}" -ge 3 ] && [ "${#v}" -le 60 ] || return 1
  case "$v" in *.) return 1 ;; esac
  v="$(ui_json_get "$f" details)"
  [ -n "$v" ] && [ "${#v}" -le 500 ] || return 1
  [ -n "$(ui_json_get "$f" model)" ] || return 1
  v="$(ui_json_get "$f" generated_at)"
  echo "$v" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?' || return 1
  return 0
}

# ---- item records (sourced order: common -> parse -> summarize -> render) --

UI_GS=$'\x1d'   # item sub-fields inside the items record (name GS status GS sha)
