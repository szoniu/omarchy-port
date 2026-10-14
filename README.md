# omarchy-port

**Pełne [Omarchy](https://github.com/basecamp/omarchy), tylko na Voidzie albo Gentoo zamiast Archa.** Hyprland, shell na Quickshellu, keybindy, menu, motywy i config Omarchy. Wszystko przy przypiętym tagu upstreamu, plus cienka warstwa zgodności dla runit/OpenRC i xbps/emerge.

Status: **prototyp** (Void działa w VM — wyniki w [`wyniki/`](wyniki/)). Port nie jest jeszcze gotowy do instalacji na sprzęcie.

Kontekst i decyzje: epik [szoniu/dotfiles#169](https://git.szoniu.pl/szoniu/dotfiles/issues/169). Instalatory, które będą wołać port: [szoniu/void](https://github.com/szoniu/void), [szoniu/gentoo](https://github.com/szoniu/gentoo).

## Jak to działa (stan prototypu)

1. **Pakiety:** lista Omarchy (`install/omarchy-base.packages`) zmapowana na nazwy Voida → [`dane/mapa-pakietow-void.tsv`](dane/mapa-pakietow-void.tsv). Ma trzy stany: jest / zamiennik / brak.
2. **Pliki Omarchy:** upstreamowe funkcje `package()` z PKGBUILD-ów `omarchy` i `omarchy-settings` ([omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs)) wywołane bez makepkg. Wynik trafia do `/usr/share/omarchy`, `/usr/bin/omarchy-*`, `/etc/skel` i `/etc`. Nie ma ręcznej mapy plików.
3. **`post_install` wybiórczo:** NIE nadpisujemy `os-release` (`ID_LIKE=arch` zmyliłby narzędzia rozpoznające dystrybucję) ani `nsswitch.conf`.
4. **Kroki `install/` Omarchy pojedynczo:** te zależne od pacmana, systemd czy limine pomijamy albo podmieniamy.
5. **Sesja bez uwsm:** `dbus-run-session` → PipeWire → `start-hyprland`; SDDM z motywem Omarchy.
6. **Shimy** (`/usr/local/bin`) — powstają **tylko tam, gdzie oryginału nie ma**, więc na Gentoo z systemd nie zakłada się żaden: `systemd-cat`, `uwsm-app`, `xdg-terminal-exec`.

Szczegóły, liczby i lista tego, co jeszcze pada: [`wyniki/2026-10-14-runda-1-2.md`](wyniki/2026-10-14-runda-1-2.md).

## Układ repo

| Katalog | Zawartość |
|---|---|
| `prototyp/vm/` | VM testowa: QEMU z Fedory w kontenerze podmana (virgl), VNC, QMP (klawisze, mysz), zrzuty przez VNC |
| `prototyp/void/` | baza Voida w VM, rundy portu (package(), kroki `install/`, shimy, sesja) |
| `prototyp/test/` | zrzut skrótów z plików Lua Omarchy, test skrótów w żywej sesji, test PAM |
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
5. kolejne rundy z `prototyp/void/`.

## Upstream i licencje

Omarchy (© 37signals / Basecamp) jest na licencji MIT. Port go **nie forkuje**: klonuje upstream przy tagu i dokłada własną warstwę. `default/fonts/omarchy/omarchy.ttf` zawiera loga cudzych marek, więc nie jest tu commitowany.
