#!/usr/bin/env bash
# omarchy-port: instalacja warstwy zgodności (Void/runit). Jako root, idempotentnie.
#   shimy (systemctl, systemd-run, systemd-cat, uwsm-app, xdg-terminal-exec) → /usr/local/bin,
#       TYLKO gdy prawdziwego polecenia nie ma (na Gentoo z systemd żaden nie powstaje);
#   nakładki (omarchy-pkg-*, omarchy-version*, omarchy-update*), polecenia portu (omarchy-port-*)
#       i dyspozytor `omarchy` przez /usr/share/omarchy/bin (SSH, TTY) → /usr/local/bin, zawsze —
#       /usr/local/bin jest w PATH i w secure_path sudo PRZED /usr/bin z plikami Omarchy,
#       a linki w /usr/share/omarchy/bin (PATH sesji) są przekierowane na nakładki;
#   dane → /usr/share/omarchy-port, sesja → /usr/libexec/omarchy-port + wayland-sessions,
#   greeter SDDM → config portu (upstreamowy + no_update_news) przez /etc/sddm.conf.d,
#   migracje pominięte/podmienione na Voidzie (share/void/migracje.tsv) i migracje samego portu
#       (share/void/migracje-portu) → /usr/share/omarchy/migrations,
#   łatki z upstreamu, których przypięte wydanie nie ma (share/latki), i łatki Voida (share/void/latki:
#       branding menu i paska) → pliki /usr/share/omarchy,
#   branding Voida: logo w greeterze SDDM, About/fastfetch i wygaszaczu (share/void/branding.sh).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SRC/.." && pwd)"
STATE=/var/lib/omarchy-port
(( EUID == 0 )) || { echo "install-layer: uruchom jako root" >&2; exit 1; }
command -v xbps-install >/dev/null || { echo "install-layer: na razie tylko Void (xbps) — Gentoo: omarchy-port#5" >&2; exit 1; }

install -d /usr/share/omarchy-port /usr/libexec/omarchy-port /usr/local/bin /usr/share/wayland-sessions
install -m 644 "$SRC/share/pkg-map.sh" "$SRC/share/runit-services.tsv" "$SRC/share/user-units-skip.tsv" /usr/share/omarchy-port/
install -m 644 "$REPO/dane/mapa-pakietow-void.tsv" /usr/share/omarchy-port/

for shim in systemctl systemd-run systemd-cat systemd-inhibit timedatectl uwsm uwsm-app xdg-terminal-exec; do
  real=$(PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v "$shim" || true)
  if [[ -n $real ]]; then
    echo "pomijam shim $shim — jest $real"
    rm -f "/usr/local/bin/$shim"   # stary shim nie może przesłaniać prawdziwego polecenia
  else
    install -m 755 "$SRC/bin/$shim" /usr/local/bin/
    echo "shim: /usr/local/bin/$shim"
  fi
done

# nakładki na polecenia Omarchy, które pytają pacmana (pakiety, wersja/kanał/data aktualizacji,
# kroki omarchy-update); omarchy-port-* to polecenia samego portu (bez odpowiednika w Omarchy)
NAKLADKI=("$SRC"/bin/omarchy-pkg-* "$SRC"/bin/omarchy-version* "$SRC"/bin/omarchy-update*)
for f in "${NAKLADKI[@]}" "$SRC"/bin/omarchy-port-* "$SRC/bin/omarchy"; do
  install -m 755 "$f" /usr/local/bin/
  echo "nakładka: /usr/local/bin/$(basename "$f")"
done

# Sesja Omarchy (default/uwsm) i omarchy-provision-user stawiają /usr/share/omarchy/bin PRZED
# /usr/local/bin, a package() Omarchy robi tam linki do /usr/bin/omarchy-* (wersje z pacmanem).
# Bez przekierowania nakładka działa tylko z SSH i sudo, a w sesji (menu, skróty) wygrywa pacman.
# Każda reinstalacja plików Omarchy odtwarza te linki — po niej ten skrypt trzeba puścić ponownie.
if [[ -d /usr/share/omarchy/bin ]]; then
  for f in "${NAKLADKI[@]}"; do
    b=$(basename "$f")
    [[ -L /usr/share/omarchy/bin/$b ]] || continue
    ln -sfn "/usr/local/bin/$b" "/usr/share/omarchy/bin/$b"
    echo "przekierowanie: /usr/share/omarchy/bin/$b → /usr/local/bin/$b"
  done
