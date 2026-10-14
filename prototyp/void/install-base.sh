#!/usr/bin/env bash
# Bazowy Void (glibc, runit) na /dev/vda — odpalany w live ISO przez SSH.
# Tylko VM prototypu: sudo bez hasła dla wheel.
# Hasło jako GOTOWY hash z hosta, np.:
#   ssh vm "PASS_HASH='$(openssl passwd -6 'hasło')' bash -s" < install-base.sh
# Zwykłe `chpasswd` (jawne hasło) na Voidzie to no-op: /etc/pam.d/chpasswd ma
# `password required pam_permit.so` — rc=0, a w /etc/shadow zostaje `!`.
# `chpasswd -e` z hashem omija PAM i działa (jak w instalatorze szoniu/void).
set -euo pipefail
: "${PASS_HASH:?ustaw PASS_HASH (openssl passwd -6 …)}"
REPO=https://repo-default.voidlinux.org/current
DISK=/dev/vda
USERNAME=szoniu

echo "### xbps w live"
xbps-install -Syu xbps

echo "### partycje"
wipefs -af "$DISK"
sfdisk "$DISK" <<'EOF'
label: gpt
,1G,U
,,L
EOF
mkfs.vfat -F32 -n EFI "${DISK}1"
mkfs.ext4 -F -L void "${DISK}2"
mount "${DISK}2" /mnt
mkdir -p /mnt/boot/efi
mount "${DISK}1" /mnt/boot/efi

echo "### base-system"
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
XBPS_ARCH=x86_64 xbps-install -Sy -r /mnt -R "$REPO" \
  base-system grub-x86_64-efi openssh dhcpcd sudo git curl wget bash-completion

echo "### chroot"
for d in dev proc sys; do mount --rbind "/$d" "/mnt/$d"; mount --make-rslave "/mnt/$d"; done
cp /etc/resolv.conf /mnt/etc/resolv.conf
ROOT_UUID=$(blkid -s UUID -o value "${DISK}2")
EFI_UUID=$(blkid -s UUID -o value "${DISK}1")
PUBKEY=$(cat /root/.ssh/authorized_keys)

chroot /mnt /bin/bash -s <<CHROOT
set -euo pipefail
echo void-omarchy > /etc/hostname
cat >> /etc/rc.conf <<'EOF'
TIMEZONE="Europe/Warsaw"
KEYMAP="pl"
EOF
ln -sf /usr/share/zoneinfo/Europe/Warsaw /etc/localtime
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/; s/^#pl_PL.UTF-8/pl_PL.UTF-8/' /etc/default/libc-locales
echo 'LANG=pl_PL.UTF-8' > /etc/locale.conf
xbps-reconfigure -f glibc-locales
cat > /etc/fstab <<EOF
UUID=$ROOT_UUID / ext4 defaults 0 1
UUID=$EFI_UUID /boot/efi vfat defaults 0 2
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF
echo 'root:$PASS_HASH' | chpasswd -e
useradd -m -G wheel,audio,video,input,users -s /bin/bash $USERNAME
echo '$USERNAME:$PASS_HASH' | chpasswd -e
echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
for h in /root /home/$USERNAME; do
  mkdir -p \$h/.ssh; echo '$PUBKEY' > \$h/.ssh/authorized_keys; chmod 700 \$h/.ssh; chmod 600 \$h/.ssh/authorized_keys
done
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
ln -sf /etc/sv/dhcpcd /etc/runit/runsvdir/default/
ln -sf /etc/sv/sshd /etc/runit/runsvdir/default/
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 console=tty0 console=ttyS0,115200"/' /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=void --removable
xbps-reconfigure -fa
CHROOT

echo "### koniec"
umount -R /mnt
echo INSTALL-BASE-OK
