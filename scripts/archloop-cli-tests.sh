#!/usr/bin/env bash
# archloop-cli-tests.sh — bin/archloop stub suite (zero quota, no real model).
# Stub opencode: `models` prints a fixed roster; `run` prints PONG (and can be
# told to fail). Covers spec §1-3: presets + overrides + precedence, refusal
# rules (exit 2), roster/PONG validation, detached launch of archloop-loop.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="${ARCHLOOP_CLI:-$SCRIPT_DIR/../bin/archloop}"
LOOP_STUB_SRC="$SCRIPT_DIR/fixtures/loop-stub.sh"
[ -f "$CLI" ] || { echo "ABORT: bin/archloop not found at $CLI"; exit 1; }
[ -f "$LOOP_STUB_SRC" ] || { echo "ABORT: loop stub not found at $LOOP_STUB_SRC"; exit 1; }
TMP="$(mktemp -d)"
STUB_HOME="$TMP/home"          # fake home: presets.conf lives here, OC is NOT resolved from it
mkdir -p "$STUB_HOME/.config/archloop"
STUB="$TMP/stub-opencode"
LOOP="$TMP/archloop-loop.sh"
. "$SCRIPT_DIR/lib/harness.sh"
kill_loops() { pkill -f "archloop-loop.sh $TMP/" 2>/dev/null; sleep 0.3; }

cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Stub opencode for bin/archloop tests. `models` -> roster; `run` -> PONG.
case "$1 $2" in
  "models ")
    printf 'zai/glm-5.3-flash\nzai/glm-5.3\nzai/glm-5.3-air\nother/keep-model\n'
    exit 0 ;;
  "run --model")
    [ "${STUB_PONG_FAIL:-0}" = "1" ] && { echo "UnknownError" >&2; exit 1; }
    echo "PONG"
    exit 0 ;;
  *) echo "stub: unexpected args: $*" >&2; exit 9 ;;
esac
STUBEOF
chmod +x "$STUB"
cp "$LOOP_STUB_SRC" "$LOOP"; chmod +x "$LOOP"

# fresh_repo <name> — git repo on main with .archloop/config (excluded), one commit.
fresh_repo() {
  local r="$TMP/$1"
  rm -rf "$r"; git init -q -b main "$r"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  echo a > "$r/f.txt"; git -C "$r" add f.txt; git -C "$r" -c commit.gpgsign=false commit -qm init
  mkdir -p "$r/.archloop"
  printf 'ARCHLOOP_TEST_CMD=true\nARCHLOOP_LINT_CMD=true\n' > "$r/.archloop/config"
  printf '.archloop/\n' >> "$r/.git/info/exclude"
  REPO="$r"
}

# run_cli <args...> — CLI under the stub home/loop/opencode; sets OUT/RC.
run_cli() {
  OUT="$(env HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$STUB" ARCHLOOP_LOOP_SCRIPT="$LOOP" \
    ARCHLOOP_PRESETS_CONF="$TMP/presets.conf" \
    STUB_LAUNCH_ENV="$TMP/launch-env" bash "$CLI" "$@" 2>&1)"
  RC=$?
}
trap 'kill_loops 2>/dev/null; rm -rf "$TMP"' EXIT

echo "== Test 1: presets — builtins, flags, conf override/extension =="
run_cli presets
check "$RC" "0" "presets exits 0"
for p in "cheap" "strong" "max"; do contains "$p" "$OUT" "builtin preset listed: $p"; done
contains "zai/glm-5.3-flash" "$OUT" "cheap scan model listed"
contains "zai/glm-5.3" "$OUT" "strong gate model listed"
printf '# override cheap scan + extend\ncheap|ov/scan|zai/glm-5.3-flash|zai/glm-5.3\nbig|big/s|big/i|big/g\n' \
  > "$TMP/presets.conf"
run_cli presets
contains "ov/scan" "$OUT" "presets.conf overrides builtin"
contains "big/s" "$OUT" "presets.conf extends builtin"
rm -f "$TMP/presets.conf"
OUT="$(ok "harness self-check")"
contains "✅" "$OUT" "harness ok-prefix present via shared lib"

