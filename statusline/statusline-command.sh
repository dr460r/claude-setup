#!/usr/bin/env bash
# Claude Code statusLine script
#
# Reads the JSON context Claude Code pipes on stdin and prints two rows:
#   row 1:  📁 dir 📦 repo 🌿 branch
#   row 2:  Opus 5 High (500k) | 🧠 95k/250k bar | ⏳ 30% bar ↻2.0h | 📅 16% bar ↻4.6d ∅3.1d -18.3%/d +12.2%/d
#
# Emoji are used only as labels; values use plain glyphs (↻ reset, ∅ dry in,
# - used per day, + left per day).
#
# Colours are the 16 ANSI slots (30-37 / 90-97) rather than fixed 256-colour
# indices, so the terminal's own palette decides the actual shades and the
# line follows whatever colourscheme is in use.

input=$(cat)

# ---------------------------------------------------------------- config ----

CTX_SEGMENTS=25      # context bar width; the bar spans half the window, so
                     # one segment = 2% of the window -- 20k on a 1m window
LIMIT_SEGMENTS=10    # width of the S and W rate-limit bars

# Context bar is half-scale: it spans 0..50% of the window, then wraps.
CTX_WARN_PCT=30      # window % where the warning band opens
CTX_HOT_PCT=40       # window % where the danger band opens
CTX_PHASE_PCT=50     # window % where the bar wraps into the alarm colour

# Rate-limit bar thresholds (percent of the limit consumed), per bar.
S_WARN_PCT=65        # session bar goes yellow only once past this
S_HOT_PCT=80
# The weekly bar has two zones: safe, then danger once this much is consumed.
W_HOT_PCT=95
# The pace metrics (-used/d, dry in) and the grey unused track follow the
# projected usage at reset: projected = used% / fraction-of-week-elapsed.
W_PROJ_WARN=85       # projected % at reset below which quota may go unused (grey)
W_PROJ_HOT=100       # projected % at reset where it runs dry early (danger)
W_MIN_ELAPSED_PCT=5  # % of the week before the projection is trusted

# Bar glyphs. A cell is full, partial, or empty:
#   full     the cell's whole share of the bar is used
#   partial  at least half of it is used -- less than half counts as empty,
#            so a cell never claims more than it has earned
#   empty    the track
# Filled cells in the safe zone (and in S/W bars below their warn threshold)
# use the lighter BAR_FILL_SAFE, so the solid block is reserved for fill that
# has reached the warning band or past it.
BAR_FILL='█'
BAR_FILL_SAFE='▓'
BAR_PART='▒'
BAR_TRACK='⣿'

# 16-colour ANSI. Every code carries an explicit intensity (22 = normal) so a
# dim slot never bleeds into the colour that follows it.
#
# Bars are coloured by zone: 0 = safe, 1 = warn, 2 = danger. On the context bar
# every cell, empty or filled, takes its zone colour, so the bands are visible
# ahead of the fill. On S and W only filled cells change colour with the zone;
# every empty cell is the same C_SAFE track colour (the sparse braille glyph
# reads as faded on its own). The exception is the W bar, whose empty cells are C_UNUSED grey while the pace projects unused quota.
RESET=$'\033[0m'
DIM=$'\033[2m'
C_SAFE=$'\033[22;32m'         # green  - zone 0 (also the used-token count)
C_WARN=$'\033[22;33m'         # yellow - zone 1
C_DANGER=$'\033[22;31m'       # red    - zone 2
C_UNUSED=$'\033[22;90m'       # grey   - empty cells of the W bar
C_PATH=$'\033[22;34m'
C_REPO=$'\033[22;36m'
C_MODEL=$'\033[22;35m'

# ------------------------------------------------------------- read json ----

