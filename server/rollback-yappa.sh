#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALL_PARENT="$(dirname -- "$SCRIPT_ROOT")"
INSTALL_NAME="$(basename -- "$SCRIPT_ROOT")"
ROLLBACK_ROOT="$INSTALL_PARENT/$INSTALL_NAME.rollback"
PRE_ROLLBACK_ROOT="$INSTALL_PARENT/$INSTALL_NAME.pre-rollback"

if [[ $# -ne 1 || "$1" != /* ]]; then
  echo "Use: ./install-yappa.sh rollback --backup /absolute/new/backup.tar.gz.age" >&2
  exit 1
fi
BACKUP="$1"
if [[ -e "$BACKUP" || ! -d "$ROLLBACK_ROOT" ||
  ! -x "$ROLLBACK_ROOT/install-yappa.sh" ||
  -e "$PRE_ROLLBACK_ROOT" ]]; then
  echo "Rollback requires a new backup path, a valid rollback installation, and no pre-rollback directory." >&2
  exit 1
fi

"$SCRIPT_ROOT/backup-yappa.sh" "$BACKUP"
"$SCRIPT_ROOT/verify-yappa-backup.sh" "$BACKUP"
"$SCRIPT_ROOT/install-yappa.sh" stop

mv -- "$SCRIPT_ROOT" "$PRE_ROLLBACK_ROOT"
if ! mv -- "$ROLLBACK_ROOT" "$SCRIPT_ROOT"; then
  mv -- "$PRE_ROLLBACK_ROOT" "$SCRIPT_ROOT"
  "$SCRIPT_ROOT/install-yappa.sh" start >/dev/null 2>&1 || true
  echo "Rollback swap failed; the newer installation was restored." >&2
  exit 1
fi
if "$SCRIPT_ROOT/install-yappa.sh" start &&
  "$SCRIPT_ROOT/install-yappa.sh" verify; then
  echo "Yappa rollback completed and passed operational verification."
  echo "Newer state backup:       $BACKUP"
  echo "Newer installation copy: $PRE_ROLLBACK_ROOT"
  exit 0
fi

"$SCRIPT_ROOT/install-yappa.sh" stop >/dev/null 2>&1 || true
mv -- "$SCRIPT_ROOT" "$ROLLBACK_ROOT"
mv -- "$PRE_ROLLBACK_ROOT" "$SCRIPT_ROOT"
if ! "$SCRIPT_ROOT/install-yappa.sh" start ||
  ! "$SCRIPT_ROOT/install-yappa.sh" verify; then
  echo "Rollback failed; the newer installation was restored but did not start." >&2
  exit 1
fi
echo "Rollback verification failed; the newer installation was restored." >&2
exit 1
