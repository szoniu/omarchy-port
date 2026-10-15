#!/usr/bin/env bash
# omarchy-port: pełne Omarchy na Voidzie (glibc, x86_64, runit) albo Gentoo (amd64, systemd) —
# orkiestrator. Jako root, na DZIAŁAJĄCYM systemie z siecią, gitem i istniejącym użytkownikiem (taki
# stan zostawia instalator szoniu/void albo szoniu/gentoo + git). Idempotentny: ponowne uruchomienie
# dociąga to, czego brakuje. Część zależna od dystrybucji i initu: share/<dystrybucja>/backend.sh
# i share/init/<init>.sh (rozpoznanie: share/system.sh); reszta etapów jest wspólna.
#   port/install.sh --user NAZWA [--name "Imię Nazwisko"] [--email adres]
#   port/install.sh --update
# --name/--email: tożsamość dla gita i XCompose (na ISO Omarchy pyta o nie instalator); domyślnie
# imię z pola GECOS konta, e-mail pusty.
# --update: ścieżka aktualizacji (woła ją omarchy-update przez omarchy-port-update po `git pull`
# w /opt/omarchy-port) — etapy 1–5 przy pinie z tej wersji portu, z usunięciem plików poprzedniej
# wersji Omarchy; etapy 6–9 (dom, kroki install/, provision-user, usługi) są tylko przy instalacji
# — zmiany po instalacji niosą migracje Omarchy (omarchy-migrate jako użytkownik, po tym skrypcie).
# Port do aktualizacji: klon /opt/omarchy-port (instalacja go zakłada, gdy go nie ma).
#
# Etapy:
#   1. repozytoria — Void: nonfree + blackhole (Hyprland), klucz blackhole przypięty (share/void/xbps-keys);
#      Gentoo: GURU + hyproverlay, keywordy/USE/licencje per atom (share/gentoo/portage)
#   2. pakiety: pełna aktualizacja systemu i dane/pakiety-<dystrybucja>.txt (lista Omarchy zmapowana);
#      sshd przeładowany, gdy aktualizacja podmieniła openssh pod działającą usługą
#   3. pliki Omarchy: upstreamowe package() z omarchy-pkgs przy przypiętym commicie (share/upstream.env),
#      także pakietów w stanie „port” z mapy (bez odpowiednika w repo dystrybucji: ufw-docker, na Gentoo
#      też gum, mise, …) — PKGBUILD z share/pakiety albo omarchy-pkgs, źródła sprawdzone jego sumami;
#      zmienione przez admina pliki z backup=() PKGBUILD-a zostają, nowa wersja obok jako .omarchy-new;
#      pliki poprzedniej wersji, których nowa nie ma, znikają (zmienione przez admina → .omarchy-save);
#      przeładowania działającego Hyprlanda wstrzymane na czas podmiany (jak hooki libalpm Omarchy)
#   4. post_install omarchy-settings wybiórczo (bez os-release i nsswitch.conf)
#   5. warstwa zgodności: install-layer.sh (z łatkami i brandingiem dystrybucji)
#   6. dom użytkownika z /etc/skel — tylko przy pierwszej instalacji, jako użytkownik
#   7. kroki install/ jako root, pojedynczo; pominięcia i podmiany: share/<dystrybucja>/kroki.tsv; przed
#      config/firewall.sh włączony sshd dostaje regułę z Setup > Security > SSH (ufw limit 22/tcp)
#   8. omarchy-provision-user jako użytkownik, na tym samym drzewie kroków — tylko dopóki nie przeszło
#   9. usługi bazowe initu (runit: dbus, polkitd, chronyd; systemd: timesyncd); dhcpcd wyłączony,
#      gdy sieć przejmuje NetworkManager;
#      SDDM dostaje ostatniego użytkownika (motyw Omarchy nie ma pola użytkownika)
# Usługi włączane w trakcie (krok enable-services i etap 9) NIE startują od razu — wstają przy
# następnym starcie systemu (na runit: shim systemctl w trybie OMARCHY_PORT_INSTALL).
# Przy --update etapy 6–9 nie idą, z jednym wyjątkiem: instalacja sprzed omarchy-port#8 (krok
# config/firewall.sh pominięty) dostaje firewall raz — ufw rusza przy następnym starcie systemu.
#
# Logi: /var/log/omarchy-port/install-<czas>/ albo update-<czas>/ (całość, log per krok, kroki.tsv).
# Kod wyjścia: 0 — wszystko przeszło (pominięcia z kroki.tsv to nie błąd); 1 — któryś krok padł
# (lista w podsumowaniu, reszta jest doinstalowana); 2 — przerwane (zły stan wejściowy albo etap,
# bez którego dalsze nie mają sensu) — każde inne przerwanie też kończy się kodem 2.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SRC="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SRC/.." && pwd)"
STATE=/var/lib/omarchy-port
CACHE=/var/cache/omarchy-port
OV=/usr/share/omarchy-port/install   # drzewo install/ Omarchy z pominięciami i podmianami portu
PORT_DIR=/opt/omarchy-port           # klon portu, z którego omarchy-update bierze nowe wersje
PORT_URL=https://github.com/szoniu/omarchy-port.git
LOGDIR=

die() { echo "install.sh: $*" >&2; exit 2; }

