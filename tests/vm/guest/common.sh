# shellcheck shell=bash disable=SC2034
# Gemeinsame Hilfen fuer die Szenario-Bauskripte (laufen als root in der Builder-VM,
# Zielplatte ist /dev/vdb, die Builder-Platte /dev/vda).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

DISK=/dev/vdb
T=/mnt/target

prep_tools() {
  apt-get update -qq
  apt-get install -y -qq btrfs-progs gdisk parted rsync dosfstools grub-efi-amd64-bin efibootmgr
}

partition_target() {
  sgdisk -Z "$DISK"
  sgdisk -n1:0:+512M -t1:ef00 -n2:0:0 -t2:8300 "$DISK"
  partprobe "$DISK"; udevadm settle
  mkfs.vfat -F32 -n EFI "${DISK}1"
  mkfs.btrfs -f -L system "${DISK}2"
}

# Systemverzeichnis (ohne virtuelle Dateisysteme) von der Builder-Platte kopieren.
copy_system() { # zielverzeichnis
  rsync -aAXHx --numeric-ids \
    --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/run/*' \
    --exclude='/mnt/*' --exclude='/tmp/*' --exclude='/boot/efi/*' --exclude='/swap.img' \
    / "$1"/
  # Ubuntu-Cloud-Images haben eine eigene /boot-Partition, die -x ueberspringt.
  if mountpoint -q /boot; then
    rsync -aAXH --numeric-ids --exclude='/efi/*' /boot/ "$1"/boot/
  fi
  mkdir -p "$1"/{dev,proc,sys,run,mnt,tmp,boot/efi}
  chmod 1777 "$1/tmp"
}

# GRUB und initramfs im Ziel-Root installieren (chroot, ESP gemountet).
install_boot() { # root-mountpoint
  local r=$1
  mount "${DISK}1" "$r/boot/efi"
  for d in dev proc sys run; do mount --rbind "/$d" "$r/$d"; done
  mount --make-rslave "$r/dev" "$r/proc" "$r/sys" "$r/run" 2>/dev/null || true
  chroot "$r" env GRUB_DISABLE_OS_PROBER=true bash -euxc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq btrfs-progs grub-efi-amd64-bin 2>/dev/null || true
    update-initramfs -u -k all
    id=$(. /etc/os-release; echo "$ID")
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$id" --no-nvram
    # Fallback-Loader wie auf den echten Nodes (EFI/BOOT): OVMF hat in der Test-VM keinen NVRAM-Eintrag.
    esp=/boot/efi/EFI
    mkdir -p "$esp/BOOT"
    if [ -f "$esp/$id/shimx64.efi" ]; then
      cp "$esp/$id/shimx64.efi" "$esp/BOOT/BOOTX64.EFI"
      cp "$esp/$id/grubx64.efi" "$esp/BOOT/"
      [ -f "$esp/$id/mmx64.efi" ] && cp "$esp/$id/mmx64.efi" "$esp/BOOT/"
    else
      cp "$esp/$id/grubx64.efi" "$esp/BOOT/BOOTX64.EFI"
    fi
    update-grub
  '
  sync
  for d in run sys proc dev; do umount -R -l "$r/$d" || true; done
  umount "$r/boot/efi"
}
