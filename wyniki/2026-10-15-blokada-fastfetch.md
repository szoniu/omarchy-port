## 2026-10-15: blokada ekranu (#10) i fastfetch (#11)

Oba błędy wyszły w teście ręcznym przez VNC po rundzie 4. Poprawki to nakładki w `install-layer.sh` — łatka z mastera Omarchy i trzy nakładki `omarchy-version*`.

### #10 — blokada ekranu działa raz na sesję

**Przyczyna:** regresja w Quickshell 0.3.2 (quickshell-mirror/quickshell#1230). `WlSessionLock::unlock()` sprawdza `isLocked()` dopiero po `manager->unlock()`, więc `lockStateChanged` przy odblokowaniu nie wychodzi nigdy (w 0.3.1 wychodził).
- W Omarchy v4.0.4 wiązanie `locked` w `shell/plugins/lock/Service.qml` zostaje przez to `true`.
- `IpcHandler.lock()` (`if (!root.locked && …)`) traktuje każde kolejne żądanie jako wykonane: skrót, menu, bezczynność i blokada przed uśpieniem nic nie robią.
- Omarchy naprawiło to na masterze w `d1a614ce` (#14978): decyzje czytają stan na bieżąco (`currentlyLocked()`). Wydania z tą poprawką jeszcze nie ma.

**Poprawka:** `port/share/latki/blokada-biezacy-stan.patch` — ta sama zmiana przeniesiona na plik z v4.0.4. `install-layer.sh` nakłada łatki z `share/latki/` przez `git apply` (`patch` nie ma w bazie Voida, git i tak jest warunkiem orkiestratora):
- plik po łatce → „już nałożona”;
- plik, do którego nie pasuje ani łatka, ani jej cofnięcie (inna wersja Omarchy) → UWAGA i bez zmian.

**Quickshell nie przeładowuje zmienionych plików QML sam.** Łatka działa od restartu powłoki albo systemu: przebieg pod żywą sesją nałożył ją, a status dalej był stary. Upstream robi to samo — `omarchy-update-restart` po aktualizacji woła `omarchy-restart-shell`, bo „a stale process can lazy-load new files into old code”. Orkiestrator kończy się poleceniem restartu systemu.

**Test przez realny kanał** (klawiatura VM przez QMP, żywa sesja):

| Przebieg | Blokada 1 (Super+Ctrl+L) | Odblokowanie hasłem | Blokada 2 | Status po odblokowaniu |
|---|---|---|---|---|
| bez łatki (czerwone) | blokuje (tu: po bezczynności) | OK | **nic** (zrzut: pulpit) | `locked:true`, `sessionLocked:false` |
| łatka bez restartu powłoki | — | — | **nic** | bez zmian — stary kod w pamięci |
| łatka po restarcie systemu (zielone) | blokuje | OK | **blokuje** (zrzut: pole hasła) | `locked:false` |

Blokada po bezczynności po dwóch wcześniejszych odblokowaniach (zielone): `lock-system: lock-timeout` o 07:45:16, 300 s po ostatnim klawiszu → `session-locked=true`, `secure=true`.

Końcowy przebieg orkiestratora pod żywą sesją: `KOD=0`. Etap 3 wypakował `Service.qml` od nowa, a warstwa nałożyła łatkę ponownie. Gałąź UWAGA sprawdzona na `Service.qml` z mastera Omarchy, który ma już poprawkę: nie pasuje ani łatka, ani jej cofnięcie.

### #11 — fastfetch: linie wersji, kanału i aktualizacji

Config fastfetch Omarchy woła trzy polecenia, które czytają pacmana. Na porcie:
- linia OS znikała (`omarchy-version` → `pacman -Q`, rc=1);
- w linii kanału było „unknown” (mirrorlist pacmana);
- „Update” pokazywało zawsze dzisiejszą północ (`date -d ""` przy braku `pacman.log`).

**Poprawka** (decyzja z #11): nakładki w `port/bin/`, ten sam mechanizm co `omarchy-pkg-*` (instalacja do `/usr/local/bin` + przekierowanie linków w `/usr/share/omarchy/bin`, PATH sesji):
- `omarchy-version` → `pkgver-pkgrel` z przypiętego PKGBUILD-a `omarchy`, zapisane przez etap 3 orkiestratora w `/var/lib/omarchy-port/wersja-pakietu-omarchy`. Gałąź dev jak upstream.
- `omarchy-version-channel` → `void`.
- `omarchy-version-pkgs` → najnowsza `install-date` z bazy xbps (xbps nie ma logu transakcji). Obejmuje też instalacje, nie tylko aktualizacje.

**Test w terminalu sesji** (Super+Enter → `fastfetch`, zrzuty):
- przed: brak linii OS, kanał „unknown”, „Update: Thursday, October 15 2026 at 00:00”;
- po: „OS: Omarchy 4.0.4-2”, kanał „void”, „Update: Thursday, October 15 2026 at 07:37” (aktualizacja mesa w tym przebiegu).

Kontrola mostu jest ta sama co dla `omarchy-pkg-*` z rundy 4: bez przekierowania linków sesja bierze wersje z pacmanem — dokładnie stan „przed”.

### Nowe ustalenie: linia motywu w fastfetch

Linia motywu pokazuje dosłowne `-e Tokyo Night \e[38m●…` zamiast kolorowych kropek.
- Config Omarchy (`/etc/fastfetch/config.jsonc:122`) ma `echo -e "… \e[38m● …"`.
- Moduł `command` fastfetch wykonuje tekst przez `/bin/sh` — sprawdzone: `$0` = `/bin/sh` → `/usr/bin/dash`.
- Na Voidzie `/bin/sh` to `dash`, którego `echo` nie zna `-e` ani `\e`. Na Archu `/bin/sh` to bash.
- Innych bashizmów wykonywanych przez `sh -c` w configu fastfetch, skrótach i autostarcie Hyprlanda nie znalazłem; Quickshell woła `bash -c`.
- `/etc/fastfetch/config.jsonc` jest w `backup=()` `omarchy-settings`, więc łatka na config zderzy się z ochroną zmian admina.
- Decyzja (15.10.2026): zadanie w backlogu → #12 (łatki dla plików z `backup=()` nakładane w etapie 3 na rozpakowany pakiet).

### Poprawki po review PR #3

Review (zwykły) dał 15 ustaleń. Wszystkie sprawdziłem sam: 12 poprawionych, 3 odrzucone z uzasadnieniem.

| Ustalenie | Co zrobione | Test w VM |
|---|---|---|
| `die` przy nieczytelnej wersji stał **po** etapie 3 (przerwanie po nadpisaniu plików, nie do obejścia ponownym uruchomieniem) | wersja czytana i sprawdzana przed zmianami na dysku; zła = UWAGA i brak pliku, nie przerwanie; regex przyjmuje epoch i pkgrel z kropką | przebieg `KOD=0` |
| niedopasowana łatka blokady ginęła w logu, a orkiestrator kończył się OK | po etapie 5 orkiestrator sprawdza każdą łatkę: brak = BŁĄD w `kroki.tsv`, kod 1; łatka bezpieczeństwa ma to słowo w 1. linii nagłówka → UWAGA w podsumowaniu | kopia z zepsutą łatką: BŁĄD, `UWAGA share/latki/…: … BEZPIECZEŃSTWO …`, `KOD=1` |
| „już nałożona” łapała też wydanie z tą samą poprawką — sygnał do usunięcia łatki nie przychodził | orkiestrator woła warstwę z `OMARCHY_PORT_SWIEZE_PLIKI=1` (pliki świeżo wypakowane): cofnięcie pasuje → „wydanie ma już tę zmianę, łatkę można usunąć”; samodzielnie → „już nałożona” | obie gałęzie |
| brak gita lub plików Omarchy dawał mylące „nie pasuje” | osobne komunikaty, łatki pominięte | — (niesprawdzone w VM; prosta gałąź) |
| `omarchy-version` bez pliku wersji (sama warstwa) → linia OS znika | rezerwa: tag z `wersja-omarchy` (`4.0.4`) | bez pliku `4.0.4`, z plikiem `4.0.4-2` |
| `install-date` ma skrót strefy: w bazie mieszają się CEST i UTC (174 wpisy z chroota), `date -d` nie zna np. AEDT, sort leksykalny myli kolejność | `omarchy-version-pkgs` z czasu modyfikacji `.<pakiet>-files.plist` (xbps zapisuje je przy instalacji i aktualizacji; przebieg bez zmian ich nie rusza — sprawdzone) | 07:37 = najnowsza lista (mesa) |
| `ls -t` (SC2012) | znika razem z poprzednim | — |
| plik stanu z umaską roota | `chmod 644` | `644` (przebieg z umaską 022; z 077 nie uruchamiałem całości) |
| epoch pomijany | `[epoch:]pkgver-pkgrel` jak `pacman -Q` | — |
| PKGBUILD wczytywany drugi raz po tar | odczyt przeniesiony przed zmiany (jedno miejsce) | — |
| testy nie obejmowały nowych przekierowań ani łatki | `stan-systemu.sh`: przekierowania `omarchy-version*`, licznik `currentlyLocked`, plik wersji z prawami | nowe wiersze w odcisku |
| README nie linkował wyników | linki do rundy 4, tego pliku i issues | — |
| **odrzucone:** łatać sam Quickshell zamiast QML | port nie buduje własnych pakietów xbps; upstream Omarchy wybrał obejście w QML; `loadBackground: root.locked` zostaje jak upstream (nieaktualne `true` trzyma tylko tło w pamięci) | — |
| **odrzucone:** stała ścieżki stanu we wspólnej bibliotece | `systemctl` i core-service też wpisują `/var/lib/omarchy-port` wprost — spójnie | — |
| **odrzucone:** decyzja o linii motywu niezacommitowana | wchodzi w tym commicie (#12) | — |

Przy okazji: `.cowsay-files.plist` z 14.10, 21:35 to instalacja z menu z testu ręcznego (punkt 3) — `cowsay-3.8.4_1` przez xbps, czyli ścieżka z sesji działa.
