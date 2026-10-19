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
# nazwa od „-” nie idzie do menedżera pakietów jako opcja (xbps-query --version / -h dają rc 0)
t "omarchy-pkg-present --version" 1 omarchy-pkg-present --version
t "omarchy-pkg-missing -h" 0 omarchy-pkg-missing -h
# add: odmowa ma paść, zanim cokolwiek dojdzie do sudo. sudo podmienione na atrapę, która tylko zapisuje
# wywołanie — bez niej regresja odpaliłaby `xbps-install -Sy --version` / `emerge … @zestaw` jako root albo
# czekała na hasło. Samo rc nic nie mówi: bez odmowy `add --version` daje na Voidzie 0 (xbps-query --version
# kończy się 0), na Gentoo 1; na Gentoo present i missing czytają /var/db/pkg, opcja i zestaw trafiają do
# menedżera tylko przez add.
atrapa=$(mktemp -d)
trap 'rm -rf "$atrapa"' EXIT
printf '#!/bin/sh\necho "$*" >>"%s/wywolania"\nexit 1\n' "$atrapa" >"$atrapa/sudo"
chmod 755 "$atrapa/sudo"
for nazwa in --version @omarchy-port-test; do
  rm -f "$atrapa/wywolania"
  out=$(env -i "${E[@]}" bash -c 'PATH="$1:$PATH"; omarchy-pkg-add "$2"' _ "$atrapa" "$nazwa" 2>&1)
  if [[ $out == *"nie jest nazwą pakietu"* && ! -e $atrapa/wywolania ]]; then
    printf '  OK   omarchy-pkg-add %s (odmowa przed sudo)\n' "$nazwa"
  else
    printf '  FAIL omarchy-pkg-add %s (sudo: %s; wyjście: %s)\n' "$nazwa" "$(cat "$atrapa/wywolania" 2>/dev/null)" "$(head -c 100 <<<"$out" | tr '\n' ' ')"
    fail=1
  fi
done
exit $fail
