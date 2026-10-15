# shellcheck shell=bash
# shellcheck disable=SC2034  # USLUGI_BAZOWE czyta install.sh (etap 9)
# omarchy-port: init systemd (Gentoo) dla install.sh — prawdziwe systemctl, bez shimów portu.

init_pid() { # init_pid <usługa> — PID procesu głównego działającej usługi (0 = nie działa)
  local pid
  pid=$(systemctl show -p MainPID --value "$1.service" 2>/dev/null) || return 1
  [[ $pid =~ ^[1-9][0-9]*$ ]] && echo "$pid"
}
# SIGHUP: sshd uruchamia się od nowa z dysku (re-exec), trwające sesje — osobne procesy — zostają.
# `systemctl restart` przy KillMode innym niż process zamknąłby też sesję, z której idzie instalacja.
init_przeladuj_sshd() {
  local pid
  pid=$(init_pid sshd) || return 1
  kill -HUP "$pid"
}
# dbus i polkit są na systemd aktywowane same; NTP jak na Archu — systemd-timesyncd
# (omarchy-update-time restartuje właśnie tę usługę).
USLUGI_BAZOWE=(systemd-timesyncd)
