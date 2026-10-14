#!/usr/bin/env bash
# Zrzut ekranu VM przez VNC (screendump QMP nie działa przy wyjściu GL/virgl).
# użycie: ./shot.sh shots/nazwa.png   (ścieżka względem $VM_DIR)
set -euo pipefail
VM_DIR="${VM_DIR:-$HOME/vm/omarchy-port}"
mkdir -p "$VM_DIR/$(dirname "$1")"
cd "$VM_DIR"
podman run --rm --network host --security-opt label=disable -v "$PWD":/vm localhost/qemu-virgl:latest \
  gvnccapture --quiet 127.0.0.1:1 "/vm/$1"
