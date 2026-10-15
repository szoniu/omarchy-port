## 2026-10-15: ścieżka aktualizacji portu (#3)

Decyzje z #3:
- źródło nowych wersji to klon portu w `/opt/omarchy-port` (gałąź `main`); podbicie Omarchy = commit w porcie po bramce VM;
- zakres: ścieżka działająca dziś + mechanizm podbicia, test podbicia na syntetycznej wersji (nowszego wydania Omarchy nie ma).

### Co powstało

| Element | Co robi |
|---|---|
| `port/bin/omarchy-update` | nakładka na `omarchy-update` z v4.0.4 — ta sama kolejność i te same pomocnicze polecenia upstreamu (log, blokada, wolne miejsce, potwierdzenie, snapshot→127, `stay-awake`, `update-dev`, `omarchy-migrate`, hook `post-update`). Kroki pacmana (`pkg-prune`, `keyring`, `system-pkgs`) → `sudo omarchy-port-update`; bez AUR i bez analizy logu initcpio |
| `port/bin/omarchy-port-update` | root: `git pull --ff-only` w `/opt/omarchy-port`, potem `port/install.sh --update` **nowej** wersji |
| `port/install.sh --update` | etapy 1–5 (repo i klucz blackhole, `xbps-install -Su` + lista, pliki Omarchy przy pinie, warstwa, łatki, restart `sshd`); etapy 6–9 tylko przy instalacji. Nowe w obu trybach: **usuwanie plików poprzedniej wersji** (zmienione z `backup=()` → `.omarchy-save`, puste katalogi tylko w `/usr/share/omarchy` i tylko te, których nowa wersja nie ma); **`kroki.tsv` i `migracje.tsv` sprawdzane na źródle przed zmianami na dysku**; adresy repo Omarchy w `upstream.env`; klon `/opt/omarchy-port` przy instalacji; `wersja-portu` dla wskaźnika |
| `port/share/void/migracje.tsv` | pominięte/podmienione migracje (format jak `kroki.tsv`); warstwa wstawia zaślepkę albo podmianę do `/usr/share/omarchy/migrations`, upstreamowe `omarchy-migrate` uruchamia je bez zmian. Dziś puste — instalacja oznacza wszystkie istniejące migracje jako wykonane |
| nakładki `omarchy-update-available`, `-mise`, `-orphan-pkgs`, `-restart` | nowy commit portu (`git ls-remote`, bez dostępu do repo roota); `mise up --no-prune`; sieroty `xbps-query -O` / `xbps-remove -o`; jądro po właścicielu plików działającego jądra (`xbps-query -o`) — reszta jak upstream |
| `prototyp/bramka/podbicie.sh` | przed zmianą pinu: nowe migracje i kroki `install/` z wykrytymi zależnościami (pacman, systemd, limine, snapper, initramfs, plymouth, kroki z `kroki.tsv` wołane wprost), zmiany `install/omarchy-base.packages` wobec mapy Voida, stan łatek |

Pasek („Update System”, co 6 h) i menu Update → Omarchy trafiają w nakładki przez przekierowanie linków w `/usr/share/omarchy/bin`, jak przy `omarchy-pkg-*`.

### Test w VM (realny kanał: menu w żywej sesji, klawiatura VM)

Repo testowe portu w VM udostępnione przez `git daemon` na localhoście (klon `/opt/omarchy-port` śledzi jego `main`), żeby root i użytkownik widzieli je jak zdalne. Na prawdziwej maszynie to https GitHuba.

**A. Aktualizacja na obecnym pinie** (Super+Enter → `omarchy-menu summon update` → Enter na „Omarchy” → „Yes”):
- port bez zmian;
- `OMARCHY-PORT-UPDATE-OK (v4.0.4)`, usunięte 0 plików;
- mise: node 26.11.1 → 26.12.0, **stara wersja została** (`--no-prune`);
- jądro bez zmian, więc bez pytania o restart;
- powłoka zrestartowana, kod 0.

**B. Podbicie do syntetycznego `v4.0.5-test`.** Lokalne repo Omarchy i omarchy-pkgs z commitem, który:
- zmienia `bin/omarchy-version-branch` i `version`;
- usuwa `bin/omarchy-upgrade-to-quattro`, `default/voxtype`, `etc/gnupg/dirmngr.conf` (wcześniej zmieniony przez admina) i `etc/sysctl.d/90-omarchy-file-watchers.conf`;
- dodaje nowy plik w nowym katalogu oraz dwie migracje — zwykłą i z `sudo pacman -S` (pominiętą w `migracje.tsv`).

