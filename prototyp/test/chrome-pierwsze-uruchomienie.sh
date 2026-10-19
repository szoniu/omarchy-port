#!/usr/bin/env bash
# Gentoo: pierwsze uruchomienie Chrome bez kreatora (omarchy-port#13). Kreator z zaznaczonym „domyślna
# przeglądarka” woła w sesji `xdg-settings set default-web-browser`, które przy hyprland-mimeapps.list
# z v4.0.5 wpisuje omarchy-browser.desktop do ogólnego mimeapps.list (opis: wyniki/2026-10-19-podbicie-4.0.5.md).
# Uruchamiać W VM jako użytkownik sesji — tym samym kanałem co skrót: omarchy-launch-browser w env żywej
# sesji (env z Quickshella). Zabija Chrome użytkownika i usuwa znacznik ~/.config/google-chrome/First Run.
pid=$(pgrep -u "$(id -u)" -x quickshell | head -1)
[[ -n $pid ]] || { echo "BRAK SESJI (quickshell)"; exit 2; }
mapfile -d '' E <"/proc/$pid/environ"
s() { env -i "${E[@]}" bash -c "$*"; }
kreator='witamy|welcome|warunki|terms of service'

pkill -u "$(id -u)" -f /opt/google/chrome/chrome
sleep 2
rm -f ~/.config/google-chrome/"First Run"
przed=$(md5sum <~/.config/mimeapps.list)
s 'omarchy-launch-browser https://example.com/' >/dev/null 2>&1
for _ in {1..30}; do
  okna=$(s 'hyprctl clients -j' | jq -r '.[].title')
  grep -qi -E "example|$kreator" <<<"$okna" && break
  sleep 1
done

fail=0
if grep -qi -E "$kreator" <<<"$okna"; then
  printf '  FAIL kreator pierwszego uruchomienia: %s\n' "$(grep -i -E "$kreator" <<<"$okna" | head -1)"
  fail=1
else
  printf '  OK   bez kreatora pierwszego uruchomienia\n'
fi
if grep -qi example <<<"$okna"; then printf '  OK   strona otwarta od razu\n'; else printf '  FAIL brak okna ze stroną\n'; fail=1; fi
if [[ $(md5sum <~/.config/mimeapps.list) == "$przed" ]]; then
  printf '  OK   mimeapps.list bez zmian\n'
else
  printf '  FAIL mimeapps.list zmieniony: %s\n' "$(grep -h 'x-scheme-handler/http=' ~/.config/mimeapps.list)"
  fail=1
fi
pkill -u "$(id -u)" -f /opt/google/chrome/chrome
exit $fail