else
  echo "UWAGA: brak /usr/share/omarchy/bin — puść install-layer.sh ponownie po instalacji plików Omarchy" >&2
fi

# PipeWire na Voidzie: WirePlumber i serwer pulse jako moduły pipewire (Void Handbook) — nadzorca
# unitów startuje sam `pipewire`, reszta wstaje z tych dwóch plików
install -d /etc/pipewire/pipewire.conf.d
ln -sfn /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
ln -sfn /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/
echo "pipewire: wireplumber + pulse jako moduły"

install -m 755 "$SRC/session/session" /usr/libexec/omarchy-port/session
# reguły tmpfiles Omarchy przy boocie (Void nie ma systemd-tmpfiles) — m.in. sprzątanie „sudo bez hasła”
install -m 644 "$SRC/share/runit/90-omarchy-port-tmpfiles.sh" /etc/runit/core-services/
echo "core-service: /etc/runit/core-services/90-omarchy-port-tmpfiles.sh"
# usługi włączone w trakcie instalacji (shim systemctl, tryb OMARCHY_PORT_INSTALL) startują przy boocie
install -m 644 "$SRC/share/runit/91-omarchy-port-start-at-boot.sh" /etc/runit/core-services/
echo "core-service: /etc/runit/core-services/91-omarchy-port-start-at-boot.sh"
install -m 644 "$SRC/session/omarchy-void.desktop" /usr/share/wayland-sessions/
echo "sesja: /usr/libexec/omarchy-port/session"

# Greeter SDDM: config Omarchy + no_update_news (okno „Hyprland updated” zasłania pole hasła — #2).
# Nadpisanie CompositorCommand ma sens tylko, dopóki Omarchy woła greeter tak jak w v4.0.4 —
# inaczej drop-in portu po cichu przykryłby zmianę upstreamu.
GREETER_UPSTREAM='CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua'
if [[ -f /usr/share/sddm/hyprland.lua ]] && /usr/bin/grep -qxF "$GREETER_UPSTREAM" /etc/sddm.conf.d/10-wayland.conf 2>/dev/null; then
  install -m 644 "$SRC/session/sddm-hyprland.lua" /usr/share/omarchy-port/
  install -d /etc/sddm.conf.d
  install -m 644 "$SRC/session/30-omarchy-port-greeter.conf" /etc/sddm.conf.d/
  echo "greeter: /etc/sddm.conf.d/30-omarchy-port-greeter.conf"
else
  rm -f /etc/sddm.conf.d/30-omarchy-port-greeter.conf
  echo "UWAGA: Omarchy woła greeter inaczej niż w v4.0.4 (10-wayland.conf) — config greetera portu pominięty, przejrzyj session/sddm-hyprland.lua" >&2
fi

