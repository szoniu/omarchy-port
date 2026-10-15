# shellcheck shell=bash
# omarchy-port: nazwy pakietów Archa (tak woła je Omarchy) → nazwy Voida.
# Źródło: /usr/share/omarchy-port/mapa-pakietow-void.tsv (kolumny: arch, stan, void, na_archu_z).
# Pakiet spoza mapy próbujemy pod tą samą nazwą — Omarchy dociąga na żądanie
# rzeczy spoza listy bazowej (np. sof-firmware), a większość nazw jest wspólna.
# Stan „port”: pakiet z omarchy-pkgs bez odpowiednika w repo Voida, który instaluje port/install.sh
# (etap 3, package() z PKGBUILD-a) — nazwa „port:<arch>”, obecność = manifest portu, nie baza xbps.

PORT_PKG_MAP=${PORT_PKG_MAP:-/usr/share/omarchy-port/mapa-pakietow-void.tsv}

# port_pkg_name <arch> → wypisuje nazwę Voida (albo port:<arch>); rc 1 = pakietu świadomie brak na Voidzie
port_pkg_name() {
  local arch=$1 row stan void
  row=$(awk -F'\t' -v p="$arch" 'NR > 1 && $1 == p { print $2 "\t" $3; exit }' "$PORT_PKG_MAP" 2>/dev/null)
  if [[ -z $row ]]; then
    printf '%s\n' "$arch"
    return 0
  fi
  stan=${row%%$'\t'*}
  void=${row#*$'\t'}
  if [[ $stan == port ]]; then
    printf 'port:%s\n' "$arch"
    return 0
  fi
  if [[ $stan == brak || -z $void ]]; then
    echo "omarchy-port: pakietu '$arch' nie ma na Voidzie (mapa: $PORT_PKG_MAP)" >&2
    return 1
  fi
  printf '%s\n' "$void"
}

# port_pkg_installed <nazwa-voida|port:<arch>>
port_pkg_installed() {
  if [[ $1 == port:* ]]; then
    [[ -s /var/lib/omarchy-port/manifest-${1#port:}.txt ]]
    return
  fi
  xbps-query "$1" >/dev/null 2>&1
}
