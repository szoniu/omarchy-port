# shellcheck shell=bash
# omarchy-port: dodatki warstwy zgodności tylko dla Gentoo — sourcowane przez install-layer.sh.
# Chrome zamiast Chromium (omarchy-port#5): wrapper z flagami Omarchy (share/gentoo/bin) i w /etc/skel to,
# co na Archu robi `omarchy-install-browser chrome` dla konta — plik flag i plik .desktop wskazujący na
# wrapper. omarchy-launch-webapp bierze Exec z ~/.local, ~/.nix-profile albo /usr/share/applications
# (nie z /usr/local), więc nadpisanie musi być w ~/.local konta; dom powstaje z /etc/skel w etapie 6,
# po warstwie.
install -m 755 "$DYST/bin/google-chrome-stable" /usr/local/bin/
# katalog polityk Chrome tak jak config/browser-policy.sh dla Chromium (etap 7 upstreamu) — przed
# user/theme.sh, który zapisuje tam kolor motywu; purge usuwa tylko wpisy nie-roota, więc color.json zostaje.
# Od v4.0.5 setup_dir kładzie też omarchy.json z $OMARCHY_PATH (DefaultBrowserSettingEnabled: false), a etap 5
# orkiestratora idzie przed eksportem OMARCHY_PATH — bez niego `install` dostaje /default/… i omarchy.json
# nie powstaje (przycisk „ustaw jako domyślną” w Chrome zostaje, omarchy-port#13).
if [[ -f /usr/share/omarchy/install/helpers/browser-policy.sh ]] &&
  OMARCHY_PATH=/usr/share/omarchy bash -c 'source "$OMARCHY_PATH/install/helpers/browser-policy.sh" && browser_policy_setup_dir /etc/opt/chrome/policies/managed'; then
  echo "chrome: /etc/opt/chrome/policies/managed"
else
  echo "UWAGA: polityki Chrome (/etc/opt/chrome/policies/managed) nie powstały — motyw Omarchy nie pokoloruje przeglądarki, a Chrome może przestawić domyślną przeglądarkę" >&2
fi
echo "chrome: /usr/local/bin/google-chrome-stable (flagi z ~/.config/chrome-flags.conf)"
install -d /etc/skel/.config /etc/skel/.local/share/applications
if [[ -f /usr/share/omarchy/config/chromium-flags.conf ]]; then
  install -m 644 /usr/share/omarchy/config/chromium-flags.conf /etc/skel/.config/chrome-flags.conf
else
  echo "UWAGA: brak plików Omarchy — /etc/skel/.config/chrome-flags.conf pominięty, puść install-layer.sh ponownie" >&2
fi
if [[ -f /usr/share/applications/google-chrome.desktop ]]; then
  sed 's|/usr/bin/google-chrome-stable|/usr/local/bin/google-chrome-stable|g' /usr/share/applications/google-chrome.desktop \
    >/etc/skel/.local/share/applications/google-chrome.desktop
  echo "chrome: /etc/skel/.local/share/applications/google-chrome.desktop → wrapper"
else
  echo "UWAGA: brak /usr/share/applications/google-chrome.desktop — Chrome nie zainstalowany?" >&2
fi
