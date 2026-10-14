#!/usr/bin/env bash
# omarchy-pkg-* w ŚRODOWISKU ŻYWEJ SESJI (env z procesu Quickshella, PATH bez zmian) — tym kanałem
# idą menu i skróty. Uruchamiać W VM jako użytkownik sesji. Pakiet, który na pewno jest: foot.
# Czerwone przed przekierowaniem /usr/share/omarchy/bin (install-layer.sh): present → rc 1, bo pacmana nie ma.
pid=$(pgrep -u "$(id -u)" -x quickshell | head -1)
[[ -n $pid ]] || { echo "BRAK SESJI (quickshell)"; exit 2; }
mapfile -d '' E <"/proc/$pid/environ"
fail=0
t() { # t <opis> <oczekiwane rc> <polecenie…>
  local opis=$1 want=$2 rc
  shift 2
  env -i "${E[@]}" bash -c "$*" >/dev/null 2>&1
  rc=$?
  if [[ $rc == "$want" ]]; then printf '  OK   %s (rc=%s)\n' "$opis" "$rc"; else printf '  FAIL %s (rc=%s, oczekiwane %s)\n' "$opis" "$rc" "$want"; fail=1; fi
}
for c in omarchy-pkg-present omarchy-pkg-missing omarchy-pkg-add; do
  r=$(env -i "${E[@]}" bash -c "command -v $c")
  printf '  %-22s %s → %s\n' "$c" "$r" "$(readlink -f "$r")"
done
t "omarchy-pkg-present foot" 0 omarchy-pkg-present foot
t "omarchy-pkg-missing foot" 1 omarchy-pkg-missing foot
t "omarchy-pkg-present nie-ma-takiego" 1 omarchy-pkg-present nie-ma-takiego-pakietu
exit $fail
