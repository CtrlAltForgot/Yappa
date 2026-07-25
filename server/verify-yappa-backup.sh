#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $# -ne 1 ]]; then
  echo "Usage: ./verify-yappa-backup.sh /path/to/yappa-backup.tar.gz.age"
  exit 1
fi

SCRIPT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
AGE_BIN="${YAPPA_AGE_BIN:-}"
if [[ -z "$AGE_BIN" && -x "$SCRIPT_ROOT/bin/age" ]]; then
  AGE_BIN="$SCRIPT_ROOT/bin/age"
fi
if [[ -z "$AGE_BIN" ]]; then
  AGE_BIN="$(command -v age || true)"
fi
if [[ -z "$AGE_BIN" || ! -x "$AGE_BIN" ]]; then
  echo "Backup verification requires age."
  exit 1
fi

for command_name in tar sqlite3 mktemp; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Backup verification requires ${command_name}."
    exit 1
  fi
done

BACKUP="$1"
if [[ "$BACKUP" != /* ]]; then
  BACKUP="${PWD}/${BACKUP}"
fi
if [[ ! -f "$BACKUP" ]]; then
  echo "Encrypted backup was not found: ${BACKUP}"
  exit 1
fi

RESTORE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/yappa-restore-test.XXXXXXXX")"
chmod 700 "$RESTORE_ROOT"
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  rm -rf -- "$RESTORE_ROOT"
  exit "$status"
}
trap cleanup EXIT INT TERM

echo "Enter the backup passphrase when age prompts."
"$AGE_BIN" --decrypt "$BACKUP" |
  tar \
    --extract \
    --gzip \
    --file=- \
    --directory="$RESTORE_ROOT" \
    --no-same-owner \
    --no-same-permissions

if [[ ! -f "$RESTORE_ROOT/.env" || ! -d "$RESTORE_ROOT/data" ]]; then
  echo "Backup is missing the required .env or data directory."
  exit 1
fi
chmod 600 "$RESTORE_ROOT/.env"

mapfile -d '' databases < <(
  find "$RESTORE_ROOT/data" -type f -name '*.db' -print0
)
if [[ ${#databases[@]} -ne 1 ]]; then
  echo "Backup must contain exactly one Yappa database."
  exit 1
fi

integrity="$(sqlite3 "${databases[0]}" 'PRAGMA quick_check;')"
if [[ "$integrity" != "ok" ]]; then
  echo "Restored database failed its SQLite integrity check."
  exit 1
fi

schema_version="$(sqlite3 "${databases[0]}" \
  "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;")"
user_count="$(sqlite3 "${databases[0]}" 'SELECT COUNT(*) FROM users;')"
message_count="$(sqlite3 "${databases[0]}" 'SELECT COUNT(*) FROM messages;')"

identity_count="$(
  find "$RESTORE_ROOT/data" -type f -name 'server-identity.json' |
    wc -l |
    tr -d '[:space:]'
)"
if [[ "$identity_count" != "1" ]]; then
  echo "Backup must contain exactly one persistent server identity."
  exit 1
fi

echo "Encrypted backup restore verification passed."
echo "Schema version: ${schema_version}"
echo "Users: ${user_count}"
echo "Legacy messages: ${message_count}"
echo "The isolated restored copy has been removed."
