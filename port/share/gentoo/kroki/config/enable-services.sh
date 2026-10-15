# omarchy-port (Gentoo): config/enable-services.sh z Omarchy v4.0.4 bez linux-modules-cleanup.service —
# ta jednostka pochodzi z archowego kernel-modules-hook (na Gentoo brak), a upstream pod set -e stawał na niej
# i nie włączał niczego dalej (docker.socket, resolved, NetworkManager, sddm, oomd). Reszta bez zmian.
# Enable services only. Installs are followed by reboot, so don't start/reload
# daemons mid-install. UFW and hardware-gated services stay in their own scripts.
systemctl enable cups.service
systemctl enable avahi-daemon.service
systemctl enable docker.socket
systemctl enable systemd-resolved.service
systemctl enable NetworkManager.service
# Don't let network-online.target hold up graphical.target waiting for
# DHCP/Wi-Fi association. Nothing in the session needs to block on the network.
# Mirrors the systemd-networkd-wait-online mask in install/hardware/network.sh.
systemctl mask NetworkManager-wait-online.service
systemctl enable power-profiles-daemon.service
systemctl enable sddm.service
# Kill one runaway app scope instead of letting reclaim thrashing take the
# whole session down. [Install] pulls in systemd-oomd.socket via Also=, which
# is what the user manager reports app.slice candidacy over.
systemctl enable systemd-oomd.service
