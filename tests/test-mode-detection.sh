#!/usr/bin/env bash
# Prueft die Moduserkennung und Argumentbehandlung von setup-btrfs.sh ohne Root und ohne Btrfs.
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO_DIR/setup-btrfs.sh"

# Funktionen laden, ohne dass das Skript etwas ausfuehrt.
# shellcheck source=../setup-btrfs.sh
SETUP_BTRFS_SOURCE_ONLY=1 source "$SCRIPT"

fail=0
check() { # Beschreibung erwartet tatsaechlich
  if [[ "$2" == "$3" ]]; then
    printf '  ok    %s\n' "$1"
  else
    printf '  FAIL  %s (erwartet "%s", war "%s")\n' "$1" "$2" "$3"
    fail=1
  fi
}

check "Subvolume aus /dev/vda2[/@rootfs]" "/@rootfs" "$(root_subvol_of '/dev/vda2[/@rootfs]')"
check "Subvolume aus /dev/vda3[/@]"       "/@"       "$(root_subvol_of '/dev/vda3[/@]')"
check "Top-Level hat kein Subvolume"      ""         "$(root_subvol_of '/dev/vda2')"

check "Top-Level -> initial"                     initial     "$(detect_mode '/dev/vda2' 0)"
check "Top-Level + --finish-migration -> initial" initial     "$(detect_mode '/dev/vda2' 1)"
check "von @ -> incremental"                     incremental "$(detect_mode '/dev/vda3[/@]' 0)"
check "von @rootfs -> incremental"               incremental "$(detect_mode '/dev/vda2[/@rootfs]' 0)"
check "von @rootfs + --finish-migration -> finish" finish    "$(detect_mode '/dev/vda2[/@rootfs]' 1)"
check "von @ + --finish-migration -> done"       "done"      "$(detect_mode '/dev/vda3[/@]' 1)"

# Argumente: unbekannte Option und sich ausschliessende Modi muessen scheitern (ohne Root-Pruefung).
if "$SCRIPT" --gibt-es-nicht >/dev/null 2>&1; then
  echo "  FAIL  unbekannte Option wurde akzeptiert"; fail=1
else
  echo "  ok    unbekannte Option wird abgelehnt"
fi
if "$SCRIPT" --finish-migration --cleanup-old-root >/dev/null 2>&1; then
  echo "  FAIL  --finish-migration und --cleanup-old-root gleichzeitig akzeptiert"; fail=1
else
  echo "  ok    --finish-migration und --cleanup-old-root schliessen sich aus"
fi
if "$SCRIPT" --fix-boot --cleanup-old-root >/dev/null 2>&1; then
  echo "  FAIL  --fix-boot und --cleanup-old-root gleichzeitig akzeptiert"; fail=1
else
  echo "  ok    --fix-boot und --cleanup-old-root schliessen sich aus"
fi
if ! "$SCRIPT" --help | grep -q -- '--fix-boot'; then
  echo "  FAIL  --help nennt --fix-boot nicht"; fail=1
else
  echo "  ok    --help nennt --fix-boot"
fi
if ! "$SCRIPT" --help | grep -q -- '--finish-migration'; then
  echo "  FAIL  --help nennt --finish-migration nicht"; fail=1
else
  echo "  ok    --help nennt --finish-migration"
fi

# Neue Mappings muessen vorhanden sein und zu den Optionstabellen passen.
for sub in @microk8s @k8s-storage @journal-remote; do
  if grep -Fq ":$sub\"" "$SCRIPT" && grep -Fq "[$sub]=" "$SCRIPT"; then
    echo "  ok    Mapping $sub vorhanden"
  else
    echo "  FAIL  Mapping $sub fehlt"; fail=1
  fi
done

if [[ $fail -ne 0 ]]; then exit 1; fi
echo "OK: Moduserkennung und Argumente von setup-btrfs.sh."