U='' IMIE='' EMAIL='' imie_podane=0 AKTUALIZACJA=0
while (($#)); do
  case $1 in
    --user) [[ $# -ge 2 ]] || die "--user wymaga nazwy"; U=$2; shift 2 ;;
    --name) [[ $# -ge 2 ]] || die "--name wymaga wartości"; IMIE=$2; imie_podane=1; shift 2 ;;
    --email) [[ $# -ge 2 ]] || die "--email wymaga wartości"; EMAIL=$2; shift 2 ;;
    --update) AKTUALIZACJA=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "nieznana opcja: $1 (użycie: install.sh --user NAZWA [--name …] [--email …] | install.sh --update)" ;;
  esac
done
if ((AKTUALIZACJA)); then
  [[ -z $U$IMIE$EMAIL ]] || die "--update nie przyjmuje --user/--name/--email (użytkownika ma już instalacja)"
fi

# Każde wyjście, które nie przeszło przez podsumowanie, to przerwanie — kod 2, nie kod polecenia,
# które padło (1 znaczy „krok padł, reszta doinstalowana”, a tu dalsze etapy w ogóle nie poszły).
KONIEC=0
STRAZNIK=/usr/bin/omarchy-hyprland-reload-guard
wstrzymane=0   # przeładowania Hyprlanda wstrzymane na czas etapu 3 — przerwanie musi je wznowić
# Etap 3 kładzie surowe pliki Omarchy: linki /usr/share/omarchy/bin na wersje z pacmanem, migracje bez
# zaślepek portu. Przerwanie przed etapem 5 zostawiłoby menu Update i powiadomienie o migracjach
# wskazujące na nie — pułapka nakłada wtedy warstwę jeszcze raz.
wypakowywanie=0 warstwa_ok=0
koniec() {
  local rc=$?
  if ((wstrzymane)); then "$STRAZNIK" resume || true; fi
  if ((wypakowywanie && !warstwa_ok)); then
    echo "install.sh: przerwane w trakcie podmiany plików Omarchy — nakładam warstwę portu ponownie" >&2
    bash "$SRC/install-layer.sh" >"${LOGDIR:-/tmp}/warstwa-po-przerwaniu.log" 2>&1 ||
      echo "install.sh: UWAGA — warstwa się nie nałożyła (${LOGDIR:-/tmp}/warstwa-po-przerwaniu.log); uruchom port/install-layer.sh" >&2
  fi
  ((KONIEC)) && exit "$rc"
  ((rc == 2)) || echo "install.sh: przerwane (rc=$rc) — przyczyna wyżej${LOGDIR:+; log: $LOGDIR}" >&2
  exit 2
}
trap koniec EXIT

(( EUID == 0 )) || die "uruchom jako root"
# shellcheck source=share/system.sh
source "$SRC/share/system.sh"
wykryj_system || die "przerwane — powód wyżej"
DYST="$SRC/share/$DYSTR"
# shellcheck source=share/void/backend.sh
source "$DYST/backend.sh"
# shellcheck source=share/init/runit.sh
source "$SRC/share/init/$INIT.sh"
dyst_sprawdz
if ((AKTUALIZACJA)); then
  [[ -e $STATE/wersja-omarchy ]] || die "--update: brak instalacji portu ($STATE/wersja-omarchy) — najpierw install.sh --user NAZWA"
else
  [[ -n $U && $U != root ]] || die "podaj użytkownika: --user NAZWA (nie root)"
  getent passwd "$U" >/dev/null || die "użytkownik $U nie istnieje — port go nie zakłada (to robota instalatora)"
  H=$(getent passwd "$U" | cut -d: -f6)
  (( $(id -u "$U") >= 1000 )) || die "$U to konto systemowe (UID < 1000)"
  [[ $H == /?* && -d $H && $(stat -c %U "$H") == "$U" ]] ||
    die "katalog domowy $U (${H:-pusty}) nie istnieje albo nie należy do $U"
  ((imie_podane)) || IMIE=$(getent passwd "$U" | cut -d: -f5 | cut -d, -f1)
fi
command -v git >/dev/null || die "brak gita — zainstaluj go menedżerem pakietów dystrybucji"

# shellcheck source=share/upstream.env
source "$SRC/share/upstream.env"
git ls-remote "$OMARCHY_URL" HEAD >/dev/null 2>&1 ||
  die "brak dostępu do $OMARCHY_URL — sieć potrzebna do pobrania Omarchy"

install -d -m 755 "$STATE" "$CACHE"
exec 9>"$STATE/install.lock"
flock -n 9 || die "orkiestrator już działa ($STATE/install.lock)"

if ((AKTUALIZACJA)); then TRYB=update; else TRYB=install; fi
LOGDIR=/var/log/omarchy-port/$TRYB-$(date +%Y%m%d-%H%M%S)
mkdir -p "$LOGDIR/kroki"
exec > >(tee -a "$LOGDIR/$TRYB.log") 2>&1

WYNIKI="$LOGDIR/kroki.tsv"
printf 'krok\tkto\twynik\tszczegóły\n' >"$WYNIKI"
BLEDY=0
etap() { printf '\n=== %s ===\n' "$*"; }
wynik() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$WYNIKI"; }

if ((AKTUALIZACJA)); then
  echo "omarchy-port: aktualizacja do Omarchy $OMARCHY_TAG (było: $(cut -d' ' -f1 "$STATE/wersja-omarchy")) — log: $LOGDIR"
else
  echo "omarchy-port: Omarchy $OMARCHY_TAG dla użytkownika $U — log: $LOGDIR"
fi

# ---------------------------------------------------------------------------------------------
etap "1/9 repozytoria"
dyst_repozytoria

# ---------------------------------------------------------------------------------------------
etap "2/9 pakiety"
mapfile -t PAKIETY < <(grep -v '^#' "$REPO/dane/pakiety-$DYSTR.txt" | tr -s ' ' '\n' | sed '/^$/d')
echo "pakietów na liście: ${#PAKIETY[@]}"
dyst_pakiety "${PAKIETY[@]}"
# OpenSSH ≥ 9.8 przy każdym połączeniu uruchamia sshd-session z dysku: po aktualizacji openssh nowy
# nie dogada się ze starym, działającym sshd i nowe połączenia SSH padają aż do restartu systemu.
# Przeładowanie (share/init) dotyczy tylko nasłuchującego sshd — trwające sesje zostają.
sshd_pid=$(init_pid sshd) || sshd_pid=
if [[ -n $sshd_pid && $(readlink "/proc/$sshd_pid/exe" 2>/dev/null) == *' (deleted)' ]]; then
  if init_przeladuj_sshd; then
    echo "sshd: przeładowany — openssh zaktualizowany pod działającą usługą"
  else
    echo "UWAGA: przeładowanie sshd nie powiodło się — nowe połączenia SSH mogą padać do restartu systemu"
  fi
fi

# ---------------------------------------------------------------------------------------------
etap "3/9 pliki Omarchy $OMARCHY_TAG"
pobierz() { # pobierz <url> <katalog> <commit> — płytki klon dokładnie tego commita
  local url=$1 dir=$2 sha=$3
  if [[ $(git -C "$dir" rev-parse HEAD 2>/dev/null) != "$sha" || -n $(git -C "$dir" status --porcelain 2>/dev/null) ]]; then
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 "$url" "$sha"
    git -C "$dir" checkout -q FETCH_HEAD
  fi
  [[ $(git -C "$dir" rev-parse HEAD) == "$sha" ]] || die "$url: oczekiwany commit $sha"
}
pobierz "$OMARCHY_PKGS_URL" "$CACHE/omarchy-pkgs" "$OMARCHY_PKGS_COMMIT"
pobierz "$OMARCHY_URL" "$CACHE/src/omarchy" "$OMARCHY_COMMIT"
# Tag lekki ma tylko wpis refs/tags/X, tag z adnotacją dodatkowo X^{} (dopiero to jest commit).
tagi=$(git ls-remote "$OMARCHY_URL" "refs/tags/$OMARCHY_TAG" "refs/tags/$OMARCHY_TAG^{}") || true
tag=$(awk -v t="refs/tags/$OMARCHY_TAG" '$2 == t "^{}" { p = $1 } $2 == t { l = $1 } END { print (p != "" ? p : l) }' <<<"$tagi")
[[ $tag == "$OMARCHY_COMMIT" ]] || echo "UWAGA: tag $OMARCHY_TAG wskazuje dziś na ${tag:-nic}, a przypięty commit to $OMARCHY_COMMIT (instaluję przypięty)"
for p in omarchy omarchy-settings; do
  c=$(sed -n "s/^_commit='\(.*\)'$/\1/p" "$CACHE/omarchy-pkgs/pkgbuilds/$p/PKGBUILD")
  [[ $c == "$OMARCHY_COMMIT" ]] || die "PKGBUILD $p ma _commit=$c, a upstream.env $OMARCHY_COMMIT — popraw upstream.env"
done
# Wersja pakietu omarchy w formacie `pacman -Q` ([epoch:]pkgver-pkgrel) dla nakładki omarchy-version
# (fastfetch: „Omarchy 4.0.4-2”, jak na Archu). Czytana przed zmianami na dysku; to dane kosmetyczne,
# więc nieczytelna wersja to UWAGA, a nie przerwanie.
WERSJA_PAKIETU=$(bash -c 'cd "$1"; source ./PKGBUILD >/dev/null 2>&1; echo "${epoch:+$epoch:}$pkgver-$pkgrel"' \
  bash "$CACHE/omarchy-pkgs/pkgbuilds/omarchy")
if [[ ! $WERSJA_PAKIETU =~ ^([0-9]+:)?[0-9A-Za-z._+~]+-[0-9]+(\.[0-9]+)?$ ]]; then
  echo "UWAGA: PKGBUILD omarchy — nieczytelna wersja ($WERSJA_PAKIETU); omarchy-version pokaże sam tag"
  WERSJA_PAKIETU=
fi
# Listy pominięć i podmian muszą pasować do TEJ wersji Omarchy — sprawdzane na źródle, zanim cokolwiek
# na dysku się zmieni (po podbiciu pinu niepasująca lista przerywa przed podmianą plików).
lista_pasuje() { # lista_pasuje <plik .tsv> <katalog w źródle Omarchy> <katalog podmian portu>
  local tsv=$1 kat=$2 podm=$3 nazwa akcja powod
  while IFS=$'\t' read -r nazwa akcja powod; do
    [[ -z $nazwa || $nazwa == \#* ]] && continue
    [[ -f $CACHE/src/omarchy/$kat/$nazwa ]] ||
      die "${tsv##*/}: $kat/$nazwa nie istnieje w Omarchy $OMARCHY_TAG — przejrzyj listę po zmianie wersji"
    case $akcja in
      pomiń) [[ -n $powod ]] || die "${tsv##*/}: $nazwa bez powodu pominięcia" ;;
      podmień) [[ -f $podm/$nazwa ]] || die "${tsv##*/}: brak podmiany $podm/$nazwa" ;;
      *) die "${tsv##*/}: nieznana akcja '$akcja' dla $nazwa" ;;
    esac
  done <"$tsv"
}
lista_pasuje "$DYST/kroki.tsv" install "$DYST/kroki"
lista_pasuje "$DYST/migracje.tsv" migrations "$DYST/migracje"
# Krok firewalla port obsługuje po nazwie (krok_firewall: reguła SSH przed nim, raz przy aktualizacji) —
# po zmianie nazwy albo wypadnięciu z config/all.sh szedłby jako zwykły krok bez reguły SSH albo wcale.
grep -qxF 'run_logged "$OMARCHY_INSTALL/config/firewall.sh"' "$CACHE/src/omarchy/install/config/all.sh" ||
  die "install/config/all.sh w Omarchy $OMARCHY_TAG nie woła już config/firewall.sh — przejrzyj krok_firewall (omarchy-port#8)"

# Pakiety budowane przez package() bez makepkg: omarchy i omarchy-settings ze źródeł Omarchy przy
# przypiętym commicie ($CACHE/src), a pakiety w stanie „port” z mapy dystrybucji (bez odpowiednika w jej
# repo: ufw-docker dla config/firewall.sh — omarchy-port#8, na Gentoo też gum, mise, …) ze źródeł z ich
# PKGBUILD-a — z share/pakiety/<nazwa> portu, inaczej z omarchy-pkgs przy przypiętym commicie —
# sprawdzonych jego sumami (b2sums albo sha256sums, także warianty _x86_64 jak w makepkg).
mapfile -t PAKIETY_PORTU < <(awk -F'\t' 'NR > 1 && $2 == "port" { print $1 }' "$REPO/dane/mapa-pakietow-$DYSTR.tsv")
PAKIETY_UPSTREAM=(omarchy-settings omarchy "${PAKIETY_PORTU[@]}")
declare -A ZRODLA=([omarchy-settings]="$CACHE/src" [omarchy]="$CACHE/src")
katalog_pkgbuild() { # katalog_pkgbuild <pakiet> — PKGBUILD portu ma pierwszeństwo przed omarchy-pkgs
  if [[ -f $SRC/share/pakiety/$1/PKGBUILD ]]; then
    echo "$SRC/share/pakiety/$1"
  else
    echo "$CACHE/omarchy-pkgs/pkgbuilds/$1"
  fi
}
zrodla() { # zrodla <pakiet> — source= i sumy z PKGBUILD-a, jak makepkg; wynik w ZRODLA[<pakiet>]
  local p=$1 pb dl="$CACHE/pobrane/$1" sd="$CACHE/zrodla/$1"
  local i s nazwa url plik typ wartosc alg='' wzor
  local -a src=() sumy=()
  pb=$(katalog_pkgbuild "$p")
  [[ -f $pb/PKGBUILD ]] || die "brak PKGBUILD-a $p (share/pakiety portu ani omarchy-pkgs $OMARCHY_PKGS_COMMIT) — popraw mapę pakietów"
  # jedno wczytanie PKGBUILD-a: S<tab>źródło, B|H<tab>suma b2sum|sha256 (pusta tablica = brak wierszy)
  while IFS=$'\t' read -r typ wartosc; do
    case $typ in
      S) src+=("$wartosc") ;;
      B | H) sumy+=("$wartosc"); alg=$typ ;;
    esac
  done < <(bash -c 'CARCH=x86_64; cd "$1" && source ./PKGBUILD >/dev/null 2>&1 || exit
    for s in "${source[@]}" "${source_x86_64[@]}"; do printf "S\t%s\n" "$s"; done
    if (( ${#b2sums[@]} + ${#b2sums_x86_64[@]} )); then
      for s in "${b2sums[@]}" "${b2sums_x86_64[@]}"; do printf "B\t%s\n" "$s"; done
    else
      for s in "${sha256sums[@]}" "${sha256sums_x86_64[@]}"; do printf "H\t%s\n" "$s"; done
    fi' bash "$pb")
  (( ${#src[@]} > 0 && ${#src[@]} == ${#sumy[@]} )) ||
    die "PKGBUILD $p: źródła (${#src[@]}) i sumy b2sums/sha256sums (${#sumy[@]}) nie do pary — port instaluje tylko źródła z sumą"
  if [[ $alg == B ]]; then wzor='^[0-9a-f]{128}$'; else wzor='^[0-9a-f]{64}$'; fi
  suma() { if [[ $alg == B ]]; then b2sum <"$1"; else sha256sum <"$1"; fi | cut -d' ' -f1; }
  rm -rf "$sd"
  mkdir -p "$sd" "$dl"
  for i in "${!src[@]}"; do
    s=${src[i]}
    if [[ $s == *::* ]]; then nazwa=${s%%::*} url=${s#*::}; else nazwa=${s##*/} url=$s; fi
    [[ ${sumy[i]} =~ $wzor ]] || die "PKGBUILD $p: $nazwa bez sumy (${sumy[i]})"
    case $url in
      https://*)
        plik="$dl/$nazwa"
        if [[ ! -f $plik || $(suma "$plik") != "${sumy[i]}" ]]; then
          curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 -o "$plik.part" "$url" ||
            die "PKGBUILD $p: pobranie $url nie powiodło się"
          mv -f "$plik.part" "$plik"
        fi ;;
      *://*) die "PKGBUILD $p: źródło $url — port obsługuje tylko https:// i pliki obok PKGBUILD-a" ;;
      *) plik="$pb/$url" ;;
    esac
    [[ $(suma "$plik") == "${sumy[i]}" ]] ||
      die "PKGBUILD $p: $nazwa ma inną sumę niż w PKGBUILD-zie ($plik)"
    case $nazwa in
      *.tar|*.tar.*|*.tgz) tar -xf "$plik" -C "$sd" --no-same-owner ;;
      *) ln -s "$plik" "$sd/$nazwa" ;;
    esac
  done
  ZRODLA[$p]=$sd
  echo "$p: źródła zgodne z sumami z PKGBUILD-a (${#src[@]})"
}
for p in "${PAKIETY_UPSTREAM[@]}"; do
  [[ -n ${ZRODLA[$p]:-} ]] || zrodla "$p"
done

# Ścieżki należące do pakietów dystrybucji — raz, z bazy menedżera pakietów (share/<dystrybucja>/backend.sh).
dyst_pliki_pakietow >"$CACHE/pliki-dystrybucji.txt"

# Żywy Hyprland przeładowuje config przy każdej zmianie w /usr/share/omarchy/default/hypr/, a podmiana
# tych plików pod działającą sesją ją wywraca (przy rerunie w sesji: awaria, start w trybie awaryjnym).
# Na Archu pauzę i wznowienie robią hooki libalpm omarchy-settings — tu ten sam strażnik, wprost.
# Strażnik jest z poprzedniej instalacji; przy pierwszej nie ma ani jego, ani sesji Hyprlanda.
if [[ -x $STRAZNIK ]]; then
  if "$STRAZNIK" pause; then
    wstrzymane=1
    echo "Hyprland: przeładowania wstrzymane na czas podmiany plików"
  else
    echo "UWAGA: $STRAZNIK pause nie powiódł się — działająca sesja Hyprlanda może paść przy podmianie configu"
  fi
fi

# Kolejność jak w pacmanie: najpierw budowa i sprawdzenia wszystkich pakietów (bez zmian na dysku), potem
# usunięcie plików poprzedniej wersji, na końcu wypakowanie. Stan poprzedniej wersji (wszystkie pakiety
# razem — plik może przejść z jednego do drugiego) zostaje w $STATE aż do pełnego przebiegu: przerwanie
# po wypakowaniu części nie gubi plików do usunięcia przy ponownej próbie.
POPRZ_MANIFEST="$STATE/manifest-poprzedni.txt"
POPRZ_SUMY="$STATE/kopie-poprzednie.sums"
# Z WSZYSTKICH manifestów w $STATE, nie tylko z bieżącej listy: pakiet, który wypadł ze stanu „port”
# (np. gum dostępny już w repo dystrybucji), ma pliki do usunięcia, a jego manifest — do skasowania.
if [[ ! -f $POPRZ_MANIFEST ]]; then
  for m in "$STATE"/manifest-*.txt; do
    if [[ -f $m && $m != "$POPRZ_MANIFEST" ]]; then cat "$m"; fi
  done | LC_ALL=C sort -u >"$POPRZ_MANIFEST.tmp"
  for m in "$STATE"/kopie-*.sums; do
    if [[ -f $m && $m != "$POPRZ_SUMY" ]]; then cat "$m"; fi
  done >"$POPRZ_SUMY.tmp"
  mv "$POPRZ_SUMY.tmp" "$POPRZ_SUMY"
  mv "$POPRZ_MANIFEST.tmp" "$POPRZ_MANIFEST"
fi

for p in "${PAKIETY_UPSTREAM[@]}"; do
  st="$CACHE/stage/$p"
  rm -rf "$st"
  mkdir -p "$st"
  # Osobny proces bash: `set -e` w podpowłoce wołanej w warunku (|| / if) bash po cichu ignoruje.
  bash -e -c 'CARCH=x86_64 srcdir=$1 pkgdir=$2; cd "$3"; source ./PKGBUILD; package' \
    bash "${ZRODLA[$p]}" "$st" "$(katalog_pkgbuild "$p")" >"$LOGDIR/package-$p.log" 2>&1 ||
    die "package() $p padło — $LOGDIR/package-$p.log"
  # Hooki libalpm są dla pacmana — pauzę przeładowań Hyprlanda port robi sam (wyżej).
  (cd "$st" && find . ! -type d ! -path './usr/share/libalpm/*' | sed 's|^\.||' | LC_ALL=C sort) >"$CACHE/manifest-$p.new"
  # Plik, który już jest na dysku, a nie pochodzi z poprzedniej instalacji portu, może należeć do
  # pakietu dystrybucji — takiego nie nadpisujemy po cichu.
  konflikty=()
  while IFS= read -r f; do
    if [[ -e $f || -L $f ]]; then konflikty+=("$f ($(dyst_wlasciciel "$f"))"); fi
  done < <(LC_ALL=C comm -23 "$CACHE/manifest-$p.new" "$POPRZ_MANIFEST" | LC_ALL=C comm -12 - "$CACHE/pliki-dystrybucji.txt")
  (( ${#konflikty[@]} == 0 )) || die "$p nadpisałby pliki pakietów dystrybucji: ${konflikty[*]}"

  # backup=() z PKGBUILD-a jak w pacmanie: plik zmieniony przez admina (albo istniejący wcześniej,
  # nie nasz) zostaje, nowa wersja obok jako .omarchy-new; niezmieniony — nadpisujemy nowszą.
  mapfile -t KOPIE < <(bash -c 'CARCH=x86_64; cd "$1"; source ./PKGBUILD >/dev/null 2>&1; for b in "${backup[@]}"; do echo "/$b"; done' \
    bash "$(katalog_pkgbuild "$p")")
  wyklucz="$CACHE/wyklucz-$p.txt"
  : >"$wyklucz"
  : >"$CACHE/kopie-$p.new"
  for f in "${KOPIE[@]}"; do
    [[ -f $st$f ]] || continue
    nowa=$(sha256sum <"$st$f" | cut -d' ' -f1)
    echo "$nowa $f" >>"$CACHE/kopie-$p.new"
    [[ -f $f ]] || continue
    dysk=$(sha256sum <"$f" | cut -d' ' -f1)
    [[ $dysk == "$nowa" ]] && continue
    stara=$(awk -v f="$f" '$2 == f { print $1 }' "$POPRZ_SUMY")
    [[ -n $stara && $dysk == "$stara" ]] && continue
    cp -p "$st$f" "$f.omarchy-new"
    echo ".$f" >>"$wyklucz"
    echo "  zachowany zmieniony $f — nowa wersja: $f.omarchy-new"
    wynik "$f" root "zachowany" "zmieniony przez admina; wersja Omarchy w $f.omarchy-new"
  done
done

# Pliki poprzedniej wersji, których nowa nie ma — pacman usuwa je przy aktualizacji pakietu, przed
# wypakowaniem nowej (ścieżka może zmienić się z pliku w katalog i odwrotnie). Plik z backup=()
# zmieniony przez admina zostaje jako .omarchy-save (jak .pacsave); plik, który należy dziś do pakietu
# dystrybucji, nie jest już nasz i zostaje. Od tego miejsca dysk się zmienia — przerwanie przywraca warstwę.
wypakowywanie=1
for p in "${PAKIETY_UPSTREAM[@]}"; do cat "$CACHE/manifest-$p.new"; done | LC_ALL=C sort -u >"$CACHE/manifest-nowy.txt"
# katalogi nowej wersji (także puste) zostają; reszta opróżnionych — tylko we własnym drzewie, bo
# gdzie indziej katalog mógł założyć pakiet dystrybucji
for p in "${PAKIETY_UPSTREAM[@]}"; do (cd "$CACHE/stage/$p" && find . -type d | sed 's|^\.||'); done |
  LC_ALL=C sort -u >"$CACHE/katalogi-nowe.txt"
usuniete=0
while IFS= read -r f; do
  [[ -e $f || -L $f ]] || continue
  [[ -d $f && ! -L $f ]] && continue   # dziś katalog (np. podmieniony ręcznie) — nie nasz plik
  stara=$(awk -v f="$f" '$2 == f { print $1 }' "$POPRZ_SUMY")
  if [[ -n $stara && -f $f && ! -L $f && $(sha256sum <"$f" | cut -d' ' -f1) != "$stara" ]]; then
    mv -f "$f" "$f.omarchy-save"
    echo "  zachowany zmieniony $f — nie ma go w $OMARCHY_TAG, kopia: $f.omarchy-save"
    wynik "$f" root zachowany "usunięty z Omarchy $OMARCHY_TAG, zmieniony przez admina — kopia w $f.omarchy-save"
    continue
  fi
  rm -f "$f"
  echo "  usunięty    $f"
  usuniete=$((usuniete + 1))
  d=${f%/*}
  while [[ $d == /usr/share/omarchy/* ]] && ! grep -qxF "$d" "$CACHE/katalogi-nowe.txt" && rmdir "$d" 2>/dev/null; do
    d=${d%/*}
  done
done < <(LC_ALL=C comm -23 "$POPRZ_MANIFEST" "$CACHE/manifest-nowy.txt" | LC_ALL=C comm -23 - "$CACHE/pliki-dystrybucji.txt")
echo "pliki poprzedniej wersji usunięte: $usuniete"

for p in "${PAKIETY_UPSTREAM[@]}"; do
  tar -C "$CACHE/stage/$p" --exclude=./usr/share/libalpm -X "$CACHE/wyklucz-$p.txt" -cf - . | tar -C / --no-overwrite-dir -xpf -
  mv "$CACHE/manifest-$p.new" "$STATE/manifest-$p.txt"
  mv "$CACHE/kopie-$p.new" "$STATE/kopie-$p.sums"
  echo "$p: $(wc -l <"$STATE/manifest-$p.txt") plików"
done
# manifesty pakietów spoza bieżącej listy — ich pliki zniknęły wyżej (albo należą już do dystrybucji)
for m in "$STATE"/manifest-*.txt; do
  [[ -f $m && $m != "$POPRZ_MANIFEST" ]] || continue
  p=${m##*/manifest-}
  p=${p%.txt}
  na_liscie=0
  for q in "${PAKIETY_UPSTREAM[@]}"; do [[ $q == "$p" ]] && na_liscie=1; done
  if (( ! na_liscie )); then
    rm -f "$m" "$STATE/kopie-$p.sums"
    echo "$p: wypadł z listy pakietów — manifest usunięty"
  fi
done
rm -f "$POPRZ_MANIFEST" "$POPRZ_SUMY"   # pełny przebieg — następna aktualizacja liczy od tej wersji
if ((wstrzymane)); then
  # resume jak hook PostTransaction: jedno `hyprctl reload` na nowych plikach, potem stare ustawienia
  "$STRAZNIK" resume || echo "UWAGA: $STRAZNIK resume nie powiódł się — auto-reload Hyprlanda może zostać wyłączony do wylogowania"
  wstrzymane=0
  echo "Hyprland: przeładowania wznowione"
fi
echo "$OMARCHY_TAG $OMARCHY_COMMIT" >"$STATE/wersja-omarchy"
# czyta go nakładka omarchy-version w sesji użytkownika — prawa jawnie, niezależnie od umaski roota
if [[ -n $WERSJA_PAKIETU ]]; then
  echo "$WERSJA_PAKIETU" >"$STATE/wersja-pakietu-omarchy"
  chmod 644 "$STATE/wersja-pakietu-omarchy"
else
  rm -f "$STATE/wersja-pakietu-omarchy"   # wersja z poprzedniego pinu byłaby fałszywa
fi

# ---------------------------------------------------------------------------------------------
etap "4/9 post_install omarchy-settings (wybiórczo)"
EO=/usr/share/omarchy/etc-overrides
install -m 644 "$EO/dot.bashrc" /etc/skel/.bashrc
echo "/etc/skel/.bashrc"
# moduły PAM: Void w /usr/lib/security, Gentoo w /lib64/security (albo /usr/lib64 po scaleniu /usr)
if compgen -G '/usr/lib/security/pam_faillock.so' >/dev/null || compgen -G '/lib*/security/pam_faillock.so' >/dev/null ||
  compgen -G '/usr/lib64/security/pam_faillock.so' >/dev/null; then
  install -m 644 "$EO/security-faillock.conf" /etc/security/faillock.conf
  echo "/etc/security/faillock.conf"
else
  echo "brak pam_faillock.so — faillock.conf pominięty"
fi
if [[ -f /etc/cups/cups-browsed.conf ]]; then
  install -m 644 "$EO/cups-cups-browsed.conf" /etc/cups/cups-browsed.conf
  echo "/etc/cups/cups-browsed.conf"
fi
echo "celowo NIE: os-release (ID_LIKE=arch myli rozpoznawanie dystrybucji), nsswitch.conf (Arch),"
echo "            plymouthd.conf (Void w porcie bez plymouth), cups-files.conf (UID-y Archa)"

# ---------------------------------------------------------------------------------------------
etap "5/9 warstwa zgodności"
# Etap 3 wypakował pliki Omarchy od nowa — łatka, której cofnięcie pasuje, jest już w samym wydaniu.
OMARCHY_PORT_SWIEZE_PLIKI=1 bash "$SRC/install-layer.sh"
warstwa_ok=1
# Łatka, która nie weszła (inna wersja Omarchy), nie może zginąć w logu warstwy: trafia do
# podsumowania i kodu wyjścia. Łatki bezpieczeństwa mają to słowo w pierwszej linii nagłówka.
for l in "$SRC"/share/latki/*.patch "$DYST"/latki/*.patch; do
  [[ -e $l ]] || continue
  git -C /usr/share/omarchy apply --check -R -p1 "$l" 2>/dev/null && continue
  wynik "${l#"$SRC"/}" root BŁĄD "nie nałożona — $(head -1 "$l")"
  echo "  BŁĄD         łatka ${l#"$SRC"/share/} nie nałożona — przejrzyj ją przy zmianie wersji Omarchy"
  BLEDY=$((BLEDY + 1))
done
# Branding dystrybucji, który nie przeszedł (warstwa zostawia plik), też trafia do podsumowania, ale jako uwaga
# bez kodu 1: kosmetyka nie zatrzymuje omarchy-update przed migracjami Omarchy (install-layer.sh).
if [[ -e $STATE/branding-blad ]]; then
  wynik "share/$DYSTR/branding.sh" root uwaga "$(cat "$STATE/branding-blad")"
  echo "  UWAGA        $(cat "$STATE/branding-blad")"
fi

uruchom_krok() { # uruchom_krok <krok> <plik> [dopisek do „ok”] — krok install/ jako root; rc kroku
  local log="$LOGDIR/kroki/${1//\//_}.log" rc=0
  timeout 1200 bash -eE -c 'source "$1"' bash "$2" </dev/null >"$log" 2>&1 || rc=$?
  if (( rc == 0 )); then
    wynik "$1" root "ok${3:-}"
    echo "  ok           $1"
  else
    wynik "$1" root "BŁĄD rc=$rc" "$log"
    echo "  BŁĄD rc=$rc   $1 — $log"
    BLEDY=$((BLEDY + 1))
  fi
  return "$rc"
}

# SSH a firewall (omarchy-port#8). Omarchy z ISO nie włącza sshd, więc „deny incoming” z config/firewall.sh
# niczego tam nie odcina. Na Voidzie sshd zwykle działa (włącza go instalator), a maszyna instalowana
# zdalnie po restarcie straciłaby dostęp — włączony sshd dostaje regułę z Setup > Security > SSH
# (omarchy-setup-security-sshd: `ufw limit 22/tcp comment omarchy-sshd`), na każdym porcie, na którym
# słucha (`sshd -T`: ListenAddress, inaczej Port — OpenSSH ≥ 10.5 pisze je wielką literą; brak = 22).
# omarchy-remove-security-sshd usuwa tylko regułę dla 22.
# Reguła idzie PRZED krokiem, póki ufw.conf ma ENABLED=no. Nowa reguła `limit` przy ENABLED=yes
# i niezaładowanym jeszcze firewallu (ruszy dopiero po restarcie) każe ufw przeładować łańcuchy, których
# nie ma: „ERROR: problem running” i kod 1, choć plik reguł jest już zapisany (sprawdzone w VM). Dlatego
# o wyniku decyduje obecność reguły w `ufw show added`, nie kod wyjścia.
ssh_w_firewallu() { # rc 1 = sshd włączony, a którejś reguły nie ma
  local porty port wyjscie dodane gniazdo=0
  local -a brak=()
  # na systemd sshd bywa uruchamiany przez gniazdo (sshd.socket, port w ListenStream, nie w sshd_config)
  if [[ $INIT == systemd ]] && systemctl -q is-enabled sshd.socket 2>/dev/null; then gniazdo=1; fi
  systemctl -q is-enabled sshd.service || ((gniazdo)) || return 0
  porty=$(sshd -T 2>/dev/null | awk 'tolower($1) == "listenaddress" { n = split($2, a, ":"); print a[n] }' | sort -un) || porty=
  [[ -n $porty ]] || porty=$(sshd -T 2>/dev/null | awk 'tolower($1) == "port" { print $2 }' | sort -un) || porty=
  [[ -n $porty ]] || porty=22
  if ((gniazdo)); then
    # Listen=[::]:22 (Stream) 0.0.0.0:2222 (Stream) — port po ostatnim dwukropku każdego adresu
    porty=$( { echo "$porty"; systemctl show -p Listen --value sshd.socket 2>/dev/null |
      grep -oE ':[0-9]+ \(Stream\)' | grep -oE '[0-9]+'; } | sort -un) || true
  fi
  for port in $porty; do
    wyjscie=$(ufw limit "$port/tcp" comment omarchy-sshd 2>&1) || true
    dodane=$(ufw show added 2>&1) || true
    if ! grep -qxF "ufw limit $port/tcp comment 'omarchy-sshd'" <<<"$dodane"; then
      brak+=("$port/tcp (ufw: ${wyjscie//$'\n'/ })")
    fi
  done
  porty=$(printf '%s/tcp ' $porty)
  if (( ${#brak[@]} )); then
    wynik "SSH w firewallu" root BŁĄD "sshd na ${porty% } — brak reguły ufw limit dla ${brak[*]}"
    echo "  BŁĄD         SSH w firewallu — brak reguły dla ${brak[*]}"
    BLEDY=$((BLEDY + 1))
    return 1
  fi
  wynik "SSH w firewallu" root ok "sshd włączony: ufw limit ${porty% } comment omarchy-sshd"
  echo "  ok           SSH w firewallu (sshd włączony: ufw limit ${porty% })"
}

# Upstreamowy krok firewalla raz na maszynę, z regułą SSH przed nim (znacznik $STATE/firewall), przy
# instalacji i przy aktualizacji tak samo. ufw włączony przez kogoś innego (usługa i ENABLED=yes, bez
# znacznika) zostaje taki, jaki jest — także przy ponownej instalacji. Bez reguły SSH krok nie idzie:
# włączony firewall odciąłby po restarcie sshd. Firewall, który zostaje wyłączony, trafia do
# podsumowania jako UWAGA BEZPIECZEŃSTWO. FIREWALL_TERAZ=1 — krok poszedł w tym przebiegu.
FIREWALL_TERAZ=0
krok_firewall() { # krok_firewall <plik kroku> [dopisek do „ok”]
  if [[ -e $STATE/firewall ]]; then
    wynik config/firewall.sh root pominięty "już wykonany (znacznik $STATE/firewall)"
    echo "  pominięty    config/firewall.sh (już wykonany — znacznik)"
    return 0
  fi
  if systemctl -q is-enabled ufw.service && grep -qiE '^ENABLED=yes' /etc/ufw/ufw.conf; then
    wynik config/firewall.sh root uwaga "ufw był już włączony — port zostawia jego konfigurację (reguły Omarchy: sudo bash $1)"
    echo "  UWAGA        ufw był już włączony — konfiguracja bez zmian"
    touch "$STATE/firewall"
    return 0
  fi
  if ! ssh_w_firewallu; then
    wynik firewall root wyłączony "BEZPIECZEŃSTWO: firewall nie włączony — bez reguły SSH odciąłby sshd; krok pójdzie w następnym przebiegu"
    return 0
  fi
  if ! uruchom_krok config/firewall.sh "$1" "${2:-}"; then
    wynik firewall root wyłączony "BEZPIECZEŃSTWO: config/firewall.sh padł — firewall może być wyłączony; krok pójdzie w następnym przebiegu"
    return 0
  fi
  touch "$STATE/firewall"
  FIREWALL_TERAZ=1
}

# Instalacja sprzed omarchy-port#8 ma krok config/firewall.sh pominięty (firewall wyłączony), a kroki
# install/ idą tylko przy instalacji — aktualizacja puszcza go ten jeden raz, z pominięciem albo
# podmianą z kroki.tsv jak w etapie 7. ufw rusza dopiero przy starcie systemu, więc konta portu dostają
# reboot-required (jak po migracjach Omarchy) — omarchy-update-restart zapyta o restart.
firewall_przy_aktualizacji() {
  local krok=config/firewall.sh plik akcja='' powod='' zn u
  etap "firewall (omarchy-port#8, jednorazowo)"
  # shim systemctl jak w etapie 7: ufw włączony bez startu, firewall ruszy przy następnym starcie systemu
  export OMARCHY_PATH=/usr/share/omarchy OMARCHY_PORT_INSTALL=1
  plik=$OMARCHY_PATH/install/$krok
  IFS=$'\t' read -r _ akcja powod < <(awk -F'\t' -v k="$krok" '$1 == k' "$DYST/kroki.tsv") || true
  case $akcja in
    pomiń)
      wynik "$krok" root pominięty "$powod"
      echo "  pominięty    $krok"
      return 0 ;;
    podmień) plik=$DYST/kroki/$krok ;;
  esac
  krok_firewall "$plik" "${akcja:+ (podmieniony)}"
  if ((FIREWALL_TERAZ)); then
    for zn in "$STATE"/dom-*; do
      [[ -e $zn ]] || continue
      u=${zn##*/dom-}
      su - "$u" -c 'omarchy-state set reboot-required' </dev/null ||
        echo "  UWAGA        reboot-required dla $u nie ustawiony — firewall ruszy po restarcie systemu"
    done
    echo "  firewall ruszy po restarcie systemu — omarchy-update zapyta o restart"
  fi
  if [[ -s $STATE/start-at-boot ]]; then
    echo "  wstaną przy następnym starcie: $(tr '\n' ' ' <"$STATE/start-at-boot")"
  fi
}

# Etapy 6–9 tylko przy instalacji: przy aktualizacji zmiany w systemie i domu użytkownika niosą
# migracje Omarchy (omarchy-migrate jako użytkownik, po tym skrypcie), jak na Archu.
etapy_instalacji() {
# ---------------------------------------------------------------------------------------------
etap "6/9 dom użytkownika $U"
# Na ISO Omarchy użytkownik powstaje PO instalacji pakietów, więc /etc/skel trafia do domu sam.
# Tu użytkownik już jest — kopia jak w omarchy-reinstall-configs: jako użytkownik (root w cudzym
# domu poszedłby za dowiązaniem typu ~/.bashrc → /etc/shadow) i tylko raz, bo ponowne uruchomienie
# orkiestratora nie może kasować zmian użytkownika.
if [[ -e $STATE/dom-$U ]]; then
  echo "już zasiany — pomijam (pełny reset konfiguracji: omarchy-reinstall-configs jako $U)"
else
  su - "$U" -c 'cp -af /etc/skel/. ~/' </dev/null || die "kopiowanie /etc/skel do $H nie powiodło się"
  touch "$STATE/dom-$U"
  echo "$H ← /etc/skel"
fi

# ---------------------------------------------------------------------------------------------
etap "7/9 kroki install/ jako root"
rm -rf "$OV"
mkdir -p "$(dirname "$OV")"
cp -a /usr/share/omarchy/install "$OV"
declare -A AKCJA POWOD
while IFS=$'\t' read -r krok akcja powod; do
  [[ -z $krok || $krok == \#* ]] && continue
  [[ -f $OV/$krok ]] || die "kroki.tsv: $krok nie istnieje w Omarchy $OMARCHY_TAG — przejrzyj listę po zmianie wersji"
  case $akcja in
    pomiń)
      printf '# omarchy-port: krok pominięty na %s (port/share/%s/kroki.tsv)\necho %q\n' "$DYSTR" "$DYSTR" \
        "omarchy-port: pominięty — $powod" >"$OV/$krok" ;;
    podmień)
      [[ -f $DYST/kroki/$krok ]] || die "kroki.tsv: brak podmiany $DYST/kroki/$krok"
      install -m 644 "$DYST/kroki/$krok" "$OV/$krok" ;;
    *) die "kroki.tsv: nieznana akcja '$akcja' dla $krok" ;;
  esac
  AKCJA[$krok]=$akcja
  POWOD[$krok]=$powod
done <"$DYST/kroki.tsv"

kroki_grupy() { # kroki z <grupa>/all.sh; linia inna niż run_logged = upstream zmienił format
  local line re='^run_logged "\$OMARCHY_INSTALL/([^"]+)"$'
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $line =~ $re ]] || { echo "nieznana linia w $1/all.sh: $line" >&2; return 1; }
    echo "${BASH_REMATCH[1]}"
  done <"$OV/$1/all.sh"
}

# Środowisko jak w omarchy-apply-system (łącznie z $OMARCHY_PATH/bin na początku PATH), tylko
# install/ wskazuje na drzewo portu. apply-system staje na pierwszym błędzie — tu każdy krok
# idzie osobno, a wynik trafia do kroki.tsv. OMARCHY_PORT_INSTALL: shim systemctl włącza usługi
# bez startu (start przy następnym boocie) — jak systemd w chroocie ISO.
export OMARCHY_INSTALL_USER="$U" OMARCHY_FIRST_INSTALL=1 OMARCHY_UPGRADE=0
export OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL="$OV"
export OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log
export OMARCHY_PORT_INSTALL=1
export PATH="$OMARCHY_PATH/bin:$PATH"
for grp in config hardware login post-install; do
  lista=$(kroki_grupy "$grp") || die "nie umiem odczytać $grp/all.sh"
  for s in $lista; do
    if [[ ${AKCJA[$s]:-} == pomiń ]]; then
      wynik "$s" root pominięty "${POWOD[$s]}"
      echo "  pominięty    $s"
      continue
    fi
    if [[ $s == config/firewall.sh ]]; then
      krok_firewall "$OV/$s" "${AKCJA[$s]:+ (podmieniony)}"
    else
      uruchom_krok "$s" "$OV/$s" "${AKCJA[$s]:+ (podmieniony)}" || true
    fi
  done
done

# ---------------------------------------------------------------------------------------------
etap "8/9 omarchy-provision-user jako $U"
# Upstreamowe polecenie: kroki user/ (z pominięciami i podmianami z drzewa portu), katalogi XDG,
# domyślna przeglądarka, znaczniki migracji. Staje na pierwszym błędzie — wtedy log mówi, gdzie.
for s in "${!AKCJA[@]}"; do
  [[ $s == user/* ]] || continue
  case ${AKCJA[$s]} in pomiń) w=pominięty ;; *) w=podmieniony ;; esac
  wynik "$s" użytkownik "$w" "${POWOD[$s]}"
done
provision_ok=0
if [[ -e $H/.local/state/omarchy/done/finalize-user ]]; then
  provision_ok=1
  # --first-install wymusza całość od nowa: przestawia przeglądarkę i mailto, nadpisuje ~/.XCompose
  # i oznacza WSZYSTKIE migracje jako wykonane — po podbiciu wersji nowe migracje by przepadły.
  wynik omarchy-provision-user użytkownik pominięty "już wykonane (znacznik finalize-user)"
  echo "  pominięty    omarchy-provision-user (już wykonane — znacznik finalize-user)"
else
  if [[ -z ${IMIE//[[:space:]]/} || -z ${EMAIL//[[:space:]]/} ]]; then
    wynik "tożsamość ($U)" użytkownik uwaga "brak imienia lub e-maila (--name/--email): git bez user.name/email, puste wpisy w ~/.XCompose"
  fi
  # OMARCHY_SETUP_CONTEXT: samo --first-install ustawia „iso-chroot”, a wtedy user/mise-work.sh szuka
  # Node z ISO w /opt/packages i pada. Kontekst czytają tylko dwa kroki: theme.sh (wszystko poza
  # „runtime” = bez żywej sesji — prawda) i mise-work.sh (poza iso-chroot/provision-owner = sieć).
  printf -v cmd 'OMARCHY_SETUP_CONTEXT=omarchy-port OMARCHY_INSTALL=%q OMARCHY_USER_NAME=%q OMARCHY_USER_EMAIL=%q omarchy-provision-user --first-install' \
    "$OV" "$IMIE" "$EMAIL"
  rc=0
  timeout 1800 su - "$U" -c "$cmd" </dev/null >"$LOGDIR/provision-user.log" 2>&1 || rc=$?
  if (( rc == 0 )); then
    wynik omarchy-provision-user użytkownik ok
    echo "  ok           omarchy-provision-user"
    provision_ok=1
  else
    wynik omarchy-provision-user użytkownik "BŁĄD rc=$rc" "$LOGDIR/provision-user.log"
    echo "  BŁĄD rc=$rc   omarchy-provision-user — $LOGDIR/provision-user.log"
    tail -5 "$LOGDIR/provision-user.log" | sed 's/^/    | /'
    BLEDY=$((BLEDY + 1))
  fi
fi

# Dodatki dystrybucji po provision (Gentoo: Chrome jako domyślna przeglądarka) — raz na konto, ze
# znacznikiem: po udanym przebiegu nie nadpisują późniejszego wyboru użytkownika, a nieudany idzie
# ponownie przy następnym uruchomieniu orkiestratora (provision ma już wtedy swój znacznik).
if (( provision_ok )) && [[ ! -e $STATE/po-provision-$U ]]; then
  if dyst_po_provision "$U"; then
    touch "$STATE/po-provision-$U"
  else
    wynik "po provision ($DYSTR)" użytkownik BŁĄD "share/$DYSTR/backend.sh: dyst_po_provision — szczegóły wyżej w logu"
    BLEDY=$((BLEDY + 1))
  fi
fi

# ---------------------------------------------------------------------------------------------
etap "9/9 usługi i logowanie"
# Przez systemctl (na runit: shim portu, ta sama logika co w krokach Omarchy, łącznie z plikiem down
# i startem przy boocie). Lista usług bazowych i jej uzasadnienie: share/init/<init>.sh.
# NetworkManager, sddm, cups itd. włącza krok config/enable-services.sh.
for s in "${USLUGI_BAZOWE[@]}"; do
  if systemctl enable "$s.service"; then
    echo "  włączona     $s"
  else
    wynik "usługa $s" root BŁĄD "systemctl enable $s.service"
    BLEDY=$((BLEDY + 1))
  fi
done
# Dwa klienty DHCP na jednym interfejsie walczą o adres — zostaje NetworkManager z Omarchy.
# `disable` bez --now (jak w systemd): dhcpcd działa do restartu, więc sieć nie znika w trakcie.
if systemctl -q is-enabled NetworkManager.service && systemctl -q is-enabled dhcpcd.service; then
  systemctl disable dhcpcd.service
  echo "  wyłączona    dhcpcd (od następnego startu sieć prowadzi NetworkManager)"
fi
# Motyw SDDM Omarchy nie ma pola użytkownika — loguje userModel.lastUser. Na świeżej maszynie
# to pusty ciąg i logowanie hasłem pada („Authentication for user ""”); Omarchy z ISO ma autologin.
# Zapis to samo, co SDDM robi sam po pierwszym udanym logowaniu (omarchy-port#2).
if [[ ! -e /var/lib/sddm/state.conf ]] && getent passwd sddm >/dev/null; then
  install -d -o sddm -g sddm /var/lib/sddm
  printf '[Last]\nUser=%s\n' "$U" >/var/lib/sddm/state.conf
  chown sddm:sddm /var/lib/sddm/state.conf
  echo "  SDDM         ostatni użytkownik: $U"
fi
if [[ -s $STATE/start-at-boot ]]; then
  echo "  wstaną przy następnym starcie: $(tr '\n' ' ' <"$STATE/start-at-boot")"
fi
}
if ((AKTUALIZACJA)); then
  etap "6–9/9 pominięte przy aktualizacji (dom, kroki install/, provision-user, usługi)"
  if [[ ! -e $STATE/firewall ]]; then firewall_przy_aktualizacji; fi
else
  etapy_instalacji
fi

# ---------------------------------------------------------------------------------------------
etap "źródło aktualizacji"
# omarchy-update bierze nowe wersje z klonu $PORT_DIR (git pull --ff-only na jego gałęzi). Port
# instalowany z innego miejsca dostaje klon z GitHuba; istniejący klon zostaje taki, jaki jest.
if [[ ! -e $PORT_DIR ]]; then
  if git clone -q --branch main "$PORT_URL" "$PORT_DIR"; then
    echo "  $PORT_DIR ← $PORT_URL (main)"
  else
    wynik "$PORT_DIR" root BŁĄD "git clone $PORT_URL nie powiódł się — bez klonu omarchy-update nie ma skąd brać nowych wersji"
    BLEDY=$((BLEDY + 1))
  fi
elif [[ ! -d $PORT_DIR/.git ]]; then
  wynik "$PORT_DIR" root BŁĄD "istnieje, ale nie jest klonem gita — omarchy-update nie ma skąd brać nowych wersji"
  BLEDY=$((BLEDY + 1))
fi
# Wersja zainstalowanego portu i upstream klonu — nakładka omarchy-update-available porównuje je
# jako użytkownik (git ls-remote), bez dostępu do repo roota.
if [[ -d $PORT_DIR/.git ]]; then
  # safe.directory: klon albo checkout innego właściciela (np. w domu użytkownika, przez sudo)
  zrodlo_ref=$(git -c safe.directory="$PORT_DIR" -C "$PORT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || zrodlo_ref=
  zrodlo_url='' zrodlo_galaz=''
  if [[ -n $zrodlo_ref ]]; then
    zrodlo_url=$(git -c safe.directory="$PORT_DIR" -C "$PORT_DIR" remote get-url "${zrodlo_ref%%/*}" 2>/dev/null) || zrodlo_url=
    zrodlo_galaz=refs/heads/${zrodlo_ref#*/}
  fi
  # wersja tylko z repo, którego korzeniem jest port (nie z cudzego repo, w którym leży kopia)
  wersja=
  if [[ $(git -c safe.directory="$REPO" -C "$REPO" rev-parse --show-toplevel 2>/dev/null) == "$REPO" ]]; then
    wersja=$(git -c safe.directory="$REPO" -C "$REPO" rev-parse HEAD)
  fi
  # Przebieg z błędami (kod 1) nie jest pełną wersją: omarchy-update staje przed migracjami, więc
  # wskaźnik ma dalej zapraszać do ponownej próby, zamiast mówić „up to date”.
  if (( BLEDY > 0 )) && [[ -n $wersja ]]; then wersja=niepełna; fi
  printf '%s\t%s\t%s\n' "$wersja" "$zrodlo_url" "$zrodlo_galaz" >"$STATE/wersja-portu"
  chmod 644 "$STATE/wersja-portu"
  echo "  wersja portu: ${wersja:-nieznana (instalacja spoza gita)}, aktualizacje z: ${zrodlo_url:-brak upstreamu} ${zrodlo_galaz#refs/heads/}"
fi

# ---------------------------------------------------------------------------------------------
etap "podsumowanie"
awk -F'\t' 'NR > 1 && $3 != "ok" { printf "  %-34s %-11s %s\n", $1, $3, $4 }' "$WYNIKI"
awk -F'\t' 'NR > 1 && $4 ~ /BEZPIECZEŃSTWO/ { printf "\nUWAGA  %s: %s\n", $1, $4 }' "$WYNIKI"
echo "wyniki: $WYNIKI"
KONIEC=1
if (( BLEDY > 0 )); then
  echo "BŁĘDÓW: $BLEDY — reszta jest doinstalowana; po poprawce wystarczy uruchomić orkiestrator ponownie"
  exit 1
fi
if ((AKTUALIZACJA)); then
  date -Iseconds >"$STATE/zaktualizowane"
  echo "OMARCHY-PORT-UPDATE-OK ($OMARCHY_TAG)"
else
  date -Iseconds >"$STATE/zainstalowane"
  echo "OMARCHY-PORT-INSTALL-OK ($OMARCHY_TAG) — teraz restart systemu"
fi
