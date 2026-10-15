# shellcheck shell=bash
# omarchy-port: backend Gentoo (emerge) dla install.sh — etapy 1–2 i pliki należące do pakietów dystrybucji.
# Sourcowany przez orkiestrator po wykryj_system; korzysta z jego die, DYST, REPO.
# Port nie zmienia polityki binarek: FEATURES/getbinpkg i make.conf zostają takie, jakie ustawił
# instalator — z binhostem Gentoo większość listy przychodzi gotowa, bez niego wszystko się kompiluje.

dyst_sprawdz() {
  local arch elibc
  arch=$(portageq envvar ARCH) elibc=$(portageq envvar ELIBC)
  [[ $arch == amd64 ]] || die "na razie tylko Gentoo amd64 (jest: $arch)"
  [[ $elibc == glibc ]] || die "na razie tylko Gentoo z glibc (jest: $elibc)"
}

# GURU (quickshell, brightnessctl, nerdfonts) i hyproverlay (Hyprland — z ::gentoo usunięty 2026-03-27),
# oba z listy repozytoriów Gentoo (eselect repository). Keywordy ~amd64, USE i licencje per atom
# z share/gentoo/portage/<katalog>/omarchy-port — tylko to, czego wymaga lista Omarchy (bez zbiorczego
# */*::overlay ~amd64), pliki portu nadpisywane przy każdym przebiegu.
dyst_repozytoria() {
  local r d
  if ! eselect repository list >/dev/null 2>&1; then
    emerge --ask=n --noreplace app-eselect/eselect-repository </dev/null
  fi
  for r in guru hyproverlay; do
    if eselect repository list -i 2>/dev/null | awk -v r="$r" '$2 == r { f = 1 } END { exit !f }'; then
      echo "repozytorium $r: już włączone"
    else
      eselect repository enable "$r"
    fi
  done
  for d in package.accept_keywords package.use package.license; do
    if [[ -e /etc/portage/$d && ! -d /etc/portage/$d ]]; then
      die "/etc/portage/$d to plik — port dokłada własny plik do katalogu; przenieś zawartość do /etc/portage/$d/inne"
    fi
    install -d "/etc/portage/$d"
    install -m 644 "$DYST/portage/$d/omarchy-port" "/etc/portage/$d/omarchy-port"
    echo "/etc/portage/$d/omarchy-port"
  done
  synchronizuj
}

# rsync.gentoo.org losuje mirror przy każdym połączeniu, a zepsuty mirror (w VM 15.10.2026: plik
# lastreplicate spoza Manifestu → „Manifest verification failed”) wywraca całe `emaint sync`, choć
# overlaye przeszły. Do trzech prób; potem, jeśli drzewa nie są puste, dalej na stanie z poprzedniej
# synchronizacji — z UWAGĄ w podsumowaniu, bo pakiety mogą być nieaktualne.
synchronizuj() {
  local proba r sciezka
  for proba in 1 2 3; do
    emaint sync --auto </dev/null && return 0
    echo "synchronizacja repozytoriów: próba $proba nie przeszła"
  done
  for r in gentoo guru hyproverlay; do
    sciezka=$(portageq get_repo_path / "$r" 2>/dev/null) || sciezka=
    [[ -n $sciezka && -n $(ls -A "$sciezka" 2>/dev/null) ]] ||
      die "synchronizacja nie przeszła 3 razy, a repozytorium $r jest puste — nie ma z czego instalować"
  done
  wynik "synchronizacja repozytoriów" root uwaga "emaint sync nie przeszedł 3 razy — pakiety z drzewa poprzedniej synchronizacji"
  echo "  UWAGA        emaint sync nie przeszedł 3 razy — instalacja na drzewie z poprzedniej synchronizacji"
}

# Po udanym omarchy-provision-user: Omarchy ustawia tam na sztywno chromium.desktop (u nas alias z
# share/gentoo/applications), a przeglądarką na Gentoo jest Chrome (omarchy-port#5) — jak
# `omarchy-install-browser chrome` / Setup > Defaults > Browser. Katalog polityk Chrome zakłada warstwa
# (share/gentoo/warstwa.sh), zanim krok user/theme.sh zapisze tam kolor motywu. rc ≠ 0 = BŁĄD w
# podsumowaniu i ponowna próba przy następnym przebiegu (znacznik w install.sh).
dyst_po_provision() { # dyst_po_provision <użytkownik>
  su - "$1" -c 'env -u BROWSER xdg-settings set default-web-browser google-chrome.desktop' </dev/null || {
    echo "  BŁĄD         domyślna przeglądarka $1 nie przestawiona na Chrome (xdg-settings)"
    return 1
  }
  echo "  ok           domyślna przeglądarka $1: google-chrome.desktop"
}

# Pełna aktualizacja systemu i lista Omarchy w jednym grafie zależności (jedno przeliczenie zamiast
# dwóch); atomy z listy trafiają do @world, zainstalowane tylko się aktualizują.
dyst_pakiety() { # dyst_pakiety <atom…>
  emerge --ask=n --quiet-build --update --deep --newuse --with-bdeps=y @world "$@" </dev/null
}

# Ścieżki należące do pakietów Gentoo — z list plików w /var/db/pkg (CONTENTS: obj <ścieżka> <md5> <czas>,
# sym <ścieżka> -> <cel> <czas>).
dyst_pliki_pakietow() {
  cat /var/db/pkg/*/*/CONTENTS 2>/dev/null |
    sed -n -E 's/^obj (.*) [0-9a-f]{32} [0-9]+$/\1/p; s/^sym (.*) -> .* [0-9]+$/\1/p' | LC_ALL=C sort -u
}
dyst_wlasciciel() { # dyst_wlasciciel <plik> — kategoria/pakiet-wersja, do którego plik należy
  grep -l -F -e "obj $1 " -e "sym $1 -> " /var/db/pkg/*/*/CONTENTS 2>/dev/null | head -1 |
    sed 's|^/var/db/pkg/||; s|/CONTENTS$||'
}
