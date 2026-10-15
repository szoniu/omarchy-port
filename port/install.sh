#!/usr/bin/env bash
# omarchy-port: pełne Omarchy na Voidzie (glibc, x86_64, runit) — orkiestrator. Jako root, na
# DZIAŁAJĄCYM systemie z siecią, gitem i istniejącym użytkownikiem (taki stan zostawia instalator
# szoniu/void + `xbps-install -S git`). Idempotentny: ponowne uruchomienie dociąga to, czego brakuje.
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
#   1. repozytoria: nonfree + blackhole (Hyprland), klucz blackhole przypięty (share/void/xbps-keys)
#   2. pakiety: dane/pakiety-do-instalacji.txt (lista Omarchy zmapowana na Voida); sshd restartowany,
#      gdy aktualizacja podmieniła openssh pod działającą usługą
#   3. pliki Omarchy: upstreamowe package() z omarchy-pkgs przy przypiętym commicie (share/upstream.env);
#      zmienione przez admina pliki z backup=() PKGBUILD-a zostają, nowa wersja obok jako .omarchy-new;
#      pliki poprzedniej wersji, których nowa nie ma, znikają (zmienione przez admina → .omarchy-save);
#      przeładowania działającego Hyprlanda wstrzymane na czas podmiany (jak hooki libalpm Omarchy)
#   4. post_install omarchy-settings wybiórczo (bez os-release i nsswitch.conf)
#   5. warstwa zgodności: install-layer.sh (z łatkami i brandingiem Voida)
#   6. dom użytkownika z /etc/skel — tylko przy pierwszej instalacji, jako użytkownik
#   7. kroki install/ jako root, pojedynczo; pominięcia i podmiany: share/void/kroki.tsv
#   8. omarchy-provision-user jako użytkownik, na tym samym drzewie kroków — tylko dopóki nie przeszło
#   9. usługi: dbus, polkitd, chronyd (NTP); dhcpcd wyłączony, gdy sieć przejmuje NetworkManager;
#      SDDM dostaje ostatniego użytkownika (motyw Omarchy nie ma pola użytkownika)
# Usługi włączane w trakcie (krok enable-services i etap 9) NIE startują od razu — jak w systemd
# wstają przy następnym starcie systemu (shim systemctl w trybie OMARCHY_PORT_INSTALL).
#
# Logi: /var/log/omarchy-port/install-<czas>/ albo update-<czas>/ (całość, log per krok, kroki.tsv).
# Kod wyjścia: 0 — wszystko przeszło (pominięcia z kroki.tsv to nie błąd); 1 — któryś krok padł
# (lista w podsumowaniu, reszta jest doinstalowana); 2 — przerwane (zły stan wejściowy albo etap,
# bez którego dalsze nie mają sensu) — każde inne przerwanie też kończy się kodem 2.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SRC="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SRC/.." && pwd)"
VOID="$SRC/share/void"
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
command -v xbps-install >/dev/null || die "na razie tylko Void (xbps) — Gentoo: omarchy-port#5"
[[ $(xbps-uhelper arch) == x86_64 ]] || die "na razie tylko Void x86_64 z glibc (jest: $(xbps-uhelper arch))"
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
# /var/service wskazuje na /run/runit/… — istnieje tylko w działającym systemie. Kroki Omarchy
# włączają usługi przez shim systemctl, który bez działającego runit nie ma czego włączać.
[[ -d /var/service ]] || die "system nie działa pod runit (chroot?) — orkiestrator wymaga uruchomionego systemu"
command -v git >/dev/null || die "brak gita: xbps-install -S git"

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
# Adres i nazwa pliku jak w instalatorze szoniu/void (_setup_hyprland_repo) — oba trafiają w to samo.
# Klucz blackhole NIE jest przyjmowany w ciemno: przypięty plik trafia do keys/ PRZED pierwszą
# synchronizacją, xbps dostaje </dev/null (pytanie o nowy klucz = odmowa, a nie Enter = „tak”),
# a po synchronizacji repo musi być podpisane kluczem o przypiętym odcisku — także wtedy, gdy klucz
# był już w systemie (np. przyjęty przez instalator).
BH_CONF=/etc/xbps.d/20-blackhole.conf
BH_URL="https://mirror.black-hole.dev/$(xbps-uhelper arch)"
klucze=("$VOID"/xbps-keys/*.plist)
(( ${#klucze[@]} == 1 )) || die "w $VOID/xbps-keys ma być dokładnie jeden klucz"
BH_FP=${klucze[0]##*/}
BH_FP=${BH_FP%.plist}   # nazwa pliku klucza xbps = jego odcisk
BH_KEY=/var/db/xbps/keys/${klucze[0]##*/}
bh_key_nowy=0
[[ -e $BH_KEY ]] || bh_key_nowy=1
install -m 644 "${klucze[0]}" /var/db/xbps/keys/
echo "repository=$BH_URL" >"$BH_CONF"
odrzuc_blackhole() { # repo i klucz wgrany przez ten przebieg znikają — przyjęty wcześniej zostaje
  rm -f "$BH_CONF"
  if ((bh_key_nowy)); then rm -f "$BH_KEY"; fi
}
synchro() {
  "$@" </dev/null && return 0
  odrzuc_blackhole
  die "$* nie powiodło się — jeśli xbps pytał wyżej o klucz, repo blackhole podpisuje inny klucz niż przypięty ($BH_FP); repo usunięte"
}
synchro xbps-install -Syu xbps   # najpierw sam xbps — Void wymaga aktualnego xbps przed resztą
synchro xbps-install -y void-repo-nonfree
synchro xbps-install -S
fp=$(xbps-query -vL </dev/null | awk -v u="$BH_URL" '
  $2 == u { w = 1; next }
  w && $1 ~ /^[0-9]+$/ && $2 ~ /^https?:/ { exit }
  w && NF == 2 && $2 ~ /^[0-9a-f]{2}(:[0-9a-f]{2})+$/ { print $2; exit }')
if [[ $fp != "$BH_FP" ]]; then
  odrzuc_blackhole
  die "repo blackhole podpisane kluczem ${fp:-nieznanym}, a przypięty to $BH_FP — repo usunięte"
fi
echo "blackhole: podpis zgodny z przypiętym kluczem $BH_FP"

# ---------------------------------------------------------------------------------------------
etap "2/9 pakiety"
xbps-install -yu </dev/null   # pełna aktualizacja przed doinstalowaniem — xbps nie robi aktualizacji częściowych
mapfile -t PAKIETY < <(grep -v '^#' "$REPO/dane/pakiety-do-instalacji.txt" | tr -s ' ' '\n' | sed '/^$/d')
echo "pakietów na liście: ${#PAKIETY[@]}"
xbps-install -y "${PAKIETY[@]}" </dev/null
# OpenSSH ≥ 9.8 przy każdym połączeniu uruchamia sshd-session z dysku: po aktualizacji openssh nowy
# nie dogada się ze starym, działającym sshd i nowe połączenia SSH padają aż do restartu systemu.
# runit wysyła TERM tylko do nasłuchującego sshd — trwające sesje (także ta z instalacją) zostają.
sshd_pid=$(cat /var/service/sshd/supervise/pid 2>/dev/null) || sshd_pid=
if [[ -n $sshd_pid && $(readlink "/proc/$sshd_pid/exe" 2>/dev/null) == *' (deleted)' ]]; then
  if sv restart sshd >/dev/null; then
    echo "sshd: zrestartowany — openssh zaktualizowany pod działającą usługą"
  else
    echo "UWAGA: sv restart sshd nie powiódł się — nowe połączenia SSH mogą padać do restartu systemu"
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
lista_pasuje "$VOID/kroki.tsv" install "$VOID/kroki"
lista_pasuje "$VOID/migracje.tsv" migrations "$VOID/migracje"

# Ścieżki należące do pakietów Voida — raz, z list plików w bazie xbps (xbps-query -o na plik to
# ~0,25 s, a plików Omarchy jest ~2000).
sed -n 's|^[[:space:]]*<string>\(/[^<]*\)</string>.*|\1|p' /var/db/xbps/.*-files.plist | LC_ALL=C sort -u >"$CACHE/pliki-xbps.txt"

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

# Kolejność jak w pacmanie: najpierw budowa i sprawdzenia obu pakietów (bez zmian na dysku), potem
# usunięcie plików poprzedniej wersji, na końcu wypakowanie. Stan poprzedniej wersji (oba pakiety
# razem — plik może przejść z jednego do drugiego) zostaje w $STATE aż do pełnego przebiegu: przerwanie
# po wypakowaniu części nie gubi plików do usunięcia przy ponownej próbie.
POPRZ_MANIFEST="$STATE/manifest-poprzedni.txt"
POPRZ_SUMY="$STATE/kopie-poprzednie.sums"
if [[ ! -f $POPRZ_MANIFEST ]]; then
  { cat "$STATE"/manifest-omarchy-settings.txt "$STATE"/manifest-omarchy.txt 2>/dev/null || true; } |
    LC_ALL=C sort -u >"$POPRZ_MANIFEST.tmp"
  { cat "$STATE"/kopie-omarchy-settings.sums "$STATE"/kopie-omarchy.sums 2>/dev/null || true; } >"$POPRZ_SUMY"
  mv "$POPRZ_MANIFEST.tmp" "$POPRZ_MANIFEST"
fi

for p in omarchy-settings omarchy; do
  st="$CACHE/stage/$p"
  rm -rf "$st"
  mkdir -p "$st"
  # Osobny proces bash: `set -e` w podpowłoce wołanej w warunku (|| / if) bash po cichu ignoruje.
  bash -e -c 'CARCH=x86_64 srcdir=$1 pkgdir=$2; cd "$3"; source ./PKGBUILD; package' \
    bash "$CACHE/src" "$st" "$CACHE/omarchy-pkgs/pkgbuilds/$p" >"$LOGDIR/package-$p.log" 2>&1 ||
    die "package() $p padło — $LOGDIR/package-$p.log"
  # Hooki libalpm są dla pacmana — pauzę przeładowań Hyprlanda port robi sam (wyżej).
  (cd "$st" && find . ! -type d ! -path './usr/share/libalpm/*' | sed 's|^\.||' | LC_ALL=C sort) >"$CACHE/manifest-$p.new"
  # Plik, który już jest na dysku, a nie pochodzi z poprzedniej instalacji portu, może należeć do
  # pakietu Voida — takiego nie nadpisujemy po cichu.
  konflikty=()
  while IFS= read -r f; do
    if [[ -e $f || -L $f ]]; then konflikty+=("$f ($(xbps-query -o "$f" 2>/dev/null | head -1 | cut -d: -f1))"); fi
  done < <(LC_ALL=C comm -23 "$CACHE/manifest-$p.new" "$POPRZ_MANIFEST" | LC_ALL=C comm -12 - "$CACHE/pliki-xbps.txt")
  (( ${#konflikty[@]} == 0 )) || die "$p nadpisałby pliki pakietów Voida: ${konflikty[*]}"

  # backup=() z PKGBUILD-a jak w pacmanie: plik zmieniony przez admina (albo istniejący wcześniej,
  # nie nasz) zostaje, nowa wersja obok jako .omarchy-new; niezmieniony — nadpisujemy nowszą.
  mapfile -t KOPIE < <(bash -c 'CARCH=x86_64; cd "$1"; source ./PKGBUILD >/dev/null 2>&1; for b in "${backup[@]}"; do echo "/$b"; done' \
    bash "$CACHE/omarchy-pkgs/pkgbuilds/$p")
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
# Voida, nie jest już nasz i zostaje. Od tego miejsca dysk się zmienia — przerwanie przywraca warstwę.
wypakowywanie=1
cat "$CACHE"/manifest-omarchy-settings.new "$CACHE"/manifest-omarchy.new | LC_ALL=C sort -u >"$CACHE/manifest-nowy.txt"
# katalogi nowej wersji (także puste) zostają; reszta opróżnionych — tylko we własnym drzewie, bo
# gdzie indziej katalog mógł założyć pakiet Voida
for p in omarchy-settings omarchy; do (cd "$CACHE/stage/$p" && find . -type d | sed 's|^\.||'); done |
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
done < <(LC_ALL=C comm -23 "$POPRZ_MANIFEST" "$CACHE/manifest-nowy.txt" | LC_ALL=C comm -23 - "$CACHE/pliki-xbps.txt")
echo "pliki poprzedniej wersji usunięte: $usuniete"

for p in omarchy-settings omarchy; do
  tar -C "$CACHE/stage/$p" --exclude=./usr/share/libalpm -X "$CACHE/wyklucz-$p.txt" -cf - . | tar -C / --no-overwrite-dir -xpf -
  mv "$CACHE/manifest-$p.new" "$STATE/manifest-$p.txt"
  mv "$CACHE/kopie-$p.new" "$STATE/kopie-$p.sums"
  echo "$p: $(wc -l <"$STATE/manifest-$p.txt") plików"
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
if [[ -e /usr/lib/security/pam_faillock.so ]]; then
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
for l in "$SRC"/share/latki/*.patch "$SRC"/share/void/latki/*.patch; do
  [[ -e $l ]] || continue
  git -C /usr/share/omarchy apply --check -R -p1 "$l" 2>/dev/null && continue
  wynik "${l#"$SRC"/}" root BŁĄD "nie nałożona — $(head -1 "$l")"
  echo "  BŁĄD         łatka ${l#"$SRC"/share/} nie nałożona — przejrzyj ją przy zmianie wersji Omarchy"
  BLEDY=$((BLEDY + 1))
done
# To samo dla brandingu Voida — warstwa zostawia plik, gdy któryś element nie przeszedł.
if [[ -e $STATE/branding-blad ]]; then
  wynik share/void/branding.sh root BŁĄD "$(cat "$STATE/branding-blad")"
  echo "  BŁĄD         $(cat "$STATE/branding-blad")"
  BLEDY=$((BLEDY + 1))
fi

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
      printf '# omarchy-port: krok pominięty na Voidzie (port/share/void/kroki.tsv)\necho %q\n' \
        "omarchy-port: pominięty — $powod" >"$OV/$krok" ;;
    podmień)
      [[ -f $VOID/kroki/$krok ]] || die "kroki.tsv: brak podmiany $VOID/kroki/$krok"
      install -m 644 "$VOID/kroki/$krok" "$OV/$krok" ;;
    *) die "kroki.tsv: nieznana akcja '$akcja' dla $krok" ;;
  esac
  AKCJA[$krok]=$akcja
  POWOD[$krok]=$powod
done <"$VOID/kroki.tsv"

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
    log="$LOGDIR/kroki/${s//\//_}.log"
    rc=0
    timeout 1200 bash -eE -c 'source "$1"' bash "$OV/$s" </dev/null >"$log" 2>&1 || rc=$?
    if (( rc == 0 )); then
      wynik "$s" root "ok${AKCJA[$s]:+ (podmieniony)}"
      echo "  ok           $s"
    else
      wynik "$s" root "BŁĄD rc=$rc" "$log"
      echo "  BŁĄD rc=$rc   $s — $log"
      BLEDY=$((BLEDY + 1))
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
if [[ -e $H/.local/state/omarchy/done/finalize-user ]]; then
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
  else
    wynik omarchy-provision-user użytkownik "BŁĄD rc=$rc" "$LOGDIR/provision-user.log"
    echo "  BŁĄD rc=$rc   omarchy-provision-user — $LOGDIR/provision-user.log"
    tail -5 "$LOGDIR/provision-user.log" | sed 's/^/    | /'
    BLEDY=$((BLEDY + 1))
  fi
fi

# ---------------------------------------------------------------------------------------------
etap "9/9 usługi i logowanie"
# Przez shim systemctl (ta sama logika co w krokach Omarchy, łącznie z plikiem down i startem przy
# boocie). elogind celowo bez usługi runit: startuje z aktywacji D-Bus, a usługa obok kręci się
# w pętli „already running” (sprawdzone w VM). chronyd zamiast systemd-timesyncd, który na Archu
# dochodzi z systemd. NetworkManager, sddm, cups itd. włącza krok config/enable-services.sh.
for s in dbus polkitd chronyd; do
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
