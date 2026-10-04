#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Verwendung: setup-btrfs.sh [Optionen]

  (ohne Option)          Erstmigration (Root nach @) oder, wenn / schon von @ läuft,
                         inkrementelles Ergänzen fehlender Subvolumes.
  --finish-migration     Halb migrierte Systeme abschließen: / läuft noch von einem anderen
                         Subvolume (z. B. @rootfs), @ wird neu befüllt, GRUB im neuen Root
                         neu erzeugt. Danach Reboot nötig.
  --cleanup-old-root     Nach erfolgreichem Reboot von @: Altdaten des alten Roots entfernen
                         (@rootfs bzw. die Root-Dateien im Top-Level). Löscht Daten.
  --fix-boot             Läuft / von @ und bootet GRUB trotzdem eine veraltete /boot-Kopie im
                         Top-Level (Kernel wird nie aktualisiert)? Schreibt GRUB neu und setzt das
                         Default-Subvolume auf den Top-Level zurück. Danach Reboot.
  --subvols LISTE        Kommagetrennte Subvolume-Namen (z. B. @root,@home,@microk8s) statt
                         Auswahldialog bzw. Standardauswahl.
  --yes, -y              Rückfrage "Backup vorhanden?" automatisch bejahen.
  -h, --help             Diese Hilfe.
USAGE
}

# Aus "/dev/vda2[/@rootfs]" den Subvolume-Pfad ("/@rootfs") ermitteln; leer, wenn Top-Level.
root_subvol_of() {
  local src="$1"
  [[ "$src" == *"["* ]] || { echo ""; return 0; }
  src="${src#*[}"
  echo "${src%]}"
}

# detect_mode ROOT_SRC FINISH(0|1) -> initial | incremental | finish | done
detect_mode() {
  local sub
  sub=$(root_subvol_of "$1")
  if [[ -z "$sub" ]]; then
    echo initial
  elif [[ "$2" == 1 ]]; then
    if [[ "$sub" == "/@" ]]; then echo "done"; else echo "finish"; fi
  else
    echo incremental
  fi
}

# Zum Testen der Funktionen oben per "source" ohne Nebenwirkungen laden.
if [[ "${SETUP_BTRFS_SOURCE_ONLY:-}" == 1 ]]; then
  return 0 2>/dev/null || exit 0
fi

MODE_FINISH=0
MODE_CLEANUP=0
MODE_FIXBOOT=0
ASSUME_YES=0
SUBVOLS_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --finish-migration) MODE_FINISH=1 ;;
    --cleanup-old-root) MODE_CLEANUP=1 ;;
    --fix-boot) MODE_FIXBOOT=1 ;;
    --subvols) SUBVOLS_ARG="${2:?--subvols braucht eine Liste}"; shift ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if (( MODE_FINISH + MODE_CLEANUP + MODE_FIXBOOT > 1 )); then
  echo "--finish-migration, --cleanup-old-root und --fix-boot schließen sich gegenseitig aus." >&2
  exit 2
fi

echo ">>> Btrfs-Setup: Root auf @ + alle Subvolumes/Mounts (final)"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen." >&2
  exit 1
fi

# --- Abhängigkeiten sicherstellen (Debian/apt) ---
need_pkg() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo ">>> Installiere benötigtes Paket: $pkg"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  else
    echo ">>> Abhängigkeit $pkg ($cmd) ist bereits vorhanden."
  fi
}

need_pkg rsync rsync
need_pkg btrfs btrfs-progs

# --- Root-Quelle ermitteln, z.B. /dev/vda2[/@rootfs] ---
ROOT_SRC=$(findmnt -no SOURCE / || true)
if [[ -z "$ROOT_SRC" ]]; then
  echo "Konnte Root-Quelle nicht ermitteln." >&2
  exit 1
fi

