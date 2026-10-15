#!/usr/bin/env bash
# omarchy-port#7: branding Voida (decyzja 7 w szoniu/dotfiles#169) — logo dystrybucji tam, gdzie Omarchy
# pokazuje swoje; teksty UI zostają przy Omarchy. Jako root, z install-layer.sh, po każdym wypakowaniu
# plików Omarchy (etap 3 orkiestratora kładzie oryginały od nowa). Menu i przycisk paska to łatki
# share/void/latki. Grafiki powstają tu z void-artwork (na liście pakietów portu), w repo nie ma logo:
#   ekran logowania SDDM — void-logo.svg z białym napisem i obrysami w kolorze tła motywu → logo.png
#       motywu i jego wzorzec w drzewie Omarchy (omarchy-refresh-sddm odtwarza motyw z wzorca, więc
#       daje Voida; Style → Unlock → default pada na Voidzie wcześniej, na plymouth/mkinitcpio).
#       Logo motywu ustawione przez użytkownika (omarchy plymouth set) zostaje przy samodzielnym
#       uruchomieniu warstwy; aktualizacja kładzie motyw od nowa (etap 3), tak jak pacman na Archu;
#   About i fastfetch — void-logo-notext.svg → ASCII 54×26, jak omarchy-branding-about image;
#   wygaszacz — same litery VOID z void-logo.svg → ASCII, jak omarchy-branding-screensaver image.
#   ASCII w trybie block (pełne bloki), jak domyślne icon.txt i logo.txt Omarchy — braille, domyślny
#   w omarchy-transcode-ascii, wychodzi w oknie About blado.
# ASCII trafia do icon.txt i logo.txt Omarchy (Style → About/Screensaver → Restore Default) oraz do
# /etc/skel (nowe konta; etap 6 orkiestratora kopiuje skel po warstwie). Konta sprzed brandingu dostają
# logo przez migrację portu (share/void/migracje-portu). Założenia o plikach Omarchy (cele, tło motywu,
# tryb block) sprawdza bramka podbicia (prototyp/bramka/podbicie.sh, wiersze „branding”).
# Kod 1 = któryś element nie przeszedł (reszta nałożona); install-layer.sh przekazuje to orkiestratorowi.
set -euo pipefail
O=/usr/share/omarchy
ART=/usr/share/icons/hicolor/scalable/apps
SDDM_TLO='#1a1b26'   # tło motywu SDDM Omarchy (default/sddm/omarchy/Main.qml)
SDDM_PX=320          # bok logo; napis OMARCHY w motywie ma 800×188

bledy=0
blad() { echo "branding: BŁĄD — $*" >&2; bledy=$((bledy + 1)); }

for f in "$ART/void-logo.svg" "$ART/void-logo-notext.svg"; do
  [[ -f $f ]] || { echo "branding: brak $f (pakiet void-artwork)" >&2; exit 1; }
done
command -v magick >/dev/null || { echo "branding: brak magick (ImageMagick)" >&2; exit 1; }
[[ -x $O/bin/omarchy-transcode-ascii ]] || { echo "branding: brak $O/bin/omarchy-transcode-ascii" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Upstreamowe polecenie z menu Style. Tryb block składa gotowe znaki UTF-8 i daje ten sam wynik w każdym
# locale; C.UTF-8 chroni tryb braille, który w locale C (orkiestrator jako root przez SSH nie ma LANG)
# wychodzi z printf %c gawka jako pojedyncze bajty — gdyby ktoś do niego wrócił.
ascii() { # ascii <obraz> <wyjście> [opcje omarchy-transcode-ascii]
  LC_ALL=C.UTF-8 OMARCHY_PATH=$O PATH="$O/bin:$PATH" omarchy-transcode-ascii "$@" --mode block >/dev/null
}

wstaw() { # wstaw <plik> <cel>… — tylko istniejące cele: brak = Omarchy przeniosło plik (sprawdzić po podbiciu)
  local src=$1 cel
  shift
  for cel; do
    if [[ -f $cel ]]; then
      install -m 644 "$src" "$cel"
      echo "branding: $cel"
    else
      blad "brak $cel w tej wersji Omarchy"
    fi
  done
}

# Ekran logowania. W void-logo.svg napis jest czarny, a części logo mają białe obrysy, które oddzielają
# je od siebie — na ciemnym tle motywu napis biały, a obrysy w kolorze tła.
sed -e 's/fill:rgb(0%,0%,0%)/fill:rgb(100%,100%,100%)/g' -e "s/stroke:rgb(100%,100%,100%)/stroke:$SDDM_TLO/g" \
  "$ART/void-logo.svg" >"$tmp/sddm.svg"
if ! /usr/bin/grep -q 'fill:rgb(100%,100%,100%)' "$tmp/sddm.svg" || ! /usr/bin/grep -qF "stroke:$SDDM_TLO" "$tmp/sddm.svg"; then
  blad "void-logo.svg ma inną budowę niż w void-artwork-20221013 (czarny napis, białe obrysy) — logo SDDM bez zmian"
elif ! magick -background none -density 300 "$tmp/sddm.svg" -resize "${SDDM_PX}x$SDDM_PX" -strip "PNG32:$tmp/sddm.png"; then
  blad "magick nie wyrenderował void-logo.svg — logo SDDM bez zmian"
else
  WZOR=$O/default/sddm/omarchy/logo.png
  MOTYW=/usr/share/sddm/themes/omarchy/logo.png
  if [[ ! -f $WZOR || ! -f $MOTYW ]]; then
    blad "brak $WZOR albo $MOTYW w tej wersji Omarchy"
  else
    # motyw równy wzorcowi = logo domyślne (świeżo wypakowane albo nasze z poprzedniego przebiegu)
    if cmp -s "$MOTYW" "$WZOR"; then
      install -m 644 "$tmp/sddm.png" "$MOTYW"
      echo "branding: $MOTYW"
    else
      echo "branding: $MOTYW ustawione przez użytkownika (omarchy plymouth set) — zostaje do aktualizacji"
    fi
    install -m 644 "$tmp/sddm.png" "$WZOR"
    echo "branding: $WZOR"
  fi
fi

# About i fastfetch: sam pierścień — napis nachodzi na pierścień i w ASCII zlewa się z nim w plamę.
if ascii "$ART/void-logo-notext.svg" "$tmp/about.txt" --width 54 --height 26; then
  wstaw "$tmp/about.txt" "$O/icon.txt" /etc/skel/.config/omarchy/branding/about.txt
else
  blad "omarchy-transcode-ascii nie przerobił void-logo-notext.svg — About bez zmian"
fi

# Wygaszacz: napis, jak OMARCHY w Omarchy — z void-logo.svg zostają ścieżki liter (czarne, bez obrysu).
awk '/<path/ { if ($0 ~ /stroke:none/ && $0 ~ /fill:rgb\(0%,0%,0%\)/) print; next } { print }' \
  "$ART/void-logo.svg" >"$tmp/napis.svg"
if ! /usr/bin/grep -q '<path' "$tmp/napis.svg"; then
  blad "void-logo.svg bez czarnych liter bez obrysu — wygaszacz bez zmian"
elif ascii "$tmp/napis.svg" "$tmp/screensaver.txt"; then
  wstaw "$tmp/screensaver.txt" "$O/logo.txt" /etc/skel/.config/omarchy/branding/screensaver.txt
else
  blad "omarchy-transcode-ascii nie przerobił napisu VOID — wygaszacz bez zmian"
fi

(( bledy == 0 ))