# One jq call for every field, tab separated. `// empty` would collapse fields
# and desync the read, so missing values become a literal "-" placeholder.
fields=$(printf '%s' "$input" | jq -r '
  def f: if . == null then "-" else tostring end;
  [ ((.workspace.current_dir // .cwd)            | f),
    (.model.display_name                         | f),
    (.effort.level                               | f),
    (.thinking.enabled                           | f),
    (.context_window.total_input_tokens          | f),
    (.context_window.context_window_size         | f),
    (.workspace.repo.name                        | f),
    (.rate_limits.five_hour.used_percentage      | f),
    (.rate_limits.seven_day.used_percentage      | f),
    (.rate_limits.five_hour.resets_at            | f),
    (.rate_limits.seven_day.resets_at            | f)
  ] | @tsv' 2>/dev/null)

IFS=$'\t' read -r cwd model effort thinking ctx_used ctx_size repo five week five_reset week_reset \
  <<< "$fields"

# Normalise the placeholder back to empty.
for v in cwd model effort thinking ctx_used ctx_size repo five week five_reset week_reset; do
  [ "${!v}" = "-" ] && printf -v "$v" '%s' ''
done

is_num() { [ -n "$1" ] && [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }

# ---------------------------------------------------------------- helpers ---

# Format a token count as e.g. "40k" or "1m". Always truncates toward zero --
# 75.1k and 75.9k both render as "75k" -- so the number never reads as more
# context than is actually in use.
humanize_tokens() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) printf "%dm", int(n / 1000000)
    else if (n >= 1000) printf "%dk", int(n / 1000)
    else printf "%d", int(n)
  }'
}

# draw_bar <fill 0..1> <segments> <mode> [zone] [grey track 0|1]
#   mode 0 = flat bar, every filled cell in zone $4 (the S and W bars)
#   mode 1 = context bar, phase 1: zone 0, then 1 at the warn mark, 2 at the hot mark
#   mode 2 = context bar, phase 2: the whole bar is zone 2
#   empty cells: context bar, their zone colour; S/W, C_SAFE (or C_UNUSED grey when $5 is 1)
draw_bar() {
  local fill=$1 segs=$2 mode=$3 zone=${4:-0} grey=${5:-0}
  awk -v fill="$fill" -v segs="$segs" -v mode="$mode" -v flat="$zone" \
      -v grey="$grey" -v unused="$C_UNUSED" \
      -v warn_pct="$CTX_WARN_PCT" -v hot_pct="$CTX_HOT_PCT" -v phase_pct="$CTX_PHASE_PCT" \
      -v c0="$C_SAFE" -v c1="$C_WARN" -v c2="$C_DANGER" -v reset="$RESET" \
      -v gfull="$BAR_FILL" -v gsafe="$BAR_FILL_SAFE" \
      -v gpart="$BAR_PART" -v gt="$BAR_TRACK" '
  function zone_of(idx) {
    if (mode == 0) return flat
    if (mode == 2) return 2
    return (idx < warn_cells) ? 0 : ((idx < hot_cells) ? 1 : 2)
  }
  function color_of(z) { return (z == 0) ? c0 : ((z == 1) ? c1 : c2) }
  BEGIN {
    if (fill < 0) fill = 0
    if (fill > 1) fill = 1
    # The bar spans 0..phase_pct of the window, so each band opens
    # pct/phase_pct of the way along it.
    warn_cells = int(segs * warn_pct / phase_pct + 1e-9)
    hot_cells = int(segs * hot_pct / phase_pct + 1e-9)
    exact = fill * segs
    out = ""; cur = ""
    for (i = 0; i < segs; i++) {
      cell = exact - i              # how much of this cell is used, 0..1
      z = zone_of(i)
      if (cell >= 1 - 1e-9)        { c = color_of(z); g = (z == 0) ? gsafe : gfull }
      else if (cell >= 0.5 - 1e-9) { c = color_of(z); g = gpart }
      else                         { c = grey ? unused : ((mode == 0) ? c0 : color_of(z)); g = gt }
      if (c != cur) { out = out c; cur = c }
      out = out g
    }
    printf "%s%s", out, reset
  }'
}

# Rate-limit zone (0/1/2) from the percentage consumed.
limit_zone() {
  awk -v p="$1" -v warn="$2" -v hot="$3" \
      'BEGIN { printf "%d", (p >= hot) ? 2 : ((p >= warn) ? 1 : 0) }'
}

# Zone -> text colour.
zone_color() {
  case "$1" in 2) printf '%s' "$C_DANGER" ;; 1) printf '%s' "$C_WARN" ;; *) printf '%s' "$C_SAFE" ;; esac
}

# ----------------------------------------------------------------- items ---

