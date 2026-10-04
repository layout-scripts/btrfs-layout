#!/bin/bash
# Kompletter Testlauf von setup-btrfs.sh in einem VM-Szenario (drei Reboots).
#   tests/vm/run-scenario.sh <a|b>
# a: Erstmigration (Ubuntu, Top-Level-Root, Swap-Datei)   b: --finish-migration (Debian, @rootfs)
# a-legacy: wie a, aber zuerst mit der ALTEN Skriptversion (node6-Zustand), danach --fix-boot
set -uo pipefail

scenario=${1:?usage: run-scenario.sh <a|b|a-legacy|k>}
legacy=0
mk=0
sc=$scenario
if [[ $scenario == a-legacy ]]; then sc=a; legacy=1; fi
if [[ $scenario == k ]]; then mk=1; export BTRFS_VM_MEM=${BTRFS_VM_MEM:-3072}; fi
LEGACY_REF=38ec6bd   # letzter Commit vor --finish-migration/--fix-boot, setzte @ als Default-Subvolume
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
VM="$HERE/vm.sh"
SUBVOLS=@root,@home,@log,@cache,@tmp_var,@tmp,@microk8s,@k8s-storage
FAILED=0

ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; FAILED=1; }
vm()  { "$VM" ssh "$sc" "$@"; }

expect_match() { # beschreibung regex text
  if [[ "$3" =~ $2 ]]; then ok "$1"; else bad "$1 (Ausgabe: $(echo "$3" | head -3 | tr '\n' ' '))"; fi
}
expect_nomatch() {
  if [[ "$3" =~ $2 ]]; then bad "$1 (Ausgabe: $(echo "$3" | head -3 | tr '\n' ' '))"; else ok "$1"; fi
}

verify_migrated() { # label
  echo "== Pruefung $1"
  expect_match   "/ laeuft von @"                     '\[/@\]'        "$(vm 'findmnt -no SOURCE /')"
  expect_nomatch "cmdline ohne @rootfs"               '@rootfs'       "$(vm 'cat /proc/cmdline')"
  if [[ $legacy -eq 0 ]]; then
    expect_match "@microk8s gemountet"                '\[/@microk8s\]' "$(vm 'findmnt -no SOURCE /var/snap/microk8s/common')"
    expect_match "@k8s-storage gemountet"             '\[/@k8s-storage\]' "$(vm 'findmnt -no SOURCE /var/lib/k8s-storage')"
  fi
  expect_nomatch "findmnt --verify ohne Fehler"       '\[E\]'         "$(vm 'findmnt --verify 2>&1')"
  expect_match   "GRUB liest /@/boot (nicht den Top-Level)" 'BOOT_IMAGE=(\([^)]*\))?/@/boot/' "$(vm 'cat /proc/cmdline')"
  expect_match   "rootflags=subvol=@ gesetzt"         'rootflags=subvol=@( |$)' "$(vm 'cat /proc/cmdline')"
  expect_match   "Default-Subvolume bleibt Top-Level" 'FS_TREE'       "$(vm 'btrfs subvolume get-default /')"
  if [[ ( $sc == a || $sc == k ) && $legacy -eq 0 ]]; then
    expect_match "Swap-Datei aktiv unter /swap"       '/swap/swapfile' "$(vm 'swapon --show --noheadings')"
  fi
  if [[ $mk -eq 1 ]]; then
    expect_match "MicroK8s laeuft"                    'microk8s is running' "$(vm 'microk8s status --wait-ready --timeout 400 2>&1 | head -3')"
    expect_match "Kubernetes-Node ist Ready"          ' Ready ' "$(vm 'microk8s kubectl get nodes --no-headers 2>&1')"
    expect_match "MicroK8s-Daten liegen in @microk8s" '\[/@microk8s\]' "$(vm 'findmnt -no SOURCE /var/snap/microk8s/common')"
  fi
}

echo "== Szenario $scenario: Start im Ausgangszustand"
"$VM" boot "$sc" fresh || exit 1
vm 'findmnt -no SOURCE,OPTIONS /; cat /proc/cmdline | tr " " "\n" | grep -E "root|subvol" ; swapon --show --noheadings; btrfs subvolume list / ' | sed 's/^/    /'

"$VM" push "$sc" "$REPO/setup-btrfs.sh" /tmp/setup-btrfs.sh
vm 'install -m 755 /tmp/setup-btrfs.sh /root/setup-btrfs.sh'

