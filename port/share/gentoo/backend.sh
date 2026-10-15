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
  emaint sync --auto </dev/null
}

dyst_pakiety() { # dyst_pakiety <atom…> — pełna aktualizacja systemu, potem lista Omarchy (do @world)
  emerge --ask=n --quiet-build --update --deep --newuse --with-bdeps=y @world </dev/null
  emerge --ask=n --quiet-build --noreplace "$@" </dev/null
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
