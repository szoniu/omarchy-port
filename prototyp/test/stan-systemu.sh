#!/usr/bin/env bash
# Odcisk stanu systemu z portem — TYLKO ODCZYT. Porównanie dwóch maszyn (np. VM budowana ręcznie
# rundami vs świeża instalacja orkiestratorem) pokazuje, co któraś ma, a druga nie.
# Użycie (root w VM): stan-systemu.sh <użytkownik> > stan.txt ; potem diff dwóch plików.
# Wiersze: <sekcja>\t<klucz>\t<wartość>, posortowane. Wartości zmienne z natury (hasła, klucze hosta,
# znaczniki czasu) pominięte.
set -uo pipefail
U=${1:?użytkownik}
H=$(getent passwd "$U" | cut -d: -f6)

row() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}"; }
sum() { sha256sum "$1" 2>/dev/null | cut -c1-16; }
files() { # files <sekcja> <katalog> — pliki z sumą, linki z celem
  local s=$1 d=$2 f
  [[ -d $d ]] || { row "$s" "(brak katalogu $d)"; return; }
  while IFS= read -r f; do
    if [[ -L $f ]]; then row "$s" "${f#"$d"/}" "-> $(readlink "$f")"
    else row "$s" "${f#"$d"/}" "$(sum "$f")"; fi
  done < <(find "$d" -mindepth 1 \( -type f -o -type l \) | sort)
}

{
  xbps-query -m | sed 's/-[^-]*_[0-9]*$//' | while read -r p; do row pakiet-ręczny "$p"; done
  xbps-query -L | awk '{print $2}' | while read -r r; do row repo "$r"; done
  for k in /var/db/xbps/keys/*.plist; do row klucz-xbps "$(basename "$k")"; done
  for l in /etc/runit/runsvdir/default/*; do row usługa "$(basename "$l")" "$([[ -e /etc/sv/$(basename "$l")/down ]] && echo down)"; done
  for d in /etc/sv/*/down; do [[ -e $d ]] && row usługa-down "$(basename "$(dirname "$d")")"; done
  files xbps.d /etc/xbps.d
  files sddm.conf.d /etc/sddm.conf.d
  files pipewire.conf.d /etc/pipewire/pipewire.conf.d
  files usr-local-bin /usr/local/bin
  files libexec-port /usr/libexec/omarchy-port
  files share-port /usr/share/omarchy-port
  files wayland-sessions /usr/share/wayland-sessions
  files core-services /etc/runit/core-services
  files sudoers.d /etc/sudoers.d
  files pam.d /etc/pam.d
  for f in /etc/security/faillock.conf /etc/skel/.bashrc /etc/os-release /etc/nsswitch.conf /etc/ufw/ufw.conf /etc/rc.conf; do
    row plik-etc "$f" "$(sum "$f")"
  done
  for f in /usr/share/omarchy/bin/omarchy-pkg-* /usr/share/omarchy/bin/omarchy-version*; do row omarchy-bin "$(basename "$f")" "-> $(readlink "$f")"; done
  # łatki portu (share/latki): bez nich blokada ekranu działa raz na sesję (#10)
  row omarchy "łatka blokada (currentlyLocked)" "$(grep -c "currentlyLocked" /usr/share/omarchy/shell/plugins/lock/Service.qml 2>/dev/null)"
  row port "wersja-pakietu-omarchy" "$(cat /var/lib/omarchy-port/wersja-pakietu-omarchy 2>/dev/null) $(stat -c %a /var/lib/omarchy-port/wersja-pakietu-omarchy 2>/dev/null)"
  row omarchy "wersja" "$(cat /usr/share/omarchy/version 2>/dev/null)"
  row omarchy "pliki /usr/share/omarchy" "$(find /usr/share/omarchy -type f | wc -l)"
  row omarchy "polecenia /usr/bin/omarchy-*" "$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l)"
  row omarchy "pliki /etc/skel" "$(find /etc/skel -type f | wc -l)"
  row użytkownik grupy "$(id -nG "$U" | tr ' ' '\n' | sort | tr '\n' ' ')"
  row użytkownik powłoka "$(getent passwd "$U" | cut -d: -f7)"
  for m in "$H"/.local/state/omarchy/done/*; do [[ -e $m ]] && row znacznik-done "$(basename "$m")"; done
  row znaczniki-migracji liczba "$(find "$H/.local/state/omarchy/migrations" -type f 2>/dev/null | wc -l)"
  for c in "$H"/.config/*; do row home-config "$(basename "$c")"; done
  row home "pliki ~/.config" "$(find "$H/.config" -type f 2>/dev/null | wc -l)"
  row home "aplikacje ~/.local/share/applications" "$(find "$H/.local/share/applications" -name '*.desktop' 2>/dev/null | wc -l)"
  for t in "$H"/.local/share/mise/installs/*; do [[ -e $t ]] && row mise-narzędzie "$(basename "$t")"; done
  row mise config "$(sum "$H/.config/mise/config.toml")"
  row mimeapps przeglądarka "$(sed -n 's/^x-scheme-handler\/https=//p' "$H/.config/mimeapps.list" 2>/dev/null | head -1)"
} | sort
