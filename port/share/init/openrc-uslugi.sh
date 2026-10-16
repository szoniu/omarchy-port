# shellcheck shell=bash
# shellcheck disable=SC2034  # USL_KOLUMNA czyta front
# omarchy-port: backend usług OpenRC (Gentoo) dla shima systemctl (port/bin/systemctl) — front sourcuje go
# z /usr/share/omarchy-port/uslugi-backend.sh (kładzie go install-layer.sh). Front robi mapę nazw, kody
# wyjścia i komunikaty systemd i daje tu log oraz MAP; tu jest tylko mechanika OpenRC.
# rc-update add NIE startuje usługi, więc „włączona od następnego startu” (Omarchy: „Enable services only…
# don't start daemons mid-install”) wychodzi sama — bez trybu instalacji, którego potrzebuje runit.
# Pełne ścieżki: Omarchy sprawdza stan usług bez sudo, a w sesji PATH bywa bez /sbin.
USL_KOLUMNA=openrc
RC_SERVICE=/sbin/rc-service
RC_UPDATE=/sbin/rc-update
RUNLEVELS=/etc/runlevels

usl_istnieje() { [[ -x /etc/init.d/$1 ]]; }

# runlevel z mapy (kolumna openrc: elogind@boot), domyślnie default
usl_runlevel() {
  local r
  r=$(awk -F'\t' -v n="$1" '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == "openrc") c = i; next }
    c && index($c, n "@") == 1 { print substr($c, length(n) + 2); exit }' "$MAP" 2>/dev/null)
  printf '%s\n' "${r:-default}"
}

# Stan z `rc-service <nazwa> status` („* status: started|stopped|crashed|…”) — oba strumienie, bo
# „crashed” OpenRC wypisuje przez eerror na stderr. Gdyby bez roota rc-service nie odpowiedział, zostaje
# katalog stanu OpenRC (/run/openrc/started — czytelny dla wszystkich).
usl_stan() {
  local st
  st=$("$RC_SERVICE" "$1" status 2>&1 | sed -n 's/.*status: *\([a-z]*\).*/\1/p' | head -1)
  case $st in
    started) echo run ;;
    crashed) echo crashed ;;
    '') if [[ -e /run/openrc/started/$1 ]]; then echo run; else echo down; fi ;;
    *) echo down ;;
  esac
}
# włączona = w którymkolwiek runlevelu (admin mógł dodać usługę do boot zamiast default)
usl_wlaczona() {
  local r
  for r in "$RUNLEVELS"/*/"$1"; do [[ -L $r ]] && return 0; done
  return 1
}

# SDDM na OpenRC nie ma własnego skryptu: wstaje przez display-manager (gui-libs/display-manager-init,
# dociągany przez sddm[-systemd]) z DISPLAYMANAGER w /etc/conf.d/display-manager (domyślnie xdm).
# Omarchy włącza sddm.service, a mapa kieruje to na display-manager — innego menedżera port nie włącza.
dm_sddm() {
  local f=/etc/conf.d/display-manager
  if [[ -f $f ]] && grep -q '^DISPLAYMANAGER=' "$f"; then
    sed -i 's/^DISPLAYMANAGER=.*/DISPLAYMANAGER="sddm"/' "$f"
  else
    echo 'DISPLAYMANAGER="sddm"' >>"$f"
  fi
}

usl_wlacz() { # usl_wlacz <nazwa> <now>
  if ! usl_wlaczona "$1"; then
    "$RC_UPDATE" add "$1" "$(usl_runlevel "$1")" >/dev/null || return 1
  fi
  if [[ $1 == display-manager ]]; then dm_sddm || return 1; fi
  if (( $2 )); then usl_start "$1" || return 1; fi
  return 0
}
# disable = zdjęcie z każdego runlevelu, bez zatrzymania — jak w systemd; --now dodatkowo zatrzymuje
usl_wylacz() { # usl_wylacz <nazwa> <now>
  local r
  for r in "$RUNLEVELS"/*/"$1"; do
    [[ -L $r ]] || continue
    "$RC_UPDATE" del "$1" "$(basename "$(dirname "$r")")" >/dev/null || return 1
  done
  if (( $2 )); then usl_stop "$1" || return 1; fi
  return 0
}
# OpenRC nie ma maski: mask = disable bez zatrzymania (jak systemctl mask), unmask nic nie robi
usl_maskuj() { usl_wylacz "$1" 0; }
usl_odmaskuj() { :; }
# Usługa „crashed” jest dla OpenRC wciąż uruchomiona: start mówi „already started”, więc najpierw zap
usl_start() {
  case $(usl_stan "$1") in
    run) return 0 ;;
    crashed) "$RC_SERVICE" "$1" zap >/dev/null ;;
  esac
  "$RC_SERVICE" "$1" start >/dev/null
}
usl_restart() {
  if [[ $(usl_stan "$1") == crashed ]]; then "$RC_SERVICE" "$1" zap >/dev/null; fi
  "$RC_SERVICE" "$1" restart >/dev/null
}
usl_stop() { [[ $(usl_stan "$1") == down ]] || "$RC_SERVICE" "$1" stop >/dev/null; }
usl_przeladuj() { "$RC_SERVICE" "$1" reload >/dev/null; }
