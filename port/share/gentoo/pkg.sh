# shellcheck shell=bash
# shellcheck disable=SC2034  # zmienne dla nakładek, które ten plik sourcują
# omarchy-port: backend pakietów Gentoo (portage) dla nakładek omarchy-pkg-*, omarchy-version-* i
# omarchy-update-* — instalowany jako /usr/share/omarchy-port/pkg-backend.sh, sourcowany przez pkg-map.sh.
# Funkcje backend_* dostają atomy Gentoo z mapy (kategoria/pakiet, opcjonalnie :slot), nie nazwy Archa.
PORT_DYSTR=gentoo
PORT_DYSTR_NAZWA=Gentoo
PORT_NA="na Gentoo"   # do komunikatów: „pakietu X nie ma na Gentoo”

# Obecność z bazy /var/db/pkg (bez Pythona portageq — Omarchy pyta o pakiety seriami). Atom ze slotem
# (dev-lang/lua:5.1) — dowolna zainstalowana wersja w tym slocie. Nazwa bez kategorii (pakiet spoza
# mapy pod nazwą z Archa, np. sof-firmware z hardware/intel/sof-firmware.sh) — w dowolnej kategorii,
# tak jak przyjmuje ją emerge.
backend_pkg_installed() {
  local atom=${1%%:*} slot='' d
  [[ $1 == *:* ]] && slot=${1#*:}
  [[ $atom == */* ]] || atom="*/$atom"
  for d in /var/db/pkg/$atom-[0-9]*; do
    [[ -d $d ]] || continue
    [[ -z $slot ]] && return 0
    [[ $(cut -d/ -f1 "$d/SLOT" 2>/dev/null) == "$slot" ]] && return 0
  done
  return 1
}
# w repo = widoczny dla portage (z uwzględnieniem keywordów i masek)
backend_pkg_w_repo() { [[ -n $(portageq best_visible / "$1" 2>/dev/null) ]]; }
backend_pkg_instaluj() { emerge --ask=n --quiet-build --noreplace "$@" </dev/null; }   # jako root
# pacman -Rns: wypisanie z @world i usunięcie, jeśli nic innego go nie potrzebuje (depclean)
backend_pkg_usun() { emerge --ask=n --deselect "$@" </dev/null && emerge --ask=n --depclean "$@" </dev/null; }

# Lista do wyboru w omarchy-pkg-install / -remove (fzf): atom w pierwszej kolumnie, podgląd w fzf
backend_pkg_lista_repo() {
  local r
  local -a nazwy
  read -ra nazwy < <(portageq get_repos /)
  while read -r r; do
    find "$r" -mindepth 3 -maxdepth 3 -name '*.ebuild' -printf '%h\n' | sed "s|^$r/||"
  done < <(portageq get_repo_path / "${nazwy[@]}") | LC_ALL=C sort -u
}
BACKEND_PODGLAD_REPO='p=$(portageq best_visible / {1}); echo "$p"; portageq metadata / ebuild "$p" DESCRIPTION HOMEPAGE LICENSE 2>/dev/null'
# pakiety wybrane ręcznie (odpowiednik pacman -Qqe) — zestaw @world
backend_pkg_lista_reczne() { grep -v '^#' /var/lib/portage/world 2>/dev/null; }
BACKEND_PODGLAD_RECZNE='for d in /var/db/pkg/{1}-[0-9]*; do echo "${d#/var/db/pkg/}"; cat "$d/DESCRIPTION"; done'

# Sieroty (pacman -Qtdq): to, co usunąłby `emerge --depclean` — zależności, których nic już nie
# potrzebuje. Jądro dystrybucji (gentoo-kernel-bin) ma własne sprzątanie, więc nie jest pomijane osobno.
# Lista z wiersza „All selected packages: =kat/pakiet-wersja …” — jest z --quiet i bez (nagłówka
# „These are the packages that would be unmerged” przy --quiet nie ma), a dokładne wersje usuwają tylko
# pokazane pakiety, nawet gdy w międzyczasie coś doszło.
# Pakiety, o których portage ostrzega „is part of your system profile” (np. nano jako dostawca
# virtual/editor, gdy doszedł neovim), są pomijane: ich usunięcie zostawia EDITOR=/bin/nano bez pliku
# (sprawdzone w VM 15.10.2026), a profil systemu to zakres Gentoo, nie Omarchy.
backend_sieroty() {
  emerge --pretend --depclean --quiet </dev/null 2>&1 |
    awk '/is part of your system profile/ { if (match($0, /'"'"'[^'"'"']+'"'"'/)) chron[substr($0, RSTART + 1, RLENGTH - 2)] = 1 }
         /^All selected packages:/ {
           for (i = 4; i <= NF; i++) { a = $i; sub(/^=/, "", a); sub(/-[0-9].*$/, "", a); if (!(a in chron)) print $i }
         }'
}
backend_usun_sieroty() { emerge --ask=n --depclean "$@" </dev/null; }   # jako root; atomy z backend_sieroty

# Ostatnia instalacja albo aktualizacja pakietu (epoka), jak „upgraded” z pacman.log w upstreamie:
# najnowszy katalog pakietu w /var/db/pkg (powstaje przy każdym emerge pakietu). Nie /var/log/emerge.log —
# ma prawa portage:portage 0660, a fastfetch woła omarchy-version-pkgs jako użytkownik.
backend_ostatnia_zmiana() {
  local last
  last=$(find /var/db/pkg -mindepth 2 -maxdepth 2 -type d -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
  [[ -n $last ]] && echo "${last%.*}"
}

# Czy działające jądro zostało podmienione (pytanie o restart): jak w upstreamie — moduły działającego
# jądra zniknęły z dysku, bo aktualizacja jądra dystrybucji (gentoo-kernel-bin) usuwa poprzednią wersję.
backend_jadro_podmienione() {
  local r
  r=$(uname -r)
  [[ ! -e /lib/modules/$r/modules.order && ! -e /usr/lib/modules/$r/modules.order ]]
}