ROOT_DEV=${ROOT_SRC%%[*}

FSTYPE=$(findmnt -no FSTYPE / || true)
if [[ "$FSTYPE" != "btrfs" ]]; then
  echo "/ ist kein Btrfs-Dateisystem (FSTYPE=$FSTYPE). Abbruch." >&2
  exit 1
fi

UUID=$(blkid -s UUID -o value "$ROOT_DEV" || true)
if [[ -z "$UUID" ]]; then
  echo "Konnte UUID von $ROOT_DEV nicht ermitteln. Abbruch." >&2
  exit 1
fi

# --- Modus erkennen: erstmaliger Umstieg oder nachtraegliches Ergaenzen? ---
# Wenn / schon von einem benannten Subvolume laeuft, wurde dieses Skript (oder
# eine gleichwertige Migration) bereits erfolgreich durchgefuehrt. Root, GRUB
# und das Default-Subvolume bleiben dann unangetastet; es werden nur noch
# fehlende Subvolumes fuer noch nicht separat gemountete Pfade ergaenzt - ohne
# Neustart, da kein Root-Wechsel mehr noetig ist.
# --- Altdaten nach erfolgreichem Wechsel auf @ entfernen (--cleanup-old-root) ---
cleanup_old_root() {
  local mnt=/mnt/btrfs-root x name size confirm
  local -a subs=() cands=() nested=()
  local old_root_names=(bin boot dev etc home lib lib32 lib64 libx32 lost+found media mnt opt proc root run
                        sbin srv sys tmp usr var snap swap.img bin.usr-is-merged lib.usr-is-merged sbin.usr-is-merged)

  if [[ "$(root_subvol_of "$ROOT_SRC")" != "/@" ]]; then
    echo "FEHLER: / läuft nicht von @ (${ROOT_SRC}). Aufräumen abgelehnt, solange der alte Root noch gebraucht wird." >&2
    exit 1
  fi
  if mount | grep -q " on $mnt "; then
    echo "$mnt ist bereits gemountet, bitte zuerst aushängen." >&2
    exit 1
  fi
  mkdir -p "$mnt"
  mount -o subvolid=5 "$ROOT_DEV" "$mnt"
  trap 'umount "$mnt" 2>/dev/null || true' RETURN

  if [[ ! -d "$mnt/@/etc" || ! -d "$mnt/@/usr" ]]; then
    echo "FEHLER: @ enthält kein vollständiges System (etc/usr fehlen). Abbruch." >&2
    return 1
  fi

  mapfile -t subs < <(btrfs subvolume list "$mnt" | awk '{print $NF}')
  is_subvol() { local y; for y in "${subs[@]}"; do [[ "$y" == "$1" ]] && return 0; done; return 1; }

  is_subvol "@rootfs" && cands+=("@rootfs")
  for name in "${old_root_names[@]}"; do
    [[ -e "$mnt/$name" || -L "$mnt/$name" ]] || continue
    is_subvol "$name" && continue
    cands+=("$name")
  done

  if [[ ${#cands[@]} -eq 0 ]]; then
    echo ">>> Keine Altdaten des alten Roots gefunden - nichts zu tun."
    return 0
  fi

  echo ">>> Folgende Altdaten im Top-Level werden GELÖSCHT (@, @home, timeshift-btrfs usw. bleiben):"
  for name in "${cands[@]}"; do
    size=$(du -shx "$mnt/$name" 2>/dev/null | awk '{print $1}')
    echo "    $name  (${size:-?})"
  done
  if [[ $ASSUME_YES -eq 1 ]]; then
    echo ">>> --yes angegeben - Bestätigung übersprungen."
  elif [[ -t 0 ]]; then
    read -r -p "Wirklich löschen? Zum Fortfahren exakt 'ja' eingeben: " confirm
    [[ "$confirm" == "ja" ]] || { echo "Abgebrochen." >&2; return 1; }
  else
    echo "FEHLER: Kein Terminal und kein --yes - Löschen abgelehnt." >&2
    return 1
  fi

  for name in "${cands[@]}"; do
    # verschachtelte Subvolumes (z. B. Docker-btrfs-Driver) zuerst, tiefste zuerst
    mapfile -t nested < <(printf '%s\n' "${subs[@]}" | grep -E "^${name//./\\.}/" | sort -r || true)
    for x in "${nested[@]}"; do
      [[ -n "$x" ]] || continue
      echo ">>> Lösche Subvolume $x"
      btrfs subvolume delete "$mnt/$x" >/dev/null
    done
    if is_subvol "$name"; then
      echo ">>> Lösche Subvolume $name"
      btrfs subvolume delete "$mnt/$name" >/dev/null
    else
      echo ">>> Lösche $name"
      rm -rf --one-file-system "${mnt:?}/$name"
    fi
  done
  echo ">>> Aufräumen abgeschlossen."
  df -h / | tail -1
}

# --- Bootkonfiguration (GRUB) -------------------------------------------------------------
# GRUB loest Pfade auf Btrfs relativ zum TOP-LEVEL (subvolid=5) auf, NICHT relativ zum mit
# "btrfs subvolume set-default" gesetzten Default-Subvolume (im QEMU-Test geprueft: in der
# GRUB-Shell zeigt "ls (hd0,gpt2)/" @, @home, ...). Daraus folgt:
#   - Das Default-Subvolume muss der Top-Level bleiben (ID 5). Nur dann erzeugen
#     grub-mkconfig und grub-install Pfade der Form /@/boot/... und "rootflags=subvol=@".
#     Aeltere Versionen dieses Skripts setzten @ als Default; GRUB las danach weiter die
#     veraltete /boot-Kopie im Top-Level und startete neue Kernel nie (node6: Kernel 7.0.0-27
#     trotz installiertem 7.0.0-34).
#   - GRUB selbst (Image/grub.cfg auf der ESP bzw. core.img im MBR-Gap) muss per
#     grub-install neu geschrieben werden, damit der Praefix /@/boot/grub lautet.
#   - grub.cfg muss im neuen Root (@) erzeugt werden.
BOOT_ROOT=""          # leer = laufendes System, sonst chroot-Verzeichnis
DEFAULT_CHANGED=0
OLD_DEFAULT_ID=""

boot_run() {
  if [[ -n "$BOOT_ROOT" ]]; then chroot "$BOOT_ROOT" "$@"; else "$@"; fi
}

ensure_toplevel_default() {
  OLD_DEFAULT_ID=$(btrfs subvolume get-default "$MNT" 2>/dev/null | awk '{print $2}')
  if [[ -n "$OLD_DEFAULT_ID" && "$OLD_DEFAULT_ID" != "5" ]]; then
    echo ">>> Default-Subvolume ist ID ${OLD_DEFAULT_ID}, nicht der Top-Level (5). Wird zurückgesetzt, weil GRUB"
    echo ">>> Pfade relativ zum Top-Level auflöst (siehe Kommentar im Skript)."
    btrfs subvolume set-default 5 "$MNT"
    DEFAULT_CHANGED=1
  fi
}

restore_default_subvolume() {
  if [[ $DEFAULT_CHANGED -eq 1 && -n "$OLD_DEFAULT_ID" ]]; then
    echo ">>> Setze Default-Subvolume zurück auf ID $OLD_DEFAULT_ID." >&2
    btrfs subvolume set-default "$OLD_DEFAULT_ID" "$MNT" || true
    DEFAULT_CHANGED=0
  fi
}

# Fallback-Loader (EFI/BOOT) aktualisieren, falls vorhanden: Signierte Setups (shim) bekommen
# die Dateien aus dem Distributionsverzeichnis, Standalone-Images werden kopiert.
refresh_fallback_loader() {
  local esp="$1" arch up id d name
  case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64) arch=aa64 ;;
    *) return 0 ;;
  esac
  up="${arch^^}"
  [[ -f "$esp/EFI/BOOT/BOOT${up}.EFI" ]] || return 0
  # Standard-Fallback von Ubuntu/Debian (shim + fbx64.efi): Der Fallback-Loader startet ueber
  # BOOT*.CSV den Eintrag aus EFI/<id>/ und enthaelt selbst kein GRUB - nichts zu aktualisieren.
  [[ -f "$esp/EFI/BOOT/fb${arch}.efi" ]] && return 0
  id=""
  for d in "$esp"/EFI/*/; do
    name=$(basename "$d")
    [[ "$name" == BOOT ]] && continue
    [[ -f "$d/grub${arch}.efi" ]] || continue
    id="$name"
    break
  done
  if [[ -z "$id" ]]; then
    echo "WARNUNG: Kein GRUB-Verzeichnis auf der ESP gefunden - Fallback-Loader EFI/BOOT nicht aktualisiert." >&2
    return 0
  fi
  echo ">>> Aktualisiere Fallback-Loader EFI/BOOT aus EFI/$id"
  if [[ -f "$esp/EFI/$id/shim${arch}.efi" ]]; then
    cp "$esp/EFI/$id/shim${arch}.efi" "$esp/EFI/BOOT/BOOT${up}.EFI"
    cp "$esp/EFI/$id/grub${arch}.efi" "$esp/EFI/BOOT/"
    [[ -f "$esp/EFI/$id/mm${arch}.efi" ]] && cp "$esp/EFI/$id/mm${arch}.efi" "$esp/EFI/BOOT/"
  else
    cp "$esp/EFI/$id/grub${arch}.efi" "$esp/EFI/BOOT/BOOT${up}.EFI"
  fi
}

write_boot_files() {
  local esp="${BOOT_ROOT}/boot/efi" disk
  if [[ -d /sys/firmware/efi ]]; then
    if mountpoint -q "$esp"; then
      echo ">>> grub-install (EFI) im Zielsystem"
      boot_run grub-install --no-nvram || return 1
      refresh_fallback_loader "$esp"
    else
      echo "FEHLER: /boot/efi ist nicht gemountet - GRUB (EFI) kann nicht aktualisiert werden." >&2
      return 1
    fi
  else
    disk=$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null | head -1)
    if [[ -z "$disk" ]]; then
      echo "FEHLER: Konnte die Platte von $ROOT_DEV für grub-install (BIOS) nicht ermitteln." >&2
      return 1
    fi
    echo ">>> grub-install (BIOS) auf /dev/$disk"
    boot_run grub-install "/dev/$disk" || return 1
  fi
  echo ">>> GRUB-Konfiguration erzeugen"
  boot_run /bin/sh -c '
    if command -v update-grub >/dev/null 2>&1; then update-grub
    elif command -v grub-mkconfig >/dev/null 2>&1; then grub-mkconfig -o /boot/grub/grub.cfg
    else echo "Weder update-grub noch grub-mkconfig gefunden" >&2; exit 3; fi'
}

verify_boot_config() {
  local cfg="${BOOT_ROOT}/boot/grub/grub.cfg" esp="${BOOT_ROOT}/boot/efi" f ok=1
  if [[ ! -s "$cfg" ]] || ! grep -Eq '^[[:space:]]*linux[[:space:]]' "$cfg"; then
    echo "FEHLER: Erzeugte grub.cfg enthält keine Kernel-Einträge ($cfg)." >&2
    return 1
  fi
  if ! grep -Eq 'rootflags=subvol=@([[:space:]]|$)' "$cfg"; then
    echo "FEHLER: grub.cfg enthält kein rootflags=subvol=@ - das System würde nicht von @ starten." >&2
    ok=0
  fi
  if [[ -n "${ROOT_SUBVOL:-}" && "$ROOT_SUBVOL" != "/@" ]] && grep -Fq "${ROOT_SUBVOL#/}" "$cfg"; then
    echo "FEHLER: grub.cfg verweist noch auf das alte Root-Subvolume ${ROOT_SUBVOL}." >&2
    ok=0
  fi
  for f in "$esp"/EFI/*/grub.cfg; do
    [[ -f "$f" ]] || continue
    if grep -q 'set prefix=' "$f" && ! grep -Eq "set prefix=.*/@/boot/grub" "$f"; then
      echo "FEHLER: $f verweist nicht auf /@/boot/grub (GRUB würde die alte Konfiguration lesen)." >&2
      ok=0
    fi
  done
  [[ $ok -eq 1 ]]
}

# Erstmigration/--finish-migration: Bootkonfiguration im frisch befuellten @ erzeugen.
regenerate_boot_in_new_root() {
  local newroot=/mnt/btrfs-newroot d ok=1
  ensure_toplevel_default
  echo ">>> Bootkonfiguration im neuen Root (@) erzeugen"
  mkdir -p "$newroot"
  mount -o subvol=@ "$ROOT_DEV" "$newroot"
  for d in dev proc sys run; do
    mount --rbind "/$d" "$newroot/$d"
    mount --make-rslave "$newroot/$d"
  done
  if mountpoint -q /boot; then mount --bind /boot "$newroot/boot"; fi
  if mountpoint -q /boot/efi; then
    mkdir -p "$newroot/boot/efi"
    mount --bind /boot/efi "$newroot/boot/efi"
  fi
  if [[ -f "$newroot/etc/default/grub" ]]; then
    sed -i 's/@rootfs/@/g' "$newroot/etc/default/grub"
  fi
  BOOT_ROOT="$newroot"
  write_boot_files || ok=0
  if [[ $ok -eq 1 ]]; then verify_boot_config || ok=0; fi
  BOOT_ROOT=""
  umount -R -l "$newroot" || true
  if [[ $ok -ne 1 ]]; then
    echo "FEHLER: Bootkonfiguration im neuen Root fehlgeschlagen." >&2
    restore_default_subvolume
    restart_stopped_services
    umount "$MNT" || true
    exit 1
  fi
}

# --fix-boot: Bootkonfiguration des laufenden @-Systems reparieren (z. B. node6 nach der
# alten Skriptversion: Default-Subvolume @, GRUB liest veraltete /boot-Kopie im Top-Level).
fix_boot() {
  local confirm
  ROOT_SUBVOL=$(root_subvol_of "$ROOT_SRC")
  if [[ "$ROOT_SUBVOL" != "/@" ]]; then
    echo "FEHLER: --fix-boot erwartet, dass / von @ läuft (ist: ${ROOT_SRC})." >&2
    exit 1
  fi
  echo ">>> --fix-boot: GRUB wird neu geschrieben (grub-install, update-grub) und das Default-Subvolume"
  echo ">>> bei Bedarf auf den Top-Level zurückgesetzt. Ein Fehler kann das System unbootbar machen;"
  echo ">>> die Konfiguration wird vorher in /root/btrfs-layout-boot-backup-<Zeit> gesichert."
  if [[ $ASSUME_YES -eq 1 ]]; then
    echo ">>> --yes angegeben - Bestätigung übersprungen."
  elif [[ -t 0 ]]; then
    read -r -p "Fortfahren? Exakt 'ja' eingeben: " confirm
    [[ "$confirm" == "ja" ]] || { echo "Abgebrochen." >&2; exit 1; }
  fi
  local bk
  bk="/root/btrfs-layout-boot-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$bk"
  cp -a /boot/grub "$bk/" 2>/dev/null || true
  cp -a /boot/efi/EFI "$bk/EFI" 2>/dev/null || true
  btrfs subvolume get-default / > "$bk/default-subvolume.txt" 2>/dev/null || true
  MNT=/mnt/btrfs-root
  mkdir -p "$MNT"
  mount -o subvolid=5 "$ROOT_DEV" "$MNT"
  # shellcheck disable=SC2064
  trap "umount '$MNT' 2>/dev/null || true" EXIT
  ensure_toplevel_default
  BOOT_ROOT=""
  if ! write_boot_files || ! verify_boot_config; then
    echo "FEHLER: Bootkonfiguration konnte nicht erzeugt werden. Sicherung: $bk" >&2
    restore_default_subvolume
    umount "$MNT" || true
    exit 1
  fi
  umount "$MNT" || true
  echo ">>> Bootkonfiguration repariert. Sicherung: $bk"
  echo ">>> Jetzt neu starten und prüfen: /proc/cmdline soll BOOT_IMAGE=/@/boot/... und rootflags=subvol=@ zeigen."
}

if [[ $MODE_CLEANUP -eq 1 ]]; then
  cleanup_old_root
  exit $?
fi

if [[ $MODE_FIXBOOT -eq 1 ]]; then
  fix_boot
  exit $?
fi

ROOT_SUBVOL=$(root_subvol_of "$ROOT_SRC")
MODE=$(detect_mode "$ROOT_SRC" "$MODE_FINISH")
INCREMENTAL=0
case "$MODE" in
  done)
    echo ">>> / läuft bereits von @ - die Migration ist abgeschlossen, nichts zu tun."
    echo ">>> Alte Root-Daten entfernen: setup-btrfs.sh --cleanup-old-root"
    exit 0
    ;;
  finish)
    echo ">>> / läuft von ${ROOT_SUBVOL}, nicht von @. Migration wird abgeschlossen (--finish-migration):"
    echo ">>> @ wird aus dem laufenden Root neu befüllt, GRUB im neuen Root neu erzeugt."
    ;;
  incremental)
    INCREMENTAL=1
    echo ">>> / läuft bereits von einem benannten Subvolume (${ROOT_SRC})."
    echo ">>> Inkrementeller Modus: nur fehlende Subvolumes werden ergänzt."
    echo ">>> Root, GRUB und Default-Subvolume bleiben unangetastet, kein Neustart nötig."
    if [[ "$ROOT_SUBVOL" != "/@" ]]; then
      echo "WARNUNG: / läuft von ${ROOT_SUBVOL} und nicht von @. Ist die Migration unvollständig?" >&2
      echo "         Dann mit --finish-migration abschließen." >&2
    fi
    ;;
