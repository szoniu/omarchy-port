#!/usr/bin/env bash
# omarchy-port: instalacja warstwy zgodności (Void/runit). Jako root, idempotentnie.
#   shimy (systemctl, systemd-run, systemd-cat, uwsm-app, xdg-terminal-exec) → /usr/local/bin,
#       TYLKO gdy prawdziwego polecenia nie ma (na Gentoo z systemd żaden nie powstaje);
#   nakładki pakietowe (omarchy-pkg-*) i nadzorca unitów → /usr/local/bin, zawsze —
#       /usr/local/bin jest w PATH i w secure_path sudo PRZED /usr/bin z plikami Omarchy,
#       a linki w /usr/share/omarchy/bin (PATH sesji) są przekierowane na nakładki;
#   dane → /usr/share/omarchy-port, sesja → /usr/libexec/omarchy-port + wayland-sessions,
#   greeter SDDM → config portu (upstreamowy + no_update_news) przez /etc/sddm.conf.d.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SRC/.." && pwd)"
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

for f in "$SRC"/bin/omarchy-pkg-* "$SRC/bin/omarchy-port-units"; do
  install -m 755 "$f" /usr/local/bin/
  echo "nakładka: /usr/local/bin/$(basename "$f")"
done

# Sesja Omarchy (default/uwsm) i omarchy-provision-user stawiają /usr/share/omarchy/bin PRZED
# /usr/local/bin, a package() Omarchy robi tam linki do /usr/bin/omarchy-* (wersje z pacmanem).
# Bez przekierowania nakładka działa tylko z SSH i sudo, a w sesji (menu, skróty) wygrywa pacman.
# Każda reinstalacja plików Omarchy odtwarza te linki — po niej ten skrypt trzeba puścić ponownie.
if [[ -d /usr/share/omarchy/bin ]]; then
  for f in "$SRC"/bin/omarchy-pkg-*; do
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
echo LAYER-OK
