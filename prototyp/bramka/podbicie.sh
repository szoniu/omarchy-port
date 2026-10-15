#!/usr/bin/env bash
# Bramka podbicia wersji Omarchy: co przejrzeć, zanim zmieni się pin w port/share/upstream.env.
#   prototyp/bramka/podbicie.sh <nowy commit|tag Omarchy> [<stary commit>]
# Stary commit domyślnie z upstream.env, źródło z OMARCHY_URL (klon w ~/.cache/omarchy-port-bramka).
# Wypisuje (TSV na stdout, podsumowanie na stderr):
#   migracja  <plik>  <wykryte zależności>  <stan w migracje.tsv>   — nowe migracje
#   krok      <krok>  <A|D|M + zależności>  <stan w kroki.tsv>       — kroki install/ dodane/usunięte/zmienione
#   pakiet    <nazwa> <+|->                 <stan w mapie Voida>     — zmiany install/omarchy-base.packages
#   łatka     <plik>  <pasuje|już w wydaniu|nie pasuje>
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
  done <"$PORT/port/share/void/kroki.tsv"
  local IFS=,
  echo "${zn[*]:-—}"
}
stan_listy() { # stan_listy <plik tsv> <nazwa>
  awk -F'\t' -v n="$2" '$1 == n { print $2; f = 1 } END { if (!f) print "—" }' "$1"
}

n_mig=0 n_mig_flag=0 n_krok=0 n_pak=0 n_latka_zle=0

while IFS=$'\t' read -r st plik; do
  [[ $st == A ]] || continue
  m=${plik#migrations/}
  z=$(zaleznosci "$NOWY_SHA" "$plik")
  printf 'migracja\t%s\t%s\t%s\n' "$m" "$z" "$(stan_listy "$PORT/port/share/void/migracje.tsv" "$m")"
  n_mig=$((n_mig + 1))
  [[ $z == "—" || $z == pakiety || $z == sudo || $z == pakiety,sudo ]] || n_mig_flag=$((n_mig_flag + 1))
done < <(git -C "$SRC" diff --name-status --no-renames "$STARY" "$NOWY_SHA" -- migrations/)

while IFS=$'\t' read -r st plik; do
  [[ $plik == install/*.sh ]] || continue
  k=${plik#install/}
  z=$(zaleznosci "$NOWY_SHA" "$plik")
  printf 'krok\t%s\t%s %s\t%s\n' "$k" "$st" "$z" "$(stan_listy "$PORT/port/share/void/kroki.tsv" "$k")"
  n_krok=$((n_krok + 1))
done < <(git -C "$SRC" diff --name-status --no-renames "$STARY" "$NOWY_SHA" -- install/)

pakiety() { git -C "$SRC" show "$1:install/omarchy-base.packages" 2>/dev/null | grep -v '^\s*#' | sed '/^\s*$/d;s/\s.*//' | LC_ALL=C sort -u; }
while IFS= read -r linia; do
  znak=${linia:0:1} p=${linia:1}
  printf 'pakiet\t%s\t%s\t%s\n' "$p" "$znak" "$(stan_listy "$PORT/dane/mapa-pakietow-void.tsv" "$p")"
  n_pak=$((n_pak + 1))
done < <(diff <(pakiety "$STARY") <(pakiety "$NOWY_SHA") | sed -n 's/^< /-/p; s/^> /+/p')

d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
git -C "$SRC" archive "$NOWY_SHA" shell | tar -x -C "$d"
for l in "$PORT"/port/share/latki/*.patch; do
  [[ -e $l ]] || continue
  if git -C "$d" apply --check -R -p1 "$l" 2>/dev/null; then w="już w wydaniu — do usunięcia"
  elif git -C "$d" apply --check -p1 "$l" 2>/dev/null; then w="pasuje"
  else w="nie pasuje — przejrzeć"; n_latka_zle=$((n_latka_zle + 1)); fi
  printf 'łatka\t%s\t%s\n' "${l##*/}" "$w"
done

{
  echo
  echo "Omarchy $STARY → $NOWY ($NOWY_SHA)"
  echo "  nowe migracje: $n_mig, z zależnościami od Archa/systemd (poza pakiety/sudo): $n_mig_flag"
  echo "  kroki install/ zmienione: $n_krok — kroki z kroki.tsv: podmiany przejrzeć ze zmianą upstreamu"
  echo "  zmiany listy pakietów: $n_pak — brak w mapie Voida = dopisać do dane/mapa-pakietow-void.tsv"
  echo "  łatki do przejrzenia: $n_latka_zle"
  echo "Dalej: migracje.tsv / kroki.tsv / mapa, upstream.env, test w VM (orkiestrator --update + omarchy-update)."
} >&2
