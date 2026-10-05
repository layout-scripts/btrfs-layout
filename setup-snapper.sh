#!/usr/bin/env bash
set -euo pipefail

echo ">>> Snapper-Setup: root-Konfiguration + Timeline + apt-Hooks + grub-btrfs"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen." >&2
  exit 1
fi

ASSUME_YES=${LAYOUT_SCRIPT_ASSUME_YES:-0}
TOPLEVEL_MNT=""
GUARD_SNAPSHOT=""
APT_UPDATED=0
GRUB_BTRFSD_DROPIN=/etc/systemd/system/grub-btrfsd.service.d/90-layout-script.conf

cleanup() {
  if [[ -n "$TOPLEVEL_MNT" && -d "$TOPLEVEL_MNT" ]]; then
    umount "$TOPLEVEL_MNT" 2>/dev/null || true
    rmdir "$TOPLEVEL_MNT" 2>/dev/null || true
  fi
}
trap cleanup EXIT

apt_package_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

need_pkg() {
  local cmd="$1" pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo ">>> Abhängigkeit $pkg ($cmd) ist bereits vorhanden."
    return 0
  fi

  echo ">>> Installiere benötigtes Paket: $pkg"
  ensure_apt_updated
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
}

# Sorgt dafuer, dass apt-get update genau einmal pro Skriptlauf ausgefuehrt
# wird, egal wie oft need_pkg() aufgerufen wird - vermeidet redundante
# Netzwerk-/Index-Aktualisierungen bei mehreren benoetigten Paketen.
ensure_apt_updated() {
  if [[ "$APT_UPDATED" != "1" ]]; then
    echo ">>> Aktualisiere apt-Paketindex"
    apt-get update
    APT_UPDATED=1
  fi
}

confirm_or_abort() {
  # ASSUME_YES wird zuerst geprueft: ein explizit gesetztes
  # LAYOUT_SCRIPT_ASSUME_YES=1 soll die Abfrage auch dann ueberspringen,
  # wenn stdin ein TTY ist (z.B. ssh -t, docker run -it, manche
  # Ansible-Konfigurationen) - sonst haengt eine Automatisierung trotz
  # gesetztem Bypass an der interaktiven Nachfrage fest.
  if [[ "$ASSUME_YES" == "1" ]]; then
    echo ">>> LAYOUT_SCRIPT_ASSUME_YES=1 gesetzt, Bestätigung übersprungen."
  elif [[ -t 0 ]]; then
    read -r -p "Guard-Snapshot erstellen und Snapper einrichten? Exakt 'ja' eingeben: " CONFIRM
    if [[ "$CONFIRM" != "ja" ]]; then
      echo "Abgebrochen." >&2
      exit 1
    fi
  else
    echo "FEHLER: Kein interaktives Terminal. Setze LAYOUT_SCRIPT_ASSUME_YES=1 für automatisierte Läufe." >&2
    exit 1
  fi
}

require_command() {
  local cmd="$1" hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "FEHLER: Benötigtes Kommando '$cmd' fehlt. $hint" >&2
    exit 1
  fi
}

