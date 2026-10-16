#!/bin/bash
# Testy poprawek z review PR #1 — uruchamiać W VM jako użytkownik sesji (w VM sudo bez hasła).
# Każdy blok = jedno ustalenie review; FAIL = regresja.
export XDG_RUNTIME_DIR=/run/user/1000
qpid=$(pgrep -u 1000 -x quickshell | head -1)
# bez żywej sesji test szedłby środowiskiem SSH — to nie ten kanał, więc stop zamiast cichego pominięcia
[ -n "$qpid" ] || { echo "BRAK SESJI (quickshell użytkownika 1000) — test wymaga żywej sesji" >&2; exit 2; }
while IFS= read -r -d '' kv; do export "${kv?}"; done < /proc/$qpid/environ
# PATH z sesji bez zmian (zob. bind-test.sh) — test ma iść tym samym kanałem co menu i skróty
ok() { printf '  %-4s %s\n' "$1" "$2"; }
t() { if eval "$2"; then ok OK "$1"; else ok FAIL "$1"; fi; }
mkdir -p ~/.config/systemd/user
echo "### #2 is-active usługi systemowej bez roota"
t "sshd active jako user" '[[ $(systemctl is-active sshd.service) == active ]]'
echo "### #9 disable bez --now nie zatrzymuje, enable/--now"
# usługa testowa jak w uslugi-test.sh: runit uuidd, OpenRC rsyncd (uuidd na Gentoo wymaga USE uuidd w util-linux)
U=uuidd
[[ -d /run/openrc ]] && U=rsyncd
byla=$(systemctl is-enabled $U.service)
sudo systemctl disable $U.service; sleep 1
t "$U po disable: is-enabled=disabled" '[[ $(systemctl is-enabled $U.service) == disabled ]]'
sudo systemctl enable --now $U.service
t "enable --now: $U active od razu" '[[ $(systemctl is-active $U.service) == active ]]'
sudo systemctl disable $U.service; sleep 6
t "disable (bez --now): $U dalej active" '[[ $(systemctl is-active $U.service) == active ]]'
sudo systemctl disable --now $U.service; sleep 6
t "disable --now: $U zatrzymany" '[[ $(systemctl is-active $U.service) == inactive ]]'
if [[ $byla == enabled ]]; then sudo systemctl enable $U.service >/dev/null; fi
echo "### #10 enable usługi bez pakietu"
sudo systemctl enable supergfxd.service 2>/dev/null; rc=$?
t "supergfxd: rc≠0 i brak wiszącego wpisu w initcie" '(( rc != 0 )) && [[ ! -L /var/service/supergfxd && -z $(compgen -G "/etc/runlevels/*/supergfxd") ]]'
echo "### #4 timery roota widoczne dla systemctl"
sudo systemd-run --on-active=60s --unit=omarchy-test-root true
t "sudo systemctl is-active X.timer = active" '[[ $(sudo systemctl is-active omarchy-test-root.timer) == active ]]'
sudo systemctl stop omarchy-test-root.timer
t "po stop: inactive" '[[ $(sudo systemctl is-active omarchy-test-root.timer) == inactive ]]'
echo "### #4b reguła tmpfiles przy boocie"
echo 'szoniu ALL=(ALL) NOPASSWD: /bin/true' | sudo tee /etc/sudoers.d/99-omarchy-nopasswd-test >/dev/null
# OpenRC: to samo, co robi przy starcie systemd-tmpfiles-setup, tylko dla reguł Omarchy (pełny przebieg
# --remove na żywym systemie czyściłby też /tmp); runit: core-service portu
if [[ -d /run/openrc ]]; then sudo sh -c 'systemd-tmpfiles --remove --boot /etc/tmpfiles.d/omarchy*.conf'
else sudo sh -c '. /etc/runit/core-services/90-omarchy-port-tmpfiles.sh'; fi
# przez sudo: /etc/sudoers.d ma 0750 root, więc użytkownik nie widzi plików w środku i samo -e zawsze mówi „nie ma”
t "grant NOPASSWD usunięty przez reguły tmpfiles" '! sudo test -e /etc/sudoers.d/99-omarchy-nopasswd-test'
echo "### #3 systemd-run: --wait po poleceniu idzie do programu; --unit w tle widoczny"
systemd-run --user --quiet --unit=omarchy-test-args sh -c 'echo "$@" > /tmp/args-test; sleep 30' _ --wait
sleep 1
t "program dostał --wait" 'grep -qx -- "--wait" /tmp/args-test'
t "systemctl --user is-active omarchy-test-args.service" '[[ $(systemctl --user is-active omarchy-test-args.service) == active ]]'
systemctl --user stop omarchy-test-args.service
t "po stop: proces zabity" '! pgrep -f "[s]leep 30" >/dev/null'
echo "### #11 czasy"
for x in 1min 90sec 3hours; do systemd-run --user --on-active=$x --unit=omarchy-t-$x true; done
t "1min/90sec/3hours przyjęte (3 timery)" '[[ $(systemctl --user list-timers --all --output=json "omarchy-t-*" | jq length) == 3 ]]'
for x in 1min 90sec 3hours; do systemctl --user stop omarchy-t-$x.timer; done
echo "### #1 show -p --value, status --no-pager, is-enabled --no-pager"
t "show -p ActiveState --value sleep-lock = active" '[[ $(systemctl --user show -p ActiveState --value omarchy-sleep-lock.service) == active ]]'
t "show --property=ActiveState --value graphical-session.target = inactive (bez śmieci)" '[[ $(systemctl --user show --property=ActiveState --value graphical-session.target) == inactive ]]'
mp=$(systemctl --user show -p MainPID --value omarchy-sleep-lock.service)
t "MainPID sleep-lock = żywy proces unitu ($mp)" '[[ $mp -gt 0 ]] && grep -q sleep-monitor /proc/$mp/cmdline'
t "status --no-pager aktywnego = rc 0" 'systemctl --user status omarchy-sleep-lock.service --no-pager >/dev/null'
t "is-enabled --no-pager = enabled" '[[ $(systemctl --user is-enabled omarchy-sleep-lock.service --no-pager) == enabled ]]'
echo "### #6 stop zabija wnuki"
printf '[Service]\nExecStart=/bin/bash -c "sleep 1001 & wait"\nRestart=always\n' > ~/.config/systemd/user/t-grand.service
systemctl --user start t-grand.service; sleep 1.5
t "wnuk sleep 1001 działa" 'pgrep -f "[s]leep 1001" >/dev/null'
systemctl --user stop t-grand.service; sleep 1
t "po stop: brak sieroty sleep 1001" '! pgrep -f "[s]leep 1001" >/dev/null'
echo "### #14 równoległe starty = 1 nadzorca"
systemctl --user start t-grand.service & systemctl --user start t-grand.service & systemctl --user start t-grand.service & wait; sleep 1.5
n=$(pgrep -f "[o]marchy-port-units __supervise t-grand.service" | wc -l)
t "1 nadzorca (jest $n)" '[[ $n == 1 ]]'
echo "### #7 restart w trakcie RestartSec nie gubi nowego nadzorcy"
printf '[Service]\nExecStart=/bin/true\nRestart=always\nRestartSec=3\n' > ~/.config/systemd/user/t-loop.service
systemctl --user start t-loop.service; sleep 1
systemctl --user restart t-loop.service; sleep 4
t "po restarcie is-active=active" '[[ $(systemctl --user is-active t-loop.service) == active ]]'
systemctl --user stop t-loop.service t-grand.service
echo "### #13 RestartSec=500ms i StartLimit"
printf '[Service]\nExecStart=/nie/istnieje\nRestart=always\nRestartSec=500ms\n' > ~/.config/systemd/user/t-fail.service
systemctl --user start t-fail.service; sleep 6
t "po 6 s nadzorca się poddał (StartLimit)" '! pgrep -f "[o]marchy-port-units __supervise t-fail.service" >/dev/null'
t "w logu StartLimitBurst" 'grep -q "t-fail.service: 5 restartów" ~/.local/state/omarchy-port/units.log'
echo "### #5 restart dźwięku jak omarchy-restart-audio"
systemctl --user restart wireplumber.service pipewire.service pipewire-pulse.service; sleep 2
t "po restarcie główny pipewire działa" 'pgrep -u 1000 -fx pipewire >/dev/null'
echo "### #8 inny pipewire (speaker-tuning) nie udaje dźwięku"
systemctl --user stop pipewire.service
setsid pipewire -c /dev/null >/dev/null 2>&1 & fake=$!; sleep 0.5
t "audio nieaktywne mimo innego procesu pipewire" '[[ $(systemctl --user is-active pipewire.service) == inactive ]]'
kill $fake 2>/dev/null
systemctl --user start pipewire.service; sleep 1
t "start pipewire.service podnosi demona" 'pgrep -u 1000 -fx pipewire >/dev/null'
rm -f ~/.config/systemd/user/t-*.service /tmp/args-test
