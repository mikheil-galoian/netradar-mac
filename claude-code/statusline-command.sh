#!/bin/sh
input=$(cat)

used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
dir=$(basename "$cwd")

# colors
G="\033[32m"; O="\033[33m"; R="\033[31m"; C="\033[36m"; DIM="\033[90m"; B="\033[1m"; X="\033[0m"

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
    radar=" ${DIM}\302\267${X} ${C}${B}RADAR${X} ${C}${sw}${X} ${G}LAN ${lan}${X}"
    if [ "${neu:-0}" -gt 0 ] 2>/dev/null; then radar="${radar} ${DIM}\302\267${X} ${R}${B}NEW ${neu}${X}"; fi
    if [ "${inb:-0}" -gt 0 ] 2>/dev/null; then radar="${radar} ${DIM}\302\267${X} ${O}IN ${inb}${X}"; fi
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
  if [ "$used_int" -ge 80 ]; then zone="$R"; elif [ "$used_int" -ge 50 ]; then zone="$O"; else zone="$G"; fi

  bar=""
  i=0
  while [ "$i" -lt "$segments" ]; do
    if [ "$i" -eq "$fill" ]; then
      bar="${bar}${zone}\342\227\217${X}"          # ● cursor
    elif [ "$i" -eq "$orange_at" ]; then
      bar="${bar}${O}\342\227\246${X}"              # ◦ orange threshold
    elif [ "$i" -eq "$red_at" ]; then
      bar="${bar}${R}\342\227\246${X}"              # ◦ red threshold
    else
      bar="${bar}${DIM}\342\227\246${X}"            # ◦ dim
    fi
    i=$((i + 1))
  done

  printf "${B}CONTEXT:${X} %b ${zone}%s%%${X}%b ${DIM}\302\267${X} %s ${DIM}\302\267${X} %s" "$bar" "$used_int" "$radar" "$model" "$dir"
else
  printf "%s \302\267 %s%b" "$model" "$dir" "$radar"
fi
