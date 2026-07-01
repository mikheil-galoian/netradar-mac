#!/bin/sh
# Host-level firewall через pf. Ручной и авто-режим.
#   net-guard.sh setup        — разово: беспарольный pfctl (sudoers) + включить авто-блок [нужен пароль]
#   net-guard.sh unsetup      — убрать права и выключить авто-блок [нужен пароль]
#   net-guard.sh auto on|off  — включить/выключить авто-блок входящих
#   net-guard.sh block <ip>   — заблокировать IP
#   net-guard.sh allow <ip>   — снять блок + добавить в allowlist (не блокировать впредь)
#   net-guard.sh list         — показать заблокированные
# Изолирует ТВОЙ Mac от узла (drop к/от него), не выкидывает устройство из всей сети.
# Правила pf живут до перезагрузки.
set -e
DIR="$HOME/.claude/statusbar"
ANCHOR="com.apple/netradar"     # грузится под com.apple/* — этот путь macOS уже вычисляет
TABLE="netradar_block"
CONF="$DIR/netradar.pf.conf"
FLAG="$DIR/autoblock.on"
ALLOW="$DIR/net-allow.json"
BLOCKED="$DIR/net-blocked.json"
PF="$(command -v pfctl 2>/dev/null || echo /sbin/pfctl)"

# интерактивно (есть tty) — обычный sudo; из демона (нет tty) — sudo -n
if [ -t 0 ]; then SUDO="sudo"; else SUDO="sudo -n"; fi

ensure_conf() {
  cat > "$CONF" <<EOF
table <$TABLE> persist
block drop quick from <$TABLE> to any
block drop quick from any to <$TABLE>
EOF
}
load() {
  ensure_conf
  $SUDO "$PF" -a "$ANCHOR" -f "$CONF" >/dev/null 2>&1 || true
  $SUDO "$PF" -E >/dev/null 2>&1 || true
}
jq_add() { [ -f "$1" ] || echo "[]" > "$1"; jq --arg v "$2" '. + [$v] | unique' "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
jq_del() { [ -f "$1" ] && jq --arg v "$2" 'map(select(. != $v))' "$1" > "$1.tmp" && mv "$1.tmp" "$1" || true; }

case "$1" in
  setup)
    U="$(whoami)"
    TMP="$(mktemp)"
    printf '%s ALL=(root) NOPASSWD: %s\n' "$U" "$PF" > "$TMP"
    echo "Будет установлено в /etc/sudoers.d/netradar (беспарольный pfctl для $U):"
    sed 's/^/  /' "$TMP"
    if ! sudo visudo -c -f "$TMP" >/dev/null 2>&1; then echo "sudoers невалиден, отмена"; rm -f "$TMP"; exit 1; fi
    sudo install -m 0440 -o root -g wheel "$TMP" /etc/sudoers.d/netradar
    rm -f "$TMP"
    touch "$FLAG"
    echo "готово. Авто-блок ВКЛ. Выключить: net-guard.sh auto off | Убрать права: net-guard.sh unsetup"
    ;;
  unsetup)
    sudo rm -f /etc/sudoers.d/netradar
    rm -f "$FLAG"
    echo "права убраны, авто-блок ВЫКЛ"
    ;;
  auto)
    case "$2" in
      on) touch "$FLAG"; echo "авто-блок ВКЛ" ;;
      off) rm -f "$FLAG"; echo "авто-блок ВЫКЛ" ;;
      *) echo "usage: net-guard.sh auto {on|off}"; exit 1 ;;
    esac
    ;;
  block)
    [ -z "$2" ] && { echo "usage: net-guard.sh block <ip>"; exit 1; }
    load
    $SUDO "$PF" -a "$ANCHOR" -t "$TABLE" -T add "$2" >/dev/null 2>&1
    jq_del "$ALLOW" "$2"
    echo "заблокирован $2 (host-level)"
    ;;
  allow)
    [ -z "$2" ] && { echo "usage: net-guard.sh allow <ip>"; exit 1; }
    $SUDO "$PF" -a "$ANCHOR" -t "$TABLE" -T delete "$2" >/dev/null 2>&1 || true
    jq_del "$BLOCKED" "$2"
    jq_add "$ALLOW" "$2"
    echo "разблокирован $2 (добавлен в allowlist)"
    ;;
  list)
    $SUDO "$PF" -a "$ANCHOR" -t "$TABLE" -T show 2>/dev/null || echo "(пусто или анкор ещё не загружен)"
    ;;
  *)
    echo "usage: net-guard.sh {setup|unsetup|auto on|off|block <ip>|allow <ip>|list}"; exit 1 ;;
esac