Przebieg:
- wskaźnik: `omarchy-port e44443f -> 46ba95f (main)`, ikona na pasku;
- **pierwsza próba:** `package()` padło — mój syntetyczny commit usunął `default/plymouth`, który PKGBUILD kopiuje wprost. Wynik pokazuje przerwanie w środku etapu 3: przed zmianami na dysku, strażnik wznowiony, wersja i pliki bez zmian, Hyprland żyje, komunikat „Something went wrong” z adresem zgłoszeń portu;
- **po poprawce** (nowy commit portu na wierzchu, `pull` jako fast-forward): `OMARCHY-PORT-UPDATE-OK (v4.0.5-test)`, a na dysku:

| Sprawdzenie | Wynik |
|---|---|
| wersja / pakiet | `4.0.5-test` / `4.0.5-1` (fastfetch: Omarchy 4.0.5-1) |
| plik zmieniony | nowa treść |
| usunięte (bin + link, plik `voxtype` i pusty katalog, niezmieniony plik z `backup=()`) | 4, katalog `default/voxtype` zniknął, `default/plymouth` (10 plików) został |
| zmieniony przez admina, usunięty w nowej wersji | `/etc/gnupg/dirmngr.conf.omarchy-save` z linią admina |
| nowy plik w nowym katalogu | jest |
| migracje | 2 nowe znaczniki; zwykła wykonana (plik-znacznik w domu), z pacmanem → zaślepka „omarchy-port: pominięta — …” |
| łatka blokady, przekierowania (`omarchy-update`, `-available`, `omarchy-pkg-add`, `omarchy-version`) | nałożone ponownie |
| sesja | Hyprland ten sam PID (strażnik przeładowań), Quickshell zrestartowany przez `omarchy-update-restart` |
| wskaźnik po aktualizacji | „Omarchy is up to date” |

**Kontrola mostu:** z przekierowaniem `omarchy-update` cofniętym na wersję z pacmanem to samo polecenie w środowisku sesji kończy się `sudo: pacman: command not found` → „Something went wrong”, rc=1.

### Znalezione przy teście

- `omarchy-update-available` w katalogu bez prawa odczytu (`git ls-remote` czyta bieżący katalog) zwracało po cichu „up to date” → `cd /` przed `ls-remote`. Wyszło przez moje narzędzie testowe (`su` z cwd `/root`); pasek działa z katalogu domowego.
- Wskaźnik aktualizacji działa jako użytkownik, więc adres w `wersja-portu` musi być czytelny bez kluczy roota — https GitHuba tak. Klon na `git@github.com:` (SSH) nie pokaże aktualizacji, choć sama aktualizacja (root) zadziała.

### Bramka na prawdziwym upstreamie (podgląd następnego wydania)

`prototyp/bramka/podbicie.sh origin/quattro` (v4.0.4 → `quattro` @ `246f33a`, 15.10.2026). Pełne wyniki: [`2026-10-15-bramka-quattro.tsv`](2026-10-15-bramka-quattro.tsv).

- **87 nowych migracji.** Wykryte zależności: sudo 28, pakiety 18, limine 14, initramfs 13, systemd 11, pacman 6, plymouth 2; bez wykrytych 40. 26 ma zależność od Archa/systemd poza pakietami i sudo.
- **45 zmienionych kroków `install/`.** Upstream zmienił `user/mise.sh` (port go podmienia — podmianę trzeba przejrzeć) i `post-install/pacman.sh` (pomijany).
- **31 zmian listy pakietów.** Nowe bez mapy Voida: m.in. `base-devel`, `ffmpeg`, `qt6-*`, `fcitx5-*` (CJK), `omasnap`, `owe`, `gliff`, `superwhisper-bin`. Usunięte: m.in. `clang`, `llvm`, `kdenlive`, `xournalpp`, `lazydocker`, `dua-cli`.
- **Łatka blokady na `quattro` nie pasuje** — poprawka jest tam z innym kontekstem (zgodnie z #10). Przy podbiciu do wydania z `d1a614ce` łatkę się usuwa.

### Zostaje

- Prawdziwe podbicie: przegląd 87 migracji do `migracje.tsv`, mapa pakietów, podmiana `user/mise.sh` — przy pierwszym wydaniu po v4.0.4.
- Gentoo (#5): `emerge -uDN @world` zamiast xbps w `--update`.
