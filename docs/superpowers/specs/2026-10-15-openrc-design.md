# Gentoo z OpenRC — projekt (omarchy-port#5)

Data: 15.10.2026. Status: projekt zaakceptowany w rozmowie, spec do przejrzenia.

## Cel i kryteria sukcesu

Port działa na Gentoo z OpenRC tak jak na Gentoo z systemd. Kryteria (te same co w `wyniki/2026-10-15-gentoo.md`):

1. `port/install.sh --user szoniu` na świeżej bazie `INIT=openrc` kończy się `KOD=0`;
2. po restarcie: `rc-status` bez usług `crashed`, greeter SDDM, logowanie hasłem, sesja Hyprlanda z Quickshellem, dźwięk (PipeWire, WirePlumber, pipewire-pulse), unity użytkownika Omarchy;
3. `prototyp/test/firewall.sh`: 0 ŹLE; `bind-test.sh`: wynik na poziomie Gentoo/systemd (95 ze 119);
4. blokada (PAM), About, reboot i wylogowanie z menu, aktualizacja z menu (Update → Omarchy);
5. regresja: Void (instalacja od zera i aktualizacja z menu) oraz Gentoo z systemd (aktualizacja z menu).

## Zakres

W zakresie: warstwa initu OpenRC, pakiety zależne od initu, sesja bez uwsm, testy w VM, dokumentacja.