configure_grub_btrfsd() {
  local dropin_dir grub_btrfsd_bin

  grub_btrfsd_bin=$(command -v grub-btrfsd)
  if ! systemctl list-unit-files grub-btrfsd.service 2>/dev/null | grep -q '^grub-btrfsd\.service'; then
    echo "FEHLER: grub-btrfsd.service wurde trotz installiertem grub-btrfs nicht gefunden." >&2
    exit 1
  fi

  if [[ -d "$GRUB_BTRFSD_DROPIN" || -L "$GRUB_BTRFSD_DROPIN" ]]; then
    echo "FEHLER: Drop-in-Ziel ist kein verwaltbares normales File: $GRUB_BTRFSD_DROPIN" >&2
    exit 1
  fi
  if [[ -e "$GRUB_BTRFSD_DROPIN" ]] && ! grep -Eq '^# Managed by debian-btrfs/layout-script setup-(snapper|timeshift)\.sh$' "$GRUB_BTRFSD_DROPIN"; then
    echo "FEHLER: Vorhandenes fremdes grub-btrfsd-Drop-in wird nicht überschrieben: $GRUB_BTRFSD_DROPIN" >&2
    echo "Bitte das Drop-in prüfen oder entfernen und setup-snapper.sh danach erneut ausführen." >&2
    exit 1
  fi

  dropin_dir=$(dirname "$GRUB_BTRFSD_DROPIN")
  install -d -m 0755 "$dropin_dir"
  cat > "$GRUB_BTRFSD_DROPIN" <<EOF
# Managed by debian-btrfs/layout-script setup-snapper.sh
[Service]
ExecStart=
ExecStart=$grub_btrfsd_bin --syslog /.snapshots
EOF

  echo ">>> Konfiguriere grub-btrfsd für Snapper (überwacht /.snapshots)"
  systemctl daemon-reload
  systemctl enable grub-btrfsd.service
  if systemctl is-active --quiet grub-btrfsd.service; then
    systemctl restart grub-btrfsd.service
  else
    systemctl start grub-btrfsd.service
  fi
}

echo ">>> Prüfe Voraussetzungen"
require_command findmnt "Bitte util-linux installieren."
require_command blkid "Bitte util-linux/blkid installieren."
require_command btrfs "Bitte zuerst btrfs-progs installieren."

if [[ ! -w /etc/fstab ]]; then
  echo "FEHLER: /etc/fstab ist nicht beschreibbar." >&2
  exit 1
fi

FSTYPE=$(findmnt -no FSTYPE / || true)
if [[ "$FSTYPE" != "btrfs" ]]; then
  echo "/ ist kein Btrfs-Dateisystem (FSTYPE=$FSTYPE). Abbruch." >&2
  exit 1
fi

ROOT_SRC=$(findmnt -no SOURCE / || true)
if [[ -z "$ROOT_SRC" || "$ROOT_SRC" != *"["* ]]; then
  echo "FEHLER: / läuft nicht von einem benannten Subvolume (aktuell: ${ROOT_SRC:-unbekannt})." >&2
  echo "Bitte zuerst debian-btrfs/layout-script/setup-btrfs.sh ausführen." >&2
  exit 1
fi

