# shellcheck shell=bash disable=SC2034

# Szenario B (wie node3/node4): Debian 13, Root laeuft von @rootfs (GRUB: rootflags=subvol=@rootfs),
# Default-Subvolume bleibt Top-Level, fstab zeigt aber schon auf @ (halb migriert),
# @ ist eine veraltete Teilkopie, @home enthaelt die Heimatverzeichnisse.
prep_tools
partition_target
mkdir -p "$T" /mnt/r
mount "${DISK}2" "$T"
btrfs subvolume create "$T/@rootfs"
btrfs subvolume create "$T/@"
btrfs subvolume create "$T/@home"
mount -o subvol=@rootfs "${DISK}2" /mnt/r
copy_system /mnt/r
# @home enthaelt die aktuellen Heimatverzeichnisse (sonst verdeckt der Mount /home/test/.ssh).
rsync -aAXH --numeric-ids /home/ "$T/@home/"
mkdir -p "$T/@/etc"
rsync -a /etc/hostname /etc/os-release "$T/@/etc/"
echo "stale copy from an earlier migration attempt" > "$T/@/STALE"
UUID=$(blkid -s UUID -o value "${DISK}2")
EFI=$(blkid -s UUID -o value "${DISK}1")
cat > /mnt/r/etc/fstab <<FSTAB
UUID=$EFI /boot/efi vfat umask=0077 0 1
UUID=$UUID / btrfs noatime,compress=zstd,space_cache=v2,subvol=@ 0 1
UUID=$UUID /home btrfs noatime,compress=zstd,space_cache=v2,autodefrag,subvol=@home 0 2
FSTAB
install_boot /mnt/r
sync
umount -l /mnt/r
sync
umount -l "$T"
