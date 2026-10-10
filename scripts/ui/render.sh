#!/usr/bin/env bash
# render.sh — static HTML/text renderer (spec t_95a2c885 §5, visual language
# = approved v0 prototype, pinned tokens). Sourced by the ui driver.
# Reads the records file produced by parse.sh (one line per night, US-joined
# fields, see parse.sh header) and writes:
#   DIR/index.html
#   DIR/night/<repo>/<date><suffix>.html
#   DIR/item/<repo>/<date><suffix>/<item>.html
# Deterministic: no timestamps in output. All interpolated text is escaped.
[ -n "${UI_LIB_DIR:-}" ] || UI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_RS=$'\x1e'
UI_US=$'\x1f'

UI_CSS='*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans",Helvetica,Arial,sans-serif;background:#0d1117;color:#e6edf3;line-height:1.6;padding:2rem}
.container{max-width:960px;margin:0 auto}
h1{font-size:1.6rem;margin-bottom:.25rem}
h2{font-size:1.05rem;margin-bottom:.5rem}
.subtitle{color:#8b949e;margin-bottom:1.5rem;font-size:.95rem}
a{color:#58a6ff;text-decoration:none}
a:hover{text-decoration:underline}
code,.mono{font-family:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;font-size:.82rem}
code{background:#1c2128;padding:.1rem .35rem;border-radius:4px;color:#8b949e}
.summary{display:flex;gap:.5rem;margin-bottom:2rem;flex-wrap:wrap}
.badge{display:inline-flex;align-items:center;gap:.35rem;padding:.3rem .75rem;border-radius:20px;font-size:.78rem;font-weight:600}
.badge-shipped{background:#238636;color:#fff}
.badge-parked{background:#9e6a03;color:#fff}
.badge-clean{background:#484f58;color:#c9d1d9}
.badge-failed{background:#da3633;color:#fff}
.night-section{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:1.25rem 1.5rem;margin-bottom:1rem}
.night-header{display:flex;align-items:center;gap:.75rem;margin-bottom:.5rem;flex-wrap:wrap}
.night-header h2{font-size:1.05rem;font-weight:600}
.night-date{font-family:monospace;color:#8b949e;font-size:.85rem}
.repo-tag{display:inline-block;background:#1c2128;border:1px solid #30363d;border-radius:4px;padding:.15rem .5rem;font-family:monospace;font-size:.75rem;color:#8b949e}
.legacy-tag{display:inline-block;background:#3d1d00;border:1px solid #9e6a03;border-radius:4px;padding:.1rem .45rem;font-size:.68rem;color:#d29922;font-weight:600;letter-spacing:.03em}
.stale-tag{display:inline-block;background:#1c2128;border:1px dashed #484f58;border-radius:4px;padding:.1rem .45rem;font-size:.68rem;color:#8b949e;font-weight:600;letter-spacing:.03em}
.derived-status{display:inline-block;padding:.15rem .55rem;border-radius:4px;font-family:monospace;font-size:.7rem;font-weight:700;letter-spacing:.03em}
.ds-PUSHED{background:#238636;color:#fff}
.ds-MERGED_LOCAL{background:#1f6feb;color:#fff}
.ds-GATED_NOT_MERGED{background:#8957e5;color:#fff}
.ds-IMPLEMENTED_NO_GATE{background:#a371f7;color:#fff}
.ds-PLANNED_ONLY{background:#6e7681;color:#c9d1d9}
.ds-CLEAN_NO_CANDIDATES{background:#484f58;color:#c9d1d9}
.ds-PARKED{background:#9e6a03;color:#fff}
.ds-QUEUED{background:#6e7681;color:#c9d1d9}
.ds-SCAN_FAILED{background:#da3633;color:#fff}
.ds-PREFLIGHT_RED{background:#f85149;color:#fff}
.ds-HARD_ABORT{background:#b62324;color:#fff}
.night-link{margin-left:auto;font-size:.82rem}
.night-note{color:#8b949e;font-size:.82rem;margin-bottom:.5rem;padding-left:.25rem}
.item-row{display:flex;align-items:center;gap:.65rem;padding:.55rem .25rem;border-top:1px solid #21262d}
.item-row:hover{background:#1c2128;border-radius:4px}
.item-badge{flex-shrink:0;width:3.5rem;text-align:center;padding:.15rem 0;border-radius:3px;font-size:.65rem;font-weight:700;text-transform:uppercase;letter-spacing:.04em}
.ib-ship{background:#238636;color:#fff}
.ib-park{background:#9e6a03;color:#fff}
.item-title{font-weight:500;flex:1}
.item-sha{color:#8b949e;flex-shrink:0}
.item-name{color:#484f58;font-family:monospace;font-size:.72rem;flex-shrink:0}
.no-summary{display:inline-block;background:#1c2128;border:1px solid #30363d;border-radius:4px;padding:.1rem .45rem;font-size:.65rem;color:#8b949e;font-weight:600;letter-spacing:.03em;vertical-align:middle;margin-left:.5rem}
.llm-badge{display:inline-block;background:#1c2128;border:1px solid #30363d;border-radius:4px;padding:.1rem .45rem;font-size:.65rem;color:#8b949e;font-weight:600;letter-spacing:.03em;vertical-align:middle;margin-left:.5rem}
.card{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:1.25rem 1.5rem;margin-bottom:1rem}
.meta-grid{display:grid;grid-template-columns:120px 1fr;gap:.4rem 1rem;margin-bottom:1.5rem;font-size:.85rem}
.meta-label{color:#8b949e;text-align:right}
.llm-details{font-size:.92rem;color:#c9d1d9;line-height:1.7;margin-bottom:.5rem}
.gate-excerpt{background:#0d1117;border:1px solid #21262d;border-radius:4px;padding:.75rem 1rem;font-size:.8rem;color:#8b949e;white-space:pre-wrap;font-family:monospace;line-height:1.5}
.gate-label{font-size:.7rem;color:#484f58;text-transform:uppercase;letter-spacing:.05em;margin-bottom:.25rem}
.raw-links{display:flex;gap:.75rem;flex-wrap:wrap;margin-top:.5rem;font-size:.8rem}
.back-link{color:#8b949e;font-size:.85rem;margin-bottom:1rem;display:inline-block}
.footer{color:#484f58;font-size:.75rem;margin-top:3rem;text-align:center}'

# ---- record loading --------------------------------------------------------

ui_load_records() { # $1=records-file -> N_* arrays + NN
  local line i=0
  NN=0
  N_REPO=(); N_DATE=(); N_SUFFIX=(); N_KIND=(); N_LEGACY=(); N_STALE=()
  N_STATUS=(); N_BRANCH=(); N_ABORT=(); N_MTIME=(); N_ITEMS=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local f; IFS="$UI_US" read -r -a f <<<"$line"
    [ "${#f[@]}" -ge 10 ] || { ui_warn "short record skipped"; continue; }
    [ "${#f[@]}" -ge 11 ] || f[10]=""
    N_REPO[i]="${f[0]}"; N_DATE[i]="${f[1]}"; N_SUFFIX[i]="${f[2]}"; N_KIND[i]="${f[3]}"
    N_LEGACY[i]="${f[4]}"; N_STALE[i]="${f[5]}"; N_STATUS[i]="${f[6]}"; N_BRANCH[i]="${f[7]}"
    N_ABORT[i]="${f[8]}"; N_MTIME[i]="${f[9]}"; N_ITEMS[i]="${f[10]}"
    i=$((i+1))
  done < "$1"
  NN=$i
}

# order: date desc, same-date mtime desc -> UI_ORDER (space-separated indexes)
ui_order_nights() {
  local i
  UI_ORDER="$(for ((i=0; i<NN; i++)); do
    printf '%s %s %s\n' "${N_DATE[i]}" "${N_MTIME[i]}" "$i"
  done | sort -k1,1r -k2,2nr | awk '{printf "%s ", $3}')"
  UI_ORDER="${UI_ORDER% }"
}

# ledger lookup per repo+date (rows string from ui_ledger_rows + branch)
declare -A UI_LEDGER
ui_load_ledger() { # fills UI_LEDGER: "repo|date" -> rows
  local repo date
  for repo in $UI_REPOS; do
    while IFS= read -r date; do
      [ -n "$date" ] || continue
      UI_LEDGER["$repo|$date"]="$(ui_ledger_rows "$repo" "$date")"
    done < <(grep -oE '^- [0-9]{4}-[0-9]{2}-[0-9]{2} ' "$repo/.archloop/ledger.md" 2>/dev/null | sort -u | awk '{print $2}')
  done
}

# primary night index per repo+date: unsuffixed dir if present, else oldest
declare -A UI_PRIMARY
ui_primary_night() {
  local i key best
  UI_PRIMARY=()
  for ((i=0; i<NN; i++)); do
    key="${N_REPO[i]}|${N_DATE[i]}"
    best="${UI_PRIMARY[$key]:-}"
    if [ -z "$best" ]; then
      UI_PRIMARY["$key"]=$i
    elif [ -z "${N_SUFFIX[best]}" ] && [ -n "${N_SUFFIX[i]}" ]; then
      : # unsuffixed night stays primary
    elif [ -z "${N_SUFFIX[i]}" ] && [ -n "${N_SUFFIX[best]}" ]; then
      UI_PRIMARY["$key"]=$i
    elif [ "${N_MTIME[i]}" -lt "${N_MTIME[best]}" ]; then
      UI_PRIMARY["$key"]=$i
    fi
  done
}

# ---- item records: the name GS status GS sha wire shape (parse.sh) --------

ui_row_fields() { # $1=record -> R_ITEM R_ST R_SHA; one read, not three cuts
  IFS="$UI_GS" read -r R_ITEM R_ST R_SHA <<<"$1"
}

ui_night_dir() { # $1=night-idx -> the night dir that produced that record
  printf '%s' "${N_REPO[$1]}/.archloop/night-$(ui_night_slug "$1")"
}

ui_night_rows() { # $1=night-idx -> the rows string the index/text renderers use
  local i="$1" key rows primary
  key="${N_REPO[i]}|${N_DATE[i]}"
  rows="${UI_LEDGER[$key]:-}"
  primary="${UI_PRIMARY[$key]:--1}"
  [ "$i" = "$primary" ] && [ -n "$rows" ] && { printf '%s' "$rows"; return 0; }
  rows="${N_ITEMS[i]}"
  [ -n "$rows" ] && { printf '%s' "$rows"; return 0; }
  printf '%s' "${UI_LEDGER[$key]:-}"
}

# ---- shared fragments ------------------------------------------------------

ui_head() { # $1=title
  printf '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="UTF-8">\n<meta name="viewport" content="width=device-width, initial-scale=1.0">\n<title>%s</title>\n<style>%s</style>\n</head>\n<body>\n<div class="container">\n' \
    "$(printf '%s' "$1" | ui_esc)" "$UI_CSS"
}
ui_foot() { # $1=extra footer text
  printf '<p class="footer">generated by archloop ui &middot; %s &middot; static HTML &middot; no JS</p>\n\n</div>\n</body>\n</html>\n' "$1"
}

ui_repo_name() { basename "$1"; }

ui_night_slug() { # $1=idx -> "date+suffix" (dir-name identity)
  printf '%s%s' "${N_DATE[$1]}" "${N_SUFFIX[$1]}"
}

ui_night_url() { # $1=idx
  printf 'night/%s/%s.html' "$(ui_repo_name "${N_REPO[$1]}")" "$(ui_night_slug "$1")"
}

# sidecar access (validated); empty when absent/invalid
ui_sidecar() { # $1=night-idx $2=item $3=key
  local ndir item f
  ndir="$(ui_night_dir "$1")"
  f="$ndir/ui/$2.json"
  [ -f "$f" ] || return 0
  ui_validate_sidecar "$f" "$2" || return 0
  ui_json_get "$f" "$3"
}

ui_item_page_exists() { # $1=repo $2=date $3=item -> prints "idx" of owning night
  local i
  for ((i=0; i<NN; i++)); do
    [ "${N_REPO[i]}" = "$1" ] && [ "${N_DATE[i]}" = "$2" ] || continue
    printf '%s\n' "${N_ITEMS[i]}" | tr "$UI_RS" '\n' | grep -q "^$3${UI_GS}" && { echo "$i"; return 0; }
  done
  return 1
}

# index row link for a ledger/backfill item (spec §5: page or night anchor)
ui_row_href() { # $1=night-idx $2=item
  local owner
  if owner="$(ui_item_page_exists "${N_REPO[$1]}" "${N_DATE[$1]}" "$2")"; then
    printf 'item/%s/%s/%s.html' "$(ui_repo_name "${N_REPO[$owner]}")" "$(ui_night_slug "$owner")" "$2"
  else
    printf '%s#%s' "$(ui_night_url "$1")" "$2"
  fi
}

ui_row_title() { # $1=night-idx $2=item — sidecar title else humanized kebab
  local t
  t="$(ui_sidecar "$1" "$2" title)"
  [ -n "$t" ] && printf '%s' "$t" || ui_humanize "$2"
}

# ---- badge mapping (spec §5) -----------------------------------------------

ui_bucket() { # $1=run_status -> shipped|parked|clean|failed
  case "$1" in
    PUSHED|MERGED_LOCAL|GATED_NOT_MERGED) printf shipped ;;
    PARKED|QUEUED) printf parked ;;
    CLEAN_NO_CANDIDATES) printf clean ;;
    *) printf failed ;;
  esac
}

# ---- index -----------------------------------------------------------------

ui_render_index() { # $1=out-dir
  local out="$1" i b shipped=0 parked=0 clean=0 failed=0 nights=0 rows rec item st sha title href
  {
    ui_head "archloop history"
    printf '<h1>archloop history</h1>\n<p class="subtitle">Overnight improvement browser &mdash; static, regenerated on demand</p>\n\n'
    for ((i=0; i<NN; i++)); do
      [ "${N_STALE[i]}" = 1 ] && continue
      b="$(ui_bucket "${N_STATUS[i]}")"
      case "$b" in
        shipped) shipped=$((shipped+1)) ;; parked) parked=$((parked+1)) ;;
        clean) clean=$((clean+1)) ;; failed) failed=$((failed+1)) ;;
      esac
    done
    printf '<div class="summary">\n'
    printf '  <span class="badge badge-shipped">&#10003; Shipped %d</span>\n' "$shipped"
    printf '  <span class="badge badge-parked">&#9208; Parked %d</span>\n' "$parked"
    printf '  <span class="badge badge-clean">&#9679; Clean %d</span>\n' "$clean"
    printf '  <span class="badge badge-failed">&#10007; Failed %d</span>\n' "$failed"
    printf '</div>\n\n'
    for i in $UI_ORDER; do
      nights=$((nights+1))
      ui_render_night_section "$i"
    done
    ui_foot "$NN nights rendered"
  } > "$out/index.html"
}

ui_render_night_section() { # $1=idx — one night-section block on stdout
  local i="$1" repo date status note rows rec item st sha title href
  repo="$(ui_repo_name "${N_REPO[i]}")"; date="${N_DATE[i]}"; status="${N_STATUS[i]}"
  printf '<div class="night-section">\n  <div class="night-header">\n'
  printf '    <span class="night-date">%s</span>\n' "$(printf '%s' "$date" | ui_esc)"
  printf '    <span class="repo-tag">%s</span>\n' "$(printf '%s' "$repo" | ui_esc)"
  [ "${N_LEGACY[i]}" = 1 ] && printf '    <span class="legacy-tag">LEGACY</span>\n'
  [ "${N_STALE[i]}" = 1 ] && printf '    <span class="stale-tag">STALE</span>\n'
  printf '    <span class="derived-status ds-%s">%s</span>\n' "$status" "$status"
  printf '    <a class="night-link" href="%s">night detail &rarr;</a>\n' "$(ui_night_url "$i")"
  printf '  </div>\n'
  # one-line note: item count + merge/push outcome or abort reason
  note=""
  case "$status" in
    PUSHED) note="pushed to origin" ;;
    MERGED_LOCAL) note="merged to main (local)" ;;
    GATED_NOT_MERGED) note="gate SHIPPED, no merge evidence" ;;
  esac
  [ -n "${N_ABORT[i]}" ] && note="${N_ABORT[i]}"
  local n_items=0
  [ -n "${N_ITEMS[i]}" ] && n_items="$(printf '%s\n' "${N_ITEMS[i]}" | tr "$UI_RS" '\n' | grep -c . || true)"
  printf '  <div class="night-note">'
  if [ -n "$note" ]; then printf '%s &middot; %d item(s)' "$(printf '%s' "$note" | ui_esc)" "$n_items"
  else printf '%d item(s)' "$n_items"; fi
  printf '</div>\n\n'
  # rows: ledger-driven when this is the date's primary night and the ledger
  # has entries; backfill from REPORT items otherwise (spec §3/G2[1])
  rows="$(ui_night_rows "$i")"
  if [ -n "$rows" ]; then
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      ui_row_fields "$rec"; item="$R_ITEM"; st="$R_ST"; sha="$R_SHA"
      title="$(ui_row_title "$i" "$item")"
      href="$(ui_row_href "$i" "$item")"
      printf '  <div class="item-row">\n    <span class="item-badge ib-%s">%s</span>\n' \
        "$(echo "$st" | tr 'A-Z' 'a-z')" "$st"
      printf '    <a class="item-title" href="%s">%s</a>\n' "$href" "$(printf '%s' "$title" | ui_esc)"
      printf '    <code class="item-sha">%s</code>\n' "$(printf '%s' "${sha:--}" | ui_esc)"
      printf '    <span class="item-name">%s</span>\n' "$(printf '%s' "$item" | ui_esc)"
      printf '  </div>\n'
    done < <(printf '%s' "$rows" | tr "$UI_RS" '\n'; echo)
  fi
  printf '</div>\n\n'
}

# ---- night detail page -----------------------------------------------------

ui_raw_link() { # $1=abs-path $2=label
  printf '    <a href="file://%s">%s</a>\n' "$(printf '%s' "$1" | ui_esc)" "$2"
}

ui_render_night_page() { # $1=idx $2=out-dir
  local i="$1" out="$2" repo date slug ndir rec item st sha title gate
  repo="$(ui_repo_name "${N_REPO[i]}")"; date="${N_DATE[i]}"; slug="$(ui_night_slug "$i")"
  ndir="$(ui_night_dir "$i")"
  local dir="$out/night/$repo"
  mkdir -p "$dir"
  {
    ui_head "night $slug — $repo"
    printf '<a class="back-link" href="../../index.html">&larr; all nights</a>\n\n'
    printf '<h1>%s <span class="night-date">%s</span>' "$(printf '%s' "$repo" | ui_esc)" "$(printf '%s' "$slug" | ui_esc)"
    [ "${N_LEGACY[i]}" = 1 ] && printf ' <span class="legacy-tag">LEGACY</span>'
    printf '</h1>\n'
    printf '<p class="subtitle"><span class="derived-status ds-%s">%s</span>' "${N_STATUS[i]}" "${N_STATUS[i]}"
    [ -n "${N_BRANCH[i]}" ] && printf ' &middot; branch <code>%s</code>' "$(printf '%s' "${N_BRANCH[i]}" | ui_esc)"
    printf '</p>\n\n'
    if [ -n "${N_ABORT[i]}" ]; then
      printf '<div class="card"><h2>Abort reason</h2><p class="llm-details">%s</p></div>\n\n' \
        "$(printf '%s' "${N_ABORT[i]}" | ui_esc)"
    fi
    if [ -n "${N_ITEMS[i]}" ]; then
      printf '<div class="card">\n  <h2>Items</h2>\n'
      while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        ui_row_fields "$rec"; item="$R_ITEM"; st="$R_ST"; sha="$R_SHA"
        title="$(ui_row_title "$i" "$item")"
        printf '  <div class="item-row" id="%s">\n' "$(printf '%s' "$item" | ui_esc)"
        printf '    <span class="item-badge ib-%s">%s</span>\n' "$(echo "$st" | tr 'A-Z' 'a-z')" "$st"
        printf '    <a class="item-title" href="../../item/%s/%s/%s.html">%s</a>\n' \
          "$repo" "$slug" "$item" "$(printf '%s' "$title" | ui_esc)"
        printf '    <code class="item-sha">%s</code>\n' "$(printf '%s' "${sha:--}" | ui_esc)"
        printf '    <span class="item-name">%s</span>\n' "$(printf '%s' "$item" | ui_esc)"
        printf '  </div>\n'
      done < <(printf '%s' "${N_ITEMS[i]}" | tr "$UI_RS" '\n'; echo)
      printf '</div>\n\n'
    fi
    printf '<div class="card">\n  <h2>Raw artifacts</h2>\n  <div class="raw-links">\n'
    [ -f "$ndir/REPORT.md" ] && ui_raw_link "$ndir/REPORT.md" "REPORT.md"
    [ -f "$ndir/driver.log" ] && ui_raw_link "$ndir/driver.log" "driver.log"
    [ -f "$ndir/plan.md" ] && ui_raw_link "$ndir/plan.md" "plan.md"
    [ -f "$ndir/scan.md" ] && ui_raw_link "$ndir/scan.md" "scan.md"
    printf '  </div>\n</div>\n\n'
    ui_foot "night $slug"
  } > "$dir/$slug.html"
}

# ---- item detail page ------------------------------------------------------

ui_gate_excerpt() { # $1=gate-file — escaped, capped at 40 lines (spec §5)
  local f="$1" n
  n="$(wc -l < "$f")"
  if [ "$n" -gt 40 ]; then
    head -40 "$f" | ui_esc
    printf '\n[... truncated at 40 of %s lines ...]' "$n"
  else
    ui_esc < "$f"
  fi
}

ui_render_item_page() { # $1=night-idx $2=item $3=status $4=sha $5=out-dir
  local i="$1" item="$2" st="$3" sha="$4" out="$5"
  local repo date slug ndir title details trail gate n_plan plan_idx=0 rec it
  repo="$(ui_repo_name "${N_REPO[i]}")"; date="${N_DATE[i]}"; slug="$(ui_night_slug "$i")"
  ndir="$(ui_night_dir "$i")"
  title="$(ui_sidecar "$i" "$item" title)"
  details="$(ui_sidecar "$i" "$item" details)"
  local idir="$out/item/$repo/$slug"
  mkdir -p "$idir"
  # status trail (spec §5): recoverable from verdict/REPORT stages
  case "$st" in
    SHIP) trail="PLANNED &rarr; DONE &rarr; SHIP" ;;
    PARK) trail="PLANNED &rarr; DONE &rarr; PARK" ;;
    *)   trail="PLANNED" ;;
  esac
  # item position in plan.md order -> iN session log names
  if [ -f "$ndir/plan.md" ]; then
    n_plan=0
    while IFS= read -r it; do
      n_plan=$((n_plan+1))
      [ "$it" = "$item" ] && { plan_idx=$n_plan; break; }
    done < <(sed -n 's/^## Item: *//p' "$ndir/plan.md")
  fi
  {
    ui_head "${title:-$(ui_humanize "$item")}"
    printf '<a class="back-link" href="../../../night/%s/%s.html">&larr; night %s %s</a>\n\n' \
      "$repo" "$slug" "$date" "$repo"
    if [ -n "$title" ]; then
      printf '<h1>%s <span class="llm-badge">LLM title</span></h1>\n' "$(printf '%s' "$title" | ui_esc)"
    else
      printf '<h1>%s <span class="no-summary">no summary</span></h1>\n' "$(ui_humanize "$item" | ui_esc)"
    fi
    printf '<p class="subtitle"><code>%s</code> &middot; %s &middot; %s</p>\n\n' \
      "$(printf '%s' "$item" | ui_esc)" "$(printf '%s' "$repo" | ui_esc)" "$(printf '%s' "$slug" | ui_esc)"
    if [ -n "$details" ]; then
      printf '<div class="card">\n  <h2>Details <span class="llm-badge">LLM generated</span></h2>\n'
      printf '  <p class="llm-details">%s</p>\n</div>\n\n' "$(printf '%s' "$details" | ui_esc)"
    fi
    printf '<div class="card">\n  <h2>Metadata</h2>\n  <div class="meta-grid">\n'
    printf '    <span class="meta-label">Repo</span><span>%s</span>\n' "$(printf '%s' "$repo" | ui_esc)"
    printf '    <span class="meta-label">Night</span><span><code>%s</code></span>\n' "$(printf '%s' "$slug" | ui_esc)"
    printf '    <span class="meta-label">Branch</span><span><code>%s</code></span>\n' "$(printf '%s' "${N_BRANCH[i]:--}" | ui_esc)"
    printf '    <span class="meta-label">SHA range</span><span><code>%s</code></span>\n' "$(printf '%s' "${sha:--}" | ui_esc)"
    printf '    <span class="meta-label">Verdict</span><span><span class="item-badge ib-%s">%s</span></span>\n' \
      "$(echo "$st" | tr 'A-Z' 'a-z')" "$st"
    printf '    <span class="meta-label">Trail</span><span class="mono">%s</span>\n' "$trail"
    printf '  </div>\n</div>\n\n'
    gate="$ndir/gate-$item.md"
    if [ -f "$gate" ]; then
      printf '<div class="card">\n  <h2>Gate excerpt</h2>\n'
      printf '  <div class="gate-label">PARK criteria + verdict + findings</div>\n'
      printf '  <div class="gate-excerpt">%s</div>\n' "$(ui_gate_excerpt "$gate")"
      printf '</div>\n\n'
    fi
    printf '<div class="card">\n  <h2>Raw artifacts</h2>\n  <div class="raw-links">\n'
    [ -f "$gate" ] && ui_raw_link "$gate" "gate report"
    if [ "$plan_idx" -gt 0 ]; then
      [ -f "$ndir/i$plan_idx-implement.log" ] && ui_raw_link "$ndir/i$plan_idx-implement.log" "implement session log"
      [ -f "$ndir/i$plan_idx-gate.log" ] && ui_raw_link "$ndir/i$plan_idx-gate.log" "gate session log"
      [ -f "$ndir/green-i$plan_idx-impl.log" ] && ui_raw_link "$ndir/green-i$plan_idx-impl.log" "green impl log"
      [ -f "$ndir/green-i$plan_idx-gate.log" ] && ui_raw_link "$ndir/green-i$plan_idx-gate.log" "green gate log"
    fi
    printf '  </div>\n</div>\n\n'
    ui_foot "item $item"
  } > "$idir/$item.html"
}

# ---- entry points ----------------------------------------------------------

ui_render_html() { # $1=records-file $2=out-dir
  local out="$2" i rec item st sha
  ui_load_records "$1"
  ui_order_nights
  ui_load_ledger
  ui_primary_night
  mkdir -p "$out/night" "$out/item"
  ui_render_index "$out"
  for ((i=0; i<NN; i++)); do
    ui_render_night_page "$i" "$out"
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      ui_row_fields "$rec"; item="$R_ITEM"; st="$R_ST"; sha="$R_SHA"
      ui_render_item_page "$i" "$item" "$st" "$sha" "$out"
    done < <(printf '%s' "${N_ITEMS[i]:-}" | tr "$UI_RS" '\n'; echo)
  done
}

ui_render_text() { # $1=records-file — terminal ledger to stdout (P4 variant B)
  local i rec item st sha title note rows
  ui_load_records "$1"
  ui_order_nights
  ui_load_ledger
  ui_primary_night
  for i in $UI_ORDER; do
    note=""
    case "${N_STATUS[i]}" in
      PUSHED) note="pushed to origin" ;;
      MERGED_LOCAL) note="merged to main (local)" ;;
    esac
    [ -n "${N_ABORT[i]}" ] && note="${N_ABORT[i]}"
    printf '== %s %s %s%s%s ==%s\n' "${N_DATE[i]}" "$(ui_repo_name "${N_REPO[i]}")" "${N_STATUS[i]}" \
      "$( [ "${N_LEGACY[i]}" = 1 ] && printf ' LEGACY')" "$( [ "${N_STALE[i]}" = 1 ] && printf ' STALE')" \
      "$( [ -n "$note" ] && printf '  (%s)' "$note")"
    rows="$(ui_night_rows "$i")"
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      ui_row_fields "$rec"; item="$R_ITEM"; st="$R_ST"; sha="$R_SHA"
      title="$(ui_row_title "$i" "$item")"
      printf '  %-4s %-36s %-18s %s\n' "$st" "$item" "${sha:--}" "$title"
    done < <(printf '%s' "${rows:-}" | tr "$UI_RS" '\n'; echo)
  done
}