echo "== Test 2: start happy path — detached launch, resolved models printed =="
fresh_repo happy
run_cli start "$REPO" --max-items 3 --max-rounds 4
check "$RC" "0" "start exits 0"
contains "pid=" "$OUT" "prints pid"
contains "scan=zai/glm-5.3-flash" "$OUT" "cheap scan resolved"
contains "gate=zai/glm-5.3" "$OUT" "cheap gate resolved"
contains "max_items=3" "$OUT" "max-items passed through"
contains "max_rounds=4" "$OUT" "max-rounds passed through"
# wait for the detached stub to write its launch record (up to 5 s)
for _ in 1 2 3 4 5; do [ -f "$TMP/launch-env" ] && break; sleep 1; done
[ -f "$TMP/launch-env" ] && ok "detached loop stub actually ran" || bad "detached loop stub never ran"
if [ -f "$TMP/launch-env" ]; then
  contains "ARCHLOOP_MODEL_SCAN=zai/glm-5.3-flash" "$(cat "$TMP/launch-env")" "loop gets ARCHLOOP_MODEL_SCAN"
  contains "ARCHLOOP_MODEL_GATE=zai/glm-5.3" "$(cat "$TMP/launch-env")" "loop gets ARCHLOOP_MODEL_GATE"
  contains "ARCHLOOP_IDLE_TIMEOUT=1800" "$(cat "$TMP/launch-env")" "loop gets idle timeout 1800"
  contains "$(getent passwd "$(id -un)" | cut -d: -f6)" "$(head -1 "$TMP/launch-env")" "loop HOME is the real user home"
fi

echo "== Test 3: preset precedence — flag > --preset > repo ARCHLOOP_PRESET > cheap =="
fresh_repo prec
printf 'ARCHLOOP_PRESET=strong\n' >> "$REPO/.archloop/config"
run_cli start "$REPO"
contains "scan=zai/glm-5.3" "$OUT" "repo ARCHLOOP_PRESET=strong wins over cheap"
run_cli start "$REPO" --preset max
contains "scan=zai/glm-5.3 impl=zai/glm-5.3" "$OUT" "--preset max beats repo preset"
run_cli start "$REPO" --preset max --impl zai/glm-5.3-air
contains "impl=zai/glm-5.3-air" "$OUT" "per-stage flag beats preset"

echo "== Test 4: refusal rules — all exit 2, one-line reason =="
fresh_repo refuse
run_cli start "$TMP/no-such-repo"
check "$RC" "2" "missing .archloop/config -> exit 2"
contains "no .archloop/config" "$OUT" "reason names the missing config"
printf 'junk\n' >> "$REPO/f.txt"
run_cli start "$REPO"
check "$RC" "2" "dirty tree -> exit 2"
contains "dirty" "$OUT" "reason says dirty"
git -C "$REPO" checkout -q f.txt
git -C "$REPO" checkout -qb feature
run_cli start "$REPO"
check "$RC" "2" "off main -> exit 2"
contains "main" "$OUT" "reason says must be on main"
git -C "$REPO" checkout -q main
STUB_LOOP_HOLD=1 env HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$STUB" ARCHLOOP_LOOP_SCRIPT="$LOOP" \
  STUB_LAUNCH_ENV="$TMP/launch-env" bash "$CLI" start "$REPO" >/dev/null 2>&1 &
wait $!
check "$(pgrep -fc "archloop-loop.sh $REPO")" "1" "first loop is running (pgrep sees it)"
run_cli start "$REPO"
check "$RC" "2" "already running -> exit 2"
contains "already running" "$OUT" "reason says already running"
kill_loops
check "$(pgrep -fc "archloop-loop.sh $REPO" 2>/dev/null)" "0" "loop stopped between tests"

echo "== Test 5: model validation — roster + PONG only for non-default ids =="
fresh_repo roster
run_cli start "$REPO" --scan no-such/model
check "$RC" "2" "id missing from roster -> exit 2"
contains "no-such/model" "$OUT" "reason names the bad id"
fresh_repo roster2
# zai/glm-5.3-air IS in the stub roster and non-default -> gets PONGed (passes)
run_cli start "$REPO" --impl zai/glm-5.3-air
check "$RC" "0" "non-default rostered id PONGs -> exit 0"
STUB_PONG_FAIL=1 run_cli start "$REPO" --impl zai/glm-5.3-air
check "$RC" "2" "PONG failure -> exit 2"
contains "PONG" "$OUT" "reason names the PONG failure"
rm -f "$TMP/launch-env"
run_cli start "$REPO"
[ -f "$TMP/launch-env" ] && bad "default ids were PONG-probed (stub run called)" || ok "default ids skip PONG (no stub run call)"
# `run` was called only for the -air probe; roster calls are `models`, not `run`.

