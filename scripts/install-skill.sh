#!/usr/bin/env bash
# install-skill.sh — idempotent install of the archloop skill + CLI (spec §5).
#
# Creates DIRECTORY symlinks (never bare SKILL.md file symlinks — every
# harness expects <skillsdir>/<name>/SKILL.md; r1-skill-discovery-6harnesses):
#   ~/.agents/skills/archloop        # shared lib: dsh, zcode, opencode, pi read it natively
#   ~/.claude/skills/archloop        # Claude Code
#   ~/.hermes/skills/archloop        # Hermes (default profile)
#   ~/.pi/agent/skills/archloop      # pi
# plus the CLI on PATH:
#   ~/.local/bin/archloop            # -> bin/archloop
#
# Idempotent: correct links are left untouched and reported; a WRONG symlink is
# relinked; a real file/dir in the way is never clobbered (reported, exit 1).
#
# Run:  bash scripts/install-skill.sh
# Tests override the home: ARCHLOOP_INSTALL_HOME=/tmp/fakehome bash scripts/install-skill.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_SRC="$REPO/skill/archloop"
BIN_SRC="$REPO/bin/archloop"
INSTALL_HOME="${ARCHLOOP_INSTALL_HOME:-$HOME}"

[ -f "$SKILL_SRC/SKILL.md" ] || { echo "install-skill: ABORT: $SKILL_SRC/SKILL.md not found" >&2; exit 1; }
[ -f "$BIN_SRC" ] || { echo "install-skill: ABORT: $BIN_SRC not found" >&2; exit 1; }

FAILURES=0

# link_dir <source> <destination-path> — directory/file symlink, idempotent.
link_dir() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ]; then
    if [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
      echo "  ok: $dst (already linked)"
    else
      ln -sfn "$src" "$dst" && echo "  relinked: $dst -> $src (was -> $(readlink "$dst"))" \
        || { echo "  FAIL: could not relink $dst" >&2; FAILURES=$((FAILURES+1)); }
    fi
  elif [ -e "$dst" ]; then
    echo "  FAIL: $dst exists and is not a symlink — not clobbering" >&2
    FAILURES=$((FAILURES+1))
  else
    ln -s "$src" "$dst" && echo "  linked: $dst -> $src" \
      || { echo "  FAIL: could not link $dst" >&2; FAILURES=$((FAILURES+1)); }
  fi
}

echo "install-skill: home=$INSTALL_HOME"
echo "skill dir ($SKILL_SRC):"
for d in ".agents/skills" ".claude/skills" ".hermes/skills" ".pi/agent/skills"; do
  link_dir "$SKILL_SRC" "$INSTALL_HOME/$d/archloop"
done
echo "cli ($BIN_SRC):"
link_dir "$BIN_SRC" "$INSTALL_HOME/.local/bin/archloop"

if [ "$FAILURES" -gt 0 ]; then
  echo "install-skill: $FAILURES target(s) failed" >&2
  exit 1
fi
echo "install-skill: done"
