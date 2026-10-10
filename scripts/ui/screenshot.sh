#!/usr/bin/env bash
# screenshot.sh — capture DIR/index.html at 1280x800 (spec t_95a2c885 §6).
# Sourced by the ui driver. Backend order:
#   $ARCHLOOP_CAPTURE_CMD  (override; receives "<url> <out> <w> <h>")
#   chromium | chromium-browser | google-chrome (headless)
#   wkhtmltoimage
# None found -> exit 2 listing what was tried.
[ -n "${UI_LIB_DIR:-}" ] || UI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_SHOT_W=1280
UI_SHOT_H=800

ui_capture() { # $1=index.html abs path $2=out-image abs path
  local index="$1" img="$2" cmd cand url
  url="file://$index"
  if [ -n "${ARCHLOOP_CAPTURE_CMD:-}" ]; then
    # contract: "$ARCHLOOP_CAPTURE_CMD" <url> <out-image> <width> <height>
    ${ARCHLOOP_CAPTURE_CMD} "$url" "$img" "$UI_SHOT_W" "$UI_SHOT_H" || return 1
    [ -s "$img" ] && return 0
    return 1
  fi
  for cand in chromium chromium-browser google-chrome; do
    cmd="$(command -v "$cand" 2>/dev/null)" || continue
    "$cmd" --headless --disable-gpu --no-sandbox \
      --window-size="$UI_SHOT_W,$UI_SHOT_H" \
      --screenshot="$img" "$url" >/dev/null 2>&1 || continue
    [ -s "$img" ] && return 0
  done
  if command -v wkhtmltoimage >/dev/null 2>&1; then
    wkhtmltoimage --width "$UI_SHOT_W" --height "$UI_SHOT_H" \
      "$url" "$img" >/dev/null 2>&1 && [ -s "$img" ] && return 0
  fi
  ui_die "no screenshot backend found — tried: ARCHLOOP_CAPTURE_CMD, chromium, chromium-browser, google-chrome, wkhtmltoimage (see docs/ui.md)"
}