echo "== Test 6: unknown option / unknown preset -> exit 2 =="
fresh_repo misc
run_cli start "$REPO" --bogus
check "$RC" "1" "unknown option -> usage error (exit 1)"
run_cli start "$REPO" --preset nope
check "$RC" "2" "unknown preset -> exit 2"
contains "unknown preset" "$OUT" "reason names the unknown preset"
run_cli status "$REPO"
contains "no archloop state found" "$OUT" "status on bare repo reports no state"

echo "== Test 7: symlinked launcher (~/.local/bin install) resolves repo paths =="
# A $0-based dirname follows the symlink's directory, where neither
# ../scripts/ui nor archloop-loop.sh exists; BIN_DIR must resolve through
# the link to the real checkout. ui is the safe probe: it exercises the
# ui-lib sourcing without launching anything.
LNK="$TMP/linked-bin"; mkdir -p "$LNK"
ln -s "$SCRIPT_DIR/../bin/archloop" "$LNK/archloop"
uisite="$TMP/uisite"
OUT="$(env HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$STUB" \
  bash "$LNK/archloop" ui --repo "$SCRIPT_DIR/../tests/ui-fixtures/repos/demo-a" \
  --no-summarize --out "$uisite" 2>&1)"
RC=$?
check "$RC" "0" "symlinked ui exit 0 (ui libs resolve through the link)"
[ -f "$uisite/index.html" ] && ok "symlinked ui rendered index.html" || bad "symlinked ui produced no index.html"

echo "== Test 8: bare ui view — tmp render + browser open =="
# No --out: render into the stable tmp view dir (TMPDIR-scoped here) and open
# it via $ARCHLOOP_OPEN_CMD. --out runs and --no-open never touch a browser.
OPENER="$TMP/open-stub"
cat > "$OPENER" <<'OPENEOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$OPEN_LOG"
OPENEOF
chmod +x "$OPENER"
DEMO_A="$SCRIPT_DIR/../tests/ui-fixtures/repos/demo-a"
# --out run: renders in place, never opens
rm -f "$TMP/open.log"
OUT="$(env HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$STUB" ARCHLOOP_OPEN_CMD="$OPENER" \
  OPEN_LOG="$TMP/open.log" TMPDIR="$TMP" \
  bash "$LNK/archloop" ui --repo "$DEMO_A" --no-summarize --out "$TMP/uisite2" 2>&1)"
RC=$?
check "$RC" "0" "--out run exit 0"
[ -f "$TMP/open.log" ] && bad "--out run opened a browser" || ok "--out run does not open a browser"
# bare run: rebuilds the tmp view (stale marker must vanish) and opens it
mkdir -p "$TMP/archloop-ui"; echo stale > "$TMP/archloop-ui/stale-marker.html"
rm -f "$TMP/open.log"
OUT="$(env HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$STUB" ARCHLOOP_OPEN_CMD="$OPENER" \
  OPEN_LOG="$TMP/open.log" TMPDIR="$TMP" \
  bash "$LNK/archloop" ui --repo "$DEMO_A" --no-summarize 2>&1)"
RC=$?
check "$RC" "0" "bare view exit 0"
check "$(cat "$TMP/open.log" 2>/dev/null)" "file://$TMP/archloop-ui/index.html" "bare view opens the tmp index"
[ -f "$TMP/archloop-ui/index.html" ] && ok "bare view rendered into \$TMPDIR/archloop-ui" || bad "bare view missing tmp index"
[ ! -e "$TMP/archloop-ui/stale-marker.html" ] && ok "tmp view rebuilt from scratch (stale file gone)" || bad "stale file survived the rebuild"
# --no-open: renders the view but skips the browser
rm -f "$TMP/open.log"
OUT="$(env HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$STUB" ARCHLOOP_OPEN_CMD="$OPENER" \
  OPEN_LOG="$TMP/open.log" TMPDIR="$TMP" \
  bash "$LNK/archloop" ui --repo "$DEMO_A" --no-summarize --no-open 2>&1)"
