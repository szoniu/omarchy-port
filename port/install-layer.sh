#!/usr/bin/env bash
# omarchy-port: instalacja warstwy zgodności (Void/runit). Jako root, idempotentnie.
#   shimy (systemctl, systemd-run, systemd-cat, uwsm-app, xdg-terminal-exec) → /usr/local/bin,
#       TYLKO gdy prawdziwego polecenia nie ma (na Gentoo z systemd żaden nie powstaje);
#   nakładki pakietowe (omarchy-pkg-*) i nadzorca unitów → /usr/local/bin, zawsze —
#       /usr/local/bin jest w PATH i w secure_path sudo PRZED /usr/bin z plikami Omarchy;
#   dane → /usr/share/omarchy-port, sesja → /usr/libexec/omarchy-port + wayland-sessions.
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

install -m 755 "$SRC/session/session" /usr/libexec/omarchy-port/session
install -m 644 "$SRC/session/omarchy-void.desktop" /usr/share/wayland-sessions/
echo "sesja: /usr/libexec/omarchy-port/session"
echo LAYER-OK
