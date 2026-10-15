#!/usr/bin/env bash
# Test firewalla portu (omarchy-port#8) w żywym systemie — jako root, w VM po restarcie.
#   prototyp/test/firewall.sh [--bez-dockera]
# Konfiguracja (ufw włączony w runit i w ufw.conf, reguły z install/config/firewall.sh, blok ufw-docker
# w after.rules, SSH) i prawdziwe pakiety: dwie przestrzenie sieciowe na veth udają hosta z internetu
# (203.0.113.2) i z LAN-u (192.168.77.2) i łączą się z portami tej maszyny oraz z portem kontenera
# opublikowanym przez Dockera (`docker run -p`). Połączenie: otwarte / odrzucone (RST — firewall
# przepuścił, nikt nie słucha) / zablokowane (cisza — DROP). Kontener: busybox z Docker Huba.
# Wynik: TSV na stdout (sprawdzenie, oczekiwane, jest, OK|ŹLE); kod 1, gdy cokolwiek ŹLE.
set -euo pipefail
(( EUID == 0 )) || { echo "firewall.sh: uruchom jako root" >&2; exit 2; }
DOCKER=1
[[ ${1:-} == --bez-dockera ]] && DOCKER=0

ZLE=0
sprawdz() { # sprawdz <co> <oczekiwane> <jest>
  local w=OK
  [[ $2 == "$3" ]] || { w=ŹLE; ZLE=$((ZLE + 1)); }
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$w"
}

# --- konfiguracja -------------------------------------------------------------------------------
st=$(ufw status | sed -n 's/^Status: //p')
sprawdz "ufw status" active "$st"
sprawdz "ENABLED w /etc/ufw/ufw.conf" yes "$(sed -n 's/^ENABLED=//p' /etc/ufw/ufw.conf)"
# runit: shim portu (link w /var/service bez pliku down), systemd: prawdziwy systemctl
sprawdz "usługa ufw włączona (systemctl is-enabled)" tak \
  "$(systemctl -q is-enabled ufw.service && echo tak || echo nie)"
reguly=$(ufw show added)
for r in 'ufw allow 53317/udp' 'ufw allow 53317/tcp' \
         "ufw allow from 172.16.0.0/12 to 172.17.0.1 port 53 proto udp comment 'allow-docker-dns'" \
         "ufw allow from 192.168.0.0/16 to 172.17.0.1 port 53 proto udp comment 'allow-docker-dns'"; do
  sprawdz "reguła: $r" jest "$(grep -qxF "$r" <<<"$reguly" && echo jest || echo brak)"
done
# porty sshd jak w install.sh (ssh_w_firewallu): ListenAddress z `sshd -T`, inaczej Port, domyślnie 22
ssh_ocz=brak
systemctl -q is-enabled sshd.service && ssh_ocz=jest
sshd_t=$(sshd -T 2>/dev/null) || sshd_t=
porty_ssh=$(awk 'tolower($1) == "listenaddress" { n = split($2, a, ":"); print a[n] }' <<<"$sshd_t" | sort -un)
[[ -n $porty_ssh ]] || porty_ssh=$(awk 'tolower($1) == "port" { print $2 }' <<<"$sshd_t" | sort -un)
[[ -n $porty_ssh ]] || porty_ssh=22
for port in $porty_ssh; do
  sprawdz "reguła: ufw limit $port/tcp comment 'omarchy-sshd' (gdy sshd włączony)" "$ssh_ocz" \
    "$(grep -qxF "ufw limit $port/tcp comment 'omarchy-sshd'" <<<"$reguly" && echo jest || echo brak)"
done
# wyjście do zmiennej, nie `polecenie | grep -q`: pod pipefail grep -q kończący wcześnie daje piszącemu
# SIGPIPE (141), czyli fałszywe „nie” przy poprawnej konfiguracji
werbose=$(ufw status verbose)
sprawdz "domyślnie: deny (incoming), allow (outgoing)" tak \
  "$(grep -qF 'Default: deny (incoming), allow (outgoing)' <<<"$werbose" && echo tak || echo nie)"
