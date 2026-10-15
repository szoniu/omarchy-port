echo "Void logo in About and the screensaver (omarchy-port)"

# omarchy-port#7: logo Voida w About i wygaszaczu kont założonych przed brandingiem portu. Nowe konta mają
# je ze /etc/skel ze znacznikiem tej migracji, a instalacja oznacza ją jako wykonaną. install-layer.sh
# trzyma ją w drzewie Omarchy tylko wtedy, gdy branding przeszedł, więc icon.txt i logo.txt są tu już Voida.
# Podmienia tylko niezmieniony oryginał Omarchy — plik zmieniony przez użytkownika zostaje. Sumy to icon.txt
# i logo.txt z Omarchy v4.0.4, jedynego wydania, na którym port był instalowany bez brandingu (pliki
# w domu zmienia tylko użytkownik albo migracja, nie aktualizacja pakietów).
ABOUT_OMARCHY=5fe8adced2fe67e410e177477a7272d1807b3fedc81fbc3f030dd479bc046b76
WYGASZACZ_OMARCHY=f98c966b1670d71ffc26620a6ff885a73ab355b370bff6082cea3215ee580a29

podmien() { # podmien <plik konta> <suma oryginału Omarchy> <plik domyślny z brandingiem portu>
  [[ -f $1 && $(sha256sum <"$1" | cut -d' ' -f1) == "$2" ]] || return 0
  cp "$3" "$1"
  echo "omarchy-port: $1 — logo Voida"
}

podmien ~/.config/omarchy/branding/about.txt "$ABOUT_OMARCHY" "$OMARCHY_PATH/icon.txt"
podmien ~/.config/omarchy/branding/screensaver.txt "$WYGASZACZ_OMARCHY" "$OMARCHY_PATH/logo.txt"