# Epoch seconds from either an epoch number or an ISO-8601 string.
to_epoch() {
  if is_num "$1"; then printf '%.0f' "$1"; else date -d "$1" +%s 2>/dev/null; fi
}

# Seconds until a reset timestamp (empty if unknown), clamped at 0.
secs_until() {
  local t; t=$(to_epoch "$1"); [ -z "$t" ] && return 0
  awk -v t="$t" -v n="$(date +%s)" 'BEGIN { s = t - n; printf "%d", (s < 0 ? 0 : s) }'
}

fmt_hours() {   # seconds -> "2.5h" / "40m"
  awk -v s="$1" 'BEGIN { if (s < 3600) printf "%dm", int(s / 60 + 0.5); else printf "%.1fh", s / 3600 }'
}

# dir + repo
id_parts=()
[ -n "$cwd" ] && id_parts+=("${C_PATH}📁 $(basename -- "$cwd")${RESET}")
if [ -z "$repo" ] && [ -n "$cwd" ]; then
  toplevel=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
  [ -n "$toplevel" ] && repo=$(basename -- "$toplevel")
fi
branch=""
if [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
fi
[ -n "$repo" ] && id_parts+=("${C_REPO}📦 ${repo}${RESET}")
[ -n "$branch" ] && id_parts+=("${C_REPO}🌿 ${branch}${RESET}")

# model + context
mc_parts=()
if [ -n "$model" ]; then
  label="${model%% (*}"
  reasoning=""
  if [ -n "$effort" ]; then
    case "$effort" in
      xhigh) reasoning="XHigh" ;;
      *)     reasoning="${effort^}" ;;
    esac
  elif [ "$thinking" = "true" ]; then
    reasoning="Thinking"
  fi
  [ -n "$reasoning" ] && label="${label} ${reasoning}"
  if is_num "$ctx_size" && [ "$ctx_size" != "0" ]; then
    label="${label} ($(humanize_tokens "$ctx_size"))"
  fi
  mc_parts+=("${C_MODEL}${label}${RESET}")
fi

