# shellcheck shell=bash
# shellcheck disable=SC2034  # USL_KOLUMNA czyta front
# omarchy-port: backend usług runit (Void) dla shima systemctl (port/bin/systemctl) — front sourcuje go
# z /usr/share/omarchy-port/uslugi-backend.sh (kładzie go install-layer.sh). Front robi mapę nazw, kody
# wyjścia i komunikaty systemd i daje tu log oraz MAP; tu jest tylko mechanika runit.
USL_KOLUMNA=runit
SVDIR=/etc/sv
RUNSVDIR=/var/service
# Tryb instalacji (OMARCHY_PORT_INSTALL=1, ustawia go port/install.sh): `enable` bez --now NIE startuje
# usługi — jak w systemd, a Omarchy na tym polega („Enable services only… don't start daemons
# mid-install”). runit nie ma stanu „włączona od następnego startu”, więc: link + plik down + wpis tu;
# core-service 91-omarchy-port-start-at-boot.sh zdejmuje down przed startem usług.
START_AT_BOOT=/var/lib/omarchy-port/start-at-boot
pending() { [[ -f $START_AT_BOOT ]] && /usr/bin/grep -qxF -- "$1" "$START_AT_BOOT"; }
unpend() { [[ -f $START_AT_BOOT ]] && sed -i "/^${1//./\\.}\$/d" "$START_AT_BOOT"; return 0; }
# runsvdir skanuje /var/service co ~5 s — czekamy, aż runsv tej usługi odpowiada (sv status), zamiast
# zakładać, że już jest. Nie na supervise/stat: plik zostaje po poprzednim runsv (supervise/ to link do
# /run/runit), więc przy świeżym linku wyglądał na gotowy, zanim nowy nadzorca wstał, i sv up padał.
wait_supervised() { local _; for _ in $(seq 1 30); do sv status "$RUNSVDIR/$1" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
wait_state() { local _; for _ in $(seq 1 30); do [[ $(usl_stan "$1") == "$2" ]] && return 0; sleep 0.5; done; return 1; }

usl_istnieje() { [[ -d $SVDIR/$1 ]]; }

# Stan usługi: root czyta supervise/stat. Użytkownik NIE — supervise/ to symlink do
# /run/runit/supervise.<nazwa> z prawami 0700 (a `sv status` wymaga supervise/ok), więc bez roota
# patrzymy w jawną tablicę procesów: `runsv <nazwa>` ma dziecko-usługę, a przy log/ także logger.
usl_stan() {
  local st r n expect=0
  st=$(awk '{ print $1; exit }' "$RUNSVDIR/$1/supervise/stat" 2>/dev/null)
  [[ -n $st ]] && { echo "$st"; return; }
  r=$(pgrep -fx "runsv $1") || { echo ''; return; }
  n=$(pgrep -P "$r" | wc -l)
  [[ -e $SVDIR/$1/log/run ]] && expect=1
  (( n > expect )) && echo run || echo down
}
usl_wlaczona() { [[ -L $RUNSVDIR/$1 ]] && { [[ ! -e $SVDIR/$1/down ]] || pending "$1"; }; }

# Semantyka systemd na runit:
#   enable         = link w /var/service + brak pliku down (start przy boocie)
#   disable        = plik down (BEZ zatrzymania — tak jak systemd; Omarchy na tym polega:
#                    `disable docker.service` „do not stop running containers”, `disable iwd`)
#   disable --now  = usunięcie linku (zatrzymuje)
#   mask           = usunięcie linku + down
usl_wlacz() { # usl_wlacz <nazwa> <now>
  if [[ -n ${OMARCHY_PORT_INSTALL:-} ]] && (( ! $2 )) && [[ ! -L $RUNSVDIR/$1 ]]; then
    # down PRZED linkiem — runsv nie może zdążyć wystartować usługi
    touch "$SVDIR/$1/down"
    ln -sfn "$SVDIR/$1" "$RUNSVDIR/$1" || return 1
    mkdir -p "${START_AT_BOOT%/*}"
    pending "$1" || echo "$1" >>"$START_AT_BOOT"
    log "instalacja: $1 włączona od następnego startu"
    return 0
  fi
  rm -f "$SVDIR/$1/down"
  ln -sfn "$SVDIR/$1" "$RUNSVDIR/$1" || return 1
  if (( $2 )); then
    # sv up: usługa już nadzorowana i zatrzymana (wcześniej plik down) po zdjęciu down sama nie wstaje
    wait_supervised "$1" && sv up "$RUNSVDIR/$1" >/dev/null && wait_state "$1" run ||
      { echo "systemctl (omarchy-port): $1 nie wystartował" >&2; return 1; }
  fi
  return 0
}
usl_wylacz() { # usl_wylacz <nazwa> <now>
  unpend "$1"
  if (( $2 )); then rm -f "$RUNSVDIR/$1"; else touch "$SVDIR/$1/down"; fi
}
usl_maskuj() { unpend "$1"; rm -f "$RUNSVDIR/$1"; touch "$SVDIR/$1/down"; }
usl_odmaskuj() { rm -f "$SVDIR/$1/down"; }
# systemd potrafi wystartować usługę wyłączoną — runit potrzebuje nadzorcy, więc link + down
nadzorowana() {
  if [[ ! -L $RUNSVDIR/$1 ]]; then touch "$SVDIR/$1/down"; ln -sfn "$SVDIR/$1" "$RUNSVDIR/$1"; fi
  wait_supervised "$1" || { echo "systemctl (omarchy-port): runsv nie podjął $1" >&2; return 1; }
}
usl_start() { nadzorowana "$1" && sv start "$RUNSVDIR/$1" >/dev/null; }
# sv restart potrafi wrócić, zanim usługa wstanie („down, want up”) — systemctl restart czeka na start
usl_restart() { nadzorowana "$1" && sv restart "$RUNSVDIR/$1" >/dev/null && wait_state "$1" run; }
usl_stop() { [[ ! -L $RUNSVDIR/$1 ]] || sv stop "$RUNSVDIR/$1" >/dev/null; }
usl_przeladuj() { sv hup "$RUNSVDIR/$1" >/dev/null; }
