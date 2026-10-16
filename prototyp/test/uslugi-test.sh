#!/usr/bin/env bash
# Test shima systemctl dla usług systemowych (backend runit albo OpenRC) — jako root, w VM, na działającym
# systemie. Sesja niepotrzebna, więc test idzie też na bazie przed instalacją portu (shim, mapa i backend
# położone ręcznie). Stan sprawdzany WPROST w initcie (runit: /var/service i pliki down; OpenRC:
# /etc/runlevels i rc-service), nie przez shim — to shim jest tu testowany.
# Usługa testowa (U): na runit uuidd (util-linux z Voida), na OpenRC rsyncd (rsync w stage3; uuidd na Gentoo
# wymaga USE uuidd w util-linux) — obie nieszkodliwe, nic od nich nie zależy, rsyncd ma pidfile /run/rsyncd.pid.
#   prototyp/test/uslugi-test.sh      → OK/FAIL na wiersz, kod 1 przy jakimkolwiek FAIL
# shellcheck disable=SC2034  # out i rc czytają asercje w eval (t)
set -uo pipefail
(( EUID == 0 )) || { echo "uslugi-test.sh: uruchom jako root" >&2; exit 2; }
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[[ $(command -v systemctl) == /usr/local/bin/systemctl ]] ||
  { echo "uslugi-test.sh: systemctl to nie shim portu ($(command -v systemctl)) — test dotyczy initów bez systemd" >&2; exit 2; }
FAIL=0
ok() { printf '  %-4s %s\n' "$1" "$2"; }
t() { if eval "$2"; then ok OK "$1"; else ok FAIL "$1"; FAIL=$((FAIL + 1)); fi; }
if [[ -d /run/openrc ]]; then
  INIT=openrc
  wlaczona() { [[ -L /etc/runlevels/${2:-default}/$1 ]]; }
  gdziekolwiek() { [[ -n $(compgen -G "/etc/runlevels/*/$1") ]]; }
  dziala() { [[ $(rc-service "$1" status 2>/dev/null) == *'status: started'* ]]; }
  PRZERWA=1   # rc-service działa synchronicznie
  U=rsyncd
else
  INIT=runit
  wlaczona() { [[ -L /var/service/$1 && ! -e /etc/sv/$1/down ]]; }
  gdziekolwiek() { [[ -L /var/service/$1 ]]; }
  dziala() { [[ $(sv status "/var/service/$1" 2>/dev/null) == run:* ]]; }
  PRZERWA=6   # runsvdir skanuje /var/service co ~5 s
  U=uuidd
fi
echo "### init: $INIT, usługa testowa: $U"

echo "### stan wyjściowy: $U wyłączony i zatrzymany"
systemctl disable --now "$U.service" >/dev/null 2>&1; sleep "$PRZERWA"
t "disable --now: nie ma go w initcie i nie działa" '! gdziekolwiek $U && ! dziala $U'
out=$(systemctl is-enabled "$U.service"); rc=$?
t "is-enabled wyłączonej: disabled, rc 1" '[[ $out == disabled && $rc == 1 ]]'
out=$(systemctl is-active "$U.service"); rc=$?
t "is-active zatrzymanej: inactive, rc 3" '[[ $out == inactive && $rc == 3 ]]'

echo "### enable bez --now"
systemctl enable "$U.service"; sleep "$PRZERWA"
if [[ $INIT == openrc ]]; then
  t "OpenRC: włączona (default) i NIE uruchomiona — jak w systemd" 'wlaczona $U && ! dziala $U'
else
  t "runit: włączona i uruchomiona (bez trybu instalacji runit startuje od razu)" 'wlaczona $U && dziala $U'
fi
t "is-enabled: enabled" '[[ $(systemctl is-enabled "$U.service") == enabled ]]'

echo "### tryb instalacji (OMARCHY_PORT_INSTALL): włączona od następnego startu"
systemctl disable --now "$U.service" >/dev/null; sleep "$PRZERWA"
OMARCHY_PORT_INSTALL=1 systemctl enable "$U.service"; sleep "$PRZERWA"
t "is-enabled: enabled" '[[ $(systemctl is-enabled "$U.service") == enabled ]]'
t "nie uruchomiona do restartu" '! dziala $U'
systemctl disable "$U.service" >/dev/null   # runit: zdejmuje też wpis z listy start-at-boot

echo "### enable --now, disable bez --now, stop/start/restart"
systemctl enable --now "$U.service"
t "enable --now: działa od razu" 'dziala $U'
t "is-active: active" '[[ $(systemctl is-active "$U.service") == active ]]'
systemctl disable "$U.service"; sleep "$PRZERWA"
t "disable bez --now: wyłączona, dalej działa" '! wlaczona $U && dziala $U'
systemctl stop "$U.service"; sleep 1
t "stop: nie działa" '! dziala $U'
systemctl start "$U.service"
t "start (usługa wyłączona): działa" 'dziala $U'
systemctl restart "$U.service"
t "restart: działa" 'dziala $U'

