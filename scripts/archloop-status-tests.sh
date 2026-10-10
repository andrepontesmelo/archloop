#!/usr/bin/env bash
# archloop-status-tests.sh — `archloop status` suite (spec §4, card C).
# Read-only parser over fixture night dirs copied from a real rentcli night
# (scripts/fixtures/night-dirs.tar, repo-relative paths, dated 2026-09-04 +
# a 2026-08-17 parked round). status is date-sensitive: the live round is
# night-<today>. The suite rewrites fixture dates (dir names + file contents)
# to today so the parser sees a live round, then checks every §4 field.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="${ARCHLOOP_CLI:-$SCRIPT_DIR/../bin/archloop}"
FIXTAR="$SCRIPT_DIR/fixtures/night-dirs.tar"
[ -f "$CLI" ] || { echo "ABORT: bin/archloop not found at $CLI"; exit 1; }
[ -f "$FIXTAR" ] || { echo "ABORT: fixture tar not found at $FIXTAR"; exit 1; }

. "$SCRIPT_DIR/lib/harness.sh"
jget() { # $1=json $2=key -> leaf value, or list length for arrays/objects
  python3 -c '
import json,sys
d=json.loads(sys.argv[1]); v=d[sys.argv[2]]
print(len(v) if isinstance(v,(list,dict)) else v)' "$1" "$2"; }
jidx() { # $1=json $2=list-key $3=index $4=field
  python3 -c '
import json,sys
d=json.loads(sys.argv[1]); print(d[sys.argv[2]][int(sys.argv[3])][sys.argv[4]])' "$1" "$2" "$3" "$4"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TODAY="$(date +%F)"
FD="2026-09-04"                       # fixture date -> rewritten to today
REPO=""; AR=""

# fresh_fixture_repo <name> — git repo on main + .archloop/config, fixture tar
# extracted into <repo>/.archloop, every 2026-09-04 date rewritten to today.
fresh_fixture_repo() {
  REPO="$TMP/$1"; rm -rf "$REPO"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  echo a > "$REPO/f.txt"; git -C "$REPO" add f.txt
  git -C "$REPO" -c commit.gpgsign=false commit -qm init
  AR="$REPO/.archloop"
  mkdir -p "$AR"
  printf 'ARCHLOOP_TEST_CMD=true\nARCHLOOP_LINT_CMD=true\n' > "$AR/config"
  tar -xf "$FIXTAR" -C "$AR"
  local d nd f
  for d in "$AR"/night-*; do
    nd="${d/$FD/$TODAY}"
    [ "$d" != "$nd" ] && mv "$d" "$nd"
    for f in "$nd"/*; do
      [ -f "$f" ] && sed -i "s|$FD|$TODAY|g" "$f"
    done
  done
  sed -i "s|$FD|$TODAY|g" "$AR/ledger.md" "$AR/loop-driver.log"
}

run_status() { # $1=--json or empty; sets OUT/RC. Night log pinned to a
               # nonexistent file so trigger stays deterministic (null).
  local args=("$REPO")
  [ -n "${1:-}" ] && args+=("$1")
  OUT="$(ARCHLOOP_NIGHT_LOG="$TMP/night.log" bash "$CLI" status "${args[@]}" 2>&1)"; RC=$?
}

echo "== Test 1: mid-item live round (round 2, i3-implement in flight) =="
fresh_fixture_repo live
# Loop log: cut everything from the round-3 banner so the tail reads as a
# round-2 in flight (real log ended with round 3 DONE).
sed -i '\#=== round 3/8#,$d' "$AR/loop-driver.log"
# Live driver.log: round-2 transcript ending mid item 3.
cat >> "$AR/night-$TODAY/driver.log" <<'EOF'
02:58:22 session start: scan-plan (zai/glm-5.3-flash)
03:23:26 session end: scan-plan (exit 0)
03:23:26 plan contains 4 item(s): duel-enum-label-vocab source-search-page-scaffolding tab-base-selection score-snapshot-tuple
03:23:26 session start: i1-implement (zai/glm-5.3-flash)
03:39:27 session end: i1-implement (exit 0)
03:42:20 session start: i1-gate (zai/glm-5.3)
03:53:07 session end: i1-gate (exit 0)
03:56:39 session start: i2-implement (zai/glm-5.3-flash)
04:05:55 session end: i2-implement (exit 0)
04:08:47 session start: i2-gate (zai/glm-5.3)
04:16:45 session end: i2-gate (exit 0)
04:19:37 session start: i3-implement (zai/glm-5.3-flash)
EOF
# Live plan.md: the 4 round-2 items, one section each.
cat > "$AR/night-$TODAY/plan.md" <<'EOF'
# Plan — rentcli deepening — night-2026-09-04

## Item: duel-enum-label-vocab

Two label vocabularies for the same enum drift silently. First body line.

## Item: source-search-page-scaffolding

Search page scaffolding is duplicated across sources. First body line.

## Item: tab-base-selection

Tab base selection logic is split across three sites. First body line.

## Item: score-snapshot-tuple

Score snapshots pass as bare tuples with no named shape. First body line.

## Item: silent-summarizer-drift

EOF

# Drop the last two SHIPPED lines so items 3+4 are still open (test data).
sed -i '/tab-base-selection: SHIPPED/d;/score-snapshot-tuple: SHIPPED/d' "$AR/ledger.md"
run_status --json
check "$RC" "0" "status --json exits 0"
contains '"stage": "i3-implement"' "$OUT" "stage = i3-implement"
contains '"round": 2' "$OUT" "round = 2"
contains '"max_rounds": 8' "$OUT" "max_rounds = 8"
contains '"trigger": null' "$OUT" "trigger = null (no night log)"
contains '"alive": false' "$OUT" "alive = false (pgrep clean)"
contains '"current_item": "tab-base-selection"' "$OUT" "current_item = 3rd plan item (i3)"
check "$(jget "$OUT" queued_items)" "2" "queued_items has 2 entries (i4 + i5 open)"
check "$(jidx "$OUT" queued_items 0 name)" "score-snapshot-tuple" "queued[0].name"
contains "bare tuples with no named shape" "$(jidx "$OUT" queued_items 0 summary)" "queued[0].summary first line"
check "$(jidx "$OUT" queued_items 1 name)" "silent-summarizer-drift" "queued[1].name (empty section body)"
check "$(jidx "$OUT" queued_items 1 summary)" "None" "queued[1].summary = null (empty section body)"
check "$(jget "$OUT" shipped_today)" "7" "shipped_today = 7 (9 minus 2 dropped lines)"
check "$(jget "$OUT" parked_today)" "0" "parked_today = 0"
contains '"scan": "zai/glm-5.3-flash"' "$OUT" "models.scan = flash"
contains '"impl": "zai/glm-5.3-flash"' "$OUT" "models.impl = flash"
contains '"gate": "zai/glm-5.3"' "$OUT" "models.gate = 5.3"
contains "\"night_dir\": \"$REPO/.archloop/night-$TODAY\"" "$OUT" "night_dir = live dir"
contains '"last_log_line": "04:19:37 session start: i3-implement (zai/glm-5.3-flash)"' "$OUT" "last_log_line = live tail"

run_status
check "$RC" "0" "status text exits 0"
for want in "stage: i3-implement" "round: 2/8" "current item: tab-base-selection" \
            "alive: no" "trigger: unknown" "repo: $REPO" "shipped today (7)" "parked today (0)" \
            "scan zai/glm-5.3-flash"; do
  contains "$want" "$OUT" "text has: $want"
done
contains "score-snapshot-tuple" "$OUT" "text lists queued item"
contains "bare tuples with no named shape" "$OUT" "text lists queued summary"
contains "night-$TODAY" "$OUT" "text shows night dir"

echo "== Test 2: finished night — live dir removed, audit dir is the source =="
fresh_fixture_repo idle
rm -rf "$AR/night-$TODAY"        # unsuffixed fixture dir was round 3 (scan NONE)
run_status --json
check "$RC" "0" "status --json exits 0"
contains '"stage": "done"' "$OUT" "stage = done (run complete line)"
contains '"round": 3' "$OUT" "round = 3 (loop log DONE after 3)"
contains '"max_rounds": 8' "$OUT" "max_rounds = 8"
contains "\"night_dir\": \"$REPO/.archloop/night-$TODAY-0255-round2\"" "$OUT" "night_dir = audit dir"
contains '"current_item": null' "$OUT" "current_item = null"
check "$(jget "$OUT" queued_items)" "0" "queued_items = 0 (plan items all shipped today)"
contains '"last_log_line": "02:55:24 run complete' "$OUT" "last_log_line = run complete"

echo "== Test 3: trigger=nightly via tonight's START line in the night log =="
fresh_fixture_repo trig
printf '%s START %s: launching loop driver\n' "$(date '+%F %T')" "$(basename "$REPO")" > "$TMP/night.log"
OUT="$(ARCHLOOP_NIGHT_LOG="$TMP/night.log" bash "$CLI" status "$REPO" --json 2>&1)"; RC=$?
check "$RC" "0" "status --json exits 0"
contains '"trigger": "nightly"' "$OUT" "trigger = nightly (START line for repo basename today)"

echo "== Test 4: parked round (2026-08-17 transcript, 2 PARKED) =="
fresh_fixture_repo parked
sed -i "s|2026-08-17|$TODAY|g" "$AR/ledger.md"   # park date -> today
cat >> "$AR/night-$TODAY/driver.log" <<'EOF'
00:33:44 session start: scan-plan (opencode-proxy/opencode-go/deepseek-v4-flash)
01:00:33 session end: scan-plan (exit 0)
01:00:33 plan contains 2 item(s): remove-dead-filter-settings-filtering centralize-source-fetch-search-pages
01:00:33 session start: i1-implement (opencode-proxy/opencode-go/deepseek-v4-flash)
EOF
cp "$AR/night-2026-08-17-0140-round2/plan.md" "$AR/night-$TODAY/plan.md"
run_status --json
check "$RC" "0" "status --json exits 0"
contains '"stage": "i1-implement"' "$OUT" "stage = i1-implement"
check "$(jget "$OUT" parked_today)" "2" "parked_today = 2 (both PARKED lines dated today)"
check "$(jget "$OUT" shipped_today)" "9" "shipped_today = 9 (fixture 09-04 lines)"
contains '"current_item": "remove-dead-filter-settings-filtering"' "$OUT" "current_item = parked item 1"
run_status
contains "parked today (2)" "$OUT" "text parked today: 2"
contains "current item: remove-dead-filter-settings-filtering" "$OUT" "text current item parked round"

echo "== Test 5: repo with no .archloop at all -> graceful =="
rm -rf "$TMP/empty"; git init -q -b main "$TMP/empty"
echo x > "$TMP/empty/x"; git -C "$TMP/empty" add x
git -C "$TMP/empty" -c commit.gpgsign=false commit -qm x
REPO="$TMP/empty"
run_status --json
check "$RC" "0" "no-.archloop status --json exits 0"
contains '"stage": "idle"' "$OUT" "stage = idle"
contains '"pid": null' "$OUT" "pid = null (bare repo, number field keeps unquoted null)"
contains '"night_dir": null' "$OUT" "night_dir = null"
contains '"last_log_line": null' "$OUT" "last_log_line = null"
run_status
check "$RC" "0" "no-.archloop text exits 0"
contains "no archloop state found" "$OUT" "text says no archloop state found"

echo "== Test 6: alive detection via fake loop process =="
fresh_fixture_repo alive
printf '#!/usr/bin/env bash\nsleep 300\n' > "$TMP/archloop-loop.sh"
chmod +x "$TMP/archloop-loop.sh"
setsid bash "$TMP/archloop-loop.sh" "$REPO" >/dev/null 2>&1 &
FAKEPID=$!
run_status --json
contains '"alive": true' "$OUT" "alive = true (fake loop process)"
PIDOUT="$(jget "$OUT" pid)"
[ -n "$PIDOUT" ] && [ "$PIDOUT" -gt 0 ] 2>/dev/null \
  && ok "pid reported ($PIDOUT)" || bad "pid not reported (got '$PIDOUT')"
run_status
contains "alive: yes" "$OUT" "text alive: yes"
kill "$FAKEPID" 2>/dev/null; pkill -f "archloop-loop.sh $REPO" 2>/dev/null
true

echo "== Test 7: status.json (card E) preferred while the loop pid is live =="
fresh_fixture_repo sjlive
sed -i '\#=== round 3/8#,$d' "$AR/loop-driver.log"
cat >> "$AR/night-$TODAY/driver.log" <<'EOF'
02:58:22 session start: scan-plan (zai/glm-5.3-flash)
03:23:26 session end: scan-plan (exit 0)
03:23:26 plan contains 4 item(s): duel-enum-label-vocab source-search-page-scaffolding tab-base-selection score-snapshot-tuple
03:23:26 session start: i3-implement (zai/glm-5.3-flash)
EOF
cat > "$AR/night-$TODAY/plan.md" <<'EOF'
# Plan — rentcli deepening — night-2026-09-04

## Item: duel-enum-label-vocab

Two label vocabularies for the same enum drift silently. First body line.

## Item: source-search-page-scaffolding

Search page scaffolding is duplicated across sources. First body line.

## Item: tab-base-selection

Tab base selection logic is split across three sites. First body line.

## Item: score-snapshot-tuple

Score snapshots pass as bare tuples with no named shape. First body line.
EOF
# v1 reading of this fixture: stage=i3-implement, round=2/8, trigger=null.
# status.json (fake live loop pid) must win on every field it carries.
printf '#!/usr/bin/env bash\nsleep 300\n' > "$TMP/archloop-loop.sh"
chmod +x "$TMP/archloop-loop.sh"
setsid bash "$TMP/archloop-loop.sh" "$REPO" >/dev/null 2>&1 &
FAKEPID=$!
cat > "$AR/status.json" <<EOF
{
  "pid": $FAKEPID,
  "trigger": "nightly",
  "round": 5,
  "max_rounds": 6,
  "stage": "i2-gate",
  "updated_at": $(date +%s)
}
EOF
run_status --json
check "$RC" "0" "status --json exits 0 (live status.json)"
contains '"alive": true' "$OUT" "alive = true (status.json pid)"
check "$(jget "$OUT" pid)" "$FAKEPID" "pid = status.json pid"
contains '"trigger": "nightly"' "$OUT" "trigger = nightly (status.json; no night log)"
contains '"round": 5' "$OUT" "round = 5 (status.json beats loop log's 2)"
contains '"max_rounds": 6' "$OUT" "max_rounds = 6 (status.json)"
contains '"stage": "i2-gate"' "$OUT" "stage = i2-gate (status.json beats driver.log's i3-implement)"
contains '"current_item": "source-search-page-scaffolding"' "$OUT" "current item follows status.json stage"
run_status
contains "trigger: nightly" "$OUT" "text trigger: nightly"
contains "round: 5/6" "$OUT" "text round: 5/6"
contains "stage: i2-gate" "$OUT" "text stage: i2-gate"
contains "alive: yes" "$OUT" "text alive: yes"
kill "$FAKEPID" 2>/dev/null; pkill -f "archloop-loop.sh $REPO" 2>/dev/null
true

echo "== Test 8: finished loop (dead pid, file from today) — json keeps trigger/round, v1 owns alive/stage =="
fresh_fixture_repo sjdone
sed -i '\#=== round 3/8#,$d' "$AR/loop-driver.log"
cat >> "$AR/night-$TODAY/driver.log" <<'EOF'
02:58:22 session start: scan-plan (zai/glm-5.3-flash)
03:23:26 session end: scan-plan (exit 0)
03:23:26 session start: i3-implement (zai/glm-5.3-flash)
EOF
cat > "$AR/night-$TODAY/plan.md" <<'EOF'
## Item: duel-enum-label-vocab

Two label vocabularies for the same enum drift silently. First body line.

## Item: source-search-page-scaffolding

Search page scaffolding is duplicated across sources. First body line.

## Item: tab-base-selection

Tab base selection logic is split across three sites. First body line.
EOF
setsid bash -c 'exit 0' >/dev/null 2>&1 &
DEADPID=$!
wait "$DEADPID" 2>/dev/null
cat > "$AR/status.json" <<EOF
{
  "pid": $DEADPID,
  "trigger": "manual",
  "round": 5,
  "max_rounds": 6,
  "stage": "i2-gate",
  "updated_at": $(date +%s)
}
EOF
run_status --json
check "$RC" "0" "status --json exits 0 (dead-pid status.json)"
contains '"alive": false' "$OUT" "alive = false (json pid dead, pgrep clean)"
contains '"trigger": "manual"' "$OUT" "trigger = manual (kept from today's status.json)"
contains '"round": 5' "$OUT" "round = 5 (kept from status.json)"
contains '"max_rounds": 6' "$OUT" "max_rounds = 6 (kept from status.json)"
contains '"stage": "i3-implement"' "$OUT" "stage = i3-implement (v1 parsing, not json's i2-gate)"
contains '"current_item": "tab-base-selection"' "$OUT" "current item follows v1 stage"

echo "== Test 9: yesterday's or corrupt status.json ignored (pure v1) =="
fresh_fixture_repo sjstale
sed -i '\#=== round 3/8#,$d' "$AR/loop-driver.log"
cat >> "$AR/night-$TODAY/driver.log" <<'EOF'
02:58:22 session start: scan-plan (zai/glm-5.3-flash)
03:23:26 session end: scan-plan (exit 0)
03:23:26 session start: i3-implement (zai/glm-5.3-flash)
EOF
cat > "$AR/status.json" <<EOF
{
  "pid": 1,
  "trigger": "nightly",
  "round": 5,
  "max_rounds": 6,
  "stage": "i2-gate",
  "updated_at": $(date +%s)
}
EOF
touch -d 'yesterday 23:59' "$AR/status.json"
run_status --json
check "$RC" "0" "status --json exits 0 (yesterday's status.json)"
contains '"trigger": null' "$OUT" "trigger = null (yesterday's file ignored)"
contains '"round": 2' "$OUT" "round = 2 (v1 loop log, not json's 5)"
contains '"stage": "i3-implement"' "$OUT" "stage = i3-implement (v1)"
printf 'not json at all{' > "$AR/status.json"
run_status --json
check "$RC" "0" "corrupt status.json does not crash status"
contains '"round": 2' "$OUT" "corrupt json -> v1 round"
contains '"stage": "i3-implement"' "$OUT" "corrupt json -> v1 stage"
contains '"trigger": null' "$OUT" "corrupt json -> v1 trigger"
finish
