# shellcheck shell=bash
# omarchy-port: rozpoznanie dystrybucji i initu — wspólne dla install.sh i install-layer.sh.
#   DYSTR: void (xbps) | gentoo (emerge) — wybiera katalog share/<DYSTR> (backend, kroki, migracje, łatki)
#   INIT:  runit | systemd | openrc — po działającym systemie, nie po zainstalowanych pakietach
# Obsługiwane pary: void/runit, gentoo/systemd. Gentoo z OpenRC: omarchy-port#5 (w drodze).
wykryj_system() { # ustawia DYSTR i INIT; rc 1 + powód na stderr, gdy pary nie zna
  if command -v xbps-install >/dev/null; then
    DYSTR=void
  elif command -v emerge >/dev/null; then
    DYSTR=gentoo
  else
    echo "nieobsługiwana dystrybucja — port zna Voida (xbps) i Gentoo (emerge)" >&2
    return 1
  fi
  # /run/systemd/system zakłada tylko działający systemd, /run/openrc działający OpenRC, a /var/service
  # na Voidzie wskazuje na /run/runit/… — w chroocie żadnego z nich nie ma
  if [[ -d /run/systemd/system ]]; then
    INIT=systemd
  elif [[ -d /run/openrc ]]; then
    INIT=openrc
  elif [[ -d /var/service ]]; then
    INIT=runit
  else
    echo "nie rozpoznaję działającego initu (runit, systemd, OpenRC) — chroot? port wymaga uruchomionego systemu" >&2
    return 1
  fi
  case $DYSTR/$INIT in
    void/runit | gentoo/systemd) ;;
    gentoo/openrc)
      echo "Gentoo z OpenRC: jeszcze nieobsługiwane (omarchy-port#5)" >&2
      return 1 ;;
    *)
      echo "$DYSTR z $INIT: nieobsługiwane" >&2
      return 1 ;;
  esac
}
