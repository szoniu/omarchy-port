#!/usr/bin/env bash
# Test skrótów Omarchy przez realny kanał: każde polecenie exec z binds.tsv
# odpalone w środowisku ŻYWEJ sesji Hyprlanda (env z procesu Quickshella — patrz niżej).
# Uruchamiać W VM jako użytkownik sesji; wejście (TSV: id/klawisze, opis, rodzaj, polecenie) w $1, domyślnie /tmp/binds.tsv.
# Wynik: /tmp/bind-test/wyniki.tsv (klawisze, opis, wynik, rc, okna, stderr-skrót)
set -uo pipefail
OUT=${OUT:-/tmp/bind-test}; rm -rf "$OUT"; mkdir -p "$OUT"
# env z dziecka sesji (Quickshell): sam Hyprland nie ma WAYLAND_DISPLAY ani HYPRLAND_INSTANCE_SIGNATURE
hpid=$(pgrep -u "$(id -u)" -x quickshell | head -1)
while IFS= read -r -d '' kv; do export "${kv?}"; done < "/proc/$hpid/environ"
export PATH="/usr/local/bin:$PATH"

SKIP='Close all windows|Lock system|^$|laptop display|Screenrecording|^Agent$|Eject media'
clients() { hyprctl clients -j | jq -r '.[].address' | sort; }

printf 'klawisze\topis\twynik\trc\tnowe_okna\tstderr\n' >"$OUT/wyniki.tsv"
n=0
while IFS=$'\t' read -r keys desc kind cmd; do
  [ "$kind" = exec ] || continue
  if [[ "$desc" =~ $SKIP ]]; then printf '%s\t%s\tPOMINIĘTY\t\t\t\n' "$keys" "$desc" >>"$OUT/wyniki.tsv"; continue; fi
  n=$((n+1)); err="$OUT/$n.err"
  before=$(clients)
  timeout 8 bash -c "$cmd" </dev/null >"$OUT/$n.out" 2>"$err"; rc=$?
  sleep 1.5
  after=$(clients)
  new=$(comm -13 <(echo "$before") <(echo "$after") | grep -c . || true)
  # sprzątanie: nowe okna zamykamy, otwarte menu/panele zamykamy drugim wywołaniem toggle
  for a in $(comm -13 <(echo "$before") <(echo "$after")); do
    p=$(hyprctl clients -j | jq -r --arg a "$a" '.[] | select(.address == $a) | .pid')
    [ -n "$p" ] && [ "$p" -gt 1 ] && kill "$p" 2>/dev/null
  done
  case "$cmd" in *" toggle"*|*"shell toggle"*|*togglePanelAt*) timeout 5 bash -c "$cmd" </dev/null >/dev/null 2>&1 ;; esac
  e=$(grep -v -E '^\s*$' "$err" | grep -i -E 'not found|systemctl|systemd|pacman|uwsm|error|fail|no such|cannot|unknown' | head -2 | tr '\t\n' '  ' | cut -c1-200)
  if [ "$rc" = 124 ]; then res="DZIAŁA (proces żyje)"
  elif [ -n "$e" ]; then res="BŁĄD"
  elif [ "$rc" = 0 ]; then res="OK"
  else res="rc≠0"; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$keys" "$desc" "$res" "$rc" "$new" "$e" >>"$OUT/wyniki.tsv"
done < "${1:-/tmp/binds.tsv}"
echo "przetestowanych: $n"
echo BIND-TEST-DONE