sprawdz "ufw-docker w /usr/bin (pakiet portu)" tak "$([[ -x /usr/bin/ufw-docker ]] && echo tak || echo nie)"
sprawdz "blok ufw-docker w after.rules" 1 "$(grep -c '^# BEGIN UFW AND DOCKER' /etc/ufw/after.rules || true)"
sprawdz "blok ufw-docker w after6.rules" 1 "$(grep -c '^# BEGIN UFW AND DOCKER' /etc/ufw/after6.rules || true)"
# Kolejność startu ufw i dockera w runit jest dowolna — łańcuch DOCKER-USER ma mieć reguły ufw-docker
# niezależnie od tego, kto wstał pierwszy.
docker_user=$(iptables -S DOCKER-USER 2>/dev/null) || docker_user=
sprawdz "DOCKER-USER → ufw-user-forward" tak \
  "$(grep -qxF -- '-A DOCKER-USER -j ufw-user-forward' <<<"$docker_user" && echo tak || echo nie)"

# --- prawdziwe pakiety ----------------------------------------------------------------------------
NS_PUB=fwtest-pub NS_LAN=fwtest-lan PORT_ZAMK=9999 PORT_DOCK=18080
posprzataj() {
  ip netns del "$NS_PUB" 2>/dev/null || true
  ip netns del "$NS_LAN" 2>/dev/null || true
  ip link del fwt-pub0 2>/dev/null || true
  ip link del fwt-lan0 2>/dev/null || true
  [[ -n ${SLUCH:-} ]] && kill "$SLUCH" 2>/dev/null || true
  if ((DOCKER)); then docker rm -f fwtest >/dev/null 2>&1 || true; fi
}
trap posprzataj EXIT
posprzataj
siec() { # siec <netns> <veth> <adres hosta> <adres netns> <maska>
  ip netns add "$1"
  ip link add "$2" type veth peer name eth0 netns "$1"
  ip addr add "$3/$5" dev "$2"
  ip link set "$2" up
  ip -n "$1" addr add "$4/$5" dev eth0
  ip -n "$1" link set eth0 up
  ip -n "$1" link set lo up
}
siec "$NS_PUB" fwt-pub0 203.0.113.1 203.0.113.2 24
siec "$NS_LAN" fwt-lan0 192.168.77.1 192.168.77.2 24

# słuchacz na porcie, którego firewall nie otwiera — bez firewalla połączenie by przeszło
python3 -c "import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('0.0.0.0', $PORT_ZAMK)); s.listen()
while True: c,_=s.accept(); c.close()" &
SLUCH=$!
if ((DOCKER)); then
  docker run -d --rm --name fwtest -p "$PORT_DOCK:80" busybox httpd -f -p 80 -h / >/dev/null
fi
sleep 1

polacz() { # polacz <netns> <adres> <port> → otwarte | odrzucone | zablokowane
  local rc=0
  ip netns exec "$1" timeout 3 bash -c "exec 3<>/dev/tcp/$2/$3" 2>/dev/null || rc=$?
  case $rc in 0) echo otwarte ;; 124) echo zablokowane ;; *) echo odrzucone ;; esac
}
sprawdz "internet → port $PORT_ZAMK (słuchacz, poza regułami)" zablokowane "$(polacz "$NS_PUB" 203.0.113.1 $PORT_ZAMK)"
sprawdz "LAN → port $PORT_ZAMK (słuchacz, poza regułami)" zablokowane "$(polacz "$NS_LAN" 192.168.77.1 $PORT_ZAMK)"
ls_ocz=odrzucone   # LocalSend: reguła jest, aplikacja zwykle nie słucha (RST = firewall przepuścił)
[[ -n $(ss -Hltn "sport = :53317") ]] && ls_ocz=otwarte
sprawdz "internet → 53317/tcp (LocalSend)" "$ls_ocz" "$(polacz "$NS_PUB" 203.0.113.1 53317)"
ssh_pol=zablokowane
[[ $ssh_ocz == jest ]] && ssh_pol=otwarte
for port in $porty_ssh; do
  sprawdz "internet → $port/tcp (SSH)" "$ssh_pol" "$(polacz "$NS_PUB" 203.0.113.1 "$port")"
done
if ((DOCKER)); then
  # ufw-docker: kontener opublikowany przez -p jest osiągalny z sieci prywatnych, z publicznych nie
  # (chyba że `ufw route allow`) — bez niego Docker omija ufw i port jest otwarty dla wszystkich
  sprawdz "internet → kontener -p $PORT_DOCK" zablokowane "$(polacz "$NS_PUB" 203.0.113.1 $PORT_DOCK)"
  sprawdz "LAN → kontener -p $PORT_DOCK" otwarte "$(polacz "$NS_LAN" 192.168.77.1 $PORT_DOCK)"
fi

echo "ŹLE: $ZLE" >&2
(( ZLE == 0 ))
