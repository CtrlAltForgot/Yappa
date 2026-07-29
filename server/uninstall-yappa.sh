#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALL_PARENT="$(dirname -- "$SCRIPT_ROOT")"
INSTALL_NAME="$(basename -- "$SCRIPT_ROOT")"
TOMBSTONE_ROOT="$INSTALL_PARENT/.$INSTALL_NAME.uninstalling"

if [[ $# -ne 2 || "$1" != /* || "$2" != /* || "$2" == "/" ]]; then
  echo "Use: ./install-yappa.sh uninstall --backup /absolute/new/backup --preserve-data /absolute/new/state" >&2
  exit 1
fi
BACKUP="$1"
PRESERVE_DIRECTORY="$2"
PRESERVE_PARENT="$(dirname -- "$PRESERVE_DIRECTORY")"
if [[ -e "$BACKUP" || -e "$PRESERVE_DIRECTORY" ||
  ! -d "$PRESERVE_PARENT" || ! -w "$PRESERVE_PARENT" ||
  -e "$TOMBSTONE_ROOT" ]]; then
  echo "Uninstall requires fresh backup/preservation paths and writable parents." >&2
  exit 1
fi
if [[ -e "$SCRIPT_ROOT/data/service-registration" ]]; then
  echo "Remove Yappa service registration before uninstalling." >&2
  exit 1
fi
for retained_suffix in rollback pre-rollback failed-upgrade; do
  if [[ -e "$INSTALL_PARENT/$INSTALL_NAME.$retained_suffix" ]]; then
    echo "Resolve the retained .$retained_suffix installation before uninstalling." >&2
    exit 1
  fi
done
for command_name in mktemp cp mv rm dirname basename chmod; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Uninstall requires $command_name." >&2
    exit 1
  fi
done

ASSEMBLY_ROOT="$(mktemp -d "$PRESERVE_PARENT/.yappa-uninstall-state.XXXXXXXX")"
chmod 700 "$ASSEMBLY_ROOT"
STATE_ROOT="$ASSEMBLY_ROOT/state"
mkdir -m 700 "$STATE_ROOT"
SERVER_STOPPED=false
cleanup_before_removal() {
  local status=$?
  trap - EXIT INT TERM
  rm -rf -- "$ASSEMBLY_ROOT"
  if [[ "$SERVER_STOPPED" == true && -d "$SCRIPT_ROOT" ]]; then
    "$SCRIPT_ROOT/install-yappa.sh" start >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup_before_removal EXIT INT TERM

"$SCRIPT_ROOT/install-yappa.sh" verify
"$SCRIPT_ROOT/backup-yappa.sh" "$BACKUP"
"$SCRIPT_ROOT/verify-yappa-backup.sh" "$BACKUP"
"$SCRIPT_ROOT/install-yappa.sh" stop
SERVER_STOPPED=true

cp -a -- "$SCRIPT_ROOT/.env" "$STATE_ROOT/.env"
cp -a -- "$SCRIPT_ROOT/data" "$STATE_ROOT/data"
chmod 600 "$STATE_ROOT/.env"
chmod 700 "$STATE_ROOT/data" "$STATE_ROOT"

trap - EXIT INT TERM
mv -- "$SCRIPT_ROOT" "$TOMBSTONE_ROOT"
if ! mv -- "$STATE_ROOT" "$PRESERVE_DIRECTORY"; then
  mv -- "$TOMBSTONE_ROOT" "$SCRIPT_ROOT"
  rm -rf -- "$ASSEMBLY_ROOT"
  "$SCRIPT_ROOT/install-yappa.sh" start >/dev/null 2>&1 || true
  echo "Uninstall state placement failed; the server installation was restored." >&2
  exit 1
fi
rm -rf -- "$ASSEMBLY_ROOT"
if ! rm -rf -- "$TOMBSTONE_ROOT"; then
  echo "Data was preserved, but runtime cleanup failed at $TOMBSTONE_ROOT." >&2
  exit 1
fi

echo "Yappa server runtime was uninstalled."
echo "Encrypted recovery point: $BACKUP"
echo "Preserved server state:    $PRESERVE_DIRECTORY"
echo "Restore that state only through a checksum-pinned Yappa bundle."
