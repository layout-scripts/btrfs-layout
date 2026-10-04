#!/bin/bash
# QEMU/KVM-Testumgebung fuer setup-btrfs.sh (kein Root auf dem Host noetig).
#
#   tests/vm/vm.sh fetch              Cloud-Images laden (Ubuntu 26.04, Debian 13)
#   tests/vm/vm.sh build  <a|b>       Szenario-Platte bauen
#   tests/vm/vm.sh boot   <a|b> [fresh]  Szenario starten (wartet auf SSH); "fresh" = Ausgangszustand
#   tests/vm/vm.sh ssh    <a|b> CMD   Befehl als root in der laufenden VM ausfuehren
#   tests/vm/vm.sh push   <a|b> SRC DST  Datei in die VM kopieren
#   tests/vm/vm.sh reboot <a|b>       VM neu starten und auf SSH warten
#   tests/vm/vm.sh stop   <a|b>       VM sauber herunterfahren
#   tests/vm/vm.sh reset  <a|b>       Szenario-Platte verwerfen
#
# Szenario a: Ubuntu 26.04, Btrfs-Root als Top-Level (subvolid=5), /swap.img  (wie node5/node7)
# Szenario k: wie a, aber mit installiertem, gestartetem MicroK8s (Snap)
# Szenario b: Debian 13, Root in @rootfs, veraltete @-Kopie, fstab zeigt auf @  (wie node3/node4)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${BTRFS_VM_WORK:-$HOME/.cache/btrfs-layout-vm}
PORT=${BTRFS_VM_PORT:-2222}
MEM=${BTRFS_VM_MEM:-2048}
SSH_KEY=$WORK/id_test
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd

mkdir -p "$WORK"

img_for() { case "$1" in a|k) echo "$WORK/ubuntu-resolute.img" ;; b) echo "$WORK/debian-trixie.qcow2" ;; *) echo "scenario must be a or b" >&2; exit 2 ;; esac; }
dir_for() { echo "$WORK/$1"; }

ssh_opts=(-i "$SSH_KEY" -p "$PORT" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)

make_seed() {
  [[ -f $SSH_KEY ]] || ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY"
  [[ -f $WORK/seed.iso ]] && return 0
  local t; t=$(mktemp -d)
  cat > "$t/user-data" <<UD
#cloud-config
users:
  - name: test
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$SSH_KEY.pub")
ssh_pwauth: false
package_update: false
UD
  printf 'instance-id: btrfs-vm-test\nlocal-hostname: btrfs-test\n' > "$t/meta-data"
  genisoimage -quiet -output "$WORK/seed.iso" -volid cidata -joliet -rock "$t/user-data" "$t/meta-data"
  rm -rf "$t"
}

start_qemu() { # dir disk... ; letzte Platte immer mit virtio
  local d=$1; shift
  local args=()
  local disk
  for disk in "$@"; do args+=(-drive "file=$disk,if=virtio,format=qcow2"); done
  cp -f "$OVMF_VARS" "$d/OVMF_VARS.fd"
  qemu-system-x86_64 -enable-kvm -cpu host -m "$MEM" -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$d/OVMF_VARS.fd" \
    "${args[@]}" \
    -drive "file=$WORK/seed.iso,if=virtio,format=raw,readonly=on" \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -display none -serial "file:$d/serial.log" \
    -daemonize -pidfile "$d/qemu.pid"
}

wait_ssh() {
  for _ in $(seq 1 90); do
    if ssh "${ssh_opts[@]}" test@127.0.0.1 true 2>/dev/null; then return 0; fi
    sleep 4
  done
  echo "VM nicht per SSH erreichbar (siehe $1/serial.log)" >&2
  return 1
}

