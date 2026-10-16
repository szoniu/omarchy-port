# shellcheck shell=bash
# shellcheck disable=SC2034  # USLUGI_BAZOWE i INIT_PAKIETY* czyta install.sh (etapy 2 i 9)
# omarchy-port: init runit (Void) dla install.sh — usługi przez shim systemctl portu (port/bin/systemctl).

init_pid() { # init_pid <usługa> — PID procesu głównego działającej usługi
  cat "/var/service/$1/supervise/pid" 2>/dev/null
}
# runit wysyła TERM tylko do nasłuchującego sshd — trwające sesje (także ta z instalacją) zostają.
init_przeladuj_sshd() {
  sv restart sshd >/dev/null
}
# elogind celowo bez usługi runit: startuje z aktywacji D-Bus, a usługa obok kręci się w pętli
# „already running” (sprawdzone w VM). chronyd zamiast systemd-timesyncd, który na Archu dochodzi
# z systemd.
USLUGI_BAZOWE=(dbus polkitd chronyd)
# pakiety zależne od initu (etap 2) — tu bez zmian względem dane/pakiety-<dystrybucja>.txt
INIT_PAKIETY_BEZ=()
INIT_PAKIETY=()