RC=$?
check "$RC" "0" "--no-open exit 0"
[ -f "$TMP/open.log" ] && bad "--no-open still opened a browser" || ok "--no-open skips the browser"
[ -f "$TMP/archloop-ui/index.html" ] && ok "--no-open still renders the view" || bad "--no-open render missing"
# conf-file discovery (no --repo): a valid repos.conf drives the render, and
# the unset-ARCHLOOP_REPOS_CONF path must not die on set -u (regression:
# bare "$ARCHLOOP_REPOS_CONF" in ui_discover_repos crashed bin/archloop)
printf '%s\n' "$DEMO_A" > "$TMP/repos.conf"
OUT="$(env HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$STUB" ARCHLOOP_OPEN_CMD="$OPENER" \
  OPEN_LOG="$TMP/open.log" ARCHLOOP_REPOS_CONF="$TMP/repos.conf" TMPDIR="$TMP" \
  bash "$LNK/archloop" ui --no-summarize --no-open 2>&1)"
RC=$?
check "$RC" "0" "repos.conf discovery (no --repo) exit 0"
[ -f "$TMP/archloop-ui/index.html" ] && ok "repos.conf discovery rendered the view" || bad "repos.conf discovery missing index"
# with ARCHLOOP_REPOS_CONF unset the CLI auto-discovers: point the walk at
# the committed ui fixtures (and a nonexistent boards dir, skipping the board
# check) so the run never touches the real ~/git or real kanban boards
OUT="$(env -u ARCHLOOP_REPOS_CONF HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$STUB" TMPDIR="$TMP" \
  ARCHLOOP_REPO_ROOT="$SCRIPT_DIR/../tests/ui-fixtures/repos" \
  ARCHLOOP_BOARDS_DIR="$TMP/no-boards-here" \
  bash "$LNK/archloop" ui --no-summarize --format text 2>&1)"
RC=$?
if grep -q "unbound variable" <<<"$OUT"; then
  bad "unset ARCHLOOP_REPOS_CONF crashes under set -u"
else
  ok "unset ARCHLOOP_REPOS_CONF handled (no unbound crash, exit $RC)"
fi
check "$RC" "0" "unset ARCHLOOP_REPOS_CONF discovers the fixture root"
# opener chain: direct default-browser --new-window first; gio only when no
# default browser resolves; URL always the last stdout line
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\nprintf "gio %%s\\n" "$2" >> "$OPEN_LOG"\n' > "$FAKEBIN/gio"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/xdg-settings"
printf '#!/usr/bin/env bash\nprintf "myfox: %%s\\n" "$*" >> "$OPEN_LOG"\n' > "$FAKEBIN/myfox"
chmod +x "$FAKEBIN/gio" "$FAKEBIN/xdg-settings" "$FAKEBIN/myfox"
mkdir -p "$TMP/share/applications"
printf '[Desktop Entry]\nType=Application\nExec=myfox %%u\n' > "$TMP/share/applications/myfox.desktop"
rm -f "$TMP/open.log"
OUT="$(env HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$STUB" OPEN_LOG="$TMP/open.log" \
  TMPDIR="$TMP" PATH="$FAKEBIN:/usr/bin:/bin" \
  bash "$LNK/archloop" ui --repo "$DEMO_A" --no-summarize 2>/dev/null)"
RC=$?
check "$RC" "0" "gio fallback exit 0 (no default browser resolvable)"
check "$(cat "$TMP/open.log" 2>/dev/null)" "gio file://$TMP/archloop-ui/index.html" "gio fallback when no default browser"
printf '#!/usr/bin/env bash\necho myfox.desktop\n' > "$FAKEBIN/xdg-settings"
rm -f "$TMP/open.log"
OUT="$(env HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$STUB" OPEN_LOG="$TMP/open.log" \
  TMPDIR="$TMP" XDG_DATA_HOME="$TMP/share" PATH="$FAKEBIN:/usr/bin:/bin" \
  bash "$LNK/archloop" ui --repo "$DEMO_A" --no-summarize 2>/dev/null)"
RC=$?
sleep 1
check "$RC" "0" "default-browser direct launch exit 0"
check "$(cat "$TMP/open.log" 2>/dev/null)" "myfox: --new-window file://$TMP/archloop-ui/index.html" "default browser launched with --new-window"
check "$(tail -1 <<<"$OUT")" "file://$TMP/archloop-ui/index.html" "URL printed as last stdout line"
rm -f "$TMP/open.log"
OUT="$(env HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$STUB" OPEN_LOG="$TMP/open.log" \
  TMPDIR="$TMP" XDG_DATA_HOME="$TMP/share" PATH="$FAKEBIN:/usr/bin:/bin" \
  ARCHLOOP_OPEN_CMD=/bin/false \
  bash "$LNK/archloop" ui --repo "$DEMO_A" --no-summarize 2>/dev/null)"
