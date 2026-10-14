#!/usr/bin/env bash
# Prototyp portu Omarchy na Void — RUNDA 1b: omarchy-settings (z CARCH) +
# KAŻDY krok install/*/all.sh osobno, ze środowiskiem jak w omarchy-apply-system.
# Wynik: /root/port-proto/kroki.tsv (krok, kto, rc) + log per krok.
set -uo pipefail
W=/var/cache/omarchy-port
USERNAME=szoniu
LOG=/root/port-proto
mkdir -p "$LOG/kroki"

echo "=== omarchy-settings: package() z CARCH ==="
rm -rf "$W/stage/omarchy-settings"; mkdir -p "$W/stage/omarchy-settings"
(
  set -e
  CARCH=x86_64; srcdir="$W/src"; pkgdir="$W/stage/omarchy-settings"
  cd /root/omarchy-pkgs/omarchy-settings
  # shellcheck disable=SC1091
  source ./PKGBUILD
  package
) >"$LOG/package-omarchy-settings.log" 2>&1
echo "package omarchy-settings rc=$? plików: $(find "$W/stage/omarchy-settings" ! -type d | wc -l)"
(cd "$W/stage/omarchy-settings" && find . ! -type d | sed 's|^\.||') >"$W/manifest-omarchy-settings.txt"
: >"$LOG/konflikty-settings.txt"
while read -r f; do
  if [ -e "$f" ] || [ -L "$f" ]; then
    owner=$(xbps-query -o "$f" 2>/dev/null | awk -F: '{print $1}' | head -1)
    echo "$f ${owner:-?}" >>"$LOG/konflikty-settings.txt"
  fi
done <"$W/manifest-omarchy-settings.txt"
echo "konflikty z istniejącymi plikami: $(wc -l <"$LOG/konflikty-settings.txt")"
tar -C "$W/stage/omarchy-settings" -cf - . | tar -C / --no-overwrite-dir -xpf -
echo "instalacja settings rc=$?"

echo "=== post_install wybiórczo ==="
cp -f /usr/share/omarchy/etc-overrides/dot.bashrc /etc/skel/.bashrc && echo "skel .bashrc"
if [ -e /usr/lib/security/pam_faillock.so ] || [ -e /lib/security/pam_faillock.so ] || [ -e /usr/lib64/security/pam_faillock.so ]; then
  cp -f /usr/share/omarchy/etc-overrides/security-faillock.conf /etc/security/faillock.conf && echo "faillock.conf"
else
  echo "brak pam_faillock.so — faillock.conf pominięty"
fi
echo "=== seed domu ==="
cp -a /etc/skel/. "/home/$USERNAME/" && chown -R "$USERNAME:$USERNAME" "/home/$USERNAME" && echo ok

export OMARCHY_INSTALL_USER="$USERNAME" OMARCHY_FIRST_INSTALL=1 OMARCHY_UPGRADE=0
export OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL=/usr/share/omarchy/install
export OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log

steps() { sed -n 's|^run_logged "\$OMARCHY_INSTALL/\(.*\)"|\1|p' "$OMARCHY_INSTALL/$1/all.sh"; }

printf 'krok\tkto\trc\n' >"$LOG/kroki.tsv"
for grp in config hardware login post-install; do
  for s in $(steps "$grp"); do
    l="$LOG/kroki/$(echo "$s" | tr / _).log"
    timeout 300 bash -eE -c 'source "$1"' bash "$OMARCHY_INSTALL/$s" </dev/null >"$l" 2>&1
    rc=$?; printf '%s\troot\t%s\n' "$s" "$rc" >>"$LOG/kroki.tsv"
  done
done
for s in $(steps user); do
  l="$LOG/kroki/$(echo "$s" | tr / _).log"
  timeout 300 su - "$USERNAME" -c "OMARCHY_PATH=$OMARCHY_PATH OMARCHY_INSTALL=$OMARCHY_INSTALL OMARCHY_FIRST_INSTALL=1 bash -eE -c 'source \"\$1\"' bash $OMARCHY_INSTALL/$s" </dev/null >"$l" 2>&1
  rc=$?; printf '%s\tuser\t%s\n' "$s" "$rc" >>"$LOG/kroki.tsv"
done

echo "=== omarchy-provision-user (całość, jako użytkownik) ==="
timeout 600 su - "$USERNAME" -c 'omarchy-provision-user --force --first-install' </dev/null >"$LOG/provision-user.log" 2>&1
echo "provision-user rc=$?"
echo PORT-STEPS-DONE
