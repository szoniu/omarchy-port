#!/usr/bin/env bash
# omarchy-port: pełne Omarchy na Voidzie (glibc, x86_64, runit) — orkiestrator. Jako root, na
# DZIAŁAJĄCYM systemie z siecią i istniejącym użytkownikiem (taki stan zostawia instalator
# szoniu/void). Idempotentny: ponowne uruchomienie dociąga to, czego brakuje.
#   port/install.sh --user NAZWA
#
# Etapy:
#   1. repozytoria: nonfree + blackhole (Hyprland), klucz blackhole przypięty (share/void/xbps-keys)
#   2. pakiety: dane/pakiety-do-instalacji.txt (lista Omarchy zmapowana na Voida)
#   3. pliki Omarchy: upstreamowe package() z omarchy-pkgs przy przypiętym commicie (share/upstream.env)
#   4. post_install omarchy-settings wybiórczo (bez os-release i nsswitch.conf)
#   5. warstwa zgodności: install-layer.sh
#   6. dom użytkownika z /etc/skel — tylko przy pierwszej instalacji
#   7. kroki install/ jako root, pojedynczo; pominięcia i podmiany: share/void/kroki.tsv
#   8. omarchy-provision-user jako użytkownik, na tym samym drzewie kroków
#   9. usługi runit: dbus, polkitd, chronyd (NTP); dhcpcd wyłączony, gdy sieć przejął NetworkManager
#
# Logi: /var/log/omarchy-port/install-<czas>/ (całość, log per krok, kroki.tsv).
# Kod wyjścia: 0 — wszystko przeszło (pominięcia z kroki.tsv to nie błąd); 1 — któryś krok padł
# (lista w podsumowaniu, reszta jest doinstalowana); 2 — przerwane (zły stan wejściowy albo etap,
# bez którego dalsze nie mają sensu).
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_COLLATE=C   # sort i comm na manifestach muszą zgadzać się co do kolejności

SRC="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SRC/.." && pwd)"
VOID="$SRC/share/void"
STATE=/var/lib/omarchy-port
CACHE=/var/cache/omarchy-port
OV=/usr/share/omarchy-port/install   # drzewo install/ Omarchy z pominięciami i podmianami portu
SV=/etc/runit/runsvdir/default

die() { echo "install.sh: $*" >&2; exit 2; }

