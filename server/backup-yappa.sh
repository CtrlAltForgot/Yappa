#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT_DIR"

if [[ $# -ne 1 ]]; then
  echo "Usage: ./backup-yappa.sh /path/to/yappa-backup-YYYY-MM-DD.tar.gz.age"
  exit 1
fi

AGE_BIN="${YAPPA_AGE_BIN:-}"
if [[ -z "$AGE_BIN" && -x "$ROOT_DIR/bin/age" ]]; then
  AGE_BIN="$ROOT_DIR/bin/age"
fi
if [[ -z "$AGE_BIN" ]]; then
  AGE_BIN="$(command -v age || true)"
fi
if [[ -z "$AGE_BIN" || ! -x "$AGE_BIN" ]]; then
  echo "Encrypted backups require the age command."
  echo "Install age from your operating system's trusted package source, then retry."
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required to safely pause and resume the Yappa backend."
  exit 1
fi
if [[ ! -f .env || ! -d data ]]; then
  echo "No initialized Yappa installation was found in ${ROOT_DIR}."
  exit 1
fi

TARGET="$1"
if [[ "$TARGET" != /* ]]; then
  TARGET="${PWD}/${TARGET}"
fi
if [[ -e "$TARGET" ]]; then
  echo "Refusing to overwrite existing backup: ${TARGET}"
  exit 1
fi
TARGET_DIR="$(dirname -- "$TARGET")"
if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Backup destination directory does not exist: ${TARGET_DIR}"
  exit 1
fi

TEMP_TARGET="${TARGET}.partial"
BACKEND_WAS_RUNNING=false
cleanup() {
  local status=$?
  if [[ -e "$TEMP_TARGET" ]]; then
    rm -f -- "$TEMP_TARGET"
  fi
  if [[ "$BACKEND_WAS_RUNNING" == true ]]; then
    docker compose start newchat-node >/dev/null
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

if [[ "$(docker inspect -f '{{.State.Running}}' newchat-node 2>/dev/null || true)" == "true" ]]; then
  BACKEND_WAS_RUNNING=true
  echo "Pausing the Yappa backend for a consistent database snapshot."
  docker compose stop newchat-node >/dev/null
fi

echo "Enter a strong backup passphrase when age prompts."
tar \
  --create \
  --gzip \
  --file=- \
  --directory="$ROOT_DIR" \
  .env \
  data \
  | "$AGE_BIN" --passphrase --output "$TEMP_TARGET"

chmod 600 "$TEMP_TARGET"
mv -- "$TEMP_TARGET" "$TARGET"

if [[ "$BACKEND_WAS_RUNNING" == true ]]; then
  docker compose start newchat-node >/dev/null
  BACKEND_WAS_RUNNING=false
fi
trap - EXIT INT TERM

echo "Encrypted Yappa backup created: ${TARGET}"
echo "Store its passphrase separately. Without it, the backup cannot be recovered."