if [[ $legacy -eq 1 ]]; then
  echo "== ALTE Skriptversion ($LEGACY_REF) ausfuehren (reproduziert den node6-Zustand)"
  git -C "$REPO" show "$LEGACY_REF:setup-btrfs.sh" > "$HERE/.legacy-setup-btrfs.sh"
  "$VM" push "$sc" "$HERE/.legacy-setup-btrfs.sh" /tmp/legacy-setup-btrfs.sh
  out=$(vm "bash /tmp/legacy-setup-btrfs.sh 2>&1; echo EXIT=\$?")
  echo "$out" | tail -6 | sed 's/^/    /'
  expect_match "Altes Skript endet mit Exit 0" 'EXIT=0$' "$out"
  echo "== Reboot (alter Stand)"
  "$VM" reboot "$sc" || { bad "VM kommt nach dem Reboot der alten Version nicht hoch"; exit 1; }
  echo "    cmdline: $(vm 'cat /proc/cmdline')"
  echo "    default: $(vm 'btrfs subvolume get-default /')"
  expect_match   "Altzustand: GRUB liest /boot im Top-Level" 'BOOT_IMAGE=(\([^)]*\))?/boot/' "$(vm 'cat /proc/cmdline')"
  expect_nomatch "Altzustand: kein rootflags"           'rootflags=' "$(vm 'cat /proc/cmdline')"
  expect_match   "Altzustand: Default-Subvolume ist @"  'path @$' "$(vm 'btrfs subvolume get-default /')"
  echo "== --fix-boot"
  out=$(vm "/root/setup-btrfs.sh --fix-boot --yes 2>&1; echo EXIT=\$?")
  echo "$out" | tail -12 | sed 's/^/    /'
  expect_match "--fix-boot endet mit Exit 0" 'EXIT=0$' "$out"
  echo "== Reboot 1"
  "$VM" reboot "$sc" || { bad "VM kommt nach --fix-boot nicht hoch"; exit 1; }
  verify_migrated "nach --fix-boot"
  echo "== --cleanup-old-root"
  out=$(vm "/root/setup-btrfs.sh --cleanup-old-root --yes 2>&1; echo EXIT=\$?")
  echo "$out" | tail -6 | sed 's/^/    /'
  expect_match "Aufraeumen endet mit Exit 0" 'EXIT=0$' "$out"
  echo "== Reboot 2"
  "$VM" reboot "$sc" || { bad "VM kommt nach dem Aufraeumen nicht hoch"; exit 1; }
  verify_migrated "nach dem Aufraeumen"
  "$VM" stop "$sc"
  if [[ $FAILED -eq 0 ]]; then echo "OK: Szenario $scenario bestanden."; else echo "FEHLGESCHLAGEN: Szenario $scenario."; exit 1; fi
  exit 0
fi

echo "== setup-btrfs.sh ausfuehren"
if [[ $sc == a || $sc == k ]]; then args="--yes --subvols $SUBVOLS"; else args="--finish-migration --yes --subvols $SUBVOLS"; fi
out=$(vm "/root/setup-btrfs.sh $args 2>&1; echo EXIT=\$?")
echo "$out" | tail -25 | sed 's/^/    /'
expect_match "Skript endet mit Exit 0" 'EXIT=0$' "$out"

echo "== Reboot 1"
"$VM" reboot "$sc" || { bad "VM kommt nach Reboot 1 nicht hoch"; exit 1; }
verify_migrated "nach Reboot 1"

echo "== update-grub im neuen System (simuliert Kernel-Update)"
vm 'update-grub 2>&1 | tail -3' | sed 's/^/    /'
expect_nomatch "grub.cfg verweist nicht auf @rootfs" '@rootfs' "$(vm 'grep -c "@rootfs" /boot/grub/grub.cfg || true' | grep -v '^0$' || true)"
echo "== Reboot 2"
"$VM" reboot "$sc" || { bad "VM kommt nach Reboot 2 nicht hoch"; exit 1; }
verify_migrated "nach Reboot 2"

echo "== --cleanup-old-root"
out=$(vm "/root/setup-btrfs.sh --cleanup-old-root --yes 2>&1; echo EXIT=\$?")
echo "$out" | tail -15 | sed 's/^/    /'
expect_match "Aufraeumen endet mit Exit 0" 'EXIT=0$' "$out"
echo "== Reboot 3"
"$VM" reboot "$sc" || { bad "VM kommt nach Reboot 3 nicht hoch"; exit 1; }
verify_migrated "nach Reboot 3 (aufgeraeumt)"
vm 'mkdir -p /mnt/t && mount -o subvolid=5 $(findmnt -no SOURCE / | sed "s/\[.*//") /mnt/t && ls /mnt/t; umount /mnt/t' | sed 's/^/    top-level: /'

"$VM" stop "$sc"
if [[ $FAILED -eq 0 ]]; then echo "OK: Szenario $scenario bestanden."; else echo "FEHLGESCHLAGEN: Szenario $scenario."; exit 1; fi
