#!/usr/bin/env bash
# Polecenie w sesji Hyprlanda użytkownika szoniu w VM (env sesji: runtime dir + instancja).
VM_DIR="${VM_DIR:-$HOME/vm/omarchy-port}"
ssh -F "$VM_DIR/ssh_config" -l szoniu vm "export XDG_RUNTIME_DIR=/run/user/1000; export HYPRLAND_INSTANCE_SIGNATURE=\$(command ls -t /run/user/1000/hypr | head -1); export WAYLAND_DISPLAY=wayland-1; . /usr/share/omarchy/default/bash/env-bootstrap; $*"