esac

# --- Ausdrückliche Bestätigung, bevor irgendetwas verändert wird ---
echo
echo "!!! ACHTUNG !!!"
if [[ $INCREMENTAL -eq 1 ]]; then
  echo "Dieses Skript legt zusätzliche Subvolumes für noch nicht separat"
  echo "gemountete Pfade an und kopiert deren aktuelle Daten hinein."
  echo "Root, /etc/default/grub und das Default-Subvolume werden NICHT verändert;"
  echo "ein Neustart ist nicht nötig."
else
  echo "Dieses Skript modifiziert /etc/fstab und /etc/default/grub und kopiert das"
  echo "komplette Root-Dateisystem in neue Subvolumes. Der eigentliche Root-Wechsel"
  echo "wird erst mit einem Neustart wirksam. Ein Fehlschlag kann das System"
  echo "unbootbar machen; ein Rollback ist dann nur manuell über eine Rescue-Konsole"
  echo "möglich (die alte fstab wird zwar gesichert, aber nicht automatisch"
  echo "zurückgespielt)."
fi
echo
if [[ $ASSUME_YES -eq 1 ]]; then
  echo ">>> --yes angegeben - Bestätigung übersprungen."
elif [[ -t 0 ]]; then
  read -r -p "Backup vorhanden? Zum Fortfahren exakt 'ja' eingeben: " CONFIRM
  if [[ "$CONFIRM" != "ja" ]]; then
    echo "Abgebrochen." >&2
    exit 1
  fi
