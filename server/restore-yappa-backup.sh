#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if [[ $# -ne 5 ]]; then
  cat >&2 <<'EOF'
Usage:
  ./restore-yappa-backup.sh BACKUP BUNDLE SHA256 /absolute/new/install parent

The fifth argument is the already-validated install parent used internally.
Use ./install-yappa.sh restore instead of invoking this helper directly.
EOF
  exit 1
fi

BACKUP="$1"
BUNDLE="$2"
EXPECTED_SHA256="$3"
INSTALL_DIRECTORY="$4"
INSTALL_PARENT="$5"

if [[ "$BACKUP" != /* ]]; then
  BACKUP="$PWD/$BACKUP"
fi
if [[ "$BUNDLE" != /* ]]; then
  BUNDLE="$PWD/$BUNDLE"
fi
if [[ ! -f "$BACKUP" || -L "$BACKUP" ]]; then
  echo "Encrypted Yappa backup was not found or is not a regular file." >&2
  exit 1
fi
if [[ ! -f "$BUNDLE" || -L "$BUNDLE" ]]; then
  echo "Local Yappa server bundle was not found or is not a regular file." >&2
  exit 1
fi
if [[ ! "$EXPECTED_SHA256" =~ ^[a-f0-9]{64}$ ]]; then
  echo "Restore bundle SHA-256 must be one full lowercase digest." >&2
  exit 1
fi
if [[ "$INSTALL_DIRECTORY" != /* || "$INSTALL_DIRECTORY" == "/" ]] ||
  [[ -e "$INSTALL_DIRECTORY" ]] ||
  [[ ! -d "$INSTALL_PARENT" ]] ||
  [[ ! -w "$INSTALL_PARENT" ]] ||
  [[ "$(dirname -- "$INSTALL_DIRECTORY")" != "$INSTALL_PARENT" ]]; then
  echo "Restore destination must be a new absolute child of the supplied parent." >&2
  exit 1
fi

AGE_BIN="${YAPPA_AGE_BIN:-}"
if [[ -z "$AGE_BIN" && -x "$SCRIPT_ROOT/bin/age" ]]; then
  AGE_BIN="$SCRIPT_ROOT/bin/age"
fi
if [[ -z "$AGE_BIN" ]]; then
  AGE_BIN="$(command -v age || true)"
fi
if [[ -z "$AGE_BIN" || ! -x "$AGE_BIN" ]]; then
  echo "Encrypted restore requires the age command." >&2
  exit 1
fi
for command_name in \
  tar sqlite3 mktemp find stat mv chmod mkdir rm dirname grep sed sort tail; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Encrypted restore requires $command_name." >&2
    exit 1
  fi
done

ASSEMBLY_ROOT="$(
  mktemp -d "$INSTALL_PARENT/.yappa-restore-assembly.XXXXXXXX"
)"
chmod 700 "$ASSEMBLY_ROOT"
RUNTIME_ROOT="$ASSEMBLY_ROOT/runtime"
RESTORED_ROOT="$ASSEMBLY_ROOT/restored"
mkdir -m 700 "$RESTORED_ROOT"
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  rm -rf -- "$ASSEMBLY_ROOT"
  exit "$status"
}
trap cleanup EXIT INT TERM

"$SCRIPT_ROOT/install-yappa.sh" install \
  --local-bundle "$BUNDLE" \
  --sha256 "$EXPECTED_SHA256" \
  --install-dir "$RUNTIME_ROOT" \
  --no-start

echo "Enter the backup passphrase when age prompts."
"$AGE_BIN" --decrypt "$BACKUP" |
  tar \
    --extract \
    --gzip \
    --file=- \
    --directory="$RESTORED_ROOT" \
    --no-same-owner \
    --no-same-permissions \
    --delay-directory-restore

if find "$RESTORED_ROOT" \
  \( -type l -o \( ! -type f -a ! -type d \) \) \
  -print -quit |
  grep -q .; then
  echo "Backup contains a symbolic link or unsupported file type." >&2
  exit 1
fi
mapfile -t TOP_LEVEL_ENTRIES < <(
  find "$RESTORED_ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
)
if [[ ${#TOP_LEVEL_ENTRIES[@]} -ne 2 ]] ||
  [[ "${TOP_LEVEL_ENTRIES[0]}" != ".env" ]] ||
  [[ "${TOP_LEVEL_ENTRIES[1]}" != "data" ]] ||
  [[ ! -f "$RESTORED_ROOT/.env" ]] ||
  [[ ! -d "$RESTORED_ROOT/data" ]]; then
  echo "Backup must contain only the required .env and data roots." >&2
  exit 1
fi

mapfile -d '' DATABASES < <(
  find "$RESTORED_ROOT/data" -type f -name '*.db' -print0
)
if [[ ${#DATABASES[@]} -ne 1 ]] || [[ -L "${DATABASES[0]}" ]]; then
  echo "Backup must contain exactly one regular Yappa database." >&2
  exit 1
fi
CONFIGURED_DB_PATH="$(
  sed -n 's/^[[:space:]]*DB_PATH[[:space:]]*=[[:space:]]*//p' \
    "$RESTORED_ROOT/.env" |
    tail -n 1
)"
CONFIGURED_DB_PATH="${CONFIGURED_DB_PATH:-./data/newchat.db}"
CONFIGURED_DB_PATH="${CONFIGURED_DB_PATH%\"}"
CONFIGURED_DB_PATH="${CONFIGURED_DB_PATH#\"}"
CONFIGURED_DB_PATH="${CONFIGURED_DB_PATH%\'}"
CONFIGURED_DB_PATH="${CONFIGURED_DB_PATH#\'}"
CONFIGURED_DB_PATH="${CONFIGURED_DB_PATH#./}"
if [[ "$CONFIGURED_DB_PATH" == /* ||
  "$CONFIGURED_DB_PATH" == ".." ||
  "$CONFIGURED_DB_PATH" == ../* ||
  "$CONFIGURED_DB_PATH" == */../* ||
  "$CONFIGURED_DB_PATH" == */.. ||
  "$CONFIGURED_DB_PATH" != data/* ]] ||
  [[ "$RESTORED_ROOT/$CONFIGURED_DB_PATH" != "${DATABASES[0]}" ]]; then
  echo "Backup DB_PATH must identify its single database inside data." >&2
  exit 1
fi
if [[ "$(sqlite3 "${DATABASES[0]}" 'PRAGMA quick_check;')" != "ok" ]]; then
  echo "Restored database failed its SQLite integrity check." >&2
  exit 1
fi
SCHEMA_VERSION="$(
  sqlite3 "${DATABASES[0]}" \
    "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;"
)"
CURRENT_SCHEMA="$(
  sed -n \
    's/^[[:space:]]*"databaseSchemaVersion":[[:space:]]*\([0-9][0-9]*\),*[[:space:]]*$/\1/p' \
    "$RUNTIME_ROOT/install-manifest.json"
)"
if [[ ! "$SCHEMA_VERSION" =~ ^[1-9][0-9]*$ ]] ||
  [[ -z "$CURRENT_SCHEMA" ]] ||
  ((SCHEMA_VERSION > CURRENT_SCHEMA)); then
  echo "Backup database schema is not supported by this Yappa bundle." >&2
  exit 1
fi

mapfile -d '' IDENTITY_FILES < <(
  find "$RESTORED_ROOT/data" -type f -name 'server-identity.json' -print0
)
if [[ ${#IDENTITY_FILES[@]} -ne 1 ]] ||
  [[ -L "${IDENTITY_FILES[0]}" ]]; then
  echo "Backup must contain exactly one regular persistent server identity." >&2
  exit 1
fi

chmod 600 "$RESTORED_ROOT/.env" "${IDENTITY_FILES[0]}"
chmod 700 "$RESTORED_ROOT/data"
mv -- "$RESTORED_ROOT/.env" "$RUNTIME_ROOT/.env"
mv -- "$RESTORED_ROOT/data" "$RUNTIME_ROOT/data"
chmod 700 "$RUNTIME_ROOT"

mv -- "$RUNTIME_ROOT" "$INSTALL_DIRECTORY"
trap - EXIT INT TERM
rm -rf -- "$ASSEMBLY_ROOT"

echo "Encrypted Yappa backup restored into a new installation."
echo "Destination: $INSTALL_DIRECTORY"
echo "Schema:      $SCHEMA_VERSION"
echo "The restored server is stopped. Review its configuration, then run:"
echo "$INSTALL_DIRECTORY/install-yappa.sh start"
