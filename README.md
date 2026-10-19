# omarchy-port

**Pełne [Omarchy](https://github.com/basecamp/omarchy), tylko na Voidzie albo Gentoo zamiast Archa.** Hyprland, shell na Quickshellu, keybindy, menu, motywy i config Omarchy. Wszystko przy przypiętym tagu upstreamu, plus cienka warstwa zgodności dla runit/OpenRC i xbps/emerge.

Status: **prototyp** (Void, Gentoo z systemd i Gentoo z OpenRC działają w VM — [#5](https://git.szoniu.pl/szoniu/omarchy-port/issues/5); wyniki w [`wyniki/`](wyniki/)). Port nie jest jeszcze gotowy do instalacji na sprzęcie.

Kontekst i decyzje: epik [szoniu/dotfiles#169](https://git.szoniu.pl/szoniu/dotfiles/issues/169). Instalatory, które będą wołać port: [szoniu/void](https://github.com/szoniu/void), [szoniu/gentoo](https://github.com/szoniu/gentoo).

## Instalacja (Void)

Jako root, na działającym Voidzie (glibc, x86_64) z siecią i istniejącym użytkownikiem — taki stan zostawia instalator [szoniu/void](https://github.com/szoniu/void):

```sh
xbps-install -Sy git
git clone https://github.com/szoniu/omarchy-port /opt/omarchy-port
/opt/omarchy-port/port/install.sh --user NAZWA --name "Imię Nazwisko" --email adres@example.com
```

`/opt/omarchy-port` to stałe miejsce klonu — z niego biorą się aktualizacje. Port zainstalowany z innego miejsca dostaje ten klon z GitHuba (gałąź `main`) na końcu instalacji.

`git` nie wchodzi w `base-system` Voida, a instalator szoniu/void stawia go tylko przy części opcji. `--name` i `--email` trafiają do gita i XCompose; bez `--name` port bierze imię z pola GECOS konta. Usługi włączane w trakcie instalacji startują dopiero po restarcie, jak w systemd. Dotyczy to też firewalla: ufw z regułami Omarchy (ruch przychodzący zamknięty poza LocalSend, porty kontenerów Dockera chronione przez `ufw-docker`). Gdy sshd jest włączony, port dodaje przed tym krokiem `ufw limit <port>/tcp` (regułę z Setup > Security > SSH) na każdym porcie, na którym sshd słucha, zwykle 22, żeby instalacja przez SSH nie odcięła dostępu po restarcie. Krok idzie raz na maszynę. Ufw włączonego przez kogoś innego port nie rusza, także przy ponownej instalacji.

Orkiestrator jest idempotentny, a logi zapisuje w `/var/log/omarchy-port/`. Kod 1 znaczy, że któryś krok padł: reszta jest doinstalowana, a lista błędów jest w podsumowaniu. Kroki `install/` Omarchy, które na danej dystrybucji są pomijane albo podmieniane, opisuje `port/share/<dystrybucja>/kroki.tsv` ([Void](port/share/void/kroki.tsv), [Gentoo](port/share/gentoo/kroki.tsv)).

## Instalacja (Gentoo) — prototyp

Jako root, na działającym Gentoo (amd64, glibc, profil `23.0/desktop/systemd` albo `23.0/desktop` z OpenRC) z siecią, gitem i istniejącym użytkownikiem:

```sh
emerge --ask=n dev-vcs/git
git clone https://github.com/szoniu/omarchy-port /opt/omarchy-port
/opt/omarchy-port/port/install.sh --user NAZWA --name "Imię Nazwisko" --email adres@example.com
```

Port włącza repozytoria GURU (quickshell, brightnessctl, nerdfonts) i hyproverlay (Hyprland, z `::gentoo` usunięty 2026-03-27) i dokłada własne pliki `/etc/portage/package.{accept_keywords,use,license}/omarchy-port`: keywordy `~amd64` per atom, bez zbiorczego dla całego overlaya. Polityki binarek nie zmienia. Z oficjalnym binhostem (`FEATURES=getbinpkg`) większość listy przychodzi gotowa (w VM 479 z 563 pakietów), a kompilują się głównie Hyprland, Quickshell i to, czemu lista zmienia flagi USE. Bez binhosta wszystko idzie ze źródeł.

Różnice wobec Omarchy na Archu:
- przeglądarka to `google-chrome`, bo Chromium nie ma w binhoście (kompilacja trwałaby godziny przy każdej aktualizacji), a webappy Omarchy wymagają przeglądarki z rodziny Chromium;
- `gum`, `mise`, `usage`, `lazydocker` i `localsend` nie mają odpowiednika w `::gentoo`, GURU ani hyproverlay, więc instaluje je sam port z wydań upstreamu (wersja i suma przypięte w [`port/share/pakiety/`](port/share/pakiety/) albo w omarchy-pkgs);
- `yaru-icon-theme` na razie brak;
- Chrome dostaje flagi Omarchy (Wayland, rozszerzenia, libsecret) przez wrapper `/usr/local/bin/google-chrome-stable`, który czyta `~/.config/chrome-flags.conf` jak wrapper z AUR; launcher Google na Gentoo tego pliku nie czyta;
- na OpenRC sesja idzie bez uwsm, jak na Voidzie: `uwsm` nie jest instalowany (shim portu). Usługi, które włącza Omarchy (`systemctl enable …`), trafiają do runleveli przez shim `systemctl` (`rc-update add`, bez startu do restartu), SDDM wstaje przez usługę `display-manager`, NTP to chrony, a PipeWire z pulse i WirePlumberem startuje nadzorca unitów portu, jak `gentoo-pipewire-launcher`, bez plików w `/etc` (inne pulpity na tej samej maszynie zostają przy swoim).

Instalacja od zera na bazie z binhostem trwa w VM (8 rdzeni) około 75 minut na systemd i około 95 minut na OpenRC; kompilują się Hyprland, Quickshell i kilkadziesiąt pakietów ze zmienionymi USE. Wyniki: [`wyniki/2026-10-15-gentoo.md`](wyniki/2026-10-15-gentoo.md) (systemd), [`wyniki/2026-10-16-openrc.md`](wyniki/2026-10-16-openrc.md) (OpenRC).

## Aktualizacja

Tak jak w Omarchy: menu **Update** (na Voidzie **Update → Void**), ikona aktualizacji na pasku albo `omarchy-update` w terminalu. Na porcie to nakładka z tą samą kolejnością kroków, a kroki pacmana zastępuje `omarchy-port-update` (root):

1. `git pull --ff-only` w `/opt/omarchy-port` — nowa wersja portu, a z nią ewentualnie nowy pin Omarchy;
2. `port/install.sh --update`:
   - pakiety dystrybucji (Void: `xbps-install -Su` i lista; Gentoo: `emerge -uDN @world` i lista);
   - pliki Omarchy przy nowym pinie, z usunięciem plików poprzedniej wersji (zmienione przez admina → `.omarchy-save`);
   - warstwa i łatki;
   - instalacja sprzed [#8](https://git.szoniu.pl/szoniu/omarchy-port/issues/8) raz dostaje firewall (krok `config/firewall.sh` z regułą SSH; ufw włączony wcześniej przez kogoś innego zostaje bez zmian). Ufw rusza po restarcie, o który omarchy-update zapyta na końcu (`reboot-required`);
3. dalej jak upstream:
   - migracje (`omarchy-migrate`; pominięte i podmienione na dystrybucji: `port/share/<dystrybucja>/migracje.tsv`);
   - hook `post-update`;
   - `mise up --no-prune`;
   - sieroty (xbps; na Gentoo `emerge --depclean`);
   - pytanie o restart (jądro, Hyprland) i restart powłoki.

Pasek co 6 h sprawdza, czy gałąź, którą śledzi klon, ma nowy commit. **Podbicie wersji Omarchy** to commit w porcie, który zmienia [`port/share/upstream.env`](port/share/upstream.env). Najpierw [`prototyp/bramka/podbicie.sh`](prototyp/bramka/podbicie.sh) wypisuje nowe migracje, kroki `install/`, zmiany listy pakietów i stan łatek do przejrzenia, potem idzie test w VM.

## Jak to działa

1. **Pakiety:** lista Omarchy (`install/omarchy-base.packages`) zmapowana na nazwy dystrybucji → [`dane/mapa-pakietow-void.tsv`](dane/mapa-pakietow-void.tsv), [`dane/mapa-pakietow-gentoo.tsv`](dane/mapa-pakietow-gentoo.tsv) (atomy). Ma cztery stany: jest / zamiennik / brak / port. „Port” to pakiet bez odpowiednika w repo dystrybucji, który instaluje sam port (Void: `ufw-docker`; Gentoo także `gum`, `mise-bin`, `usage`, `lazydocker`, `localsend`).
2. **Pliki Omarchy:** przy commicie przypiętym w [`port/share/upstream.env`](port/share/upstream.env) — upstreamowe funkcje `package()` z PKGBUILD-ów `omarchy` i `omarchy-settings` ([omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs)) wywołane bez makepkg. Tak samo pakiety w stanie „port”, ze źródłami z `source=` ich PKGBUILD-a, sprawdzonymi sumami `b2sums=` (inna suma przerywa instalację, zanim cokolwiek zmieni się na dysku). Wynik trafia do `/usr/share/omarchy`, `/usr/bin/omarchy-*`, `/etc/skel` i `/etc`. Nie ma ręcznej mapy plików.
3. **`post_install` wybiórczo:** NIE nadpisujemy `os-release` (`ID_LIKE=arch` zmyliłby narzędzia rozpoznające dystrybucję) ani `nsswitch.conf`.
4. **Kroki `install/` Omarchy pojedynczo:** te zależne od pacmana, systemd czy limine pomijamy albo podmieniamy (lista jako dane: `port/share/<dystrybucja>/kroki.tsv`). `config/firewall.sh` idzie z upstreamu bez zmian. Część użytkownika robi upstreamowe `omarchy-provision-user` na tym samym drzewie kroków.
5. **Sesja:** na runit i OpenRC bez uwsm (`dbus-run-session` → PipeWire → `start-hyprland`), na systemd upstreamowy `omarchy.desktop` przez uwsm; SDDM z motywem Omarchy (na OpenRC przez usługę `display-manager`).
6. **Warstwa zgodności** (`port/`, instalacja: `port/install-layer.sh`). Co zależy od dystrybucji i initu, siedzi w backendach: `port/share/<dystrybucja>/backend.sh` (repozytoria, pakiety, pliki pakietów), `pkg.sh` (nakładki `omarchy-pkg-*` i aktualizacji) i `port/share/init/<init>.sh` (sshd, usługi bazowe, pakiety zależne od initu), a rozpoznanie w `port/share/system.sh`:
   - shimy w `/usr/local/bin` — powstają **tylko tam, gdzie oryginału nie ma**, więc na Gentoo z systemd nie zakłada się żaden; wyjątek to `uwsm` i `uwsm-app`, które bez systemd zostają zawsze (uwsm z pakietu stawia sesję z unitów `systemd --user`);
   - shim `systemctl`: wspólny front i backend usług initu (`port/share/init/<init>-uslugi.sh`: runit, OpenRC), nazwy usług z [`port/share/uslugi.tsv`](port/share/uslugi.tsv);
   - nakładki `omarchy-pkg-*` → menedżer pakietów dystrybucji oraz `omarchy-version`, `-channel`, `-pkgs` (fastfetch) → stan portu i baza pakietów;
   - na runit i OpenRC nadzorca unitów użytkownika zamiast `systemd --user`;
   - łatki z mastera Omarchy, których przypięte wydanie jeszcze nie ma (`port/share/latki/`, opis w nagłówku każdej).
7. **Branding Voida** (teksty UI zostają przy Omarchy — to nazwa warstwy pulpitu):
   - logo Voida w greeterze SDDM, w About/fastfetch i w wygaszaczu — [`port/share/void/branding.sh`](port/share/void/branding.sh) generuje je przy instalacji z `void-artwork`, także jako „Restore Default” z menu Style;
   - menu **Update → Void**, **Learn → Void** (Void Handbook) i logo Voida na przycisku paska — łatki [`port/share/void/latki/`](port/share/void/latki/);
   - konta sprzed brandingu dostają logo przez migrację portu (`port/share/void/migracje-portu/`), a plik zmieniony przez użytkownika zostaje.

Szczegóły, liczby i lista tego, co jeszcze pada: [`wyniki/2026-10-14-runda-1-2.md`](wyniki/2026-10-14-runda-1-2.md), [`wyniki/2026-10-14-runda-3.md`](wyniki/2026-10-14-runda-3.md), [`wyniki/2026-10-14-runda-4.md`](wyniki/2026-10-14-runda-4.md) (orkiestrator, test od zera), [`wyniki/2026-10-15-blokada-fastfetch.md`](wyniki/2026-10-15-blokada-fastfetch.md) (łatki, nakładki `omarchy-version*`), [`wyniki/2026-10-15-aktualizacja.md`](wyniki/2026-10-15-aktualizacja.md) (ścieżka aktualizacji), [`wyniki/2026-10-15-branding.md`](wyniki/2026-10-15-branding.md) (branding Voida), [`wyniki/2026-10-15-firewall.md`](wyniki/2026-10-15-firewall.md) (firewall), [`wyniki/2026-10-15-gentoo.md`](wyniki/2026-10-15-gentoo.md) (Gentoo z systemd, refaktor na backendy), [`wyniki/2026-10-16-openrc.md`](wyniki/2026-10-16-openrc.md) (Gentoo z OpenRC, shim z backendami), [`wyniki/2026-10-19-podbicie-4.0.5.md`](wyniki/2026-10-19-podbicie-4.0.5.md) (pierwsze podbicie Omarchy: v4.0.4 → v4.0.5). Otwarte zadania: [issues w Forgejo](https://git.szoniu.pl/szoniu/omarchy-port/issues).

## Układ repo

| Katalog | Zawartość |
|---|---|
| `port/` | **orkiestrator** `install.sh` i **warstwa zgodności** (Void/runit, Gentoo/systemd i OpenRC; części zależne od dystrybucji i initu w `share/<dystrybucja>/` i `share/init/`, PKGBUILD-y pakietów „port” w `share/pakiety/`): shimy `systemctl`, `systemd-run`, `systemd-inhibit`, `timedatectl`, `uwsm`, `uwsm-app`, `systemd-cat`, `xdg-terminal-exec` (tylko gdy oryginału brak; `uwsm*` zawsze bez systemd), backend usług shima `systemctl` (`share/init/<init>-uslugi.sh`, mapa `share/uslugi.tsv`); nakładki `omarchy-pkg-*` (backend `share/<dystrybucja>/pkg.sh`), `omarchy-version*` i `omarchy-update*`; `omarchy-port-update`; łatki `share/latki/`; migracje `share/void/migracje.tsv`; branding Voida (`share/void/branding.sh`, łatki `share/void/latki/`, migracja `share/void/migracje-portu/`); nadzorca unitów użytkownika `omarchy-port-units`; sesja; `install-layer.sh` |
| `prototyp/vm/` | VM testowa: QEMU z Fedory w kontenerze podmana (virgl), VNC, QMP (klawisze, mysz), zrzuty przez VNC |
| `prototyp/void/`, `prototyp/gentoo/` | baza systemu w VM (`install-base.sh`) — odpowiednik instalatorów szoniu/void i szoniu/gentoo do testów; Gentoo ze stage3 (podpis releng) i binhostem, `INIT=systemd` albo `openrc`, odpalane z live ISO Voida |
| `prototyp/bramka/` | `podbicie.sh` — co przejrzeć przed zmianą pinu Omarchy (migracje, kroki, pakiety, łatki) |
| `prototyp/test/` | zrzut skrótów z plików Lua Omarchy, test skrótów i menu w żywej sesji, test PAM, odcisk stanu systemu (`stan-systemu.sh`), test firewalla prawdziwymi pakietami (`firewall.sh`), test shima `systemctl` dla usług systemowych (`uslugi-test.sh`), pierwsze uruchomienie Chrome na Gentoo bez kreatora i z polityką Omarchy (`chrome-pierwsze-uruchomienie.sh`) |
| `dane/` | mapy pakietów i listy do instalacji (`*-void`, `*-gentoo`) |
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

`ssh_config` VM ma `ControlMaster`. Firewall portu ma na SSH `limit`, a ze slirp wszystkie połączenia przychodzą z jednego adresu, więc seria osobnych połączeń zostałaby odcięta.

Podgląd z innej maszyny: `ssh -L 5901:127.0.0.1:5901 <host>`, potem klient VNC na `localhost:5901`.

Instalacja od zera:
1. ISO Void live → `$VM_DIR`;
2. kernel i initrd z ISO → `$VM_DIR/iso-boot/`;
3. `vm.sh live`;
4. `install-base.sh` przez SSH, z `PASS_HASH`;
5. `git archive HEAD port dane` do VM i `port/install.sh --user szoniu`.

Dysk domyślny to `fresh.qcow2` (Void, migawki `czysta-baza` i `przed-8`); Gentoo: `VM_DISK=gentoo.qcow2 VM_VARS=OVMF_VARS.gentoo.fd prototyp/vm/vm.sh live|disk` (migawka `gentoo-baza`); Gentoo z OpenRC: `VM_DISK=gentoo-openrc.qcow2 VM_VARS=OVMF_VARS.gentoo-openrc.fd` (migawka `gentoo-openrc-baza`). Druga VM naraz: `VM_NR=2` (SSH `vm2` na 2230, VNC 5902, `qmp2.sock`; `qmp.py`, `shot.sh` i `hx.sh` biorą tę samą zmienną).

## Upstream i licencje

Omarchy (© 37signals / Basecamp) jest na licencji MIT. Port go **nie forkuje**: klonuje upstream przy tagu i dokłada własną warstwę. `default/fonts/omarchy/omarchy.ttf` zawiera loga cudzych marek, więc nie jest tu commitowany.
