#!/usr/bin/env bash
# Gentoo: pierwsze uruchomienie Chrome bez kreatora i polityka Omarchy na miejscu (omarchy-port#13). Kreator
# z zaznaczonym „domyślna przeglądarka” i przycisk „ustaw jako domyślną” w ustawieniach wołają w sesji
# `xdg-settings set default-web-browser`, które przy hyprland-mimeapps.list z v4.0.5 wpisuje
# omarchy-browser.desktop do ogólnego mimeapps.list (opis: wyniki/2026-10-19-podbicie-4.0.5.md). Sam zapis
# do mimeapps.list idzie dopiero po kliknięciu OK, którego test nie robi — sprawdzany jest wyzwalacz (okno
# kreatora) i polityka, która chowa przycisk (DefaultBrowserSettingEnabled: false).
# Uruchamiać W VM jako użytkownik sesji — tym samym kanałem co skrót: omarchy-launch-browser w env żywej
# sesji (env z Quickshella). Zamyka Chrome użytkownika; znacznik ~/.config/google-chrome/First Run na czas
# testu usuwa i potem przywraca.
pid=$(pgrep -u "$(id -u)" -x quickshell | head -1)
[[ -n $pid ]] || { echo "BRAK SESJI (quickshell)"; exit 2; }
mapfile -d '' E <"/proc/$pid/environ"
s() { env -i "${E[@]}" bash -c "$*"; }
kreator='witamy|welcome|warunki|terms of service'
CHROME=/opt/google/chrome/chrome
znacznik=~/.config/google-chrome/"First Run"
zamknij_chrome() { # czeka, aż wszystkie procesy Chrome znikną — inaczej adres trafi do kończącej się instancji
  pkill -u "$(id -u)" -f "$CHROME"
  for _ in {1..30}; do
    pgrep -u "$(id -u)" -f "$CHROME" >/dev/null || return 0
    sleep 1
  done
  return 1
}
okna_chrome() { # tytuły okien procesów Chrome — okno kreatora ma pustą klasę, więc filtr po pid, nie po class
  local p tytul
  while IFS=$'\t' read -r p tytul; do
    [[ $(readlink "/proc/$p/exe" 2>/dev/null) == "$CHROME" ]] && printf '%s\n' "$tytul"
  done < <(s 'hyprctl clients -j' | jq -r '.[] | "\(.pid)\t\(.title)"')
}

fail=0
if jq -e '.DefaultBrowserSettingEnabled == false' /etc/opt/chrome/policies/managed/omarchy.json >/dev/null 2>&1; then
  printf '  OK   polityka Omarchy: /etc/opt/chrome/policies/managed/omarchy.json\n'
else
  printf '  FAIL brak polityki DefaultBrowserSettingEnabled: false w /etc/opt/chrome/policies/managed\n'
  fail=1
fi

zamknij_chrome || { echo "Chrome nie zakończył się w 30 s"; exit 2; }
[[ -e $znacznik ]] && byl=1 || byl=0
rm -f "$znacznik"
s 'omarchy-launch-browser https://example.com/' >/dev/null 2>&1
for _ in {1..30}; do
  okna=$(okna_chrome)
  grep -qi -E "example|$kreator" <<<"$okna" && break
  sleep 1
done
if grep -qi -E "$kreator" <<<"$okna"; then
  printf '  FAIL kreator pierwszego uruchomienia: %s\n' "$(grep -i -E "$kreator" <<<"$okna" | head -1)"
  fail=1
else
  printf '  OK   bez kreatora pierwszego uruchomienia\n'
fi
if grep -qi example <<<"$okna"; then printf '  OK   strona otwarta od razu\n'; else printf '  FAIL brak okna Chrome ze stroną\n'; fail=1; fi
zamknij_chrome
(( byl )) && touch "$znacznik"
exit $fail
