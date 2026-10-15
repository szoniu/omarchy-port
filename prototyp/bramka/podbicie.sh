#!/usr/bin/env bash
# Bramka podbicia wersji Omarchy: co przejrzeć, zanim zmieni się pin w port/share/upstream.env.
#   [NOWY_PKGS=<commit omarchy-pkgs>] prototyp/bramka/podbicie.sh <nowy commit|tag Omarchy> [<stary commit>]
# Stary commit domyślnie z upstream.env, źródło z OMARCHY_URL (klon w ~/.cache/omarchy-port-bramka);
# omarchy-pkgs: stary OMARCHY_PKGS_COMMIT, nowy z NOWY_PKGS (domyślnie gałąź domyślna, origin/HEAD).
# Wypisuje (TSV na stdout, podsumowanie na stderr):
#   migracja  <plik>  <A|D|M + zależności>  <stan w migracje.tsv>    — migracje dodane/usunięte/zmienione
#   krok      <krok>  <A|D|M + zależności>  <stan w kroki.tsv>       — kroki install/ dodane/usunięte/zmienione
#   nakładka  <plik>  <D|M + skala zmiany>                           — upstream zmienił skrypt, który port
#                                                                       zastępuje własnym (port/bin): przejrzeć
#   pakiet    <nazwa> <+|->                 <stan w mapie Voida>     — zmiany install/omarchy-base.packages
#   pakiet-portu <nazwa> <bez zmian|zmieniony …>                    — PKGBUILD-y omarchy-pkgs pakietów w stanie
#                                                                       „port” (install.sh buduje je sam)
#   łatka     <plik>  <pasuje|już w wydaniu|nie pasuje>            — share/latki i share/<dystrybucja>/latki
# Stan w listach portu (kroki.tsv, migracje.tsv, mapa pakietów) — dla każdej dystrybucji: „void:… gentoo:…”.
#   branding  <założenie> <ok|nie spełnione>                       — pliki i kolory Omarchy, na których stoi
#                                                                       share/void/branding.sh
# Wykrywanie to grep po treści (pacman, systemd, limine, snapper, initramfs, plymouth, sudo, kroki
# install/ z kroki.tsv) — podpowiedź do przeglądu, nie wyrok: każdą migrację i tak trzeba przeczytać.
# Działa na maszynie deweloperskiej (git); niczego nie instaluje.
set -euo pipefail
PORT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../port/share/upstream.env
source "$PORT/port/share/upstream.env"
NOWY=${1:?użycie: podbicie.sh <nowy commit|tag Omarchy> [<stary commit>]}
STARY=${2:-$OMARCHY_COMMIT}
SRC=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-port-bramka/omarchy

if [[ ! -d $SRC/.git ]]; then
  git clone -q "$OMARCHY_URL" "$SRC"
fi
git -C "$SRC" fetch -q --tags "$OMARCHY_URL" '+refs/heads/*:refs/remotes/origin/*'
git -C "$SRC" rev-parse -q --verify "$STARY^{commit}" >/dev/null || git -C "$SRC" fetch -q "$OMARCHY_URL" "$STARY"
git -C "$SRC" rev-parse -q --verify "$NOWY^{commit}" >/dev/null || git -C "$SRC" fetch -q "$OMARCHY_URL" "$NOWY"
NOWY_SHA=$(git -C "$SRC" rev-parse "$NOWY^{commit}")