if is_num "$ctx_used" && is_num "$ctx_size" && [ "$ctx_size" != "0" ]; then
  read -r ctx_fill ctx_mode ctx_half < <(awk \
    -v used="$ctx_used" -v size="$ctx_size" -v phase_pct="$CTX_PHASE_PCT" '
    BEGIN {
      half = size * phase_pct / 100
      if (half <= 0) { print 0, 1, 0; exit }
      if (used > half) {
        f = (used - half) / half
        if (f > 1) f = 1
        printf "%.6f 2 %d\n", f, half
      } else {
        printf "%.6f 1 %d\n", used / half, half
      }
    }')
  ctx_bar=$(draw_bar "$ctx_fill" "$CTX_SEGMENTS" "$ctx_mode")
  if [ "$ctx_mode" = "2" ]; then
    ctx_denom=$(humanize_tokens "$ctx_size")
  else
    ctx_denom=$(humanize_tokens "$ctx_half")
  fi
  mc_parts+=("${DIM}🧠${RESET} ${C_SAFE}$(humanize_tokens "$ctx_used")${RESET}${DIM}/${ctx_denom}${RESET} ${ctx_bar}")
fi

# limit_item <label> <pct> <warn> <hot> [extra...]  -- prints the item, extras
# are appended after the bar, separated by spaces.
limit_item() {
  local label=$1 pct=$2 warn=$3 hot=$4; shift 4
  is_num "$pct" || return 0
  local zone color fill bar out extra
  zone=$(limit_zone "$pct" "$warn" "$hot")
  color=$(zone_color "$zone")
  fill=$(awk -v p="$pct" 'BEGIN { f = p / 100; if (f > 1) f = 1; printf "%.6f", f }')
  bar=$(draw_bar "$fill" "$LIMIT_SEGMENTS" 0 "$zone")
  out="${DIM}${label}${RESET} ${color}$(printf '%.0f' "$pct")%${RESET} ${bar}"
  for extra in "$@"; do out="${out} ${DIM}${extra}${RESET}"; done
  printf '%s' "$out"
}

# S: session bar + time to reset
s_extra=()
s_secs=$(secs_until "$five_reset")
[ -n "$s_secs" ] && s_extra+=("↻$(fmt_hours "$s_secs")")
s_item=$(limit_item $'⏳\xef\xb8\x8f' "$five" "$S_WARN_PCT" "$S_HOT_PCT" "${s_extra[@]}")

# W: weekly bar, coloured by projected usage at reset. Empty cells are grey only while the pace leaves quota unused (level 0);
# used/left per day, time to reset, and (only when it will run dry) time to empty.
w_item=""
w_secs=$(secs_until "$week_reset")
if is_num "$week" && [ -n "$w_secs" ]; then
  read -r w_elapsed used_pd left_pd days_left dry_days w_level < <(awk \
    -v p="$week" -v s="$w_secs" -v warn="$W_PROJ_WARN" -v hot="$W_PROJ_HOT" \
    -v minel="$W_MIN_ELAPSED_PCT" 'BEGIN {
      wk = 7 * 86400
      e = (wk - s) / wk; if (e < 0) e = 0; if (e > 1) e = 1
      el = e * 7; if (el < 0.05) el = 0.05
      dl = s / 86400; if (dl < 0.05) dl = 0.05
      used = p / el; left = (100 - p) / dl
      proj = p / (e > 0.0001 ? e : 0.0001)
      lvl = 0
      if (p >= 100) lvl = 2
      else if (e * 100 >= minel) lvl = (proj >= hot) ? 2 : ((proj >= warn) ? 1 : 0)
      dry = (lvl == 2 && p < 100 && used > 0) ? (100 - p) / used : 0
      printf "%.6f %.1f %.1f %.1f %.1f %d\n", e, used, left, s / 86400, dry, lvl
    }')
  w_zone=$(limit_zone "$week" "$W_HOT_PCT" "$W_HOT_PCT")   # bar + percentage
  w_color=$(zone_color "$w_zone")
  w_pace=$(zone_color "$w_level")                          # level 2 -> danger, else safe
  [ "$w_level" = "1" ] && w_pace=$C_SAFE
  # Grey empty cells mean quota that may go unused; once the pace projects
  # to reach the warn level or beyond, the remainder will be used, so no grey.
  w_unused=0; [ "$w_level" = "0" ] && w_unused=1
  w_fill=$(awk -v p="$week" 'BEGIN { f = p / 100; if (f > 1) f = 1; printf "%.6f", f }')
  w_bar=$(draw_bar "$w_fill" "$LIMIT_SEGMENTS" 0 "$w_zone" "$w_unused")
  w_item="${DIM}📅${RESET} ${w_color}$(printf '%.0f' "$week")%${RESET} ${w_bar}"
  w_item="${w_item} ${DIM}↻${days_left}d${RESET}"
  [ "$w_level" = "2" ] && [ "$dry_days" != "0.0" ] && w_item="${w_item} ${C_DANGER}∅${dry_days}d${RESET}"
  w_item="${w_item} ${w_pace}-${used_pd}%/d${RESET} ${DIM}+${left_pd}%/d${RESET}"
fi

# ------------------------------------------------------------------- emit ---

SEP=" ${DIM}|${RESET} "
join() {   # join <sep> items...  (skips empty items)
  local sep=$1; shift
  local out="" item
  for item in "$@"; do
    [ -z "$item" ] && continue
    [ -z "$out" ] && out="$item" || out="${out}${sep}${item}"
  done
  printf '%s' "$out"
}

id_str=$(join " " "${id_parts[@]}")
mc_str=$(join "$SEP" "${mc_parts[@]}")
left_str=$(join "$SEP" "$id_str" "$mc_str")
right_str=$(join "$SEP" "$s_item" "$w_item")

# Terminal width: statusline has no tty on stdout, so ask the controlling
# terminal directly. Fall back to $COLUMNS, then a wide default.
cols=$( { stty size </dev/tty; } 2>/dev/null | awk '{print $2}')
is_num "$cols" || cols=${COLUMNS:-}
is_num "$cols" || cols=200
MARGIN=6   # Claude Code pads the status area a little

visible_len() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g' | awk '{ print length($0) }'; }

full=$(join "$SEP" "$left_str" "$right_str")
if [ -z "$right_str" ] || [ -z "$left_str" ] || [ "$(visible_len "$full")" -le $(( cols - MARGIN )) ]; then
  printf '%s\n' "$full"
else
  printf '%s\n%s\n' "$left_str" "$right_str"
fi

exit 0