# Migracje Omarchy, które na Voidzie nie idą w wersji z upstreamu (share/void/migracje.tsv): w drzewie
# Omarchy zaślepka wypisująca powód albo podmiana portu — upstreamowe omarchy-migrate uruchamia je jak
# każdą migrację i stawia znacznik. Etap 3 orkiestratora wypakowuje migracje od nowa przy każdym
# przebiegu, więc lista idzie za każdym razem (orkiestrator sprawdza ją na źródle przed zmianami).
if [[ -d /usr/share/omarchy/migrations ]]; then
  while IFS=$'\t' read -r mig akcja powod; do
    [[ -z $mig || $mig == \#* ]] && continue
    m=/usr/share/omarchy/migrations/$mig
    if [[ ! -f $m ]]; then
      echo "UWAGA: migracje.tsv: $mig nie istnieje w tej wersji Omarchy — przejrzyj listę" >&2
      continue
    fi
    case $akcja in
      pomiń)
        printf '# omarchy-port: migracja pominięta na Voidzie (port/share/void/migracje.tsv)\necho %q\n' \
          "omarchy-port: pominięta — $powod" >"$m" ;;
      podmień) install -m 644 "$SRC/share/void/migracje/$mig" "$m" ;;
      *) echo "UWAGA: migracje.tsv: nieznana akcja '$akcja' dla $mig" >&2; continue ;;
    esac
    echo "migracja: $mig — $akcja"
  done <"$SRC/share/void/migracje.tsv"
  # Migracje samego portu: omarchy-migrate uruchamia je jak upstreamowe — raz na konto, jako użytkownik
  # (po omarchy-update i przy logowaniu). Świeża instalacja oznacza je jako wykonane razem z resztą
  # (omarchy-provision-user --first-install), bo nowe konto dostaje ich skutek ze /etc/skel.
  for m in "$SRC"/share/void/migracje-portu/*.sh; do
    [[ -e $m ]] || continue
    install -m 644 "$m" /usr/share/omarchy/migrations/
    echo "migracja portu: $(basename "$m")"
  done
fi

# Łatki (ścieżki względem /usr/share/omarchy): share/latki — poprawki z mastera Omarchy, których
# przypięte wydanie jeszcze nie ma; share/void/latki — zmiany Voida, których upstream mieć nie będzie
# (branding menu i paska). Każda opisuje w nagłówku, skąd jest i po co. Etap 3 orkiestratora wypakowuje
# pliki od nowa przy każdym przebiegu, więc łatka idzie za każdym razem. Cofnięcie pasuje = plik ma już tę
# zmianę: po świeżym wypakowaniu (OMARCHY_PORT_SWIEZE_PLIKI od orkiestratora) to znaczy, że wydanie ją
# zawiera i łatkę można usunąć, a przy samodzielnym ponownym uruchomieniu — że port ją już nałożył.
# Nie pasuje ani łatka, ani cofnięcie (inna wersja Omarchy) = UWAGA i bez zmian; orkiestrator
# dodatkowo liczy to jako błąd w podsumowaniu. Działająca powłoka (Quickshell) NIE przeładowuje
# zmienionych plików QML sama — łatka działa od restartu powłoki albo systemu (na Archu
# omarchy-update-restart woła po aktualizacji omarchy-restart-shell; orkiestrator kończy się
# poleceniem restartu systemu).
shopt -s nullglob
latki=("$SRC"/share/latki/*.patch "$SRC"/share/void/latki/*.patch)
shopt -u nullglob
if (( ${#latki[@]} == 0 )); then
  :
elif [[ ! -d /usr/share/omarchy/shell ]]; then
  echo "UWAGA: brak plików Omarchy w /usr/share/omarchy — łatki pominięte, puść install-layer.sh ponownie po ich instalacji" >&2
elif ! command -v git >/dev/null; then
  echo "UWAGA: brak gita (łatki nakłada git apply) — łatki pominięte: xbps-install -S git" >&2
else
  for l in "${latki[@]}"; do
    n=${l#"$SRC"/share/}
    if git -C /usr/share/omarchy apply --check -R -p1 "$l" 2>/dev/null; then
      if [[ ${OMARCHY_PORT_SWIEZE_PLIKI:-} == 1 ]]; then
        echo "UWAGA: łatka $n — wydanie Omarchy ma już tę zmianę, łatkę można usunąć" >&2
      else
        echo "łatka: $n — już nałożona"
      fi
    elif git -C /usr/share/omarchy apply --check -p1 "$l" 2>/dev/null; then
      git -C /usr/share/omarchy apply -p1 "$l"
      echo "łatka: $n (działa od restartu powłoki: omarchy-restart-shell w sesji albo restart systemu)"
    else
      echo "UWAGA: łatka $n nie pasuje do plików Omarchy w /usr/share/omarchy — przejrzyj ją przy zmianie wersji" >&2
    fi
  done
fi

# Branding Voida (omarchy-port#7). Kosmetyka, więc błąd nie przerywa warstwy, ale nie może zginąć w jej
# logu: plik $STATE/branding-blad orkiestrator wpisuje do podsumowania i kodu wyjścia, jak łatkę,
# która nie weszła.
if [[ ! -d /usr/share/omarchy/bin ]]; then
  echo "UWAGA: brak plików Omarchy w /usr/share/omarchy — branding pominięty, puść install-layer.sh ponownie po ich instalacji" >&2
else
  install -d "$STATE"
  if bash "$SRC/share/void/branding.sh"; then
    rm -f "$STATE/branding-blad"
  else
    echo "branding Voida niepełny — przyczyna w logu warstwy, w liniach z prefiksem branding:" >"$STATE/branding-blad"
    echo "UWAGA: $(cat "$STATE/branding-blad")" >&2
  fi
fi
echo LAYER-OK