zaleznosci() { # zaleznosci <ref> <ścieżka w repo> — wykryte zależności od Archa/systemd, po przecinku
  local tresc zn=() krok
  tresc=$(git -C "$SRC" show "$1:$2" 2>/dev/null) || { echo "-"; return; }
  grep -qE '\b(pacman|yay|paru|makepkg|pacman-key|checkupdates)\b|/etc/pacman' <<<"$tresc" && zn+=(pacman)
  grep -qE '\b(systemctl|journalctl|loginctl|systemd-[a-z]+)\b' <<<"$tresc" && zn+=(systemd)
  grep -qE '\blimine' <<<"$tresc" && zn+=(limine)
  grep -qE '\bsnapper\b' <<<"$tresc" && zn+=(snapper)
  grep -qE '\b(mkinitcpio|dracut|initramfs)\b' <<<"$tresc" && zn+=(initramfs)
  grep -qE '\bplymouth' <<<"$tresc" && zn+=(plymouth)
  grep -qE '\bomarchy-pkg-(add|drop|install|remove|aur)' <<<"$tresc" && zn+=(pakiety)
  grep -qE '\bsudo\b' <<<"$tresc" && zn+=(sudo)
  # krok install/ z listy portu wołany wprost (np. source $OMARCHY_PATH/install/...) idzie w wersji
  # z upstreamu, nie z drzewa portu — pominięcie z kroki.tsv go nie obejmuje
  while IFS=$'\t' read -r krok _; do
    [[ -z $krok || $krok == \#* ]] && continue
    grep -qF "install/$krok" <<<"$tresc" && zn+=("kroki.tsv:$krok")
  done < <(cat "$PORT"/port/share/*/kroki.tsv)
  local IFS=,
  echo "${zn[*]:-—}"
}
stan_listy() { # stan_listy <plik tsv> <nazwa>
  awk -F'\t' -v n="$2" '$1 == n { print $2; f = 1 } END { if (!f) print "—" }' "$1"
}
DYSTRYBUCJE=(void gentoo)
stan_dystr() { # stan_dystr <kroki.tsv|migracje.tsv|mapa> <nazwa> — „void:… gentoo:…”
  local d plik out=()
  for d in "${DYSTRYBUCJE[@]}"; do
    if [[ $1 == mapa ]]; then plik="$PORT/dane/mapa-pakietow-$d.tsv"; else plik="$PORT/port/share/$d/$1"; fi
    out+=("$d:$(stan_listy "$plik" "$2")")
  done
  echo "${out[*]}"
}

n_mig=0 n_mig_flag=0 n_mig_lista=0 n_krok=0 n_nakl=0 n_pak=0 n_pport=0 n_latka_zle=0 n_brand=0

while IFS=$'\t' read -r st plik; do
  m=${plik#migrations/}
  z=$(zaleznosci "$NOWY_SHA" "$plik")
  lista=$(stan_dystr migracje.tsv "$m")
  printf 'migracja\t%s\t%s %s\t%s\n' "$m" "$st" "$z" "$lista"
  # usunięta albo zmieniona migracja z listy portu: orkiestrator przerwie na usuniętej, a podmiana
  # zmienionej rozjedzie się z upstreamem
  # usunięta albo zmieniona migracja, która ma stan w liście którejś dystrybucji (po odjęciu „:—” zostaje „:”)
  t=${lista//:—/}
  if [[ $st != A && $t == *:* ]]; then n_mig_lista=$((n_mig_lista + 1)); fi
  [[ $st == A ]] || continue
  n_mig=$((n_mig + 1))
  [[ $z == "—" || $z == pakiety || $z == sudo || $z == pakiety,sudo ]] || n_mig_flag=$((n_mig_flag + 1))
done < <(git -C "$SRC" diff --name-status --no-renames "$STARY" "$NOWY_SHA" -- migrations/)

while IFS=$'\t' read -r st plik; do
  [[ $plik == install/*.sh ]] || continue
  k=${plik#install/}
  z=$(zaleznosci "$NOWY_SHA" "$plik")
  printf 'krok\t%s\t%s %s\t%s\n' "$k" "$st" "$z" "$(stan_dystr kroki.tsv "$k")"
  n_krok=$((n_krok + 1))
done < <(git -C "$SRC" diff --name-status --no-renames "$STARY" "$NOWY_SHA" -- install/)

# Nakładki portu (port/bin) to zamrożone kopie skryptów upstreamu z przypiętej wersji z podmienionymi
# krokami pacmana — zmiana upstreamu (nowy krok, inna kolejność, zmieniona nazwa pomocnika) do przeniesienia.
for f in "$PORT"/port/bin/omarchy-*; do
  b=${f##*/}
  git -C "$SRC" cat-file -e "$STARY:bin/$b" 2>/dev/null || continue   # polecenie portu, nie nakładka
  if ! git -C "$SRC" cat-file -e "$NOWY_SHA:bin/$b" 2>/dev/null; then
    printf 'nakładka\t%s\tD (upstream usunął)\n' "$b"
  else
    zm=$(git -C "$SRC" diff --shortstat "$STARY" "$NOWY_SHA" -- "bin/$b")
    [[ -n $zm ]] || continue
    printf 'nakładka\t%s\tM%s\n' "$b" "${zm#*changed,}"
  fi
  n_nakl=$((n_nakl + 1))
done

# [[:space:]] zamiast \s — skrypt chodzi też na macOS (BSD sed traktuje \s jak literę s)
pakiety() { git -C "$SRC" show "$1:install/omarchy-base.packages" 2>/dev/null | grep -v '^[[:space:]]*#' | sed '/^[[:space:]]*$/d;s/[[:space:]].*//' | LC_ALL=C sort -u; }
while IFS= read -r linia; do
  znak=${linia:0:1} p=${linia:1}
  printf 'pakiet\t%s\t%s\t%s\n' "$p" "$znak" "$(stan_dystr mapa "$p")"
  n_pak=$((n_pak + 1))
done < <(diff <(pakiety "$STARY") <(pakiety "$NOWY_SHA") | sed -n 's/^< /-/p; s/^> /+/p')

# Pakiety w stanie „port” (dane/mapa-pakietow-<dystrybucja>.tsv, np. ufw-docker) port buduje sam z PKGBUILD-ów
# (install.sh, etap 3: źródła z sumami, package()) — z omarchy-pkgs albo z port/share/pakiety. Zmiana
# PKGBUILD-a z omarchy-pkgs przy podbiciu OMARCHY_PKGS_COMMIT (źródło git+, nowa zależność, post_install)
# wyszłaby dopiero przy instalacji; PKGBUILD-y portu mają wersję przypiętą w repo portu.
PKGS=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-port-bramka/omarchy-pkgs
[[ -d $PKGS/.git ]] || git clone -q "$OMARCHY_PKGS_URL" "$PKGS"
git -C "$PKGS" fetch -q "$OMARCHY_PKGS_URL" '+refs/heads/*:refs/remotes/origin/*'
git -C "$PKGS" rev-parse -q --verify "$OMARCHY_PKGS_COMMIT^{commit}" >/dev/null || git -C "$PKGS" fetch -q "$OMARCHY_PKGS_URL" "$OMARCHY_PKGS_COMMIT"
NOWY_PKGS_SHA=$(git -C "$PKGS" rev-parse "${NOWY_PKGS:-origin/HEAD}^{commit}")
wersja_pkg() { git -C "$PKGS" show "$1:pkgbuilds/$2/PKGBUILD" 2>/dev/null | sed -n 's/^pkgver=//p; s/^pkgrel=//p' | paste -sd- -; }
while read -r p; do
  if [[ -f $PORT/port/share/pakiety/$p/PKGBUILD ]]; then
    printf 'pakiet-portu\t%s\t%s\n' "$p" "PKGBUILD portu (share/pakiety), wersja $(sed -n 's/^pkgver=//p' "$PORT/port/share/pakiety/$p/PKGBUILD") — sprawdzić wydania upstreamu"
    continue
  fi
  if ! git -C "$PKGS" cat-file -e "$NOWY_PKGS_SHA:pkgbuilds/$p/PKGBUILD" 2>/dev/null; then
    w="brak PKGBUILD-a — przejrzeć PAKIETY_UPSTREAM w install.sh"; n_pport=$((n_pport + 1))
  elif git -C "$PKGS" diff --quiet "$OMARCHY_PKGS_COMMIT" "$NOWY_PKGS_SHA" -- "pkgbuilds/$p"; then
    w="bez zmian"
  else
    w="zmieniony $(wersja_pkg "$OMARCHY_PKGS_COMMIT" "$p") → $(wersja_pkg "$NOWY_PKGS_SHA" "$p") — przejrzeć source=/b2sums=/depends/package()"
    n_pport=$((n_pport + 1))
  fi
  printf 'pakiet-portu\t%s\t%s\n' "$p" "$w"
done < <(awk -F'\t' 'FNR > 1 && $2 == "port" { print $1 }' "$PORT"/dane/mapa-pakietow-*.tsv | LC_ALL=C sort -u)

d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
git -C "$SRC" archive "$NOWY_SHA" | tar -x -C "$d"   # całe drzewo — łatka może dotyczyć dowolnej ścieżki
for l in "$PORT"/port/share/latki/*.patch "$PORT"/port/share/*/latki/*.patch; do
  [[ -e $l ]] || continue
  if git -C "$d" apply --check -R -p1 "$l" 2>/dev/null; then w="już w wydaniu — do usunięcia"
  elif git -C "$d" apply --check -p1 "$l" 2>/dev/null; then w="pasuje"
  else w="nie pasuje — przejrzeć"; n_latka_zle=$((n_latka_zle + 1)); fi
  printf 'łatka\t%s\t%s\n' "${l#"$PORT"/port/share/}" "$w"
done

# Branding Voida: brak celu albo inne tło motywu SDDM wyjdzie dopiero w instalacji (UWAGA) albo
# na ekranie (obrysy logo w złym kolorze) — tu widać je przed podbiciem.
zalozenie() { # zalozenie <opis> <polecenie…>
  local opis=$1 w=ok
  shift
  "$@" || { w="nie spełnione — przejrzeć port/share/void/branding.sh"; n_brand=$((n_brand + 1)); }
  printf 'branding\t%s\t%s\n' "$opis" "$w"
}
tlo=$(sed -n "s/^SDDM_TLO='\([^']*\)'.*/\1/p" "$PORT/port/share/void/branding.sh")
for f in icon.txt logo.txt default/sddm/omarchy/logo.png; do zalozenie "$f" test -f "$d/$f"; done
zalozenie "tło motywu SDDM $tlo (Main.qml)" grep -qF "color: \"$tlo\"" "$d/default/sddm/omarchy/Main.qml"
zalozenie "omarchy-transcode-ascii --mode block" grep -qF 'mode != "block"' "$d/bin/omarchy-transcode-ascii"

{
  echo
  echo "Omarchy $STARY → $NOWY ($NOWY_SHA)"
  echo "  nowe migracje: $n_mig, z zależnościami od Archa/systemd (poza pakiety/sudo): $n_mig_flag"
  echo "  migracje z migracje.tsv usunięte/zmienione w upstreamie: $n_mig_lista"
  echo "  nakładki portu do przeniesienia zmian upstreamu: $n_nakl"
  echo "  kroki install/ zmienione: $n_krok — kroki z kroki.tsv: podmiany przejrzeć ze zmianą upstreamu"
  echo "  zmiany listy pakietów: $n_pak — brak w mapie dystrybucji (-) = dopisać do dane/mapa-pakietow-<dystrybucja>.tsv"
  echo "  pakiety portu z omarchy-pkgs zmienione ($OMARCHY_PKGS_COMMIT → $NOWY_PKGS_SHA): $n_pport"
  echo "  łatki do przejrzenia: $n_latka_zle"
  echo "  założenia brandingu Voida niespełnione: $n_brand"
  echo "Dalej: migracje.tsv / kroki.tsv / mapa, upstream.env, test w VM (orkiestrator --update + omarchy-update)."
} >&2