Poza zakresem: branding Gentoo (osobny punkt #5), greeter SDDM znikający raz na kilka startów (#15), unity systemd bez odpowiednika na żadnym z initów bez systemd (np. `tiny-dfr`, `makima`, `t2fanrd` — dziś na Voidzie też kończą się „nieznany unit”).

## Ustalenia

- #5 (15.10): OpenRC jako warstwa initu na shimach z Voida, sesja bez uwsm jak na runit, nadzorca unitów użytkownika `omarchy-port-units`, baza w VM przez `prototyp/gentoo/install-base.sh` z `INIT=openrc`.
- Ankieta 15.10: **wspólny shim `systemctl` z backendami usług** (runit, OpenRC), a nie osobny shim na każdy init.
- Ankieta 15.10: **nowy dysk VM `gentoo-openrc.qcow2`**; `gentoo.qcow2` z zainstalowanym portem na systemd zostaje do regresji.
- Odrzucone: usługi użytkownika OpenRC (≥ 0.60, `pam_openrc`) zamiast `omarchy-port-units`. Unity Omarchy to pliki systemd, a nadzorca portu już je czyta i jest sprawdzony na Voidzie. Usługi OpenRC wymagałyby tłumaczenia unitów na skrypty `openrc-run`.

## Co mamy → gdzie reużyć

| Mamy | Na OpenRC |
|---|---|
| `port/bin/omarchy-port-units` | bez zmian (dźwięk: niżej) |
| `port/session/session`, shim `uwsm` | bez zmian, instalowane jak na runit |
| shimy `systemd-run`, `systemd-cat`, `systemd-inhibit`, `uwsm-app`, `xdg-terminal-exec` | bez zmian — `install-layer.sh` zakłada je, bo oryginałów nie ma |
| shim `systemctl`: `--user`, zasilanie, timery roota, flagi, log | część wspólna (front) |
| shim `systemctl`: usługi runit | backend runit, kod przeniesiony bez zmiany zachowania |
| `port/share/runit-services.tsv` | `port/share/uslugi.tsv` z kolumnami `runit` i `openrc` |
| `port/share/init/{runit,systemd}.sh` | nowy `port/share/init/openrc.sh` |
| wzorzec `share/<dystrybucja>/pkg.sh` → `/usr/share/omarchy-port/pkg-backend.sh` | ten sam wzorzec dla backendu usług |

## Komponenty

### 1. Rozpoznanie (`port/share/system.sh`)

Para `gentoo/openrc` obsługiwana (dziś kończy się „jeszcze nieobsługiwane”). Wykrywanie initu bez zmian (`/run/openrc`).

### 2. Init dla orkiestratora (`port/share/init/openrc.sh`)

Ten sam interfejs co `runit.sh` i `systemd.sh`:
- `init_pid sshd` — PID z pidfile'a usługi (`/run/sshd.pid`), tylko gdy `rc-service sshd status` mówi „started”;
- `init_przeladuj_sshd` — `rc-service sshd reload`. Skrypt Gentoo sprawdza config i wysyła SIGHUP do nasłuchującego sshd, więc trwające sesje (także ta z instalacją) zostają;
- `USLUGI_BAZOWE=(dbus elogind chronyd)` — polkit na Gentoo startuje z aktywacji D-Bus; NTP przez chrony, jak na Voidzie (`omarchy-update-time` restartuje `systemd-timesyncd`, mapa kieruje to na `chronyd`);
- pakiety zależne od initu (nowe zmienne, w `runit.sh` i `systemd.sh` puste):
  - `INIT_PAKIETY_BEZ=(gui-apps/uwsm)` — ebuild uwsm nie zależy od systemd, więc na OpenRC by się zainstalował. Wtedy `install-layer.sh` pominąłby shim („jest /usr/bin/uwsm”), a `omarchy.desktop` (`uwsm start …`) uruchamiałby sesję przez `systemd --user`, którego nie ma;
  - `INIT_PAKIETY=(sys-auth/elogind net-misc/chrony)` — elogind dochodzi dziś z USE profilu, ale `loginctl` i `elogind-inhibit` są dla portu twardą zależnością.

Orkiestrator (etap 2) odejmuje `INIT_PAKIETY_BEZ` od listy i dokłada `INIT_PAKIETY` — przy instalacji i przy `--update`.

### 3. Shim `systemctl`: front + backend usług

`port/bin/systemctl` zostaje jedynym shimem. Front robi to, co dziś, poza usługami systemowymi: parsowanie flag, log, `--user` → `omarchy-port-units`, zasilanie → `loginctl`, `daemon-reload` i podobne → rc 0, timery z `sudo systemd-run --on-active`, unity pominięte (`-` w mapie) i nieznane (rc 5), `need_root`, teksty i kody wyjścia jak w systemd.

Backend to plik źródłowany przez front z `/usr/share/omarchy-port/uslugi-backend.sh` (kładzie go `install-layer.sh` z `port/share/init/<init>-uslugi.sh`, tak jak `pkg-backend.sh`). Front woła tylko prymitywy:

| Funkcja | runit | OpenRC |
|---|---|---|
| `usl_istnieje <nazwa>` | `/etc/sv/<nazwa>` | `/etc/init.d/<nazwa>` |
| `usl_wlacz <nazwa> <now>` | dzisiejsza logika (link, plik `down`, tryb `OMARCHY_PORT_INSTALL` + `start-at-boot`) | `rc-update add <nazwa> <runlevel>`; `--now` → też `rc-service start` |
| `usl_wylacz <nazwa> <now>` | plik `down` / usunięcie linku | `rc-update del` (bez zatrzymania, jak w systemd); `--now` → też `rc-service stop` |
| `usl_maskuj`, `usl_odmaskuj` | dzisiejsza logika | OpenRC nie ma maski: `rc-update del` bez zatrzymania (jak `systemctl mask`) / bez działania |
| `usl_start`, `usl_stop`, `usl_restart`, `usl_przeladuj` | `sv …` | `rc-service …` |
| `usl_stan <nazwa>` | `run` / `down` / pusty (dzisiejszy `svstat`) | z `rc-service <nazwa> status` |
| `usl_wlaczona <nazwa>` | link bez `down` albo `start-at-boot` | `rc-update show` w runlevelu z mapy |

Na OpenRC `rc-update add` nie startuje usługi, więc semantyka „włączona od następnego startu” (Omarchy: „Enable services only… don't start daemons mid-install”) wychodzi sama — bez trybu `OMARCHY_PORT_INSTALL` i bez `start-at-boot`.

Do sprawdzenia w VM: czy `rc-service <nazwa> status` działa bez roota (stan widzi też użytkownik: `systemctl is-active` w Omarchy idzie bez sudo). Rezerwa: `/run/openrc/started/<nazwa>`.

### 4. Mapa usług (`port/share/uslugi.tsv`)

Zastępuje `runit-services.tsv` (stary plik w `/usr/share/omarchy-port` usuwa `install-layer.sh`). Kolumny: `systemd`, `runit`, `openrc`, `uwagi`. W kolumnie `openrc` opcjonalny runlevel po `@` (domyślnie `default`). Brak wiersza = ta sama nazwa, jeśli skrypt usługi istnieje (jak dziś na runit).

Nazwy OpenRC z ebuildów Gentoo (15.10.2026): `NetworkManager`, `sshd`, `tailscale` (systemd: `tailscaled`), `iwd`, `ufw`, `thermald`, `docker` (z `docker.socket` i `docker.service`), `cupsd` (systemd: `cups`), `bluetooth`, `avahi-daemon`, `power-profiles-daemon`, `chronyd` (systemd: `systemd-timesyncd`), `dbus`, `elogind@boot`, `dhcpcd`, `uuidd`.

Nowe wiersze:
- `elogind`: runit `elogind` (ta sama nazwa co bez wiersza — zachowanie Voida bez zmian; port i tak go tam nie włącza, bo startuje z aktywacji D-Bus), OpenRC `elogind@boot` (Gentoo wiki);
- `sddm`: OpenRC `display-manager`. SDDM na OpenRC nie ma własnego skryptu — wstaje przez `display-manager` (`gui-libs/display-manager-init`, dociągany przez `sddm[-systemd]`) z `DISPLAYMANAGER="sddm"` w `/etc/conf.d/display-manager`. Backend OpenRC ustawia tę zmienną przy `enable` usługi `display-manager`.

Pozostałe wiersze z `-` (`systemd-resolved`, `systemd-networkd`, `systemd-oomd`, `NetworkManager-wait-online`, snapper, …) mają `-` także w kolumnie OpenRC.

### 5. Warstwa (`port/install-layer.sh`)

Gałąź `openrc` obok `runit` i `systemd`:
- sesja: `/usr/libexec/omarchy-port/session` i plik sesji w `wayland-sessions`. Plik powstaje z szablonu z nazwą dystrybucji (`omarchy-void.desktop` „Omarchy (Void)” bez zmian, na Gentoo `omarchy-gentoo.desktop` „Omarchy (Gentoo)”). Motyw SDDM Omarchy i tak wybiera `omarchy.desktop` przez shim `uwsm`;
- dźwięk: `/etc/pipewire/pipewire.conf.d/` z dwoma plikami portu (`context.exec` dla `wireplumber` i `pipewire -c pipewire-pulse.conf`) — ten sam model co na Voidzie, gdzie te pliki daje pakiet Voida (`/usr/share/examples/…`). Nadzorca unitów rozpoznaje dźwięk po procesie o linii dokładnie `pipewire` i jego dzieciach, więc zostaje bez zmian. Do sprawdzenia w VM (PipeWire 1.6). Rezerwa: `gentoo-pipewire-launcher` z pakietu, z poprawką wykrywania w `omarchy-port-units` (launcher startuje `/usr/bin/pipewire` pełną ścieżką i osobne procesy);
- tmpfiles przy starcie: na Gentoo z OpenRC reguły `/usr/lib/tmpfiles.d` stosuje `systemd-tmpfiles-setup` z `sys-apps/systemd-utils[tmpfiles]` (`--create --remove --boot`, więc także `r!` z `omarchy-nopasswd-sudo.conf`). Warstwa sprawdza, czy skrypt jest w runlevelu `boot`, i dokłada go tylko, gdy go brak. Odpowiednik core-service `90-omarchy-port-tmpfiles.sh` z Voida nie jest potrzebny;
- backend usług: `uslugi-backend.sh` dla runit i OpenRC; na systemd go nie ma (shima nie ma).

### 6. `timedatectl`

`set-timezone` dopisuje `TIMEZONE=` do `/etc/rc.conf` tylko na Voidzie. Na Gentoo `/etc/rc.conf` to config OpenRC — tam tylko `/etc/localtime`.

### 7. Orkiestrator (`port/install.sh`)

Poza filtrem pakietów (pkt 2) zmieniają się komentarze nagłówka. Etap 9 działa przez shim jak na runit: `systemctl enable dbus|elogind|chronyd`, `disable dhcpcd`. `ssh_w_firewallu` pyta `systemctl -q is-enabled sshd.service` — przez shim.

## Obsługa błędów

Bez nowych mechanizmów — te same zasady co na runit:
- usługa z mapy bez skryptu w `/etc/init.d` = pakietu nie ma → `enable` kończy się rc 5 i wpisem w logu, bez wiszącego wpisu w runlevelu;
- `-` w mapie → rc 0 i wpis „pominięty” w logu;
- błąd `rc-update`/`rc-service` → rc 1 shima, a orkiestrator liczy krok jako BŁĄD w podsumowaniu.

## Testy

VM `VM_DISK=gentoo-openrc.qcow2` (nowe `OVMF_VARS.gentoo-openrc.fd`), baza `INIT=openrc bash install-base.sh` z live ISO Voida, migawka `gentoo-openrc-baza`.

1. **Instalacja od zera** (`git archive` gałęzi, `install.sh --user szoniu`): `KOD=0`, w podsumowaniu tylko zamierzone pominięcia. Czas i liczba kompilowanych pakietów do wyników (binhost na profilu OpenRC może dawać inne proporcje niż na systemd).
2. **Po restarcie** — kryteria 2–4 z początku; dodatkowo stan usług (`rc-status -a`), `rc-update show` zgodny z tym, co włączyło Omarchy, reguły tmpfiles (grant „sudo bez hasła” znika po restarcie).
3. **Shim `systemctl`**: `review-test.sh` dostaje gałąź OpenRC (enable/disable z `--now` i bez na `uuidd`, nieznana usługa → rc 5 bez wpisu w runlevelu, timery roota, unity `--user`). Asercje na stanie initu wprost (`rc-update show`, `/run/openrc`), nie przez shim.
4. **Kontrola mostu**: z usuniętym `uslugi-backend.sh` (i z backendem runit podstawionym na OpenRC) testy z pkt 3 muszą się zaczerwienić.
5. **`firewall.sh`**: gałąź OpenRC w kontroli usługi ufw (`rc-update show default`).
6. **Regresja Voida** (druga VM, `fresh.qcow2`): instalacja od zera z migawki `czysta-baza` i aktualizacja z menu z `przed-8`, `review-test.sh` na runit.
7. **Regresja Gentoo z systemd** (`gentoo.qcow2`, stan po instalacji `5e3c1d2`): aktualizacja z menu do gałęzi — shimy dalej nie powstają, sesja i firewall bez zmian.

## Ryzyka i punkty do sprawdzenia w VM

- `install-base.sh` z `INIT=openrc` nie był jeszcze uruchamiany (stage3 `desktop-openrc`, profil `23.0/desktop`).
- Binhost: pakiety z USE `elogind` zamiast `systemd` — możliwe więcej kompilacji niż na systemd.
- `elogind-inhibit` (shim `systemd-inhibit`) i `loginctl reboot|poweroff` z elogind na OpenRC — sprawdzić realnym wywołaniem z menu.
- Kolejność startu `ufw` i `docker` na OpenRC (łańcuch `DOCKER-USER`) — sprawdza `firewall.sh`.
- Miejsce na dysku hosta: nowy obraz urośnie do ~30 GB przy 93 GB wolnych.

## Dokumentacja

README (status, sekcja instalacji na Gentoo z OpenRC, „Jak to działa”: sesja i warstwa, układ repo), `wyniki/2026-10-<dzień>-openrc.md` z przebiegami i testami, komentarz w #5 (OpenRC zrobione, zostaje branding Gentoo).
