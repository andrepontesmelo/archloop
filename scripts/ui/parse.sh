#!/usr/bin/env bash
# parse.sh — normalize <repo>/.archloop into night records (spec t_95a2c885 §3).
# Sourced by the ui driver; standalone for tests:
#   scripts/ui/parse.sh <repo>... > records
# Record = one line per night dir, fields joined by US (0x1f):
#   repo date suffix kind legacy stale run_status branch abort_reason mtime items
#   repo    = absolute repo path (display name = basename at render time)
#   suffix  = everything after the 10-char date in the dir name (may be "")
#   kind    = none | retry | rename | legacy
#   items   = RS-separated (0x1e) item records "name US SHIP|PARK US sha_range"
# Never fatal: an unparseable night still yields a record (status derived,
# items empty) and a warning on stderr.
[ -n "${UI_LIB_DIR:-}" ] || UI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_US=$'\x1f'
UI_RS=$'\x1e'

# derived run_status per the R1 decision table (spec §3)
ui_derive_status() { # $1=night-dir
  local d="$1" v
  if [ -f "$d/push.log" ] && grep -q '\.\.' "$d/push.log"; then printf 'PUSHED'; return; fi
  if [ -f "$d/merge.log" ]; then printf 'MERGED_LOCAL'; return; fi
  v="$(grep -oiE '^(SHIP|PARK|DONE|FAILED|PLANNED|NONE|QUEUED)$' "$d/verdict" 2>/dev/null | tail -1 | tr 'a-z' 'A-Z')"
  case "$v" in
    SHIP)   printf 'GATED_NOT_MERGED' ;;
    DONE)   printf 'IMPLEMENTED_NO_GATE' ;;
    PLANNED) printf 'PLANNED_ONLY' ;;
    NONE)   printf 'CLEAN_NO_CANDIDATES' ;;
    PARK)   printf 'PARKED' ;;
    QUEUED) printf 'QUEUED' ;;
    *) if grep -qi 'scan/plan failed' "$d/REPORT.md" 2>/dev/null; then printf 'SCAN_FAILED'
         elif grep -q 'ABORT: baseline red' "$d/driver.log" 2>/dev/null; then printf 'PREFLIGHT_RED'
         elif grep -qE '(SHIPPED: [0-9a-f]{7,}\.\.[0-9a-f]{7,})' "$d/REPORT.md" 2>/dev/null; then printf 'GATED_NOT_MERGED'
         else printf 'HARD_ABORT'; fi ;;
  esac
}

# suffix classification (spec §3): none | retry | rename | legacy
ui_suffix_kind() { # $1=suffix as it appears after the date ("" | -xxx | .xxx)
  local s="$1"
  [ -z "$s" ] && { printf 'none'; return; }
  case "$s" in
    .stale|*.v[0-9]|*.v[0-9][0-9]*|*.abort[0-9]*|*.run[0-9]*|*.stale.*) printf 'legacy'; return ;;
  esac
  local nodash="${s#-}"
  echo "$nodash" | grep -qE '(^|-)(round|loop)[0-9]+(-manual)?$' && { printf 'retry'; return; }
  echo "$nodash" | grep -qE '(^|-)(previous|[a-z0-9]+-[0-9]{3})$' && { printf 'rename'; return; }
  printf 'rename'
}

# items from REPORT.md lines + gate-file cross-check (spec §3)
ui_parse_items() { # $1=night-dir $2=legacy-flag -> RS-joined item records
  local d="$1" legacy="$2" out="" line item sha gate
  if [ -f "$d/REPORT.md" ]; then
    # current era: "- **<item>** — SHIPPED: <a>..<b> — see ..."
    while IFS= read -r line; do
      item="$(printf '%s' "$line" | sed -n 's/^\(- \)\?\*\*\([^*]*\)\*\*.*SHIPPED: \([0-9a-f]\{7,\}\)\.\.\([0-9a-f]\{7,\}\).*/\2/p')"
      sha="$(printf '%s' "$line"  | sed -n 's/^.*SHIPPED: \([0-9a-f]\{7,\}\.\.[0-9a-f]\{7,\}\).*/\1/p')"
      [ -n "$item" ] && out+="${item}${UI_GS}SHIP${UI_GS}${sha}${UI_RS}"
    done < <(grep -E '\*\*.*\*\*.*SHIPPED:' "$d/REPORT.md" 2>/dev/null)
    # parked lines: "- **<item>** — parked at gate" (any stage, lowercase)
    while IFS= read -r line; do
      item="$(printf '%s' "$line" | sed -n 's/^\(- \)\?\*\*\([^*]*\)\*\*.*parked at .*/\2/p')"
      [ -n "$item" ] && out+="${item}${UI_GS}PARK${UI_GS}${UI_RS}"
    done < <(grep -E '\*\*.*\*\*.*parked at ' "$d/REPORT.md" 2>/dev/null)
  fi
  # cross-check: gate-<item>.md present but item has no REPORT line = PARKED
  for gate in "$d"/gate-*.md; do
    [ -f "$gate" ] || continue
    item="$(basename "$gate" .md)"; item="${item#gate-}"
    printf '%s\n' "$out" | tr "$UI_RS" '\n' | grep -q "^${item}${UI_GS}" || out+="${item}${UI_GS}PARK${UI_GS}${UI_RS}"
  done
  # legacy backfill: item names from candidate-N dirs matched against REPORT
  if [ "$legacy" -eq 1 ] && [ -z "$out" ] && [ -f "$d/REPORT.md" ]; then
    local n=1
    while ls -d "$d/candidate-$n" >/dev/null 2>&1; do
      item="$(sed -n "s/^## Candidate $n: \([a-z0-9-]*\).*/\1/p" "$d/REPORT.md" | head -1)"
      [ -n "$item" ] && out+="${item}${UI_GS}SHIP${UI_GS}-${UI_RS}"
      n=$((n+1))
    done
  fi
  printf '%s' "${out%$UI_RS}"
}

