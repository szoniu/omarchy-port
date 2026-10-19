# shellcheck shell=bash
# omarchy-port: nazwy pakietów Archa (tak woła je Omarchy) → nazwy dystrybucji (Void: nazwa xbps,
# Gentoo: atom kategoria/pakiet[:slot]) i backend pakietów dystrybucji dla nakładek omarchy-pkg-*.
# Źródła: /usr/share/omarchy-port/mapa-pakietow.tsv (kolumny: arch, stan, nazwa w dystrybucji,
# na_archu_z) i pkg-backend.sh (z port/share/<dystrybucja>/pkg.sh) — oba kładzie install-layer.sh.
# Pakiet spoza mapy próbujemy pod tą samą nazwą — Omarchy dociąga na żądanie
# rzeczy spoza listy bazowej (np. sof-firmware), a większość nazw jest wspólna.
# Stan „port”: pakiet bez odpowiednika w repo dystrybucji, który instaluje port/install.sh (etap 3,
# package() z PKGBUILD-a) — nazwa „port:<arch>”, obecność = manifest portu, nie baza menedżera pakietów.

PORT_PKG_MAP=${PORT_PKG_MAP:-/usr/share/omarchy-port/mapa-pakietow.tsv}
PORT_PKG_BACKEND=${PORT_PKG_BACKEND:-/usr/share/omarchy-port/pkg-backend.sh}
# shellcheck source=void/pkg.sh
. "$PORT_PKG_BACKEND"

# port_pkg_name <arch> → wypisuje nazwę w dystrybucji (albo port:<arch>); rc 1 = pakietu świadomie brak
port_pkg_name() {
  local arch=$1 row stan nazwa
  # Nazwa od „-” trafiłaby do xbps/emerge jako opcja — upstream od v4.0.5 woła pacmana z `--` przed
  # nazwami, tu odmowa (rc 1 jak pakiet, którego brak: missing → rc 0, present i add → rc 1).
  if [[ $arch == -* ]]; then
    echo "omarchy-port: '$arch' nie jest nazwą pakietu" >&2
    return 1
  fi
  row=$(awk -F'\t' -v p="$arch" 'NR > 1 && $1 == p { print $2 "\t" $3; exit }' "$PORT_PKG_MAP" 2>/dev/null)
  if [[ -z $row ]]; then
    printf '%s\n' "$arch"
    return 0
  fi
  stan=${row%%$'\t'*}
  nazwa=${row#*$'\t'}
  if [[ $stan == port ]]; then
    printf 'port:%s\n' "$arch"
    return 0
  fi
  if [[ $stan == brak || -z $nazwa ]]; then
    echo "omarchy-port: pakietu '$arch' nie ma $PORT_NA (mapa: $PORT_PKG_MAP)" >&2
    return 1
  fi
  printf '%s\n' "$nazwa"
}

# port_pkg_installed <nazwa-w-dystrybucji|port:<arch>>
port_pkg_installed() {
  if [[ $1 == port:* ]]; then
    [[ -s /var/lib/omarchy-port/manifest-${1#port:}.txt ]]
    return
  fi
  backend_pkg_installed "$1"
}

# port_jako_root <funkcja backendu> <argumenty…> — instalacja i usuwanie pakietów (sudo, gdy trzeba)
port_jako_root() {
  if (( EUID == 0 )); then
    "$@"
  else
    sudo bash -c '. /usr/share/omarchy-port/pkg-map.sh && "$@"' bash "$@"
  fi
}
