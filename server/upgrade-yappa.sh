#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALL_PARENT="$(dirname -- "$SCRIPT_ROOT")"
INSTALL_NAME="$(basename -- "$SCRIPT_ROOT")"
ROLLBACK_ROOT="$INSTALL_PARENT/$INSTALL_NAME.rollback"

if [[ $# -ne 3 ]]; then
  echo "Use: ./install-yappa.sh upgrade --local-bundle BUNDLE --sha256 DIGEST --backup BACKUP" >&2
  exit 1
fi
BUNDLE="$1"
EXPECTED_SHA256="$2"
BACKUP="$3"
if [[ "$BACKUP" != /* ]]; then
  echo "The pre-upgrade backup path must be absolute." >&2
  exit 1
fi
if [[ -e "$BACKUP" || -e "$ROLLBACK_ROOT" ]]; then
  echo "Upgrade requires a new backup path and no existing rollback installation." >&2
  exit 1
fi
for command_name in mktemp cp mv rm dirname basename chmod sqlite3 sed tail; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Upgrade requires $command_name." >&2
    exit 1
  fi
done

ASSEMBLY_ROOT="$(mktemp -d "$INSTALL_PARENT/.yappa-upgrade-assembly.XXXXXXXX")"
chmod 700 "$ASSEMBLY_ROOT"
RUNTIME_ROOT="$ASSEMBLY_ROOT/runtime"
OLD_STOPPED=false
cleanup_before_swap() {
  local status=$?
  trap - EXIT INT TERM
  rm -rf -- "$ASSEMBLY_ROOT"
  if [[ "$OLD_STOPPED" == true ]]; then
    "$SCRIPT_ROOT/install-yappa.sh" start >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup_before_swap EXIT INT TERM

"$SCRIPT_ROOT/install-yappa.sh" verify
"$SCRIPT_ROOT/backup-yappa.sh" "$BACKUP"
"$SCRIPT_ROOT/verify-yappa-backup.sh" "$BACKUP"
"$SCRIPT_ROOT/install-yappa.sh" stop
OLD_STOPPED=true

"$SCRIPT_ROOT/install-yappa.sh" install \
  --local-bundle "$BUNDLE" \
  --sha256 "$EXPECTED_SHA256" \
  --install-dir "$RUNTIME_ROOT" \
  --no-start
cp -a -- "$SCRIPT_ROOT/.env" "$RUNTIME_ROOT/.env"
cp -a -- "$SCRIPT_ROOT/data" "$RUNTIME_ROOT/data"
chmod 600 "$RUNTIME_ROOT/.env"
chmod 700 "$RUNTIME_ROOT/data" "$RUNTIME_ROOT"

DB_PATH="$(
  sed -n 's/^[[:space:]]*DB_PATH[[:space:]]*=[[:space:]]*//p' \
    "$RUNTIME_ROOT/.env" |
    tail -n 1
)"
DB_PATH="${DB_PATH:-./data/newchat.db}"
DB_PATH="${DB_PATH%\"}"
DB_PATH="${DB_PATH#\"}"
DB_PATH="${DB_PATH%\'}"
DB_PATH="${DB_PATH#\'}"
DB_PATH="${DB_PATH#./}"
if [[ "$DB_PATH" == /* || "$DB_PATH" == ".." || "$DB_PATH" == ../* ||
  "$DB_PATH" == */../* || "$DB_PATH" == */.. || "$DB_PATH" != data/* ||
  ! -f "$RUNTIME_ROOT/$DB_PATH" || -L "$RUNTIME_ROOT/$DB_PATH" ]]; then
  echo "Upgrade database path must remain inside the copied data directory." >&2
  exit 1
fi
CURRENT_SCHEMA="$(
  sqlite3 "$RUNTIME_ROOT/$DB_PATH" \
    "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;"
)"
TARGET_SCHEMA="$(
  sed -n \
    's/^[[:space:]]*"databaseSchemaVersion":[[:space:]]*\([0-9][0-9]*\),*[[:space:]]*$/\1/p' \
    "$RUNTIME_ROOT/install-manifest.json"
)"
if [[ ! "$CURRENT_SCHEMA" =~ ^[1-9][0-9]*$ ||
  ! "$TARGET_SCHEMA" =~ ^[1-9][0-9]*$ ]] ||
  ((CURRENT_SCHEMA > TARGET_SCHEMA)); then
  echo "The selected bundle cannot open the current database schema." >&2
  exit 1
fi
if [[ "$(sqlite3 "$RUNTIME_ROOT/$DB_PATH" 'PRAGMA quick_check;')" != "ok" ]]; then
  echo "The copied upgrade database failed its SQLite integrity check." >&2
  exit 1
fi

trap - EXIT INT TERM
mv -- "$SCRIPT_ROOT" "$ROLLBACK_ROOT"
if ! mv -- "$RUNTIME_ROOT" "$SCRIPT_ROOT"; then
  mv -- "$ROLLBACK_ROOT" "$SCRIPT_ROOT"
  rm -rf -- "$ASSEMBLY_ROOT"
  "$SCRIPT_ROOT/install-yappa.sh" start >/dev/null 2>&1 || true
  echo "Upgrade swap failed; the previous installation was restored." >&2
  exit 1
fi
rm -rf -- "$ASSEMBLY_ROOT"

if "$SCRIPT_ROOT/install-yappa.sh" start &&
  "$SCRIPT_ROOT/install-yappa.sh" verify; then
  echo "Yappa upgrade completed and passed operational verification."
  echo "Encrypted recovery point: $BACKUP"
  echo "Rollback installation:     $ROLLBACK_ROOT"
  exit 0
fi

"$SCRIPT_ROOT/install-yappa.sh" stop >/dev/null 2>&1 || true
FAILED_ROOT="$INSTALL_PARENT/$INSTALL_NAME.failed-upgrade"
if [[ -e "$FAILED_ROOT" ]]; then
  echo "Upgrade failed and the reserved failed-upgrade path already exists." >&2
  echo "Manual recovery is required from $ROLLBACK_ROOT and $BACKUP." >&2
  exit 1
fi
mv -- "$SCRIPT_ROOT" "$FAILED_ROOT"
mv -- "$ROLLBACK_ROOT" "$SCRIPT_ROOT"
if ! "$SCRIPT_ROOT/install-yappa.sh" start ||
  ! "$SCRIPT_ROOT/install-yappa.sh" verify; then
  echo "Upgrade failed; the previous installation was restored but did not start." >&2
  echo "Recovery backup: $BACKUP" >&2
  exit 1
fi
echo "Upgrade verification failed; the previous installation was restored." >&2
echo "Failed candidate retained at: $FAILED_ROOT" >&2
exit 1
