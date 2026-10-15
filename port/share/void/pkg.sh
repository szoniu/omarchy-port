# shellcheck shell=bash
# shellcheck disable=SC2034  # zmienne dla nakładek, które ten plik sourcują
# omarchy-port: backend pakietów Voida (xbps) dla nakładek omarchy-pkg-*, omarchy-version-* i
# omarchy-update-* — instalowany jako /usr/share/omarchy-port/pkg-backend.sh, sourcowany przez pkg-map.sh.
# Funkcje backend_* dostają nazwy pakietów Voida (z mapy), nie Archa.
PORT_DYSTR=void
PORT_DYSTR_NAZWA=Void
PORT_NA="na Voidzie"   # do komunikatów: „pakietu X nie ma na Voidzie”

backend_pkg_installed() { xbps-query "$1" >/dev/null 2>&1; }
backend_pkg_w_repo() { xbps-query -R "$1" >/dev/null 2>&1; }
backend_pkg_instaluj() { xbps-install -Sy "$@"; }       # jako root (port_jako_root)
backend_pkg_usun() { xbps-remove -Ry "$@"; }            # jako root; pacman -Rns → -R (zależności)

# Lista do wyboru w omarchy-pkg-install / -remove (fzf): nazwa w pierwszej kolumnie, podgląd w fzf
backend_pkg_lista_repo() { xbps-query -Rs '' | awk '{ sub(/-[^-]+_[0-9]+$/, "", $2); print $2 }' | sort -u; }
BACKEND_PODGLAD_REPO='xbps-query -R {1}'
# pakiety zainstalowane ręcznie (odpowiednik pacman -Qqe)
backend_pkg_lista_reczne() { xbps-query -m | sed -E 's/-[^-]+_[0-9]+$//'; }
BACKEND_PODGLAD_RECZNE='xbps-query {1}'

# Sieroty (pacman -Qtdq): pakiety zainstalowane jako zależność, których już nic nie potrzebuje. Gdy
# metapakiet `linux` przechodzi na nową serię, poprzednia seria jądra (także ta, która właśnie działa)
# staje się sierotą — pakiety jądra są więc pomijane (stare jądra sprząta vkpurge, po restarcie).
backend_sieroty() {
  xbps-query -O 2>/dev/null | grep -Ev '^linux[0-9]+\.[0-9]+(-headers|-dbg)?-[0-9]' || true
}
# wypisane przez backend_sieroty (nazwa-wersja_rewizja) → usunięcie tylko tych, jako root
backend_usun_sieroty() {
  local o names=()
  for o in "$@"; do names+=("$(xbps-uhelper getpkgname "$o")"); done
  xbps-remove -Ry "${names[@]}"
}

# Ostatnia instalacja lub aktualizacja pakietu (epoka). xbps nie prowadzi logu transakcji, ale przy
# instalacji i aktualizacji pakietu zapisuje jego listę plików /var/db/xbps/.<pakiet>-files.plist —
# najnowszy czas modyfikacji = ostatnia zmiana pakietów (przebieg bez zmian go nie rusza). Nie
# install-date z pkgdb: ma skrót strefy (w bazie mieszają się CEST i UTC z chroota instalatora),
# którego `date -d` nie zna poza własną tabelą.
backend_ostatnia_zmiana() {
  local last
  last=$(find /var/db/xbps -maxdepth 1 -name '.*-files.plist' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
  [[ -n $last ]] && echo "${last%.*}"
}

# Czy działające jądro zostało podmienione (pytanie o restart). Upstream pyta, czy pliki działającego
# jądra wciąż należą do pakietu; na Archu aktualizacja je usuwa. Pakiety jądra Voida (preserve)
# zostawiają stare pliki na dysku, ale po aktualizacji nie należą już do żadnego pakietu — to samo
# pytanie daje tę samą odpowiedź. xbps-query -o kończy się kodem 0 także bez trafienia — liczy się wyjście.
backend_jadro_podmienione() {
  [[ -z $(xbps-query -o "/usr/lib/modules/$(uname -r)/modules.order" 2>/dev/null) ]]
}
