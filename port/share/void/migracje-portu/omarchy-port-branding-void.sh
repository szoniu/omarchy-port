echo "Void logo in About and the screensaver (omarchy-port)"

# omarchy-port#7: logo Voida w About i wygaszaczu kont założonych przed brandingiem portu. Nowe konta mają
# je ze /etc/skel, a instalacja oznacza tę migrację jako wykonaną (omarchy-provision-user --first-install).
# Podmienia tylko niezmieniony oryginał Omarchy — plik zmieniony przez użytkownika zostaje. Sumy to
# icon.txt i logo.txt z Omarchy v4.0.4, jedynego wydania, na którym port był instalowany bez brandingu.
ABOUT_OMARCHY=5fe8adced2fe67e410e177477a7272d1807b3fedc81fbc3f030dd479bc046b76
WYGASZACZ_OMARCHY=f98c966b1670d71ffc26620a6ff885a73ab355b370bff6082cea3215ee580a29

suma() { sha256sum <"$1" | cut -d' ' -f1; }

podmien() { # podmien <plik konta> <suma oryginału Omarchy> <plik domyślny z brandingiem portu>
  # Domyślny plik to dalej oryginał = warstwa nie nałożyła brandingu; błąd zostawia migrację na
  # następny przebieg, zamiast oznaczyć ją jako wykonaną bez skutku.
  if [[ $(suma "$3") == "$2" ]]; then
    echo "omarchy-port: $3 to dalej logo Omarchy — branding portu nie nałożony (port/install-layer.sh)" >&2
    exit 1
  fi
  [[ -f $1 && $(suma "$1") == "$2" ]] || return 0
  cp "$3" "$1"
  echo "omarchy-port: $1 — logo Voida"
}

podmien ~/.config/omarchy/branding/about.txt "$ABOUT_OMARCHY" "$OMARCHY_PATH/icon.txt"
podmien ~/.config/omarchy/branding/screensaver.txt "$WYGASZACZ_OMARCHY" "$OMARCHY_PATH/logo.txt"