else
  echo ">>> Kein interaktives Terminal erkannt – Bestätigung übersprungen (automatisierter Lauf)."
fi

MNT=/mnt/btrfs-root
if mount | grep -q " on $MNT "; then
  echo "$MNT ist bereits gemountet, bitte zuerst aushängen." >&2
  exit 1
fi
mkdir -p "$MNT"

echo ">>> Mount Top-Level (subvolid=5) von $ROOT_DEV nach $MNT"
mount -o subvolid=5 "$ROOT_DEV" "$MNT"

echo ">>> Vorhandene Subvolumes:"
btrfs subvolume list "$MNT" || true

create_subvol() {
  local name="$1"
  if btrfs subvolume list "$MNT" | awk '{print $NF}' | grep -qx "$name"; then
    echo "Subvolume $name existiert bereits – ok."
  else
    echo "Erzeuge Subvolume $name"
    btrfs subvolume create "$MNT/$name"
  fi
}

apt_package_available() {
  local pkg="$1"
  apt-cache show "$pkg" >/dev/null 2>&1
}

offer_optional_btrfs_tools() {
  [[ -t 0 && -t 1 ]] || return 0

  local -a tools=(
    "timeshift:Einfache System-Restore-Snapshots"
    "snapper:Server/CLI-Snapshotverwaltung für Btrfs"
    "btrbk:Btrfs-Backups und Replikation per SSH"
    "btrfsmaintenance:Scrub, Balance, Trim und Defrag planen"
    "duperemove:Deduplizierung gleicher Btrfs-Extents"
    "grub-btrfs:Btrfs-Snapshots im GRUB-Bootmenü bootbar machen"
  )
  local -a checklist_args=()
  local -a selected_tools=()
  local entry pkg desc selected

  for entry in "${tools[@]}"; do
    pkg="${entry%%:*}"
    desc="${entry#*:}"
    if apt_package_available "$pkg"; then
      checklist_args+=("$pkg" "$desc" "OFF")
    else
      echo ">>> Optionales APT-Paket $pkg ist nicht verfügbar, überspringe."
    fi
  done

  [[ ${#checklist_args[@]} -gt 0 ]] || return 0

  need_pkg whiptail whiptail
  if ! selected=$(whiptail --title "Optionale Btrfs-/Snapshot-Tools" \
    --checklist "Diese Auswahl installiert nur normale APT-Pakete, keine Snap- oder Flatpak-Pakete. Alle Tools bleiben unkonfiguriert; Timeshift, Snapper, btrbk und Wartungsjobs müssen danach manuell eingerichtet werden.\nLeertaste = an-/abwählen, Enter = bestätigen." \
    22 92 10 \
    "${checklist_args[@]}" \
    3>&1 1>&2 2>&3); then
    echo ">>> Optionale Tool-Installation übersprungen."
    return 0
  fi

  eval "selected_tools=($selected)"
  [[ ${#selected_tools[@]} -gt 0 ]] || { echo ">>> Keine optionalen Tools ausgewählt."; return 0; }

  echo ">>> Installiere optionale APT-Pakete: ${selected_tools[*]}"
  if apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "${selected_tools[@]}"; then
    echo ">>> Optionale Tools installiert. Bitte Timeshift/Snapper/btrbk/btrfsmaintenance bei Bedarf manuell konfigurieren."
    echo ">>> Hinweis grub-btrfs: für die vollständige Timeshift-Integration danach setup-timeshift.sh ausführen; für Snapper setup-snapper.sh verwenden."
  else
    echo "WARNUNG: Optionale Tool-Installation ist fehlgeschlagen. Das Btrfs-Setup wird fortgesetzt." >&2
  fi
}

# --- Mapping Quelle -> Subvolume (für Daten); einzige Quelle der Wahrheit für
# Subvolume-Namen, Rsync-Ausschlüsse, Mountpoint-Vorbereitung, -Erzeugung und
# fstab-Einträge (siehe SUBVOL_OPTS weiter unten) ---
declare -a ALL_MAPS=(
# Allgemeine Systempfade: sinnvoll auf so gut wie jedem Server, unabhaengig
# vom installierten Software-Stack. Stehen deshalb im Auswahldialog oben.
"/root:@root"
"/home:@home"
"/var/spool:@spool"
"/var/log:@log"
"/var/cache:@cache"
"/var/tmp:@tmp_var"
"/srv:@srv"
"/tmp:@tmp"
"/opt:@opt"
"/var/www:@www"
# Zentrale Journal-Sammelstelle (systemd-journal-remote). Liegt innerhalb von @log;
# eigenes Subvolume erlaubt gezielte Snapshots und Rechte, getrennt vom lokalen Journal.
"/var/log/journal/remote:@journal-remote"
# Container-Engines und ihre benannten Volumes. Volume-Subvolumes stehen
# direkt hinter ihrem Eltern-Subvolume (Zugehoerigkeit im Dialog erkennbar)
# und sind getrennt von @docker/@containers, damit Volume-Daten gezielt von
# Kompression ausgenommen werden koennen, waehrend Image-Layer/Metadaten
# weiterhin von compress=zstd profitieren.
"/var/lib/containers:@containers"
"/var/lib/containers/storage/volumes:@containers-volumes"
"/var/lib/docker:@docker"
"/var/lib/docker/volumes:@docker-volumes"
# Kubernetes (MicroK8s-Snap): Laufzeitdaten samt Datastore und lokale PersistentVolumes.
"/var/snap/microk8s/common:@microk8s"
"/var/lib/k8s-storage:@k8s-storage"
# Datenbank-/Datastore-Pfade: stark vom konkreten Software-Stack abhaengig,
# deshalb im Auswahldialog ganz unten.
"/var/lib/mongodb:@mongodb"
"/var/lib/mysql:@mysql"
"/var/lib/postgresql:@postgresql"
"/var/lib/chroma:@chroma"
"/var/lib/clamav:@clamav"
"/var/lib/stalwart:@stalwart"
"/var/lib/elasticsearch:@elasticsearch"
"/var/lib/opensearch:@opensearch"
"/var/lib/clickhouse:@clickhouse"
"/var/lib/cassandra:@cassandra"
"/var/lib/couchdb:@couchdb"
"/var/lib/neo4j:@neo4j"
"/var/lib/rabbitmq:@rabbitmq"
)

# fstab-Mount-Optionen je Subvolume. Btrfs-Mountoptionen wie compress,
# nodatacow und autodefrag sind nicht verlaesslich pro Subvolume steuerbar;
# Datenbank-/Volume-Subvolumes bekommen deshalb unten per Inode-Property
# "compression no" statt eigener fstab-Kompressionsoptionen.
declare -A SUBVOL_OPTS=(
  [@root]="noatime,compress=zstd,space_cache=v2"
  [@home]="noatime,compress=zstd,space_cache=v2,autodefrag"
  [@spool]="noatime,compress=zstd,space_cache=v2,autodefrag"
  [@log]="noatime,compress=zstd,space_cache=v2,autodefrag"
  [@cache]="noatime,compress=zstd,space_cache=v2"
  [@tmp_var]="noatime,compress=zstd,space_cache=v2"
  [@srv]="noatime,compress=zstd,space_cache=v2"
  [@tmp]="noatime,compress=zstd,space_cache=v2"
  [@opt]="noatime,compress=zstd,space_cache=v2"
  [@containers]="noatime,compress=zstd,space_cache=v2"
  [@docker]="noatime,compress=zstd,space_cache=v2"
  [@www]="noatime,compress=zstd,space_cache=v2"
  [@mongodb]="noatime,compress=zstd,space_cache=v2"
  [@mysql]="noatime,compress=zstd,space_cache=v2"
  [@postgresql]="noatime,compress=zstd,space_cache=v2"
  [@chroma]="noatime,compress=zstd,space_cache=v2"
  [@clamav]="noatime,compress=zstd,space_cache=v2"
  [@stalwart]="noatime,compress=zstd,space_cache=v2"
  [@elasticsearch]="noatime,compress=zstd,space_cache=v2"
  [@opensearch]="noatime,compress=zstd,space_cache=v2"
  [@clickhouse]="noatime,compress=zstd,space_cache=v2"
  [@cassandra]="noatime,compress=zstd,space_cache=v2"
  [@couchdb]="noatime,compress=zstd,space_cache=v2"
  [@neo4j]="noatime,compress=zstd,space_cache=v2"
  [@rabbitmq]="noatime,compress=zstd,space_cache=v2"
  [@docker-volumes]="noatime,compress=zstd,space_cache=v2"
  [@containers-volumes]="noatime,compress=zstd,space_cache=v2"
  [@journal-remote]="noatime,compress=zstd,space_cache=v2"
  [@microk8s]="noatime,compress=zstd,space_cache=v2"
  [@k8s-storage]="noatime,compress=zstd,space_cache=v2"
)

# Diese Subvolumes behalten CoW und Checksums, werden aber per
# btrfs-property von der Kompression ausgenommen. Die Property muss vor dem
# Kopieren der Daten gesetzt werden, damit neue Dateien darunter sie erben.
declare -A NO_COMPRESSION_SUBVOLS=(
  [@mongodb]=1
  [@mysql]=1
  [@postgresql]=1
  [@chroma]=1
  [@clamav]=1
  [@stalwart]=1
  [@elasticsearch]=1
  [@opensearch]=1
  [@clickhouse]=1
  [@cassandra]=1
  [@couchdb]=1
  [@neo4j]=1
  [@rabbitmq]=1
  [@docker-volumes]=1
  [@containers-volumes]=1
  [@journal-remote]=1
  [@microk8s]=1
  [@k8s-storage]=1
)

# Volume-Subvolumes liegen INNERHALB ihres Eltern-Subvolumes und brauchen es
# als eigenes Subvolume (sonst legt prepare_mp verwaiste Verzeichnisse unter
# einem nie erzeugten Eltern-Subvolume an).
declare -A VOLUME_PARENT=(
  [@docker-volumes]=@docker
  [@containers-volumes]=@containers
)

# --- Bereits erledigte bzw. anderweitig belegte Zielpfade aussortieren ---
# Drei Kategorien statt eines Alles-oder-nichts-Abbruchs:
#   - schon korrekt eingerichtet (genau das erwartete Subvolume gemountet)
#     -> wird uebersprungen, taucht im Auswahldialog gar nicht erst auf.
#   - anderweitig belegt (gemountet, aber nicht vom erwarteten Subvolume)
#     -> wird uebersprungen und gewarnt, statt blind drueberzuschreiben.
#   - noch offen (kein eigener Mount) -> Kandidat fuer die Auswahl.
declare -a MAPS=()
declare -a ALREADY_DONE=()
declare -a CONFLICTS=()
for entry in "${ALL_MAPS[@]}"; do
  src="${entry%%:*}"
  sub="${entry##*:}"
  this_src=$(findmnt -no SOURCE "$src" 2>/dev/null || true)
  if [[ -z "$this_src" ]]; then
    MAPS+=("$entry")
  elif [[ "$this_src" == *"[/${sub}]"* ]]; then
    ALREADY_DONE+=("$entry")
  else
    CONFLICTS+=("$entry ($this_src)")
  fi
done

if [[ ${#ALREADY_DONE[@]} -gt 0 ]]; then
  echo ">>> Bereits eingerichtet (übersprungen):"
  for entry in "${ALREADY_DONE[@]}"; do
    echo "    ${entry%%:*} -> ${entry##*:}"
  done
fi
if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
  echo ">>> WARNUNG: anderweitig belegt, wird übersprungen (bitte manuell prüfen):" >&2
  for c in "${CONFLICTS[@]}"; do
    echo "    $c" >&2
  done
fi
if [[ ${#MAPS[@]} -eq 0 && $INCREMENTAL -eq 1 ]]; then
  echo ">>> Nichts zu tun - alle Subvolumes sind bereits eingerichtet oder anderweitig belegt."
  umount "$MNT"
  exit 0
fi

# --- Interaktive Auswahl: welche der noch offenen Subvolumes anlegen? ---
# Universell sinnvolle Subvolumes sind vorausgewählt (klein/leer auf so gut
# wie jedem Debian-Server, so gut wie nie schaedlich). Alles, was von der
# konkreten Serverrolle oder dem installierten Software-Stack abhaengt
# (Mail-Spool, Webserver-Docroot, Container-Engines, Datenbanken), startet
# abgewaehlt, bleibt aber frei anwaehlbar. Abgewaehlte Pfade bekommen kein
# eigenes Subvolume und bleiben einfach Teil von @ (Root) - das Skript
# braucht dafuer keine Sonderbehandlung, da alles Weitere aus MAPS
# abgeleitet wird.
declare -A DEFAULT_ON=(
  [@root]=1
  [@home]=1
  [@log]=1
  [@cache]=1
  [@tmp_var]=1
  [@tmp]=1
)

checklist_desc_for() {
  local src="$1" sub="$2" category compression
  if [[ -n "${DEFAULT_ON[$sub]:-}" ]]; then
    category="default"
  else
    category="optional"
  fi
  if [[ -n "${NO_COMPRESSION_SUBVOLS[$sub]:-}" ]]; then
    compression="no-compress"
  else
    compression="compress"
  fi
  echo "${category}, ${compression}: $src"
}

echo ">>> Noch offene Subvolumes:"
for entry in "${MAPS[@]}"; do
  src="${entry%%:*}"
  sub="${entry##*:}"
  echo "    $sub ($(checklist_desc_for "$src" "$sub"))"
done

# Wendet SELECTED_ARR auf MAPS an (inkl. automatischer Eltern-Subvolumes).
apply_selection() {
  # Volume-Subvolumes brauchen ihr Eltern-Subvolume (siehe VOLUME_PARENT
  # oben); wird nur das Volume gewaehlt, muss das Elternteil automatisch
  # ergaenzt werden - sonst legt prepare_mp spaeter verwaiste Verzeichnisse
  # unter einem nie erzeugten Eltern-Subvolume an.
  for sel in "${SELECTED_ARR[@]}"; do
    parent="${VOLUME_PARENT[$sel]:-}"
    [[ -n "$parent" ]] || continue

    already=0
    for s in "${SELECTED_ARR[@]}"; do
      [[ "$s" == "$parent" ]] && { already=1; break; }
    done
    [[ $already -eq 1 ]] && continue

    candidate=0
    for entry in "${MAPS[@]}"; do
      [[ "${entry##*:}" == "$parent" ]] && { candidate=1; break; }
    done
    if [[ $candidate -eq 1 ]]; then
      echo ">>> $sel gewählt -> $parent automatisch mitausgewählt (Volume liegt darin)."
      SELECTED_ARR+=("$parent")
    fi
  done

  FILTERED_MAPS=()
  for entry in "${MAPS[@]}"; do
    sub="${entry##*:}"
    for sel in "${SELECTED_ARR[@]}"; do
      if [[ "$sub" == "$sel" ]]; then
        FILTERED_MAPS+=("$entry")
        break
      fi
    done
  done
  MAPS=("${FILTERED_MAPS[@]}")
  echo ">>> Ausgewählt: ${#MAPS[@]} Subvolumes."
}

if [[ -n "$SUBVOLS_ARG" ]]; then
  IFS=',' read -r -a SELECTED_ARR <<< "$SUBVOLS_ARG"
  for sel in "${SELECTED_ARR[@]}"; do
    known=0
    for entry in "${ALL_MAPS[@]}"; do
      [[ "${entry##*:}" == "$sel" ]] && { known=1; break; }
    done
    if [[ $known -eq 0 ]]; then
      echo "FEHLER: Unbekanntes Subvolume in --subvols: $sel" >&2
      umount "$MNT"
      exit 2
    fi
  done
  apply_selection
elif [[ -t 0 && -t 1 ]]; then
  need_pkg whiptail whiptail
  CHECKLIST_ARGS=()
  for entry in "${MAPS[@]}"; do
    src="${entry%%:*}"
    sub="${entry##*:}"
    state="OFF"
    [[ -n "${DEFAULT_ON[$sub]:-}" ]] && state="ON"
    CHECKLIST_ARGS+=("$sub" "$(checklist_desc_for "$src" "$sub")" "$state")
  done
  SELECTED=$(whiptail --title "Btrfs-Subvolumes auswählen" \
    --checklist "Universell sinnvolle Subvolumes sind vorausgewählt. Einträge mit 'no-compress' behalten CoW/Prüfsummen, bekommen aber per Btrfs-Property compression=no vor der Datenkopie. Volume-Subvolumes (*-volumes) aktivieren automatisch ihr Eltern-Subvolume. Leertaste = ab-/anwählen, Enter = bestätigen.\nAbgewählte Pfade bleiben einfach Teil von @ (Root)." \
    24 78 14 \
    "${CHECKLIST_ARGS[@]}" \
    3>&1 1>&2 2>&3) || { echo "Abgebrochen." >&2; umount "$MNT"; exit 1; }
  eval "SELECTED_ARR=($SELECTED)"

  apply_selection
else
  echo ">>> Kein interaktives Terminal erkannt - nur die universell sinnvollen Subvolumes werden angelegt (kein Auswahldialog)."
  FILTERED_MAPS=()
  for entry in "${MAPS[@]}"; do
    sub="${entry##*:}"
    [[ -n "${DEFAULT_ON[$sub]:-}" ]] && FILTERED_MAPS+=("$entry")
  done
  MAPS=("${FILTERED_MAPS[@]}")
  echo ">>> Ausgewählt: ${#MAPS[@]} Subvolumes."
fi

if [[ ${#MAPS[@]} -eq 0 && $INCREMENTAL -eq 1 ]]; then
  echo ">>> Nichts ausgewählt - nichts zu tun."
  umount "$MNT"
  exit 0
fi

# --- Speicherplatz-Check ---
# Initial-Modus: jedes Byte auf / wird einmal dupliziert (landet in @ oder
# einem eigenen Subvolume), der Gesamtbedarf entspricht also ungefaehr der
# aktuell belegten Menge auf /. Inkrementeller Modus: es wird nur das kopiert,
# was tatsaechlich ausgewaehlt wurde, also die Summe genau dieser Verzeichnisse.
echo ">>> Prüfe verfügbaren Speicherplatz"
if [[ $INCREMENTAL -eq 1 ]]; then
  NEEDED_BYTES=0
  for entry in "${MAPS[@]}"; do
    src="${entry%%:*}"
    if [[ -d "$src" ]]; then
      size=$(du -sb --one-file-system "$src" 2>/dev/null | awk '{print $1}')
      NEEDED_BYTES=$(( NEEDED_BYTES + ${size:-0} ))
    fi
  done
else
  NEEDED_BYTES=$(df --output=used -B1 / | tail -1 | tr -d '[:space:]')
fi
AVAIL_BYTES=$(df --output=avail -B1 / | tail -1 | tr -d '[:space:]')
REQUIRED_WITH_MARGIN=$(( NEEDED_BYTES * 110 / 100 ))
if (( AVAIL_BYTES < REQUIRED_WITH_MARGIN )); then
  echo "FEHLER: Nicht genug freier Speicherplatz." >&2
  echo "Benötigt (mit 10% Marge): ca. $(( REQUIRED_WITH_MARGIN / 1024 / 1024 )) MiB, verfügbar: $(( AVAIL_BYTES / 1024 / 1024 )) MiB." >&2
  echo "Grund: Die betroffenen Daten existieren kurzzeitig doppelt (alter Ort + neues Subvolume)." >&2
  umount "$MNT"
  exit 1
fi
echo ">>> Speicherplatz-Check bestanden (${AVAIL_BYTES} Bytes frei, ca. ${REQUIRED_WITH_MARGIN} Bytes benötigt)."

# --- alle ausgewählten Subvolumes anlegen (Root @ existiert im inkrementellen
# Modus schon; create_subvol ist idempotent, daher hier kein Unterschied) ---
create_subvol "@"
for entry in "${MAPS[@]}"; do
  create_subvol "${entry##*:}"
done

set_no_compression_policy() {
  local subvol="$1" target prop
  [[ -n "${NO_COMPRESSION_SUBVOLS[$subvol]:-}" ]] || return 0

  target="$MNT/$subvol"
  echo ">>> Deaktiviere Btrfs-Kompression für neue Daten in $subvol"
  btrfs property set "$target" compression no
  prop=$(btrfs property get "$target" compression)
  if [[ "$prop" != "compression=no" && "$prop" != "compression=none" ]]; then
    echo "FEHLER: Konnte Kompression für $subvol nicht deaktivieren (Ist: ${prop:-<leer>})." >&2
    echo "Abbruch, damit Daten nicht versehentlich mit falscher Kompressions-Policy kopiert werden." >&2
    umount "$MNT"
    exit 1
  fi
}

for entry in "${MAPS[@]}"; do
  set_no_compression_policy "${entry##*:}"
done

sync_dir() {
  local src="$1"    # z.B. /home
  local subvol="$2" # z.B. @home
  shift 2
  local extra_excludes=("$@") # z.B. --exclude=/volumes/* fuer verschachtelte Subvolumes

  if [[ ! -d "$src" ]]; then
    echo "Quelle $src existiert nicht, überspringe."
    return
  fi

  echo ">>> Übertrage $src nach $subvol (überschreibend)"
  rsync -axHAX --delete "${extra_excludes[@]}" "$src"/ "$MNT/$subvol"/
}

# --- Bekannte Dienste vor der Kopie stoppen (konsistente Daten statt
# halbgeschriebener Dateien bei aktiv laufenden Datenbanken/Containern) ---
declare -A SRC_SERVICE=(
  ["/var/lib/mongodb"]="mongod"
  ["/var/lib/mysql"]="mariadb mysql"
  ["/var/lib/postgresql"]="postgresql"
  ["/var/lib/chroma"]="chroma chromadb"
  ["/var/lib/clamav"]="clamav-freshclam clamav-freshclam-once.timer clamav-daemon"
  ["/var/lib/stalwart"]="stalwart-mail stalwart stalwart-server"
  ["/var/lib/elasticsearch"]="elasticsearch"
  ["/var/lib/opensearch"]="opensearch"
  ["/var/lib/clickhouse"]="clickhouse-server clickhouse"
  ["/var/lib/cassandra"]="cassandra"
  ["/var/lib/couchdb"]="couchdb"
  ["/var/lib/neo4j"]="neo4j"
  ["/var/lib/rabbitmq"]="rabbitmq-server rabbitmq"
  ["/var/lib/docker"]="docker"
  ["/var/lib/docker/volumes"]="docker"
  ["/var/lib/containers"]="podman podman.socket podman-restart crio containerd"
  ["/var/lib/containers/storage/volumes"]="podman podman.socket podman-restart crio containerd"
  ["/var/snap/microk8s/common"]="snap:microk8s"
  ["/var/lib/k8s-storage"]="snap:microk8s"
)
declare -a STOPPED_SERVICES=()
declare -A ALREADY_HANDLED=()

restart_stopped_services() {
  local svc
  for svc in "${STOPPED_SERVICES[@]}"; do
    echo ">>> Starte $svc wieder"
    if [[ "$svc" == snap:* ]]; then
      snap start "${svc#snap:}" || echo "WARNUNG: $svc konnte nicht neu gestartet werden – bitte manuell prüfen." >&2
    else
      systemctl start "$svc" || echo "WARNUNG: $svc konnte nicht neu gestartet werden – bitte manuell prüfen." >&2
    fi
  done
  STOPPED_SERVICES=()
}

for entry in "${MAPS[@]}"; do
  src="${entry%%:*}"
  for svc in ${SRC_SERVICE[$src]:-}; do
    if [[ -z "${ALREADY_HANDLED[$svc]:-}" ]]; then
      ALREADY_HANDLED[$svc]=1
      if [[ "$svc" == snap:* ]]; then
        # Snap-Dienste (z. B. MicroK8s) gesammelt per "snap stop" anhalten.
        if command -v snap >/dev/null 2>&1 \
           && snap services "${svc#snap:}" 2>/dev/null | awk 'NR>1 && $3=="active"{f=1} END{exit !f}'; then
          echo ">>> Stoppe Snap ${svc#snap:} für eine konsistente Kopie"
          snap stop "${svc#snap:}"
          STOPPED_SERVICES+=("$svc")
        fi
      elif systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo ">>> Stoppe $svc für eine konsistente Kopie"
        systemctl stop "$svc"
        STOPPED_SERVICES+=("$svc")
      fi
    fi
  done
done

echo ">>> Übertrage /root, /home, /var/... in ihre Subvolumes"
for entry in "${MAPS[@]}"; do
  src="${entry%%:*}"
  sub="${entry##*:}"
  # Verschachtelte Ziele (z. B. @docker-volumes unter @docker) werden hier generisch
  # aus MAPS abgeleitet und von der Elternkopie ausgeschlossen.
  nested_excludes=()
  for other in "${MAPS[@]}"; do
    osrc="${other%%:*}"
    if [[ "$osrc" == "$src"/* ]]; then
      nested_excludes+=(--exclude="${osrc#"$src"}/*")
    fi
  done
  sync_dir "$src" "$sub" "${nested_excludes[@]}"
done

# --- Swap-Dateien auf diesem Btrfs erkennen (nur Erstmigration/--finish-migration) ---
# Eine Swap-Datei darf nicht per rsync (CoW) in @ landen: swapon scheitert dann, und
# Snapshots von @ wuerden mit aktiver Swap-Datei fehlschlagen. Sie bekommt deshalb ein
# eigenes Subvolume @swap (eingehaengt unter /swap) und wird dort neu angelegt.
SWAP_OLD_PATH=""
SWAP_SIZE=0
if [[ $INCREMENTAL -eq 0 ]]; then
  while read -r swapfile; do
    [[ -n "$swapfile" ]] || continue
    swap_fs=$(findmnt -n -o FSTYPE -T "$swapfile" 2>/dev/null || true)
    swap_src=$(findmnt -n -o SOURCE -T "$swapfile" 2>/dev/null || true)
    if [[ "$swap_fs" == "btrfs" && "${swap_src%%[*}" == "$ROOT_DEV" ]]; then
      if [[ -z "$SWAP_OLD_PATH" ]]; then
        SWAP_OLD_PATH="$swapfile"
        SWAP_SIZE=$(stat -c %s "$swapfile")
      else
        echo "WARNUNG: Weitere Swap-Datei $swapfile auf Btrfs wird nicht migriert (nur die erste)." >&2
      fi
    fi
  done < <(swapon --noheadings --raw --show=NAME,TYPE 2>/dev/null | awk '$2=="file"{print $1}')
  if [[ -n "$SWAP_OLD_PATH" ]]; then
    echo ">>> Swap-Datei $SWAP_OLD_PATH ($(( SWAP_SIZE / 1024 / 1024 )) MiB) wird nach @swap (/swap/swapfile) migriert."
  fi
fi

# --- fstab im laufenden System anpassen ---
FSTAB="/etc/fstab"
backup="${FSTAB}.backup-$(date +%F-%H%M%S)"
echo ">>> Sicherung der aktuellen fstab nach $backup"
cp "$FSTAB" "$backup"

add_fstab_entry() {
  local mp="$1" sub="$2" opts="$3" pass="$4"
  if grep -Eq "^[^#[:space:]]+[[:space:]]+${mp}[[:space:]]+btrfs" "$FSTAB"; then
    echo ">>> fstab: Eintrag für ${mp} existiert bereits, überspringe."
  else
    echo "UUID=${UUID} ${mp} btrfs ${opts},subvol=${sub} 0 ${pass}" >> "$FSTAB"
    echo ">>> fstab: Eintrag für ${mp} hinzugefügt."
  fi
}

if [[ $INCREMENTAL -eq 0 ]]; then
  tmp="${FSTAB}.new"
  echo ">>> Kommentiere alte Btrfs-Root-Zeile(n) aus"
  awk '
    $0 !~ /^[[:space:]]*#/ && $2 == "/" && $3 == "btrfs" {
      print "#OLD-ROOT " $0
      next
    }
    { print }
  ' "$backup" > "$tmp"
  mv "$tmp" "$FSTAB"

  # Root mit subvol=@
  add_fstab_entry / @ "noatime,compress=zstd,space_cache=v2" 1

  if [[ -n "$SWAP_OLD_PATH" ]]; then
    echo ">>> Lege @swap an und erzeuge dort die neue Swap-Datei"
    create_subvol "@swap"
    chattr +C "$MNT/@swap"
    swap_new="$MNT/@swap/swapfile"
    rm -f "$swap_new"
    if btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
      btrfs filesystem mkswapfile --size "${SWAP_SIZE}" "$swap_new"
    else
      truncate -s 0 "$swap_new"
      chattr +C "$swap_new"
      fallocate -l "${SWAP_SIZE}" "$swap_new"
      chmod 600 "$swap_new"
      mkswap "$swap_new" >/dev/null
    fi
    tmp="${FSTAB}.new"
    awk -v old="$SWAP_OLD_PATH" '
      $0 !~ /^[[:space:]]*#/ && $1 == old && $3 == "swap" { print "#OLD-SWAP " $0; next }
      { print }
    ' "$FSTAB" > "$tmp"
    mv "$tmp" "$FSTAB"
    add_fstab_entry /swap @swap "noatime" 0
    echo "/swap/swapfile none swap defaults 0 0" >> "$FSTAB"
    mkdir -p "$MNT/@/swap" /swap
  fi
fi

# weitere Mounts (pass=2), Optionen aus SUBVOL_OPTS
for entry in "${MAPS[@]}"; do
  src="${entry%%:*}"
  sub="${entry##*:}"
  add_fstab_entry "$src" "$sub" "${SUBVOL_OPTS[$sub]}" 2
done

if [[ $INCREMENTAL -eq 0 ]]; then
  # Im initialen Modus muessen optionale APT-Pakete vor der Root-Kopie
  # installiert werden, damit Paketdateien und dpkg-Status in @ landen.
  offer_optional_btrfs_tools

  # --- Root nach @ kopieren (JETZT, damit neue fstab & grub darin landen) ---
  # Verzeichnisse, die wirklich ihr eigenes Subvolume bekommen, hier
  # ausschliessen: sie wurden oben bereits per sync_dir befuellt und wuerden
  # sonst redundant kopiert und per prepare_mp sofort wieder geloescht.
  # Abgewaehlte Kandidaten bleiben dagegen Teil von @ und duerfen nicht aus
  # dem Root-Rsync ausgeschlossen werden.
  echo ">>> Kopiere aktuelles Root-Dateisystem nach @ (überschreibend)"
  RSYNC_ROOT_EXCLUDES=(
    --exclude="$MNT/*"
    --exclude="/dev/*"
    --exclude="/proc/*"
    --exclude="/sys/*"
    --exclude="/run/*"
    --exclude="/mnt/*"
    --exclude="/media/*"
    --exclude="/lost+found"
  )
  for entry in "${MAPS[@]}"; do
    RSYNC_ROOT_EXCLUDES+=(--exclude="${entry%%:*}/*")
  done
  if [[ -n "$SWAP_OLD_PATH" ]]; then
    RSYNC_ROOT_EXCLUDES+=(--exclude="$SWAP_OLD_PATH")
  fi
  rsync -axHAX --delete "${RSYNC_ROOT_EXCLUDES[@]}" / "$MNT/@"
fi

# --- Mountpoints im neuen Root (@) leeren, damit Subvolumes dort einhängen können ---
# Verschachtelte Faelle (z.B. @containers-volumes wird unter
# /var/lib/containers/storage/volumes eingehaengt, also INNERHALB von
# @containers) brauchen den Platzhalter im Eltern-Subvolume, nicht in @ -
# sonst fehlt das Mount-Zielverzeichnis nach dem Einhaengen des Elternteils.
# Nutzt ALL_MAPS (nicht nur die ausgewaehlten), damit die Elternauflösung auch
# im inkrementellen Modus korrekt auf bereits vorhandene Subvolumes verweist.
parent_info_for() {
  # Gibt "SUBVOL:RELATIVER_PFAD" zurueck, z.B. "@containers:/storage/volumes"
  # oder "@:/var/lib/containers", wenn kein Elternteil in ALL_MAPS gefunden wird.
  local target="$1"
  local best_prefix="" best_subvol="@"
  local entry src sub
  for entry in "${ALL_MAPS[@]}"; do
    src="${entry%%:*}"
    sub="${entry##*:}"
    if [[ "$src" != "$target" && "$target" == "$src"/* && ${#src} -gt ${#best_prefix} ]]; then
      best_prefix="$src"
      best_subvol="$sub"
    fi
  done
  echo "${best_subvol}:${target#"$best_prefix"}"
}

prepare_mp() {
  local mp="$1" # z.B. /home oder /var/lib/containers/storage/volumes
  local info parent_subvol rel target
  info=$(parent_info_for "$mp")
  parent_subvol="${info%%:*}"
  rel="${info#*:}"
  target="$MNT/$parent_subvol$rel" # z.B. /mnt/btrfs-root/@containers/storage/volumes
  mkdir -p "$target"
  rm -rf "${target:?}"/* 2>/dev/null || true
}

echo ">>> Mountpoints im neuen Root (@) vorbereiten"
for entry in "${MAPS[@]}"; do
  prepare_mp "${entry%%:*}"
done

# --- Default-Subvolume auf @ setzen (im inkrementellen Modus ohnehin schon
# korrekt gesetzt; set-default ist idempotent, daher hier kein Unterschied) ---
if [[ $INCREMENTAL -eq 0 ]]; then
  # Bootkonfiguration im neuen Root erzeugen (Hintergrund und Funktionen: siehe unten).
  regenerate_boot_in_new_root
fi

echo ">>> Erzeuge Mountpoints im laufenden System (falls noch nicht vorhanden)"
for entry in "${MAPS[@]}"; do
  mkdir -p "${entry%%:*}"
done

umount "$MNT"

# --- fstab validieren, ohne live umzumounten (kein Eingriff in laufende Dienste) ---
echo ">>> Validiere neue fstab mit 'findmnt --verify'"
if ! findmnt --verify; then
  echo "FEHLER: 'findmnt --verify' hat Probleme in der neuen fstab gefunden." >&2
  echo "Bitte ${FSTAB} pruefen, bevor du 'mount -a' ausfuehrst oder neu startest." >&2
  echo "Die alte fstab liegt gesichert unter ${backup}." >&2
  restart_stopped_services
  exit 1
fi
echo ">>> fstab-Validierung bestanden."

echo
if [[ $INCREMENTAL -eq 1 ]]; then
  echo ">>> Aktiviere die neuen Mounts sofort (kein Neustart nötig im inkrementellen Modus)"
  if ! systemctl daemon-reload; then
    echo "FEHLER: 'systemctl daemon-reload' ist fehlgeschlagen. Dienste werden wieder gestartet, soweit möglich." >&2
    restart_stopped_services
    exit 1
  fi
  if ! mount -a; then
    echo "FEHLER: 'mount -a' ist fehlgeschlagen. Dienste werden wieder gestartet, soweit möglich." >&2
    restart_stopped_services
    exit 1
  fi
  restart_stopped_services
  offer_optional_btrfs_tools
  echo ">>> FERTIG. Neue Subvolumes sind aktiv:"
  for entry in "${MAPS[@]}"; do
    findmnt -no TARGET,SOURCE,OPTIONS "${entry%%:*}" || true
  done
else
  echo ">>> FERTIG."
  echo "Kontrolliere kurz mit:  cat /etc/fstab"
  echo "Wenn dort die neuen Btrfs-Zeilen stehen, dann:"
  echo "  mount -a"
  echo "Wenn keine Fehler kommen:"
  echo "  reboot"
  echo
  if [[ ${#STOPPED_SERVICES[@]} -gt 0 ]]; then
    echo "Folgende Dienste wurden für eine konsistente Kopie gestoppt und bleiben bis zum Reboot aus:"
    printf '  %s\n' "${STOPPED_SERVICES[@]}"
    echo
  fi
  echo "Nach dem Reboot sollte / von subvol=@ und /home, /var/log, /var/lib/docker usw. von den jeweiligen Subvolumes kommen."
  echo "Die alte fstab liegt gesichert unter ${FSTAB}.backup-<Datum>."
fi
