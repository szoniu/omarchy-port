# shellcheck shell=bash
# omarchy-port: backend Voida (xbps) dla install.sh — etapy 1–2 i pliki należące do pakietów dystrybucji.
# Sourcowany przez orkiestrator po wykryj_system; korzysta z jego die, DYST, REPO.

dyst_sprawdz() {
  [[ $(xbps-uhelper arch) == x86_64 ]] || die "na razie tylko Void x86_64 z glibc (jest: $(xbps-uhelper arch))"
}

dyst_repozytoria() {
  # Adres i nazwa pliku jak w instalatorze szoniu/void (_setup_hyprland_repo) — oba trafiają w to samo.
  # Klucz blackhole NIE jest przyjmowany w ciemno: przypięty plik trafia do keys/ PRZED pierwszą
  # synchronizacją, xbps dostaje </dev/null (pytanie o nowy klucz = odmowa, a nie Enter = „tak”),
  # a po synchronizacji repo musi być podpisane kluczem o przypiętym odcisku — także wtedy, gdy klucz
  # był już w systemie (np. przyjęty przez instalator).
  BH_CONF=/etc/xbps.d/20-blackhole.conf
  BH_URL="https://mirror.black-hole.dev/$(xbps-uhelper arch)"
  local klucze fp
  klucze=("$DYST"/xbps-keys/*.plist)
  (( ${#klucze[@]} == 1 )) || die "w $DYST/xbps-keys ma być dokładnie jeden klucz"
  BH_FP=${klucze[0]##*/}
  BH_FP=${BH_FP%.plist}   # nazwa pliku klucza xbps = jego odcisk
  BH_KEY=/var/db/xbps/keys/${klucze[0]##*/}
  bh_key_nowy=0
  [[ -e $BH_KEY ]] || bh_key_nowy=1
  install -m 644 "${klucze[0]}" /var/db/xbps/keys/
  echo "repository=$BH_URL" >"$BH_CONF"
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
}
odrzuc_blackhole() { # repo i klucz wgrany przez ten przebieg znikają — przyjęty wcześniej zostaje
  rm -f "$BH_CONF"
  if ((bh_key_nowy)); then rm -f "$BH_KEY"; fi
}
synchro() {
  "$@" </dev/null && return 0
  odrzuc_blackhole
  die "$* nie powiodło się — jeśli xbps pytał wyżej o klucz, repo blackhole podpisuje inny klucz niż przypięty ($BH_FP); repo usunięte"
}

dyst_pakiety() { # dyst_pakiety <nazwa…> — pełna aktualizacja, potem lista Omarchy
  xbps-install -yu </dev/null   # pełna aktualizacja przed doinstalowaniem — xbps nie robi aktualizacji częściowych
  xbps-install -y "$@" </dev/null
}

# Ścieżki należące do pakietów Voida — raz, z list plików w bazie xbps (xbps-query -o na plik to
# ~0,25 s, a plików Omarchy jest ~2000).
dyst_pliki_pakietow() {
  sed -n 's|^[[:space:]]*<string>\(/[^<]*\)</string>.*|\1|p' /var/db/xbps/.*-files.plist | LC_ALL=C sort -u
}
dyst_wlasciciel() { # dyst_wlasciciel <plik> — nazwa pakietu Voida, do którego plik należy
  xbps-query -o "$1" 2>/dev/null | head -1 | cut -d: -f1
}