ui_parse_repo() { # $1=repo-abs-path — emits one record line per night dir
  local repo="$1" d base alldate date suffix kind legacy stale status branch abort mtime
  for d in "$repo"/.archloop/night-*; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    alldate="$(printf '%s' "$base" | sed -n 's/^night-\(.\{10\}\)\(.*\)$/\1|\2/p')"
    [ -n "$alldate" ] || { ui_warn "unparseable night dir skipped: $d"; continue; }
    date="${alldate%%|*}"; suffix="${alldate#*|}"
    legacy=0; stale=0
    [ "$base" = "${base%.stale}" ] || stale=1
    ls -d "$d"/candidate-[0-9]* >/dev/null 2>&1 && legacy=1
    kind="$(ui_suffix_kind "$suffix")"
    [ "$kind" = legacy ] && legacy=1
    status="$(ui_derive_status "$d")"
    [ "$status" = QUEUED ] && legacy=1
    # branch: REPORT.md header line 1 (both era formats), then driver.log
    branch="$(sed -n '1{s/^.*branch \([^),]*\)).*$/\1/p}' "$d/REPORT.md" 2>/dev/null)"
    [ -n "$branch" ] || branch="$(grep -m1 -oE 'branch [^),[:space:]]+' "$d/driver.log" 2>/dev/null | sed 's/^branch //')"
    abort="$(grep -m1 'ABORT:' "$d/driver.log" 2>/dev/null | sed 's/^[0-9:]* ABORT: //' | tr -d '\r')"
    mtime="$(stat -c %Y "$d" 2>/dev/null || echo 0)"
    printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
      "$repo" "$UI_US" "$date" "$UI_US" "$suffix" "$UI_US" "$kind" "$UI_US" \
      "$legacy" "$UI_US" "$stale" "$UI_US" "$status" "$UI_US" "$branch" "$UI_US" \
      "${abort:-}" "$UI_US" "$mtime" "$UI_US" "$(ui_parse_items "$d" "$legacy")"
  done
}

# ledger rows for index (spec §3): "- DATE item: SHIPPED on branch (sha)" and
# "- DATE item: PARKED at stage". -> RS-joined rows "item US SHIP|PARK US sha"
ui_ledger_rows() { # $1=repo $2=date
  local repo="$1" date="$2" line item rest out=""
  [ -f "$repo/.archloop/ledger.md" ] || return 0
  while IFS= read -r line; do
    item="$(printf '%s' "$line" | sed -n "s/^- $date \([a-z0-9-]*\): .*/\1/p")"
    [ -n "$item" ] || continue
    rest="$(printf '%s' "$line" | sed -n "s/^- $date [a-z0-9-]*: //p")"
    case "$rest" in
      SHIPPED*) out+="${item}${UI_GS}SHIP${UI_GS}$(printf '%s' "$rest" | sed -n 's/.*(\([0-9a-f]*\)).*/\1/p')${UI_RS}" ;;
      PARKED*)  out+="${item}${UI_GS}PARK${UI_GS}${UI_RS}" ;;
    esac
  done < "$repo/.archloop/ledger.md"
  printf '%s' "${out%$UI_RS}"
}

# standalone mode (tests): repo paths as args
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  . "${UI_LIB_DIR}/common.sh"
  for r in "$@"; do ui_parse_repo "$r"; done
fi
