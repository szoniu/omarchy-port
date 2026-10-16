# shellcheck shell=bash
# shellcheck disable=SC2034  # USLUGI_BAZOWE i INIT_PAKIETY* czyta install.sh (etapy 2 i 9)
# omarchy-port: init OpenRC (Gentoo) dla install.sh — usługi przez shim systemctl portu (port/bin/systemctl,
# backend share/init/openrc-uslugi.sh).

init_pid() { # init_pid <usługa> — PID procesu głównego działającej usługi (pidfile jak w skryptach Gentoo)
  [[ $(/sbin/rc-service "$1" status 2>/dev/null) == *'status: started'* ]] || return 1
  cat "/run/$1.pid" 2>/dev/null
}
# Skrypt sshd z Gentoo przy reload sprawdza config i wysyła SIGHUP nasłuchującemu sshd — trwające sesje
# (także ta z instalacją) to osobne procesy i zostają.
init_przeladuj_sshd() {
  /sbin/rc-service sshd reload >/dev/null
}
# dbus i elogind (runlevel boot — uslugi.tsv) startują na OpenRC jako usługi; polkit z aktywacji D-Bus.
# NTP: chrony, jak na Voidzie (omarchy-update-time restartuje systemd-timesyncd → mapa: chronyd).
USLUGI_BAZOWE=(dbus elogind chronyd)
# uwsm: ebuild nie zależy od systemd, więc by się zainstalował — a uwsm stawia sesję z unitów
# systemd --user, których na OpenRC nie ma. Sesja idzie przez shim uwsm portu, jak na runit.
INIT_PAKIETY_BEZ=(gui-apps/uwsm)
# elogind dochodzi dziś z USE profilu desktop, ale loginctl i elogind-inhibit to twarda zależność portu
INIT_PAKIETY=(sys-auth/elogind net-misc/chrony)
