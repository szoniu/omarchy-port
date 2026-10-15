#!/usr/bin/env bash
# Bazowy Gentoo (glibc, amd64, systemd albo OpenRC) na /dev/vda — odpalany w live ISO Voida przez SSH
# (rozpakowanie stage3 i chroot nie zależą od systemu live). Odpowiednik prototyp/void/install-base.sh:
# instalator szoniu/gentoo nie umie dziś pulpitu Omarchy (gentoo#22) ani binhosta, więc w VM
# kompilowałby wszystko. Tu pakiety bazy idą z oficjalnego binhosta Gentoo (getbinpkg, podpisane).
# Tylko VM prototypu: sudo bez hasła dla wheel.
#   ssh vm "PASS_HASH='$(openssl passwd -6 'hasło')' INIT=systemd bash -s" < install-base.sh
# Stage3 (desktop-<init>, profil 23.0/desktop[/systemd]) sprawdzany podpisem Gentoo Release Engineering
# (Automated Weekly Release Key) o przypiętym odcisku; drzewo portage z emerge-webrsync (portage sam
# sprawdza podpis snapshotu).
set -euo pipefail
: "${PASS_HASH:?ustaw PASS_HASH (openssl passwd -6 …)}"
INIT=${INIT:-systemd}
case $INIT in systemd|openrc) ;; *) echo "INIT=systemd albo openrc (jest: $INIT)" >&2; exit 2 ;; esac
AUTOBUILDS=https://distfiles.gentoo.org/releases/amd64/autobuilds
RELENG_FPR=13EBBDBEDE7A12775DFDB1BABB572E0E2D182910
DISK=/dev/vda
USERNAME=szoniu
NAZWA_HOSTA=gentoo-omarchy

echo "### narzędzia w live (Void)"
xbps-install -Syu xbps
xbps-install -y curl xz gnupg

echo "### stage3-amd64-desktop-$INIT"
WORK=$(mktemp -d)
export GNUPGHOME=$WORK/gnupg
install -d -m 700 "$GNUPGHOME"
gpg --quiet --keyserver hkps://keys.gentoo.org --recv-keys "$RELENG_FPR"
plik=$(curl -fsS "$AUTOBUILDS/latest-stage3-amd64-desktop-$INIT.txt" | awk '/^[0-9]+T[0-9]+Z\/stage3-/ { print $1; exit }')
[[ -n $plik ]] || { echo "brak stage3 w latest-stage3-amd64-desktop-$INIT.txt" >&2; exit 1; }
curl -fsS --retry 3 -o "$WORK/stage3.tar.xz" "$AUTOBUILDS/$plik"
curl -fsS --retry 3 -o "$WORK/stage3.tar.xz.asc" "$AUTOBUILDS/$plik.asc"
# VALIDSIG: ostatnie pole to odcisk klucza głównego (podpisuje podklucz)
gpg --status-fd 1 --verify "$WORK/stage3.tar.xz.asc" "$WORK/stage3.tar.xz" 2>/dev/null |
  awk -v f="$RELENG_FPR" '$2 == "VALIDSIG" && $NF == f { ok = 1 } END { exit !ok }' ||
  { echo "stage3: podpis nie jest kluczem $RELENG_FPR" >&2; exit 1; }
echo "stage3: $plik — podpis Gentoo Release Engineering OK"

echo "### partycje"
wipefs -af "$DISK"
sfdisk "$DISK" <<'EOF'
label: gpt
,1G,U
,,L
EOF
mkfs.vfat -F32 -n EFI "${DISK}1"
mkfs.ext4 -F -L gentoo "${DISK}2"
mount "${DISK}2" /mnt
tar xpf "$WORK/stage3.tar.xz" --xattrs-include='*.*' --numeric-owner -C /mnt
mkdir -p /mnt/efi
mount "${DISK}1" /mnt/efi
rm -rf "$WORK"

echo "### chroot"
mount --types proc /proc /mnt/proc
for d in sys dev; do mount --rbind "/$d" "/mnt/$d"; mount --make-rslave "/mnt/$d"; done
mount --bind /run /mnt/run
mount --make-slave /mnt/run
cp --dereference /etc/resolv.conf /mnt/etc/resolv.conf
ROOT_UUID=$(blkid -s UUID -o value "${DISK}2")
EFI_UUID=$(blkid -s UUID -o value "${DISK}1")
PUBKEY=$(cat /root/.ssh/authorized_keys)
NPROC=$(nproc)

chroot /mnt /bin/bash -s <<CHROOT
set -euo pipefail
set +u; source /etc/profile; set -u
emerge-webrsync -q
# binhost: stage3 ma go w binrepos.conf (od 2024); paczki podpisane, klucze zakłada getuto przy pierwszym użyciu
if [[ -z \$(ls -A /etc/portage/binrepos.conf 2>/dev/null) ]]; then
  mkdir -p /etc/portage/binrepos.conf
  printf '[gentoobinhost]\npriority = 1\nsync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64\n' \
    > /etc/portage/binrepos.conf/gentoobinhost.conf
fi
cat /etc/portage/binrepos.conf/*.conf
cat >> /etc/portage/make.conf <<'EOF'
FEATURES="\${FEATURES} getbinpkg binpkg-request-signature"
MAKEOPTS="-j$NPROC -l$NPROC"
EMERGE_DEFAULT_OPTS="--getbinpkg --with-bdeps=y"
EOF
mkdir -p /etc/portage/package.use /etc/portage/package.license
echo 'sys-kernel/installkernel dracut grub' > /etc/portage/package.use/installkernel
echo 'sys-kernel/linux-firmware linux-fw-redistributable' > /etc/portage/package.license/linux-firmware
eselect profile show
echo $NAZWA_HOSTA > /etc/hostname
ln -sf /usr/share/zoneinfo/Europe/Warsaw /etc/localtime
printf 'en_US.UTF-8 UTF-8\npl_PL.UTF-8 UTF-8\n' > /etc/locale.gen
locale-gen
echo 'LANG=pl_PL.UTF-8' > /etc/locale.conf
echo 'KEYMAP=pl' > /etc/vconsole.conf
emerge --ask=n --noreplace sys-kernel/installkernel sys-kernel/gentoo-kernel-bin sys-boot/grub \
  net-misc/dhcpcd app-admin/sudo dev-vcs/git net-misc/curl
cat > /etc/fstab <<EOF
UUID=$ROOT_UUID / ext4 defaults,noatime 0 1
UUID=$EFI_UUID /efi vfat defaults 0 2
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF
echo 'root:$PASS_HASH' | chpasswd -e
useradd -m -G wheel,audio,video,input,users -s /bin/bash $USERNAME
echo '$USERNAME:$PASS_HASH' | chpasswd -e
install -d -m 750 /etc/sudoers.d   # sudoers go dołącza (@includedir), ale pakiet go nie zakłada
echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
for h in /root /home/$USERNAME; do
  mkdir -p \$h/.ssh; echo '$PUBKEY' > \$h/.ssh/authorized_keys; chmod 700 \$h/.ssh; chmod 600 \$h/.ssh/authorized_keys
done
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
if [[ $INIT == systemd ]]; then
  systemd-machine-id-setup
  systemctl enable sshd.service dhcpcd.service
else
  rc-update add sshd default
  rc-update add dhcpcd default
fi
sed -i 's/^#\?GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200"/' /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=gentoo --removable
grub-mkconfig -o /boot/grub/grub.cfg
ls /boot
CHROOT

echo "### koniec"
umount -R /mnt
echo INSTALL-BASE-OK