U=
while (($#)); do
  case $1 in
    --user) [[ $# -ge 2 ]] || die "--user wymaga nazwy"; U=$2; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "nieznana opcja: $1 (użycie: install.sh --user NAZWA)" ;;
  esac
done

(( EUID == 0 )) || die "uruchom jako root"
command -v xbps-install >/dev/null || die "na razie tylko Void (xbps) — Gentoo: omarchy-port#5"
[[ $(xbps-uhelper arch) == x86_64 ]] || die "na razie tylko Void x86_64 z glibc (jest: $(xbps-uhelper arch))"
[[ -n $U && $U != root ]] || die "podaj użytkownika: --user NAZWA (nie root)"
getent passwd "$U" >/dev/null || die "użytkownik $U nie istnieje — port go nie zakłada (to robota instalatora)"
H=$(getent passwd "$U" | cut -d: -f6)
G=$(id -gn "$U")
# /var/service wskazuje na /run/runit/… — istnieje tylko w działającym systemie. Kroki Omarchy
# włączają usługi przez shim systemctl, który bez działającego runit nie ma czego włączać.
[[ -d /var/service ]] || die "system nie działa pod runit (chroot?) — orkiestrator wymaga uruchomionego systemu"
curl -fsS --max-time 20 -o /dev/null https://github.com || die "brak sieci (github.com) — potrzebna do pobrania Omarchy"

# shellcheck source=share/upstream.env
source "$SRC/share/upstream.env"

install -d -m 755 "$STATE" "$CACHE"
exec 9>"$STATE/install.lock"
flock -n 9 || die "orkiestrator już działa ($STATE/install.lock)"

LOGDIR=/var/log/omarchy-port/install-$(date +%Y%m%d-%H%M%S)
mkdir -p "$LOGDIR/kroki"
exec > >(tee -a "$LOGDIR/install.log") 2>&1

WYNIKI="$LOGDIR/kroki.tsv"
printf 'krok\tkto\twynik\tszczegóły\n' >"$WYNIKI"
BLEDY=0
etap() { printf '\n=== %s ===\n' "$*"; }
wynik() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$WYNIKI"; }

echo "omarchy-port: Omarchy $OMARCHY_TAG dla użytkownika $U — log: $LOGDIR"

# ---------------------------------------------------------------------------------------------
etap "1/9 repozytoria"
xbps-install -Syu xbps   # najpierw sam xbps — Void wymaga aktualnego xbps przed resztą
xbps-install -y void-repo-nonfree
# Adres i nazwa pliku jak w instalatorze szoniu/void (_setup_hyprland_repo) — oba trafiają w to samo.
# Klucz NIE jest przyjmowany w ciemno (`yes |`): przypięty plik idzie do keys/, a każdy inny klucz,
# który pojawi się po synchronizacji, przerywa instalację.
mapfile -t KLUCZE_PRZED < <(find /var/db/xbps/keys -name '*.plist' -printf '%f\n')
install -m 644 "$VOID"/xbps-keys/*.plist /var/db/xbps/keys/
echo "repository=https://mirror.black-hole.dev/$(xbps-uhelper arch)" >/etc/xbps.d/20-blackhole.conf
xbps-install -S </dev/null || die "synchronizacja repozytoriów nie powiodła się"
while IFS= read -r k; do
  [[ " ${KLUCZE_PRZED[*]} " == *" $k "* || -e $VOID/xbps-keys/$k ]] && continue
  rm -f "/var/db/xbps/keys/$k" /etc/xbps.d/20-blackhole.conf
  die "repozytorium podsunęło nieznany klucz $k — usunięty razem z repo blackhole; sprawdź, czy klucz się zmienił"
done < <(find /var/db/xbps/keys -name '*.plist' -printf '%f\n')

# ---------------------------------------------------------------------------------------------
etap "2/9 pakiety"
xbps-install -yu   # pełna aktualizacja przed doinstalowaniem — xbps nie robi aktualizacji częściowych
mapfile -t PAKIETY < <(grep -v '^#' "$REPO/dane/pakiety-do-instalacji.txt" | tr -s ' ' '\n' | sed '/^$/d')
echo "pakietów na liście: ${#PAKIETY[@]}"
xbps-install -y "${PAKIETY[@]}"

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
pobierz https://github.com/omacom/omarchy-pkgs.git "$CACHE/omarchy-pkgs" "$OMARCHY_PKGS_COMMIT"
pobierz https://github.com/basecamp/omarchy.git "$CACHE/src/omarchy" "$OMARCHY_COMMIT"
tag=$(git ls-remote https://github.com/basecamp/omarchy.git "refs/tags/$OMARCHY_TAG^{}" | cut -f1) || true
[[ $tag == "$OMARCHY_COMMIT" ]] || echo "UWAGA: tag $OMARCHY_TAG wskazuje dziś na ${tag:-nic}, a przypięty commit to $OMARCHY_COMMIT (instaluję przypięty)"
for p in omarchy omarchy-settings; do
  c=$(sed -n "s/^_commit='\(.*\)'$/\1/p" "$CACHE/omarchy-pkgs/pkgbuilds/$p/PKGBUILD")
  [[ $c == "$OMARCHY_COMMIT" ]] || die "PKGBUILD $p ma _commit=$c, a upstream.env $OMARCHY_COMMIT — popraw upstream.env"
done

for p in omarchy-settings omarchy; do
  st="$CACHE/stage/$p"
  rm -rf "$st"
  mkdir -p "$st"
  # Osobny proces bash: `set -e` w podpowłoce wołanej w warunku (|| / if) bash po cichu ignoruje.
  bash -e -c 'CARCH=x86_64 srcdir=$1 pkgdir=$2; cd "$3"; source ./PKGBUILD; package' \
    bash "$CACHE/src" "$st" "$CACHE/omarchy-pkgs/pkgbuilds/$p" >"$LOGDIR/package-$p.log" 2>&1 ||
    die "package() $p padło — $LOGDIR/package-$p.log"
  # Hooki libalpm (strażnik pacmana, pauza przeładowań Hyprlanda) dotyczą tylko pacmana.
  (cd "$st" && find . ! -type d ! -path './usr/share/libalpm/*' | sed 's|^\.||' | sort) >"$CACHE/manifest-$p.new"
  # Plik, który już jest na dysku, a nie pochodzi z poprzedniej instalacji portu, może należeć do
  # pakietu Voida — takiego nie nadpisujemy po cichu.
  stary="$STATE/manifest-$p.txt"
  [[ -f $stary ]] || : >"$stary"
  konflikty=()
  while IFS= read -r f; do
    [[ -e $f || -L $f ]] || continue
    o=$(xbps-query -o "$f" 2>/dev/null | head -1 | cut -d: -f1)
    if [[ -n $o ]]; then konflikty+=("$f ($o)"); fi
  done < <(comm -23 "$CACHE/manifest-$p.new" "$stary")
  (( ${#konflikty[@]} == 0 )) || die "$p nadpisałby pliki pakietów Voida: ${konflikty[*]}"
  tar -C "$st" --exclude=./usr/share/libalpm -cf - . | tar -C / --no-overwrite-dir -xpf -
  mv "$CACHE/manifest-$p.new" "$stary"
  echo "$p: $(wc -l <"$stary") plików"
done
echo "$OMARCHY_TAG $OMARCHY_COMMIT" >"$STATE/wersja-omarchy"

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
bash "$SRC/install-layer.sh"

# ---------------------------------------------------------------------------------------------
etap "6/9 dom użytkownika $U"
# Na ISO Omarchy użytkownik powstaje PO instalacji pakietów, więc /etc/skel trafia do domu sam.
# Tu użytkownik już jest — kopia jak w omarchy-reinstall-configs, ale tylko raz: ponowne
# uruchomienie orkiestratora nie może kasować zmian użytkownika.
if [[ -e $STATE/dom-$U ]]; then
  echo "już zasiany — pomijam (pełny reset konfiguracji: omarchy-reinstall-configs jako $U)"
else
  cp -a /etc/skel/. "$H/"
  chown -R "$U:$G" "$H"
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
# idzie osobno, a wynik trafia do kroki.tsv.
export OMARCHY_INSTALL_USER="$U" OMARCHY_FIRST_INSTALL=1 OMARCHY_UPGRADE=0
export OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL="$OV"
export OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log
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
# OMARCHY_SETUP_CONTEXT: samo --first-install ustawia „iso-chroot”, a wtedy user/mise-work.sh szuka
# Node z ISO w /opt/packages i pada. Kontekst czytają tylko dwa kroki: theme.sh (wszystko poza
# „runtime” = bez żywej sesji — prawda) i mise-work.sh (poza iso-chroot/provision-owner = sieć).
rc=0
su - "$U" -c "OMARCHY_SETUP_CONTEXT=omarchy-port OMARCHY_INSTALL='$OV' omarchy-provision-user --first-install" \
  </dev/null >"$LOGDIR/provision-user.log" 2>&1 || rc=$?
if (( rc == 0 )); then
  wynik omarchy-provision-user użytkownik ok
  echo "  ok           omarchy-provision-user"
else
  wynik omarchy-provision-user użytkownik "BŁĄD rc=$rc" "$LOGDIR/provision-user.log"
  echo "  BŁĄD rc=$rc   omarchy-provision-user — $LOGDIR/provision-user.log"
  tail -5 "$LOGDIR/provision-user.log" | sed 's/^/    | /'
  BLEDY=$((BLEDY + 1))
fi

# ---------------------------------------------------------------------------------------------
etap "9/9 usługi runit"
# elogind celowo bez usługi runit: startuje z aktywacji D-Bus, a usługa obok kręci się w pętli
# „already running” (sprawdzone w VM). NetworkManager, sddm, cups itd. włącza config/enable-services.sh.
# chronyd zamiast systemd-timesyncd, który na Archu dochodzi z systemd i jest włączony domyślnie.
for s in dbus polkitd chronyd; do
  if [[ ! -d /etc/sv/$s ]]; then
    echo "  BRAK usługi $s"
    wynik "usługa $s" root "BŁĄD" "brak /etc/sv/$s"
    BLEDY=$((BLEDY + 1))
    continue
  fi
  [[ -L $SV/$s ]] || ln -s "/etc/sv/$s" "$SV/$s"
  echo "  włączona     $s"
done
# Dwa klienty DHCP na jednym interfejsie walczą o adres — zostaje NetworkManager z Omarchy.
if [[ -L $SV/NetworkManager && -L $SV/dhcpcd ]]; then
  rm -f "$SV/dhcpcd"
  echo "  wyłączona    dhcpcd (sieć przejmuje NetworkManager)"
fi

# ---------------------------------------------------------------------------------------------
etap "podsumowanie"
awk -F'\t' 'NR > 1 && $3 != "ok" { printf "  %-34s %-11s %s\n", $1, $3, $4 }' "$WYNIKI"
awk -F'\t' 'NR > 1 && $4 ~ /BEZPIECZEŃSTWO/ { printf "\nUWAGA  %s: %s\n", $1, $4 }' "$WYNIKI"
echo "wyniki: $WYNIKI"
if (( BLEDY > 0 )); then
  echo "BŁĘDÓW: $BLEDY — reszta jest doinstalowana; po poprawce wystarczy uruchomić orkiestrator ponownie"
  exit 1
fi
date -Iseconds >"$STATE/zainstalowane"
echo "OMARCHY-PORT-INSTALL-OK ($OMARCHY_TAG) — teraz restart systemu"
