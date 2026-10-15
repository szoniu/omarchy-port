# omarchy-port

**Pełne [Omarchy](https://github.com/basecamp/omarchy), tylko na Voidzie albo Gentoo zamiast Archa.** Hyprland, shell na Quickshellu, keybindy, menu, motywy i config Omarchy. Wszystko przy przypiętym tagu upstreamu, plus cienka warstwa zgodności dla runit/OpenRC i xbps/emerge.

Status: **prototyp** (Void działa w VM — wyniki w [`wyniki/`](wyniki/)). Port nie jest jeszcze gotowy do instalacji na sprzęcie.

Kontekst i decyzje: epik [szoniu/dotfiles#169](https://git.szoniu.pl/szoniu/dotfiles/issues/169). Instalatory, które będą wołać port: [szoniu/void](https://github.com/szoniu/void), [szoniu/gentoo](https://github.com/szoniu/gentoo).

## Instalacja (Void)

Jako root, na działającym Voidzie (glibc, x86_64) z siecią i istniejącym użytkownikiem — taki stan zostawia instalator [szoniu/void](https://github.com/szoniu/void):

```sh
xbps-install -Sy git
git clone https://github.com/szoniu/omarchy-port /opt/omarchy-port
/opt/omarchy-port/port/install.sh --user NAZWA --name "Imię Nazwisko" --email adres@example.com
```

`/opt/omarchy-port` to stałe miejsce klonu — z niego biorą się aktualizacje. Port zainstalowany z innego miejsca dostaje ten klon z GitHuba (gałąź `main`) na końcu instalacji.

`git` nie wchodzi w `base-system` Voida, a instalator szoniu/void stawia go tylko przy części opcji. `--name` i `--email` trafiają do gita i XCompose; bez `--name` port bierze imię z pola GECOS konta. Usługi włączane w trakcie instalacji startują dopiero po restarcie, jak w systemd.

Orkiestrator jest idempotentny, a logi zapisuje w `/var/log/omarchy-port/`. Kod 1 znaczy, że któryś krok padł: reszta jest doinstalowana, a lista błędów jest w podsumowaniu. Kroki `install/` Omarchy, które na Voidzie są pomijane albo podmieniane, opisuje [`port/share/void/kroki.tsv`](port/share/void/kroki.tsv).

## Aktualizacja

Tak jak w Omarchy: menu **Update → Omarchy**, ikona aktualizacji na pasku albo `omarchy-update` w terminalu. Na porcie to nakładka z tą samą kolejnością kroków, a kroki pacmana zastępuje `omarchy-port-update` (root):

1. `git pull --ff-only` w `/opt/omarchy-port` — nowa wersja portu, a z nią ewentualnie nowy pin Omarchy;
2. `port/install.sh --update`:
   - pakiety Voida (`xbps-install -Su` i lista);
   - pliki Omarchy przy nowym pinie, z usunięciem plików poprzedniej wersji (zmienione przez admina → `.omarchy-save`);
   - warstwa i łatki;
3. dalej jak upstream:
   - migracje (`omarchy-migrate`; pominięte i podmienione na Voidzie: [`port/share/void/migracje.tsv`](port/share/void/migracje.tsv));
   - hook `post-update`;
   - `mise up --no-prune`;
   - sieroty xbps;
   - pytanie o restart (jądro, Hyprland) i restart powłoki.

Pasek co 6 h sprawdza, czy gałąź, którą śledzi klon, ma nowy commit. **Podbicie wersji Omarchy** to commit w porcie, który zmienia [`port/share/upstream.env`](port/share/upstream.env). Najpierw [`prototyp/bramka/podbicie.sh`](prototyp/bramka/podbicie.sh) wypisuje nowe migracje, kroki `install/`, zmiany listy pakietów i stan łatek do przejrzenia, potem idzie test w VM.

## Jak to działa

1. **Pakiety:** lista Omarchy (`install/omarchy-base.packages`) zmapowana na nazwy Voida → [`dane/mapa-pakietow-void.tsv`](dane/mapa-pakietow-void.tsv). Ma trzy stany: jest / zamiennik / brak.
2. **Pliki Omarchy:** przy commicie przypiętym w [`port/share/upstream.env`](port/share/upstream.env) — upstreamowe funkcje `package()` z PKGBUILD-ów `omarchy` i `omarchy-settings` ([omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs)) wywołane bez makepkg. Wynik trafia do `/usr/share/omarchy`, `/usr/bin/omarchy-*`, `/etc/skel` i `/etc`. Nie ma ręcznej mapy plików.
3. **`post_install` wybiórczo:** NIE nadpisujemy `os-release` (`ID_LIKE=arch` zmyliłby narzędzia rozpoznające dystrybucję) ani `nsswitch.conf`.
4. **Kroki `install/` Omarchy pojedynczo:** te zależne od pacmana, systemd czy limine pomijamy albo podmieniamy (lista jako dane: `port/share/void/kroki.tsv`). Część użytkownika robi upstreamowe `omarchy-provision-user` na tym samym drzewie kroków.
5. **Sesja bez uwsm:** `dbus-run-session` → PipeWire → `start-hyprland`; SDDM z motywem Omarchy.
6. **Warstwa zgodności** (`port/`, instalacja: `port/install-layer.sh`):
   - shimy w `/usr/local/bin` — powstają **tylko tam, gdzie oryginału nie ma**, więc na Gentoo z systemd nie zakłada się żaden;
   - nakładki `omarchy-pkg-*` → xbps oraz `omarchy-version`, `-channel`, `-pkgs` (fastfetch) → stan portu i baza xbps;
   - nadzorca unitów użytkownika zamiast `systemd --user`;
   - łatki z mastera Omarchy, których przypięte wydanie jeszcze nie ma (`port/share/latki/`, opis w nagłówku każdej).
7. **Branding Voida** (teksty UI zostają przy Omarchy — to nazwa warstwy pulpitu):
   - logo Voida w greeterze SDDM, w About/fastfetch i w wygaszaczu — [`port/share/void/branding.sh`](port/share/void/branding.sh) generuje je przy instalacji z `void-artwork`, także jako „Restore Default” z menu Style;
   - menu **Update → Void**, **Learn → Void** (Void Handbook) i logo Voida na przycisku paska — łatki [`port/share/void/latki/`](port/share/void/latki/);
   - konta sprzed brandingu dostają logo przez migrację portu (`port/share/void/migracje-portu/`), a plik zmieniony przez użytkownika zostaje.

Szczegóły, liczby i lista tego, co jeszcze pada: [`wyniki/2026-10-14-runda-1-2.md`](wyniki/2026-10-14-runda-1-2.md), [`wyniki/2026-10-14-runda-3.md`](wyniki/2026-10-14-runda-3.md), [`wyniki/2026-10-14-runda-4.md`](wyniki/2026-10-14-runda-4.md) (orkiestrator, test od zera), [`wyniki/2026-10-15-blokada-fastfetch.md`](wyniki/2026-10-15-blokada-fastfetch.md) (łatki, nakładki `omarchy-version*`), [`wyniki/2026-10-15-aktualizacja.md`](wyniki/2026-10-15-aktualizacja.md) (ścieżka aktualizacji), [`wyniki/2026-10-15-branding.md`](wyniki/2026-10-15-branding.md) (branding Voida). Otwarte zadania: [issues w Forgejo](https://git.szoniu.pl/szoniu/omarchy-port/issues).

## Układ repo

| Katalog | Zawartość |
|---|---|
| `port/` | **orkiestrator** `install.sh` i **warstwa zgodności** (Void/runit): shimy `systemctl`, `systemd-run`, `systemd-inhibit`, `timedatectl`, `uwsm`, `uwsm-app`, `systemd-cat`, `xdg-terminal-exec` (tylko gdy oryginału brak); nakładki `omarchy-pkg-*` (xbps), `omarchy-version*` i `omarchy-update*`; `omarchy-port-update`; łatki `share/latki/`; migracje `share/void/migracje.tsv`; branding Voida (`share/void/branding.sh`, łatki `share/void/latki/`, migracja `share/void/migracje-portu/`); nadzorca unitów użytkownika `omarchy-port-units`; sesja; `install-layer.sh` |
| `prototyp/vm/` | VM testowa: QEMU z Fedory w kontenerze podmana (virgl), VNC, QMP (klawisze, mysz), zrzuty przez VNC |
| `prototyp/void/` | baza Voida w VM (`install-base.sh`) — odpowiednik instalatora szoniu/void do testów |
| `prototyp/bramka/` | `podbicie.sh` — co przejrzeć przed zmianą pinu Omarchy (migracje, kroki, pakiety, łatki) |
| `prototyp/test/` | zrzut skrótów z plików Lua Omarchy, test skrótów i menu w żywej sesji, test PAM, odcisk stanu systemu (`stan-systemu.sh`) |
| `dane/` | mapa pakietów, lista do instalacji |
| `wyniki/` | wyniki rund prototypu |

## VM testowa

Stan VM (ISO, dysk qcow2, OVMF, klucz SSH, logi, zrzuty) leży w `$VM_DIR` (domyślnie `~/vm/omarchy-port`), **poza repo**.

Wymagania:
- `podman` (rootless);
- dostęp do `/dev/kvm` i `/dev/dri/renderD128` (GPU hosta dla virgl).

QEMU z AlmaLinux/RHEL nie ma `virtio-vga-gl`, stąd kontener z Fedorą (`prototyp/vm/Containerfile`).

```sh
prototyp/vm/vm.sh disk              # start z dysku (ekran: VNC 127.0.0.1:5901, SSH: 127.0.0.1:2229)
prototyp/vm/vm.sh stop
prototyp/vm/shot.sh shots/x.png     # zrzut ekranu (przez VNC)
python3 prototyp/vm/qmp.py key meta_l-ctrl-t   # wciśnięcie skrótu na klawiaturze VM
prototyp/vm/hx.sh 'hyprctl clients'            # polecenie w sesji Hyprlanda użytkownika
```

Podgląd z innej maszyny: `ssh -L 5901:127.0.0.1:5901 <host>`, potem klient VNC na `localhost:5901`.

Instalacja od zera:
1. ISO Void live → `$VM_DIR`;
2. kernel i initrd z ISO → `$VM_DIR/iso-boot/`;
3. `vm.sh live`;
4. `install-base.sh` przez SSH, z `PASS_HASH`;
5. `git archive HEAD port dane` do VM i `port/install.sh --user szoniu`.

Osobny dysk obok istniejącej VM: `VM_DISK=fresh.qcow2 VM_VARS=OVMF_VARS.fresh.fd prototyp/vm/vm.sh live|disk`.

## Upstream i licencje

Omarchy (© 37signals / Basecamp) jest na licencji MIT. Port go **nie forkuje**: klonuje upstream przy tagu i dokłada własną warstwę. `default/fonts/omarchy/omarchy.ttf` zawiera loga cudzych marek, więc nie jest tu commitowany.