ROOT_DEV=${ROOT_SRC%%[*}
UUID=$(blkid -s UUID -o value "$ROOT_DEV" || true)
if [[ -z "$UUID" ]]; then
  echo "Konnte UUID von $ROOT_DEV nicht ermitteln. Abbruch." >&2
  exit 1
fi

ROOT_SUBVOL=$(echo "$ROOT_SRC" | sed -E 's/.*\[\/(.*)\]/\1/')
if [[ -z "$ROOT_SUBVOL" || "$ROOT_SUBVOL" == "$ROOT_SRC" ]]; then
  echo "Konnte Root-Subvolume aus '$ROOT_SRC' nicht zuverlässig ermitteln. Abbruch." >&2
  exit 1
fi
SNAPSHOTS_SUBVOL="${ROOT_SUBVOL}/.snapshots"

echo ">>> Root-Device: ${ROOT_DEV}"
echo ">>> Root-Subvolume: ${ROOT_SUBVOL}"
echo ">>> Geplantes Snapshot-Subvolume: ${SNAPSHOTS_SUBVOL}"

# Paketindex jetzt aktualisieren, nicht erst beim ersten need_pkg-Aufruf:
# auf einem frischen/geleerten apt-Cache waeren die folgenden
# apt_package_available-Pruefungen sonst faelschlich negativ und wuerden
# das Skript unnoetig abbrechen lassen.
ensure_apt_updated

if ! apt_package_available snapper && ! package_installed snapper; then
  echo "FEHLER: Paket 'snapper' ist in den konfigurierten APT-Quellen nicht verfügbar." >&2
  exit 1
fi
if ! apt_package_available inotify-tools && ! package_installed inotify-tools; then
  echo "FEHLER: Paket 'inotify-tools' ist in den konfigurierten APT-Quellen nicht verfügbar." >&2
  exit 1
fi

GRUB_BTRFS_AVAILABLE=0
if apt_package_available grub-btrfs || package_installed grub-btrfs; then
  GRUB_BTRFS_AVAILABLE=1
else
  echo "WARNUNG: Paket grub-btrfs ist nicht verfügbar; GRUB-Snapshot-Menü wird übersprungen." >&2
fi

echo
echo "!!! ACHTUNG !!!"
echo "Dieses Skript verändert einen laufenden Server: Es installiert Pakete,"
echo "legt Snapper für / an, schreibt /.snapshots in /etc/fstab, aktiviert"
echo "Timer und apt-Hooks und aktualisiert optional GRUB für grub-btrfs."
echo "Vor der ersten Änderung wird ein read-only Btrfs-Guard-Snapshot des"
echo "aktuellen Root-Subvolumes erstellt."
echo
confirm_or_abort

create_guard_snapshot() {
  local timestamp src parent base dest existing_guards

  timestamp=$(date +%F-%H%M%S)
  TOPLEVEL_MNT=$(mktemp -d /mnt/btrfs-toplevel.XXXXXX)
  echo ">>> Mounte Btrfs-Top-Level nach $TOPLEVEL_MNT"
  mount -o subvolid=5 "$ROOT_DEV" "$TOPLEVEL_MNT"

  src="$TOPLEVEL_MNT/$ROOT_SUBVOL"
  if [[ ! -d "$src" ]]; then
    echo "FEHLER: Root-Subvolume wurde unter $src nicht gefunden." >&2
    exit 1
  fi

  # Guard-Snapshots werden bewusst dauerhaft aufbewahrt (siehe Rollback-
  # Hinweis am Skriptende) und nie automatisch geloescht - daher hier
  # zumindest auf bereits vorhandene aus frueheren Laeufen hinweisen, statt
  # sie stillschweigend unbemerkt weiter anwachsen zu lassen.
  existing_guards=$(btrfs subvolume list "$TOPLEVEL_MNT" | awk '{print $NF}' | grep -- '\.before-snapper-setup-' || true)
  if [[ -n "$existing_guards" ]]; then
    echo ">>> Hinweis: Guard-Snapshot(s) aus früheren Läufen gefunden (werden nicht automatisch gelöscht):"
    while IFS= read -r guard; do
      printf '    %s\n' "$guard"
    done <<< "$existing_guards"
  fi

  parent=$(dirname "$ROOT_SUBVOL")
  base=$(basename "$ROOT_SUBVOL")
  if [[ "$parent" == "." ]]; then
    dest="$TOPLEVEL_MNT/${base}.before-snapper-setup-${timestamp}"
    GUARD_SNAPSHOT="${base}.before-snapper-setup-${timestamp}"
  else
    dest="$TOPLEVEL_MNT/${parent}/${base}.before-snapper-setup-${timestamp}"
    GUARD_SNAPSHOT="${parent}/${base}.before-snapper-setup-${timestamp}"
  fi

  if [[ -e "$dest" ]]; then
    echo "FEHLER: Guard-Snapshot-Ziel existiert bereits: $dest" >&2
    exit 1
  fi

  echo ">>> Erzeuge read-only Guard-Snapshot: $GUARD_SNAPSHOT"
  btrfs subvolume snapshot -r "$src" "$dest"
  echo ">>> Guard-Snapshot erstellt: $GUARD_SNAPSHOT"

  # Top-Level-Mount wird nur fuer die Snapshot-Erzeugung selbst benoetigt -
  # sofort wieder aushaengen statt ihn ueber den kompletten restlichen
  # Skriptlauf (Paketinstallation, fstab-Aenderung, GRUB-Update) offenzuhalten.
  echo ">>> Hänge Btrfs-Top-Level wieder aus (nur für den Guard-Snapshot benötigt)"
  umount "$TOPLEVEL_MNT"
  rmdir "$TOPLEVEL_MNT"
  TOPLEVEL_MNT=""
}

create_guard_snapshot

echo ">>> Installiere benötigte Pakete"
need_pkg snapper snapper
need_pkg inotifywait inotify-tools

if [[ -f /etc/snapper/configs/root ]]; then
  echo ">>> snapper-Konfiguration 'root' existiert bereits, überspringe create-config."
else
  echo ">>> Erzeuge snapper-Konfiguration 'root' (legt .snapshots als Subvolume an)"
  snapper -c root create-config /
fi

FSTAB=/etc/fstab
FSTAB_BACKUP=""
restore_fstab_backup() {
  if [[ -n "$FSTAB_BACKUP" && -f "$FSTAB_BACKUP" ]]; then
    echo ">>> Stelle alte fstab aus $FSTAB_BACKUP wieder her"
    cp "$FSTAB_BACKUP" "$FSTAB"
    systemctl daemon-reload || true
  fi
}

EXISTING_SNAPSHOTS_LINE=$(grep -E '^[^#[:space:]]+[[:space:]]+/\.snapshots[[:space:]]+btrfs' "$FSTAB" || true)
if [[ -n "$EXISTING_SNAPSHOTS_LINE" ]]; then
  # Nicht nur pruefen, DASS eine /.snapshots-Zeile existiert, sondern auch,
  # ob ihr subvol= tatsaechlich zum aktuell berechneten Subvolume passt -
  # sonst wuerde ein Eintrag aus einem frueheren Lauf (anderes ROOT_SUBVOL)
  # oder eine manuelle Aenderung stillschweigend uebernommen.
  EXISTING_SUBVOL=$(echo "$EXISTING_SNAPSHOTS_LINE" | grep -oE 'subvol=[^, ]+' | head -1 | cut -d= -f2)
  if [[ "$EXISTING_SUBVOL" == "$SNAPSHOTS_SUBVOL" ]]; then
    echo ">>> fstab: Eintrag für /.snapshots existiert bereits und passt (subvol=${EXISTING_SUBVOL}), überspringe."
  else
    echo "FEHLER: /.snapshots hat bereits einen fstab-Eintrag mit abweichendem subvol." >&2
    echo "Gefunden: '${EXISTING_SUBVOL:-<leer>}', erwartet: '${SNAPSHOTS_SUBVOL}'." >&2
    echo "Bitte ${FSTAB} manuell prüfen und den vorhandenen Eintrag korrigieren oder entfernen." >&2
    exit 1
  fi
else
  FSTAB_BACKUP="${FSTAB}.backup-$(date +%F-%H%M%S)"
  echo ">>> Sicherung der aktuellen fstab nach $FSTAB_BACKUP"
  cp "$FSTAB" "$FSTAB_BACKUP"
  echo "UUID=${UUID} /.snapshots btrfs noatime,compress=zstd,space_cache=v2,subvol=${SNAPSHOTS_SUBVOL} 0 0" >> "$FSTAB"
  echo ">>> fstab: Eintrag für /.snapshots hinzugefügt."
fi

mkdir -p /.snapshots || { echo "FEHLER: Konnte /.snapshots nicht anlegen." >&2; restore_fstab_backup; exit 1; }
echo ">>> Prüfe und aktiviere den neuen Mount"
systemctl daemon-reload || { echo "FEHLER: 'systemctl daemon-reload' ist fehlgeschlagen." >&2; restore_fstab_backup; exit 1; }
if ! findmnt --verify; then
  echo "FEHLER: 'findmnt --verify' hat Probleme in der neuen fstab gefunden." >&2
  restore_fstab_backup
  exit 1
fi
if ! mount -a; then
  echo "FEHLER: 'mount -a' ist fehlgeschlagen." >&2
  restore_fstab_backup
  exit 1
fi
findmnt -no TARGET,SOURCE,OPTIONS /.snapshots

set_snapper_config() {
  local key="$1" value="$2"
  snapper -c root set-config "${key}=${value}"
}

echo ">>> Setze Timeline-Policy in snapper-Konfiguration root"
set_snapper_config TIMELINE_CREATE yes
set_snapper_config TIMELINE_CLEANUP yes
set_snapper_config NUMBER_CLEANUP yes
set_snapper_config NUMBER_LIMIT 50
set_snapper_config TIMELINE_LIMIT_HOURLY 10
set_snapper_config TIMELINE_LIMIT_DAILY 10
set_snapper_config TIMELINE_LIMIT_WEEKLY 4
set_snapper_config TIMELINE_LIMIT_MONTHLY 6
set_snapper_config TIMELINE_LIMIT_YEARLY 2

install_apt_hooks() {
  local pre_script="/usr/local/sbin/snapper-apt-pre"
  local post_script="/usr/local/sbin/snapper-apt-post"
  local hook_conf="/etc/apt/apt.conf.d/80snapper"
  local marker="# Managed by debian-btrfs/layout-script setup-snapper.sh"
  local legacy_marker="# Managed by layout-scripts/snapper-layout-script"
  local hook_content
  hook_content=$(printf '%s\nDPkg::Pre-Invoke {"%s";};\nDPkg::Post-Invoke {"%s";};\n' \
    "$marker" "$pre_script" "$post_script")

  # Statt eines starren Marker-ODER-Legacy-Zeilenvergleichs (der schon an
  # trivialen Formatierungsunterschieden scheitert und im Trefferfall die
  # Datei trotzdem bedingungslos ueberschrieb) wird der tatsaechliche
  # Zielinhalt direkt mit dem Ist-Zustand verglichen: identisch -> idempotent
  # ueberspringen, fremd (kein Marker) -> abbrechen, eigener aber veralteter
  # Inhalt -> aktualisieren.
  if [[ -f "$hook_conf" ]]; then
    if [[ "$(cat "$hook_conf")" == "$hook_content" ]]; then
      echo ">>> apt-Hooks für snapper sind bereits aktuell ($hook_conf), überspringe."
      return 0
    fi
    if ! grep -Fqx "$marker" "$hook_conf" && ! grep -Fqx "$legacy_marker" "$hook_conf"; then
      # Das Paket snapper liefert unter genau diesem Namen eigene Hooks (Conffile). Sie wuerden
      # zusaetzlich zu unseren laufen und doppelte Snapshots anlegen. Per dpkg-divert beiseite
      # legen: Die Datei bleibt erhalten, Paket-Updates schreiben in die umgeleitete Datei, und
      # apt ignoriert die Endung ".distrib". Alles andere ist wirklich fremd: abbrechen.
      owner=$(dpkg -S "$hook_conf" 2>/dev/null | head -n1 | cut -d: -f1 || true)
      if [[ "$owner" == "snapper" ]]; then
        echo ">>> $hook_conf gehört zum Paket snapper und wird per dpkg-divert nach ${hook_conf}.distrib verlegt."
        dpkg-divert --local --rename --divert "${hook_conf}.distrib" --add "$hook_conf"
      else
        echo "FEHLER: $hook_conf existiert, ist aber nicht von diesem Skript verwaltet." >&2
        echo "Bitte manuell prüfen oder verschieben, damit keine fremden apt-Hooks überschrieben werden." >&2
        exit 1
      fi
    fi
    if [[ -f "$hook_conf" ]]; then
      echo ">>> apt-Hooks für snapper sind veraltet, aktualisiere $hook_conf"
    else
      echo ">>> Installiere apt-Hooks für Pre-/Post-Snapshots: $pre_script, $post_script, $hook_conf"
    fi
  else
    echo ">>> Installiere apt-Hooks für Pre-/Post-Snapshots: $pre_script, $post_script, $hook_conf"
  fi

  cat > "$pre_script" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

NUMBER_FILE="/run/snapper-apt-pre-number"

number=$(snapper -c root create -t pre --print-number \
  --description "apt: $(date '+%F %T')" 2>/dev/null) || {
  echo "snapper-apt-pre: konnte keinen Pre-Snapshot anlegen, apt läuft trotzdem weiter." >&2
  rm -f "$NUMBER_FILE"
  exit 0
}

echo "$number" > "$NUMBER_FILE"
exit 0
EOF
  chmod 755 "$pre_script"

  cat > "$post_script" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

NUMBER_FILE="/run/snapper-apt-pre-number"

[[ -f "$NUMBER_FILE" ]] || exit 0

pre_number=$(cat "$NUMBER_FILE")
rm -f "$NUMBER_FILE"

snapper -c root create -t post --pre-number "$pre_number" \
  --description "apt: $(date '+%F %T')" >/dev/null 2>&1 || \
  echo "snapper-apt-post: konnte keinen Post-Snapshot zu Pre #$pre_number anlegen." >&2

exit 0
EOF
  chmod 755 "$post_script"

  printf '%s' "$hook_content" > "$hook_conf"
}

install_apt_hooks

for unit in snapper-timeline.timer snapper-cleanup.timer; do
  if systemctl list-unit-files "$unit" >/dev/null 2>&1 && systemctl list-unit-files "$unit" | grep -q "$unit"; then
    echo ">>> Aktiviere $unit"
    systemctl enable --now "$unit"
  else
    echo "WARNUNG: Unit $unit nicht gefunden – bitte snapper-Paketversion prüfen." >&2
  fi
done

if [[ "$GRUB_BTRFS_AVAILABLE" == "1" ]]; then
  need_pkg grub-mkconfig grub-common 2>/dev/null || true
  need_pkg grub-btrfsd grub-btrfs
  configure_grub_btrfsd

  if command -v update-grub >/dev/null 2>&1; then
    echo ">>> update-grub ausführen"
    update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    echo ">>> grub-mkconfig -o /boot/grub/grub.cfg ausführen"
    grub-mkconfig -o /boot/grub/grub.cfg
  else
    echo "WARNUNG: Weder update-grub noch grub-mkconfig gefunden – GRUB-Menü nicht aktualisiert." >&2
  fi
else
  echo ">>> grub-btrfs wurde übersprungen, weil das Paket nicht verfügbar ist."
fi

echo
echo ">>> FERTIG."
echo "Guard-Snapshot vor der Einrichtung:"
echo "  $GUARD_SNAPSHOT"
echo
echo "Kontrolle:"
echo "  snapper list-configs"
echo "  snapper create -d test && snapper list && snapper delete <Nummer>"
echo "  systemctl status snapper-timeline.timer snapper-cleanup.timer grub-btrfsd"
echo
echo "Rollback-Hinweis:"
echo "Der Guard-Snapshot ist read-only. Für eine Wiederherstellung von einem"
echo "Rettungssystem booten, das Btrfs-Top-Level mounten, aus dem Guard-Snapshot"
echo "einen neuen schreibbaren Root-Snapshot erzeugen und Bootloader/fstab passend"
echo "auf diesen Stand zurückstellen."
echo
echo "Hinweis zu den Grenzen dieses Setups:"
echo "Snapshot-Browsing, Diff und ein read-only-Boot einzelner Snapshots über"
echo "das GRUB-Menü (grub-btrfs) funktionieren, wenn grub-btrfs verfügbar ist."
echo "Ein vollständiger bootbarer System-Rollback wie unter openSUSE setzt"
echo "zusätzlich voraus, dass root direkt aus einem .snapshots/<N>/snapshot-"
echo "Subvolume läuft; das ist mit diesem @-Layout nicht automatisch der Fall."
