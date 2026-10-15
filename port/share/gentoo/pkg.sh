# shellcheck shell=bash
# shellcheck disable=SC2034  # zmienne dla nakładek, które ten plik sourcują
# omarchy-port: backend pakietów Gentoo (portage) dla nakładek omarchy-pkg-*, omarchy-version-* i
# omarchy-update-* — instalowany jako /usr/share/omarchy-port/pkg-backend.sh, sourcowany przez pkg-map.sh.
# Funkcje backend_* dostają atomy Gentoo z mapy (kategoria/pakiet, opcjonalnie :slot), nie nazwy Archa.
PORT_DYSTR=gentoo
PORT_DYSTR_NAZWA=Gentoo
PORT_NA="na Gentoo"   # do komunikatów: „pakietu X nie ma na Gentoo”
# Wersja na końcu kategoria/pakiet-wersja (PMS): cyfry z kropkami, litera, sufiksy _alpha/_beta/_pre/_rc/_p
# i rewizja -rN. Samo „-[0-9]” myli pakiety z cyfrą po myślniku w nazwie (font-adobe-75dpi).
PORT_WERSJA_RE='-[0-9]+([.][0-9]+)*[a-z]?(_(alpha|beta|pre|rc|p)[0-9]*)*(-r[0-9]+)?$'   # [.] — ten sam wzorzec w bashu i w awk -v

# Obecność z bazy /var/db/pkg (bez Pythona portageq — Omarchy pyta o pakiety seriami). Atom ze slotem
# (dev-lang/lua:5.1) — dowolna zainstalowana wersja w tym slocie. Nazwa bez kategorii (pakiet spoza
# mapy pod nazwą z Archa, np. sof-firmware z hardware/intel/sof-firmware.sh) — w dowolnej kategorii,
# tak jak przyjmuje ją emerge.
backend_pkg_installed() {
  local atom=${1%%:*} slot='' d nazwa
  [[ $1 == *:* ]] && slot=${1#*:}
  [[ $atom == */* ]] || atom="*/$atom"
  for d in /var/db/pkg/$atom-[0-9]*; do
    [[ -d $d ]] || continue
    # nazwa dosłownie, reszta musi być wersją (font-adobe nie łapie font-adobe-75dpi-1.0.4)
    nazwa=${d##*/}
    nazwa=${nazwa#"${atom##*/}"}
    [[ $nazwa =~ ^$PORT_WERSJA_RE ]] || continue
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
# fzf woła podgląd przez $SHELL -c, a powłoką konta bywa nie bash — podgląd to jedno wywołanie basha
BACKEND_PODGLAD_REPO="bash -c '. /usr/share/omarchy-port/pkg-map.sh && backend_podglad_repo \"\$1\"' _ {1}"
backend_podglad_repo() {
  local p
  p=$(portageq best_visible / "$1" 2>/dev/null)
  echo "${p:-$1 — niewidoczny (keywordy, maski)}"
  [[ -n $p ]] && portageq metadata / ebuild "$p" DESCRIPTION HOMEPAGE LICENSE 2>/dev/null
}
# pakiety wybrane ręcznie (odpowiednik pacman -Qqe) — zestaw @world
backend_pkg_lista_reczne() { grep -v '^#' /var/lib/portage/world 2>/dev/null; }
BACKEND_PODGLAD_RECZNE="bash -c '. /usr/share/omarchy-port/pkg-map.sh && backend_podglad_reczne \"\$1\"' _ {1}"
backend_podglad_reczne() { # atom z @world, także ze slotem (dev-lang/lua:5.1)
  local atom=${1%%:*} d reszta
  for d in /var/db/pkg/"$atom"-[0-9]*; do
    [[ -d $d ]] || continue
    reszta=${d##*/}
    reszta=${reszta#"${atom##*/}"}
    [[ $reszta =~ ^$PORT_WERSJA_RE ]] || continue
    echo "${d#/var/db/pkg/}  (slot $(cat "$d/SLOT" 2>/dev/null))"
    cat "$d/DESCRIPTION" 2>/dev/null
  done
}

# Sieroty (pacman -Qtdq): to, co usunąłby `emerge --depclean` — zależności, których nic już nie
# potrzebuje. Jądro dystrybucji (gentoo-kernel-bin) ma własne sprzątanie, więc nie jest pomijane osobno.
# Lista z wiersza „All selected packages: =kat/pakiet-wersja …” — jest z --quiet i bez (nagłówka
# „These are the packages that would be unmerged” przy --quiet nie ma), a dokładne wersje usuwają tylko
# pokazane pakiety, nawet gdy w międzyczasie coś doszło.
# Pomijane: pakiety, o których portage ostrzega „is part of your system profile” (np. nano jako
# dostawca virtual/editor, gdy doszedł neovim — ich usunięcie zostawia EDITOR=/bin/nano bez pliku,
# sprawdzone w VM 15.10.2026; profil systemu to zakres Gentoo, nie Omarchy) i jądra (sys-kernel/*):
# dist-kernel ma slot na wersję, więc po aktualizacji poprzednie — także to, które właśnie działa —
# jest sierotą, a jego usunięcie zabiera moduły działającego systemu. Stare jądra jak na Voidzie:
# ręcznie, po restarcie (emerge --depclean sys-kernel/…).
backend_sieroty() {
  emerge --pretend --depclean --quiet </dev/null 2>&1 |
    awk -v re="$PORT_WERSJA_RE" '
      /is part of your system profile/ { if (match($0, /'"'"'[^'"'"']+'"'"'/)) chron[substr($0, RSTART + 1, RLENGTH - 2)] = 1 }
      /^All selected packages:/ {
        for (i = 4; i <= NF; i++) {
          a = $i; sub(/^=/, "", a); sub(re, "", a)
          if (!(a in chron) && a !~ /^sys-kernel\//) print $i
        }
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

# Czy działające jądro zostało podmienione (pytanie o restart). Dist-kernel Gentoo ma slot na wersję
# (gentoo-kernel-bin:6.18.54), więc aktualizacja dokłada nowe jądro obok, a moduły działającego zostają —
# „podmienione” = działające nie jest najnowszym na dysku (albo jego moduły już zniknęły).
backend_jadro_podmienione() {
  local najnowsze
  najnowsze=$(find /lib/modules /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -uV | tail -1)
  [[ -n $najnowsze && $najnowsze != "$(uname -r)" ]]
}
