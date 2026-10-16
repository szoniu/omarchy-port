#!/usr/bin/env bash
# Dźwięk portu bez systemd (omarchy-port#5) — jako użytkownik sesji, w VM, w żywej sesji.
# 1) sesja portu: po restarcie dźwięku dokładnie jeden pipewire, jeden pipewire-pulse i jeden wireplumber;
# 2) inny pulpit na tej samej maszynie: start dźwięku jak w Plasmie czy GNOME bez systemd (Gentoo:
#    /etc/xdg/autostart/pipewire.desktop → gentoo-pipewire-launcher restart) też daje po jednym — port nie może
#    dokładać WirePlumbera i pulse każdemu pipewire w systemie (conf.d w /etc).
# Na Voidzie (bez gentoo-pipewire-launcher) idzie tylko część 1.
set -uo pipefail
qpid=$(pgrep -u "$(id -u)" -x quickshell | head -1)
[ -n "$qpid" ] || { echo "BRAK SESJI (quickshell) — test wymaga żywej sesji" >&2; exit 2; }
while IFS= read -r -d '' kv; do export "${kv?}"; done < "/proc/$qpid/environ"
FAIL=0
ok() { printf '  %-4s %s\n' "$1" "$2"; }
t() { if eval "$2"; then ok OK "$1"; else ok FAIL "$1"; FAIL=$((FAIL + 1)); fi; }
ile() { pgrep -u "$(id -u)" -c -fx "$1"; }   # procesy o dokładnie tej linii poleceń (wyrażenie regularne)
GLOWNY='(/usr/bin/)?pipewire' PULSE='(/usr/bin/)?pipewire -c pipewire-pulse.conf' WP='(/usr/bin/)?wireplumber'
trojka() { # trojka <opis> — po jednym procesie każdego rodzaju
  t "$1: pipewire 1 (jest $(ile "$GLOWNY"))" '[[ $(ile "$GLOWNY") == 1 ]]'
  t "$1: pipewire-pulse 1 (jest $(ile "$PULSE"))" '[[ $(ile "$PULSE") == 1 ]]'
  t "$1: wireplumber 1 (jest $(ile "$WP"))" '[[ $(ile "$WP") == 1 ]]'
}

echo "### sesja portu"
systemctl --user restart pipewire.service; sleep 3
trojka "sesja"
t "sesja: domyślny sink" 'wpctl inspect @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1'

if command -v gentoo-pipewire-launcher >/dev/null; then
  echo "### inny pulpit: gentoo-pipewire-launcher restart (XDG autostart bez systemd)"
  setsid gentoo-pipewire-launcher restart >/dev/null 2>&1 </dev/null &
  sleep 5
  trojka "launcher"
  # sprzątanie: dźwięk z powrotem pod nadzorcą unitów sesji
  pkill -u "$(id -u)" -x 'pipewire|wireplumber'; sleep 1
  systemctl --user start pipewire.service; sleep 3
  trojka "sesja po powrocie"
  t "sesja po powrocie: domyślny sink" 'wpctl inspect @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1'
fi
echo "FAIL: $FAIL"
((FAIL == 0))