sleep 1
[ -s "$TMP/open.log" ] && ok "failed ARCHLOOP_OPEN_CMD falls through to browser launch" || bad "override failure did not fall through"

echo "== Test 9: ui discovery — auto walk, exclusions, board check, conf, empty =="
# Unit-level: source scripts/ui/common.sh and inspect UI_REPOS directly (the
# exact filter matrix mirroring the nightly launcher's walk), then one
# end-to-end run through the real CLI.
DISC="$TMP/disc-root"
mkdisc() { mkdir -p "$DISC/$1/.archloop"; : > "$DISC/$1/.archloop/config"; }
mkdisc alpha; mkdisc beta
mkdisc gamma                                   # board archived below -> excluded
mkdisc delta                                   # live board below    -> included
mkdisc archive                                 # dir named archive   -> excluded
mkdisc .worktrees                              # worktree path       -> excluded
mkdir -p "$DISC/not-a-repo/.archloop"          # no .archloop/config -> never matches
BOARDS="$TMP/disc-boards"
mkdir -p "$BOARDS/_archived/gamma" "$BOARDS/delta"
# disc_run <repo-root> <boards-dir> [VAR=val]... — ui_discover_repos with no
# --repo; output+rc in D_OUT/D_RC (stderr merged)
disc_run() {
  local root="$1" boards="$2"; shift 2
  D_OUT="$(cd "$SCRIPT_DIR/.." && env -u ARCHLOOP_REPOS_CONF ARCHLOOP_REPO_ROOT="$root" \
    ARCHLOOP_BOARDS_DIR="$boards" "$@" bash -c '
    . scripts/ui/common.sh; ui_discover_repos ""; printf "%s\n" "$UI_REPOS"' 2>&1)"
  D_RC=$?
}
disc_run "$DISC" "$BOARDS"
check "$D_RC" "0" "discovery walk exits 0"
check "$D_OUT" "$(printf '%s\n' "$DISC/alpha" "$DISC/beta" "$DISC/delta")" \
  "walk = archloop repos only, alphabetical (archive/.worktrees/boards-filtered/no-config dropped)"
disc_run "$DISC" "$TMP/no-boards-dir"
check "$D_OUT" "$(printf '%s\n' "$DISC/alpha" "$DISC/beta" "$DISC/delta" "$DISC/gamma")" \
  "no boards dir -> board check skipped entirely (archived-board repo included)"
# conf file still honored, and replaces discovery when set
printf '%s\n' "$DISC/alpha" > "$TMP/disc.conf"
disc_run "$DISC" "$BOARDS" ARCHLOOP_REPOS_CONF="$TMP/disc.conf"
check "$D_RC" "0" "explicit ARCHLOOP_REPOS_CONF exits 0"
check "$D_OUT" "$DISC/alpha" "explicit conf file wins over auto-discovery"
disc_run "$DISC" "$BOARDS" ARCHLOOP_REPOS_CONF="$TMP/no-such.conf"
check "$D_RC" "2" "ARCHLOOP_REPOS_CONF set but missing -> exit 2"
contains "file not found" "$D_OUT" "reason names the missing conf"
printf 'relative/path\n' > "$TMP/disc-bad.conf"
disc_run "$DISC" "$BOARDS" ARCHLOOP_REPOS_CONF="$TMP/disc-bad.conf"
check "$D_RC" "2" "conf bad line -> exit 2"
contains "path must be absolute" "$D_OUT" "reason names the bad line"
# discovery finding nothing -> exit 2 naming root + alternatives
mkdir -p "$TMP/empty-root"
disc_run "$TMP/empty-root" "$BOARDS"
check "$D_RC" "2" "empty discovery -> exit 2"
contains "$TMP/empty-root" "$D_OUT" "message names the root searched"
contains "--repo" "$D_OUT" "message names the --repo alternative"
contains "ARCHLOOP_REPOS_CONF" "$D_OUT" "message names the conf alternative"
disc_run "$TMP/does-not-exist" "$BOARDS"
check "$D_RC" "2" "missing repo root -> exit 2"
# end-to-end: the real CLI discovers the fixture fleet and renders it
mkdir -p "$DISC/alpha/.archloop/night-2026-05-01"
printf 'NONE\n' > "$DISC/alpha/.archloop/night-2026-05-01/verdict"
OUT="$(env -u ARCHLOOP_REPOS_CONF HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$STUB" TMPDIR="$TMP" \
  ARCHLOOP_REPO_ROOT="$DISC" ARCHLOOP_BOARDS_DIR="$BOARDS" \
  bash "$LNK/archloop" ui --no-summarize --format text 2>&1)"
