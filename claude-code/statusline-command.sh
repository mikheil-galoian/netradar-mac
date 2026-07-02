#!/bin/sh
input=$(cat)

used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
dir=$(basename "$cwd")

# --- colors (themeable via ~/.claude/statusbar/radar-theme.json) ---
DIM="\033[90m"; B="\033[1m"; X="\033[0m"
theme="$HOME/.claude/statusbar/radar-theme.json"
tget() { v=""; [ -f "$theme" ] && v=$(jq -r --arg k "$1" '.[$k] // empty' "$theme" 2>/dev/null); [ -z "$v" ] && v="$2"; printf '%s' "$v"; }
ansi() {
  case "$1" in
    black) printf '%s' '\033[30m';; red) printf '%s' '\033[31m';; green) printf '%s' '\033[32m';;
    yellow) printf '%s' '\033[33m';; blue) printf '%s' '\033[34m';; magenta) printf '%s' '\033[35m';;
    cyan) printf '%s' '\033[36m';; white) printf '%s' '\033[37m';; gray|grey) printf '%s' '\033[90m';;
    bred) printf '%s' '\033[91m';; bgreen) printf '%s' '\033[92m';; byellow) printf '%s' '\033[93m';;
    bblue) printf '%s' '\033[94m';; bmagenta) printf '%s' '\033[95m';; bcyan) printf '%s' '\033[96m';;
    bwhite) printf '%s' '\033[97m';;
    ''|default) printf '%s' '\033[0m';;
    *[!0-9]*) printf '%s' '\033[0m';;
    *) printf '%s' "\033[38;5;$1m";;
  esac
}
C_LABEL=$(ansi "$(tget radar_label cyan)")
C_SWEEP=$(ansi "$(tget sweep cyan)")
C_LAN=$(ansi "$(tget lan green)")
C_NEW=$(ansi "$(tget new red)")
C_IN=$(ansi "$(tget inbound yellow)")
CTX_LOW=$(ansi "$(tget context_low green)")
CTX_MID=$(ansi "$(tget context_mid yellow)")
CTX_HIGH=$(ansi "$(tget context_high red)")
C_CTXLABEL=$(ansi "$(tget context_label cyan)")
C_MODEL=$(ansi "$(tget model 111)")
C_DIR=$(ansi "$(tget dir 141)")
# глиф ячейки шкалы: берётся из radar-theme.json "context_glyph" (вставь свой символ),
# по умолчанию ○ (рисуется в любом шрифте)
CTXG=$(tget context_glyph "")
[ -z "$CTXG" ] && CTXG=$(printf '\342\227\213')

# --- network radar segment (from net.json, written by netradar.js daemon) ---
radar=""
netf="$HOME/.claude/statusbar/net.json"
if [ -f "$netf" ]; then
  lan=$(jq -r '.lan // empty' "$netf" 2>/dev/null)
  neu=$(jq -r '.new // 0' "$netf" 2>/dev/null)
  inb=$(jq -r '.inbound // 0' "$netf" 2>/dev/null)
  if [ -n "$lan" ]; then
    sec=$(date +%s 2>/dev/null || echo 0)
    case $((sec % 4)) in
      0) sw="\342\227\220";; 1) sw="\342\227\223";; 2) sw="\342\227\221";; *) sw="\342\227\222";;
    esac
    radar=" ${DIM}\302\267${X} ${C_LABEL}${B}RADAR${X} ${C_SWEEP}${sw}${X} ${C_LAN}LAN ${lan}${X}"
    if [ "${neu:-0}" -gt 0 ] 2>/dev/null; then radar="${radar} ${DIM}\302\267${X} ${C_NEW}${B}NEW ${neu}${X}"; fi
    if [ "${inb:-0}" -gt 0 ] 2>/dev/null; then radar="${radar} ${DIM}\302\267${X} ${C_IN}IN ${inb}${X}"; fi
  fi
fi

if [ -n "$used" ]; then
  used_int=$(printf "%.0f" "$used")
  remaining_int=$(printf "%.0f" "$remaining")

  segments=20
  fill=$(printf "%.0f" "$(echo "$used * $segments / 100" | bc -l 2>/dev/null || echo 0)")
  [ "$fill" -ge "$segments" ] && fill=$((segments - 1))
  orange_at=$((segments * 50 / 100))   # 50% threshold marker
  red_at=$((segments * 80 / 100))      # 80% threshold marker

  # zone color for the fill cursor + percent
  if [ "$used_int" -ge 80 ]; then zone="$CTX_HIGH"; elif [ "$used_int" -ge 50 ]; then zone="$CTX_MID"; else zone="$CTX_LOW"; fi

  bar=""
  i=0
  while [ "$i" -lt "$segments" ]; do
    if [ "$i" -eq "$fill" ]; then
      bar="${bar}${zone}${CTXG}${X}"          # ● cursor
    elif [ "$i" -eq "$orange_at" ]; then
      bar="${bar}${CTX_MID}${CTXG}${X}"        # ◦ mid threshold
    elif [ "$i" -eq "$red_at" ]; then
      bar="${bar}${CTX_HIGH}${CTXG}${X}"       # ◦ high threshold
    else
      bar="${bar}${DIM}${CTXG}${X}"            # ◦ dim
    fi
    i=$((i + 1))
  done

  printf "${C_CTXLABEL}${B}CONTEXT:${X} %b ${zone}%s%%${X}%b ${DIM}\302\267${X} ${zone}%s${X} ${DIM}\302\267${X} ${C_DIR}%s${X}" "$bar" "$used_int" "$radar" "$model" "$dir"
else
  printf "${C_MODEL}%s${X} \302\267 ${C_DIR}%s${X}%b" "$model" "$dir" "$radar"
fi
