#!/usr/bin/env bash
# install-skill-tests.sh — stub suite for scripts/install-skill.sh (zero quota,
# zero real-home writes: every run installs into a throwaway fake home).
# Covers: fresh install, idempotency (2nd run is a no-op), wrong-link repair,
# collision refusal (never clobbers real files), missing-source abort.
# Run: bash scripts/install-skill-tests.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="${ARCHLOOP_INSTALLER:-$SCRIPT_DIR/install-skill.sh}"
[ -f "$INSTALLER" ] || { echo "ABORT: installer not found at $INSTALLER" >&2; exit 1; }
TMP="$(mktemp -d)"
. "$SCRIPT_DIR/lib/harness.sh"
trap 'rm -rf "$TMP"' EXIT

# run_installer <home> — installs into the given fake home; sets OUT/RC.
run_installer() {
  OUT="$(ARCHLOOP_INSTALL_HOME="$1" bash "$INSTALLER" 2>&1)"
  RC=$?
}

# verify_install <home> <tag> — all 5 links exist and resolve to the worktree sources.
verify_install() {
  local h="$1" tag="$2" srcd
  srcd="$(cd "$SCRIPT_DIR/.." && pwd)"
  local all_ok=1
  for d in .agents/skills .claude/skills .hermes/skills .pi/agent/skills; do
    [ "$(readlink -f "$h/$d/archloop")" = "$srcd/skill/archloop" ] || all_ok=0
  done
  [ "$(readlink -f "$h/.local/bin/archloop")" = "$srcd/bin/archloop" ] || all_ok=0
  check "$all_ok" "1" "$tag: all 5 links resolve into the repo"
  if [ "$(cat "$h/.agents/skills/archloop/SKILL.md" 2>/dev/null | head -3 | grep -c '^name: archloop')" = "1" ] \
     && [ -x "$h/.local/bin/archloop" ]; then
    ok "$tag: SKILL.md readable and bin executable through the links"
  else
    bad "$tag: link targets not readable/executable"
  fi
}

echo "== Test 1: fresh install into empty home =="
H1="$TMP/home1"; mkdir -p "$H1"
run_installer "$H1"
check "$RC" "0" "installer exits 0 on fresh home"
verify_install "$H1" "fresh"
contains_new=0
grep -q "linked: $H1/.agents/skills/archloop" <<<"$OUT" && contains_new=1
check "$contains_new" "1" "fresh run reports 'linked' for the skill dir"

echo "== Test 2: idempotency — second run changes nothing =="
run_installer "$H1"
check "$RC" "0" "second run exits 0"
verify_install "$H1" "rerun"
check "$(grep -c 'already linked' <<<"$OUT")" "5" "all 5 targets reported already linked"
check "$(grep -c 'linked:' <<<"$OUT")" "0" "no target re-created"

echo "== Test 3: repair — wrong symlink target is relinked =="
ln -sfn /nonexistent/nowhere "$H1/.claude/skills/archloop"
run_installer "$H1"
check "$RC" "0" "run over a wrong link exits 0"
verify_install "$H1" "repair"
grep -q "relinked: $H1/.claude/skills/archloop" <<<"$OUT" \
  && ok "wrong link reported as relinked" || bad "wrong link not reported as relinked"

echo "== Test 4: collision — real file/dir in the way is never clobbered =="
# Fresh home: appending to a path that is already a symlink would write THROUGH
# the link and clobber the repo file (hit in this suite's first run).
H4="$TMP/home4"; mkdir -p "$H4"
run_installer "$H4"
check "$RC" "0" "fresh H4 install before collision test"
rm "$H4/.local/bin/archloop"          # drop the link, keep parent dirs
echo "keep-me" > "$H4/.local/bin/archloop"
run_installer "$H4"
check "$RC" "1" "collision -> exit 1"
grep -q "not a symlink — not clobbering" <<<"$OUT" \
  && ok "collision reported without clobbering" || bad "collision not reported"
check "$(cat "$H4/.local/bin/archloop")" "keep-me" "colliding file content intact"
# the 4 skill links were still fine in this run
check "$(grep -c 'already linked' <<<"$OUT")" "4" "skill links still reported ok despite bin collision"
rm -f "$H4/.local/bin/archloop"
run_installer "$H4"
check "$RC" "0" "after removing the collision, installer is green again"
verify_install "$H4" "recovered"

echo "== Test 5: missing source — aborts before touching the home =="
SkelRepo="$TMP/skel"; mkdir -p "$SkelRepo/scripts" "$SkelRepo/bin"
cp "$INSTALLER" "$SkelRepo/scripts/install-skill.sh"
printf '#!/usr/bin/env bash\n' > "$SkelRepo/bin/archloop"; chmod +x "$SkelRepo/bin/archloop"
H2="$TMP/home2"; mkdir -p "$H2"
OUT="$(ARCHLOOP_INSTALL_HOME="$H2" bash "$SkelRepo/scripts/install-skill.sh" 2>&1)"
RC=$?
check "$RC" "1" "missing skill source -> ABORT exit 1"
grep -q "SKILL.md not found" <<<"$OUT" && ok "abort names the missing SKILL.md" || bad "abort message unclear"
check "$(find "$H2" -mindepth 1 | wc -l)" "0" "home untouched on abort"
finish