RC=$?
check "$RC" "0" "end-to-end discovery render exits 0"
contains "== 2026-05-01 alpha CLEAN_NO_CANDIDATES ==" "$OUT" "discovered repo renders"
lacks "gamma" "$OUT" "excluded repo absent from render"

echo "== Test 10: default loop-script path resolves to the repo root (flag 107) =="
# bin/archloop used to default LOOP_SCRIPT to $BIN_DIR/archloop-loop.sh, a path
# that never existed — the driver is tracked at the repo root — so every
# `archloop start` died exit 2 with "archloop-loop.sh not found".
# Probed with an empty-roster opencode stub: the CLI then dies inside
# validate_models, i.e. strictly AFTER the [ -f "$LOOP_SCRIPT" ] check, so a
# resolved script is proven without launching a loop.
NOSTUB="$TMP/stub-opencode-noroster"
printf '#!/usr/bin/env bash\ncase "$1 $2" in "models ") exit 0 ;; esac\nexit 0\n' > "$NOSTUB"
chmod +x "$NOSTUB"
fresh_repo looppath
# probe_start <cli> [VAR=val]... — start with ARCHLOOP_LOOP_SCRIPT unset unless
# the caller re-assigns it (env applies assignments after -u).
probe_start() {
  local cli="$1"; shift
  OUT="$(env -u ARCHLOOP_LOOP_SCRIPT HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$NOSTUB" \
    ARCHLOOP_PRESETS_CONF="$TMP/presets.conf" "$@" bash "$cli" start "$REPO" 2>&1)"
  RC=$?
}
probe_start "$CLI"
check "$RC" "2" "default path probe exits 2 (roster), not on the loop script"
contains "not in opencode roster" "$OUT" "default LOOP_SCRIPT EXISTS (reached validate_models)"
lacks "archloop-loop.sh not found" "$OUT" "default never trips the loop-script check"
# the resolved default must be the repo-root driver, resolvable from the CLI's
# own location — also through a symlinked launcher, where a bare $0 dirname
# would point somewhere else entirely.
# an empty override falls back to the default (`:-` treats empty as unset)
probe_start "$CLI" ARCHLOOP_LOOP_SCRIPT=""
check "$RC" "2" "empty override falls back to the default (roster exit)"
contains "not in opencode roster" "$OUT" "empty override still resolves a real loop script"
LNK2="$TMP/linked-bin-2"; mkdir -p "$LNK2"
ln -s "$SCRIPT_DIR/../bin/archloop" "$LNK2/archloop"
probe_start "$LNK2/archloop"
check "$RC" "2" "symlinked launcher resolves the default too"
contains "not in opencode roster" "$OUT" "symlinked default LOOP_SCRIPT EXISTS"
lacks "archloop-loop.sh not found" "$OUT" "symlinked default never trips the loop-script check"
# ARCHLOOP_LOOP_SCRIPT still overrides: a bogus path must be honored (and fail),
# never silently replaced by the default.
probe_start "$CLI" ARCHLOOP_LOOP_SCRIPT="$TMP/nope/archloop-loop.sh"
check "$RC" "2" "bogus override -> exit 2"
contains "archloop-loop.sh not found at $TMP/nope/archloop-loop.sh" "$OUT" \
  "override wins over the default (reason names the override path)"
# and a good override launches the stub exactly as before
rm -f "$TMP/launch-env"
OUT="$(env -u ARCHLOOP_LOOP_SCRIPT HOME="$STUB_HOME" ARCHLOOP_OPENCODE="$STUB" \
  ARCHLOOP_LOOP_SCRIPT="$LOOP" ARCHLOOP_PRESETS_CONF="$TMP/presets.conf" \
  STUB_LAUNCH_ENV="$TMP/launch-env" bash "$CLI" start "$REPO" 2>&1)"
RC=$?
check "$RC" "0" "override to the loop stub still launches (exit 0)"
for _ in 1 2 3 4 5; do [ -f "$TMP/launch-env" ] && break; sleep 1; done
[ -f "$TMP/launch-env" ] && ok "override launched the loop stub" || bad "override loop stub never ran"
finish