# Wartet auf das Ende von QEMU; haengt der Gast beim Poweroff (kommt bei Debian vor), wird
# QEMU nach 60 s beendet. Die Dateisysteme sind dann bereits sauber ausgehaengt.
wait_exit() {
  local pidfile=$1 n=0
  while [[ -f $pidfile ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; do
    n=$((n + 1))
    if (( n > 30 )); then kill "$(cat "$pidfile")" 2>/dev/null || true; fi
    sleep 2
  done
}

vm_ssh() { ssh "${ssh_opts[@]}" test@127.0.0.1 'sudo -n bash -s' <<< "$*"; }

cmd=${1:-}; sc=${2:-}
case "$cmd" in
  fetch)
    wget -c -O "$WORK/ubuntu-resolute.img" https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img
    wget -c -O "$WORK/debian-trixie.qcow2" https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2
    ;;
  build)
    make_seed
    d=$(dir_for "$sc"); mkdir -p "$d"
    pre_scripts=()
    [[ $sc == k ]] && pre_scripts+=("$HERE/guest/pre-microk8s.sh")
    qemu-img create -q -f qcow2 -b "$(img_for "$sc")" -F qcow2 "$d/builder.qcow2" 10G
    qemu-img create -q -f qcow2 "$d/target.qcow2" 14G
    start_qemu "$d" "$d/builder.qcow2" "$d/target.qcow2"
    wait_ssh "$d"
    ssh "${ssh_opts[@]}" test@127.0.0.1 'sudo tee /root/build-target.sh >/dev/null && sudo bash /root/build-target.sh' \
      < <(cat "$HERE/guest/common.sh" "${pre_scripts[@]}" "$HERE/guest/build-target-${sc/k/a}.sh")
    ssh "${ssh_opts[@]}" test@127.0.0.1 'sudo poweroff' || true
    wait_exit "$d/qemu.pid"
    rm -f "$d/builder.qcow2"
    mv "$d/target.qcow2" "$d/base.qcow2"
    echo "Szenario $sc gebaut: $d/base.qcow2"
    ;;
  boot)
    make_seed
    d=$(dir_for "$sc")
    [[ -f $d/base.qcow2 ]] || { echo "erst 'build $sc'" >&2; exit 1; }
    # Jede Sitzung laeuft auf einem Overlay; "boot <sc> fresh" setzt auf den Ausgangszustand zurueck.
    if [[ ${3:-} == fresh || ! -f $d/run.qcow2 ]]; then
      rm -f "$d/run.qcow2"
      qemu-img create -q -f qcow2 -b "$d/base.qcow2" -F qcow2 "$d/run.qcow2"
    fi
    start_qemu "$d" "$d/run.qcow2"
    wait_ssh "$d"
    echo "VM $sc laeuft (ssh -p $PORT -i $SSH_KEY test@127.0.0.1)"
    ;;
  ssh)
    shift 2; vm_ssh "$@"
    ;;
  reboot)
    ssh "${ssh_opts[@]}" test@127.0.0.1 'sudo systemctl reboot' 2>/dev/null || true
    # warten, bis die alte Sitzung weg ist, dann auf die neue warten
    for _ in $(seq 1 30); do ssh "${ssh_opts[@]}" test@127.0.0.1 true 2>/dev/null || break; sleep 2; done
    wait_ssh "$(dir_for "$sc")"
    ;;
  push)
    scp -i "$SSH_KEY" -P "$PORT" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o BatchMode=yes "$3" "test@127.0.0.1:$4"
    ;;
  stop)
    d=$(dir_for "$sc")
    ssh "${ssh_opts[@]}" test@127.0.0.1 'sudo poweroff' 2>/dev/null || true
    wait_exit "$d/qemu.pid"
    ;;
  inspect)
    # Frisches Cloud-Image als Betrachter, Szenario-Platte (Overlay) als zweite Platte /dev/vdb.
    make_seed
    d=$(dir_for "$sc")
    rm -f "$d/inspector.qcow2" "$d/inspect-disk.qcow2"
    qemu-img create -q -f qcow2 -b "$(img_for "$sc")" -F qcow2 "$d/inspector.qcow2" 10G
    # "inspect <sc> run" zeigt den Zustand nach dem letzten Testlauf statt des Ausgangszustands.
    src=$d/base.qcow2; [[ ${3:-} == run ]] && src=$d/run.qcow2
    qemu-img create -q -f qcow2 -b "$src" -F qcow2 "$d/inspect-disk.qcow2"
    start_qemu "$d" "$d/inspector.qcow2" "$d/inspect-disk.qcow2"
    wait_ssh "$d"
    echo "Inspektor laeuft: Szenario-Platte = /dev/vdb (ssh -p $PORT -i $SSH_KEY test@127.0.0.1); 'stop $sc' beendet ihn"
    ;;
  reset)
    d=$(dir_for "$sc"); rm -rf "$d"
    ;;
  *)
    sed -n '2,13p' "$0"; exit 2
    ;;
esac
