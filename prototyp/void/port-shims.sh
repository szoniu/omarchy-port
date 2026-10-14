#!/usr/bin/env bash
# Prototyp portu Omarchy na Void — RUNDA 2: pierwsze shimy warstwy zgodności.
# Zasada: shim TYLKO gdy oryginału nie ma (na Gentoo z systemd żaden z nich nie powstaje).
set -euo pipefail
D=/usr/local/bin

shim() { # shim <nazwa> — treść ze stdin; pomija, gdy prawdziwe polecenie istnieje
  local name=$1 real
  real=$(PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v "$name" || true)
  if [ -n "$real" ]; then echo "pomijam $name — jest $real"; cat >/dev/null; return; fi
  cat >"$D/$name"; chmod 755 "$D/$name"; echo "shim: $D/$name"
}

shim systemd-cat <<'EOF'
#!/bin/sh
# omarchy-port: systemd-cat bez journala — wyjście do ~/.local/state/omarchy-port/<tag>.log.
# exec, nie fork: omarchy-launch-shell liczy, że PID to sam Quickshell.
tag=systemd-cat
while [ $# -gt 0 ]; do
  case "$1" in
    -t) tag=$2; shift 2 ;;
    --identifier=*) tag=${1#*=}; shift ;;
    -p|--priority|--stderr-priority) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-port"; mkdir -p "$dir"
[ $# -eq 0 ] && exec cat >>"$dir/$tag.log"
exec "$@" >>"$dir/$tag.log" 2>&1
EOF

shim uwsm-app <<'EOF'
#!/bin/sh
# omarchy-port: uwsm-app bez uwsm/systemd — uruchamia polecenie wprost.
# Formy w Omarchy: `uwsm-app -- cmd`, `uwsm-app -s b -- cmd`, `uwsm-app -t service -- cmd`.
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -s|-t|-a|-u|-d|-S) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { echo "uwsm-app (omarchy-port): brak polecenia" >&2; exit 2; }
case "$1" in
  *.desktop|*.desktop:*) exec gtk-launch "${1%%:*}" ;;
esac
exec "$@"
EOF

shim xdg-terminal-exec <<'EOF'
#!/bin/sh
# omarchy-port: minimalny xdg-terminal-exec — pierwszy terminal z listy preferencji.
# Opcje --app-id=/--title=/--dir= przekazywane tam, gdzie terminal je zna.
app_id= title= dir=
while [ $# -gt 0 ]; do
  case "$1" in
    --app-id=*) app_id=${1#*=}; shift ;;
    --title=*) title=${1#*=}; shift ;;
    --dir=*) dir=${1#*=}; shift ;;
    -e) shift; break ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ -n "$dir" ] && cd "$dir"
for list in "${XDG_CONFIG_HOME:-$HOME/.config}/hyprland-xdg-terminals.list" \
            "${XDG_CONFIG_HOME:-$HOME/.config}/xdg-terminals.list" \
            /usr/share/xdg-terminal-exec/hyprland-xdg-terminals.list; do
  [ -r "$list" ] || continue
  for entry in $(grep -v '^#' "$list"); do
    case "${entry%.desktop}" in
      foot) command -v foot >/dev/null || continue
            exec foot ${app_id:+--app-id="$app_id"} ${title:+--title="$title"} "$@" ;;
      Alacritty|alacritty) command -v alacritty >/dev/null || continue
            exec alacritty ${app_id:+--class="$app_id"} ${title:+--title="$title"} ${1:+-e} "$@" ;;
      kitty) command -v kitty >/dev/null || continue
            exec kitty ${app_id:+--class="$app_id"} ${title:+--title="$title"} "$@" ;;
      com.mitchellh.ghostty) command -v ghostty >/dev/null || continue
            exec ghostty ${app_id:+--class="$app_id"} ${title:+--title="$title"} ${1:+-e} "$@" ;;
    esac
  done
done
echo "xdg-terminal-exec (omarchy-port): brak znanego terminala z listy" >&2
exit 1
EOF

xbps-install -y libxkbcommon-tools libatomic >/dev/null && echo "pakiety: libxkbcommon-tools libatomic"
echo SHIMS-DONE
