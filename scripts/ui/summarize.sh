#!/usr/bin/env bash
# summarize.sh — LLM JSON sidecars as a post-pass (spec t_95a2c885 §4).
# Sourced by the ui driver. For each item in each night dir, writes
# <night-dir>/ui/<item>.json via one session; invalid output is renamed
# .rejected and the generator falls back. A session failure sets
# UI_SUMMARY_FAILED=1 but never aborts the pipeline.
[ -n "${UI_LIB_DIR:-}" ] || UI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_RS=$'\x1e'
UI_SUMMARY_FAILED=0

# resolve the session runner exactly like bin/archloop (OC fallback chain)
ui_resolve_oc() {
  UI_OC="${ARCHLOOP_OPENCODE:-}"
  if [ -z "$UI_OC" ]; then
    local cand
    for cand in "$UI_REAL_HOME/.opencode/bin/opencode" "$(command -v opencode 2>/dev/null)"; do
      [ -n "$cand" ] && [ -x "$cand" ] && { UI_OC="$cand"; break; }
    done
  fi
}

# missing one (or .rejected), unless force=1 rewrites valid ones too.
# Sets UI_SUMMARY_FAILED=1 when a session fails; never dies.
ui_summarize() {
  local repo="$1" ndir="$2" items="$3" force="${4:-0}"
  local item rec it_status sha target prompt plan_sec gate REPORT_LINE
  ui_resolve_oc
  # caller (cmd_ui) resolves per-repo WITH the --model flag; resolve here only
  # when standalone (no prior resolution) — never stomp the flag chain.
  [ -n "${UI_MODEL:-}" ] || ui_resolve_model "$repo" ""
  [ -n "${UI_OC:-}" ] || { ui_warn "no session runner found — set ARCHLOOP_OPENCODE"; UI_SUMMARY_FAILED=1; return 0; }
  if [ -z "$items" ]; then return 0; fi
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    ui_row_fields "$rec"; item="$R_ITEM"
    target="$ndir/ui/$item.json"
    if [ "$force" -eq 0 ] && [ -f "$target" ] && ui_validate_sidecar "$target" "$item"; then
      continue  # content-addressed skip: valid sidecar never rewritten
    fi
    mkdir -p "$ndir/ui"
    # prompt inputs (spec §4): plan section + gate report + REPORT item line
    plan_sec=""
    if [ -f "$ndir/plan.md" ]; then
      plan_sec="$(awk -v it="$item" '
        $0 ~ "^## Item: " it "$" {p=1; print; next}
        p && /^## Item: / {p=0}
        p {print}' "$ndir/plan.md")"
    fi
    gate=""
    [ -f "$ndir/gate-$item.md" ] && gate="$(cat "$ndir/gate-$item.md")"
    REPORT_LINE="$(grep -m1 "\*\*$item\*\*" "$ndir/REPORT.md" 2>/dev/null || true)"
    prompt="You are summarizing one archived architecture-improvement item for a static history browser. Output contract — your ENTIRE response is consumed by a strict parser, so obey exactly: write a JSON object as the only content of the file $target (no markdown fence, no prose, no trailing text). The object must have exactly these keys:

{\"schema\": 1, \"item\": \"$item\", \"title\": \"<3-60 chars, human, no trailing period>\", \"details\": \"<1-3 sentences, <=500 chars, plain text>\", \"model\": \"$UI_MODEL\", \"generated_at\": \"<ISO 8601>\"}

Base title and details only on the material below. details says what the duplication/problem was and what the change did, in plain sentences.

--- plan.md section for this item (if any):
$plan_sec

--- gate report (gate-$item.md, if any):
$gate

--- REPORT.md line for this item (if any):
$REPORT_LINE"

    echo "archloop ui: summarizing $item ($(basename "$ndir")) [$UI_MODEL]" >&2
    local rc=0
    HOME="$UI_REAL_HOME" timeout "${ARCHLOOP_UI_TIMEOUT:-300}" \
      "$UI_OC" run --dir "$repo" --model "$UI_MODEL" \
      --title "archloop-ui-$item" "$prompt" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -f "$target" ]; then
      ui_warn "session failed for $item in $(basename "$ndir") (exit $rc) — leaving fallback"
      UI_SUMMARY_FAILED=1
      continue
    fi
    if ! ui_validate_sidecar "$target" "$item"; then
      mv -f "$target" "$target.rejected"
      ui_warn "invalid sidecar for $item in $(basename "$ndir") — rejected, using fallback"
      continue
    fi
  done < <(printf '%s\n' "$items" | tr "$UI_RS" '\n' | grep -v '^$')
}
