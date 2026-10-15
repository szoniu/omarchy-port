#!/usr/bin/env bash
# Polecenie w sesji Hyprlanda użytkownika szoniu w VM (env sesji: runtime dir + instancja).
VM_DIR="${VM_DIR:-$HOME/vm/omarchy-port}"
HOST=vm
[[ ${VM_NR:-1} == 1 ]] || HOST=vm$VM_NR   # druga VM: host vm2 w ssh_config (vm.sh)
ssh -F "$VM_DIR/ssh_config" -l szoniu "$HOST" "export XDG_RUNTIME_DIR=/run/user/1000; export HYPRLAND_INSTANCE_SIGNATURE=\$(command ls -t /run/user/1000/hypr | head -1); export WAYLAND_DISPLAY=wayland-1; . /usr/share/omarchy/default/bash/env-bootstrap; $*"