if [[ $INIT == openrc ]]; then
  echo "### OpenRC: usługa w innym runlevelu (admin dodał ją do boot)"
  systemctl disable --now "$U.service" >/dev/null
  rc-update add "$U" boot >/dev/null
  t "is-enabled: enabled (runlevel boot)" '[[ $(systemctl is-enabled "$U.service") == enabled ]]'
  systemctl enable "$U.service"
  t "enable nie dubluje wpisu w default" 'wlaczona $U boot && ! wlaczona $U default'
  systemctl disable "$U.service"
  t "disable zdejmuje z boot" '! gdziekolwiek $U'

  echo "### OpenRC: usługa padła (crashed)"
  systemctl start "$U.service"
  kill -9 "$(cat "/run/$U.pid")"; sleep 1
  t "rc-service widzi crashed" '[[ $(rc-service "$U" status 2>&1) == *crashed* ]]   # crashed idzie na stderr'
  out=$(systemctl is-active "$U.service"); rc=$?
  t "is-active po padnięciu: inactive, rc 3" '[[ $out == inactive && $rc == 3 ]]'
  systemctl restart "$U.service"
  t "restart podnosi usługę po padnięciu" 'dziala $U'
  systemctl stop "$U.service"

  echo "### OpenRC: runlevel z mapy (elogind@boot)"
  if [[ -x /etc/init.d/elogind ]]; then
    systemctl enable elogind.service
    t "elogind w boot, nie w default" 'wlaczona elogind boot && ! wlaczona elogind default'
  else
    ok -- "brak /etc/init.d/elogind — pominięte"
  fi

  echo "### OpenRC: sddm → display-manager + DISPLAYMANAGER"
  if [[ -x /etc/init.d/display-manager ]]; then
    cp -p /etc/conf.d/display-manager /etc/conf.d/display-manager.uslugi-test
    sed -i 's/^DISPLAYMANAGER=.*/DISPLAYMANAGER="xdm"/' /etc/conf.d/display-manager
    systemctl enable sddm.service
    t "display-manager w default" 'wlaczona display-manager'
    t "jedna linia DISPLAYMANAGER=\"sddm\" (było xdm)" '[[ $(grep -c "^DISPLAYMANAGER=" /etc/conf.d/display-manager) == 1 ]] && grep -qx "DISPLAYMANAGER=\"sddm\"" /etc/conf.d/display-manager'
    mv -f /etc/conf.d/display-manager.uslugi-test /etc/conf.d/display-manager
  else
    ok -- "brak /etc/init.d/display-manager (baza przed instalacją portu) — pominięte"
  fi
fi

echo "### usługa bez pakietu, pominięta, mapa nazw"
systemctl enable supergfxd.service 2>/dev/null; rc=$?
t "supergfxd (brak pakietu): rc 5, bez wpisu w initcie" '[[ $rc == 5 ]] && ! gdziekolwiek supergfxd'
systemctl enable systemd-oomd.service 2>/dev/null; rc=$?
t "systemd-oomd (- w mapie): rc 0" '[[ $rc == 0 ]]'
out=$(systemctl is-active systemd-oomd.service); rc=$?
t "is-active pominiętej: inactive, rc 3" '[[ $out == inactive && $rc == 3 ]]'
if [[ -e /etc/sv/chronyd || -x /etc/init.d/chronyd ]]; then
  t "status systemd-timesyncd → chronyd" '[[ $(systemctl status systemd-timesyncd.service) == *"(chronyd)"* ]]'
else
  ok -- "brak chronyd (baza przed instalacją portu) — mapa nazw pominięta"
fi

echo "### bez roota, ubogi PATH (jak systemctl is-active w sesji)"
t "is-active sshd jako nobody z PATH=/usr/bin:/bin" '[[ $(su -s /bin/sh nobody -c "env -i PATH=/usr/bin:/bin /usr/local/bin/systemctl is-active sshd.service" 2>/dev/null) == active ]]'

if [[ -x /usr/local/bin/systemd-run ]]; then
  echo "### timery roota (systemd-run --on-active)"
  systemd-run --on-active=60s --unit=omarchy-uslugi-test true
  t "is-active timera: active" '[[ $(systemctl is-active omarchy-uslugi-test.timer) == active ]]'
  systemctl stop omarchy-uslugi-test.timer
  t "po stop: inactive" '[[ $(systemctl is-active omarchy-uslugi-test.timer) == inactive ]]'
fi

systemctl disable --now "$U.service" >/dev/null 2>&1
echo "FAIL: $FAIL"
(( FAIL == 0 ))
