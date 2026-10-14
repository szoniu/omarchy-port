#!/usr/bin/env bash
# Prototyp portu Omarchy na Void (dotfiles#170) — RUNDA 1: upstream bez shimów.
# Cel: zmierzyć, co pada poza Archem. Odpalany jako root w VM przez SSH.
# Wszystkie logi: /root/port-proto/
set -uo pipefail
TAG=v4.0.4
W=/var/cache/omarchy-port
USERNAME=szoniu
LOG=/root/port-proto
mkdir -p "$W/src" "$LOG"
step() { echo; echo "=== $* ==="; }

step "1. źródło Omarchy $TAG"
rm -rf "$W/src/omarchy"
git clone -q --depth 1 --branch "$TAG" https://github.com/basecamp/omarchy.git "$W/src/omarchy"
git -C "$W/src/omarchy" log -1 --format='%h %ci'

step "2. upstream package() → stage"
for p in omarchy-settings omarchy; do
  rm -rf "$W/stage/$p"; mkdir -p "$W/stage/$p"
  (
    set -e
    srcdir="$W/src"; pkgdir="$W/stage/$p"
    cd "/root/omarchy-pkgs/$p"
    # shellcheck disable=SC1091
    source ./PKGBUILD
    package
  ) >"$LOG/package-$p.log" 2>&1
  echo "package $p rc=$? plików: $(find "$W/stage/$p" ! -type d | wc -l)"
done

step "3. konflikty: pliki stage, które już istnieją w systemie"
: >"$LOG/konflikty.txt"
for p in omarchy-settings omarchy; do
  (cd "$W/stage/$p" && find . ! -type d | sed 's|^\.||') >"$W/manifest-$p.txt"
  while read -r f; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      owner=$(xbps-query -o "$f" 2>/dev/null | awk -F: '{print $1}' | head -1)
      echo "$p $f ${owner:-?}" >>"$LOG/konflikty.txt"
    fi
  done <"$W/manifest-$p.txt"
done
wc -l <"$LOG/konflikty.txt"

step "4. instalacja stage → / (bez hooków libalpm)"
for p in omarchy-settings omarchy; do
  tar -C "$W/stage/$p" --exclude=./usr/share/libalpm -cf - . | tar -C / --no-overwrite-dir -xpf -
  echo "$p rc=$?"
done

step "5. post_install omarchy-settings — WYBIÓRCZO"
# os-release (ID=omarchy, ID_LIKE=arch) i nsswitch.conf z Archa — NIE (zob. wyniki)
cp -f /usr/share/omarchy/etc-overrides/dot.bashrc /etc/skel/.bashrc && echo "skel .bashrc ok"
if [ -f /usr/lib/security/pam_faillock.so ] || [ -f /lib/security/pam_faillock.so ]; then
  cp -f /usr/share/omarchy/etc-overrides/security-faillock.conf /etc/security/faillock.conf && echo "faillock.conf ok"
else
  echo "brak pam_faillock — faillock.conf pominięty"
fi

step "6. seed domu istniejącego użytkownika (= omarchy-reinstall-configs)"
cp -a /etc/skel/. "/home/$USERNAME/" && chown -R "$USERNAME:$USERNAME" "/home/$USERNAME" && echo ok

step "7. omarchy-apply-system (root)"
timeout 1200 omarchy-apply-system --install-user "$USERNAME" --first-install </dev/null >"$LOG/apply-system.log" 2>&1
echo "apply-system rc=$?"

step "8. omarchy-finalize-user (użytkownik)"
timeout 1200 su - "$USERNAME" -c 'omarchy-finalize-user --force --first-install' </dev/null >"$LOG/finalize-user.log" 2>&1
echo "finalize-user rc=$?"

step "9. minimalna sesja bez uwsm (warstwa portu, nie upstream)"
install -d /usr/libexec/omarchy-port
cat >/usr/libexec/omarchy-port/session <<'EOF'
#!/bin/sh
# Sesja Omarchy na Voidzie: odpowiednik `uwsm start … hyprland.desktop` bez systemd.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  exec dbus-run-session -- "$0" "$@"
fi
[ -r /usr/share/uwsm/env.d/10-omarchy ] && . /usr/share/uwsm/env.d/10-omarchy
for f in /usr/lib/environment.d/*.conf; do [ -r "$f" ] && { set -a; . "$f"; set +a; }; done
export XDG_CURRENT_DESKTOP=Hyprland XDG_SESSION_TYPE=wayland XDG_SESSION_DESKTOP=Hyprland
mkdir -p "$HOME/.local/state/omarchy-port"
pipewire >"$HOME/.local/state/omarchy-port/pipewire.log" 2>&1 &
exec start-hyprland
EOF
chmod 755 /usr/libexec/omarchy-port/session
cat >/usr/share/wayland-sessions/omarchy-void.desktop <<'EOF'
[Desktop Entry]
Name=Omarchy (Void)
Comment=Omarchy Hyprland session without uwsm (omarchy-port prototype)
Exec=/usr/libexec/omarchy-port/session
Type=Application
EOF
# PipeWire na Voidzie: wireplumber i pulse jako moduły pipewire (Void Handbook)
install -d /etc/pipewire/pipewire.conf.d
ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
ln -sf /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/
echo ok

step "10. usługi runit"
rm -f /var/service/dhcpcd
for s in dbus elogind polkitd NetworkManager bluetoothd sddm; do
  [ -d "/etc/sv/$s" ] && ln -sf "/etc/sv/$s" /var/service/ && echo "włączona: $s" || echo "BRAK usługi: $s"
done

step "koniec"
echo PORT-PROTO-DONE
