#!/usr/bin/env bash
# VM do prototypu portu Omarchy (dotfiles#169/#170) — QEMU z Fedory w kontenerze
# podmana (rootless), bo QEMU z AlmaLinux 10 nie ma virtio-gpu-gl (virgl).
#   ./vm.sh live   — boot live ISO Voida (kernel z ISO, konsola też na ttyS0)
#   ./vm.sh disk   — boot zainstalowanego systemu (OVMF)
#   ./vm.sh stop   — twarde zatrzymanie kontenera
# Ekran: VNC 127.0.0.1:5901 (egl-headless + virgl na /dev/dri/renderD128)
# SSH:   ssh -p 2229 -i id_vm root@127.0.0.1   (hostfwd w slirp)
# QMP:   $VM_DIR/qmp.sock (python3 qmp.py …)
# Stan VM (ISO, dysk, OVMF, klucz SSH, logi) leży w $VM_DIR, POZA repo.
# Osobny dysk (np. świeża instalacja obok starej VM): VM_DISK=fresh.qcow2 VM_VARS=OVMF_VARS.fresh.fd ./vm.sh …
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="${VM_DIR:-$HOME/vm/omarchy-port}"
mkdir -p "$VM_DIR"
cd "$VM_DIR"
NAME=vm-void-omarchy
IMG=localhost/qemu-virgl:latest
ISO=void-live-x86_64-20250202-base.iso
VM_DISK="${VM_DISK:-void.qcow2}"
VM_VARS="${VM_VARS:-OVMF_VARS.fd}"
mode="${1:-}"

if [ "$mode" = stop ]; then
  podman rm -f "$NAME" >/dev/null 2>&1 || true
  exit 0
fi
case "$mode" in live|disk) ;; *) echo "użycie: $0 live|disk|stop" >&2; exit 2 ;; esac

podman image exists "$IMG" || podman build -t "$IMG" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
[ -f id_vm ] || ssh-keygen -q -t ed25519 -N "" -C vm-omarchy-port -f id_vm
# ControlMaster: firewall portu (omarchy-port#8) ma na SSH `ufw limit 22/tcp` — 6 nowych połączeń
# w 30 s z jednego adresu to blokada, a ze slirp wszystkie przychodzą z 10.0.2.2. Jedno połączenie na
# użytkownika, testy idą w nim. Starszy ssh_config (bez tych trzech linii) trzeba uzupełnić ręcznie.
[ -f ssh_config ] || cat >ssh_config <<SSHCFG
Host vm
  HostName 127.0.0.1
  Port 2229
  User root
  IdentityFile $VM_DIR/id_vm
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ConnectTimeout 5
  ControlMaster auto
  ControlPath $VM_DIR/cm-%C
  ControlPersist 10m
SSHCFG

[ -f "$VM_DISK" ] || podman run --rm -v "$PWD":/vm:z "$IMG" qemu-img create -f qcow2 "/vm/$VM_DISK" 60G
[ -f "$VM_VARS" ] || podman run --rm -v "$PWD":/vm:z "$IMG" cp /usr/share/edk2/ovmf/OVMF_VARS.fd "/vm/$VM_VARS"
rm -f qmp.sock

args=(
  -name void-omarchy -machine q35,accel=kvm -cpu host -smp 8 -m 8G
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd
  -drive "if=pflash,format=raw,file=/vm/$VM_VARS"
  -drive "file=/vm/$VM_DISK,if=virtio,format=qcow2,discard=unmap"
  -device virtio-vga-gl,xres=1920,yres=1080
  -display egl-headless,rendernode=/dev/dri/renderD128
  -vnc 127.0.0.1:1
  -device virtio-keyboard-pci -device virtio-tablet-pci
  -audiodev none,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2229-:22 -device virtio-net-pci,netdev=n0
  -qmp unix:/vm/qmp.sock,server=on,wait=off
  -serial file:/vm/serial.log
)
if [ "$mode" = live ]; then
  { [ -f "$ISO" ] && [ -f iso-boot/vmlinuz ]; } || { echo "brak $VM_DIR/$ISO albo iso-boot/ (kernel+initrd z ISO) — zob. README" >&2; exit 1; }
  args+=(
    -cdrom "/vm/$ISO"
    -kernel /vm/iso-boot/vmlinuz -initrd /vm/iso-boot/initrd
    -append "root=live:CDLABEL=VOID_LIVE ro init=/sbin/init rd.luks=0 rd.md=0 rd.dm=0 loglevel=4 gpt add_efi_memmap vconsole.unicode=1 vconsole.keymap=us locale.LANG=en_US.UTF-8 rd.live.overlay.overlayfs=1 console=tty0 console=ttyS0,115200"
  )
fi

podman rm -f "$NAME" >/dev/null 2>&1 || true
podman run -d --name "$NAME" --network host \
  --device /dev/kvm --device /dev/dri/renderD128 \
  --security-opt label=disable \
  -v "$PWD":/vm -w /vm "$IMG" qemu-system-x86_64 "${args[@]}" >/dev/null
echo "VM ($mode, $VM_DISK) wystartowała: VNC 127.0.0.1:5901, SSH 127.0.0.1:2229, QMP $PWD/qmp.sock"
