# shellcheck shell=bash disable=SC2034

# Szenario A (wie node5/node7): Ubuntu 26.04, Btrfs-Root als Top-Level (subvolid=5),
# Swap-Datei /swap.img auf Btrfs, UEFI.
prep_tools
partition_target
mkdir -p "$T"
mount "${DISK}2" "$T"
copy_system "$T"
btrfs filesystem mkswapfile --size 1g "$T/swap.img"
UUID=$(blkid -s UUID -o value "${DISK}2")
EFI=$(blkid -s UUID -o value "${DISK}1")
cat > "$T/etc/fstab" <<FSTAB
/dev/disk/by-uuid/$UUID / btrfs defaults 0 1
/dev/disk/by-uuid/$EFI /boot/efi vfat defaults 0 1
/swap.img none swap sw 0 0
FSTAB
install_boot "$T"
sync
umount -l "$T"
