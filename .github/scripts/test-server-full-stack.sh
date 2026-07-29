#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

REPOSITORY_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TEMPORARY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/yappa-full-stack.XXXXXXXX")"
BUNDLE_ROOT="$TEMPORARY_ROOT/bundle"
INSTALL_ROOT="$TEMPORARY_ROOT/Yappa Server"

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -f "$INSTALL_ROOT/docker-compose.yml" ]]; then
    docker compose \
      --project-directory "$INSTALL_ROOT" \
      down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TEMPORARY_ROOT"
  exit "$status"
}
trap cleanup EXIT INT TERM

for command_name in docker node sha256sum awk find stat; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Full-stack contract requires $command_name." >&2
    exit 1
  fi
done
if [[ "$(id -u)" == "0" ]]; then
  echo "Full-stack contract must run as an unprivileged Docker user." >&2
  exit 1
fi
docker info >/dev/null
docker compose version >/dev/null

"$REPOSITORY_ROOT/.github/scripts/build-server-bundle.sh" "" "$BUNDLE_ROOT"
mapfile -t ARCHIVES < <(find "$BUNDLE_ROOT" -maxdepth 1 -type f -name '*.tar.gz')
if [[ ${#ARCHIVES[@]} -ne 1 ]]; then
  echo "Full-stack contract requires exactly one canonical server bundle." >&2
  exit 1
fi
ARCHIVE="${ARCHIVES[0]}"
DIGEST="$(awk 'NR == 1 { print $1 }' "$ARCHIVE.sha256")"
if [[ ! "$DIGEST" =~ ^[a-f0-9]{64}$ ]]; then
  echo "Canonical server bundle checksum is malformed." >&2
  exit 1
fi

"$REPOSITORY_ROOT/server/install-yappa.sh" install \
  --local-bundle "$ARCHIVE" \
  --sha256 "$DIGEST" \
  --install-dir "$INSTALL_ROOT" \
  --lan

verify_with_retries() {
  local attempt
  for ((attempt=1; attempt<=24; attempt++)); do
    if "$INSTALL_ROOT/install-yappa.sh" verify; then
      return 0
    fi
    if ((attempt < 24)); then
      sleep 5
    fi
  done
  return 1
}

verify_with_retries
IDENTITY_PATH="$(
  find "$INSTALL_ROOT/data" -type f -name server-identity.json -print -quit
)"
if [[ -z "$IDENTITY_PATH" ]]; then
  echo "Full-stack startup did not create a persistent identity." >&2
  exit 1
fi
IDENTITY_BEFORE="$(sha256sum "$IDENTITY_PATH" | awk '{print $1}')"

"$INSTALL_ROOT/install-yappa.sh" stop
if [[ "$(cat "$INSTALL_ROOT/.yappa-host-state/desired-state")" != "stopped" ]]; then
  echo "Intentional stop did not persist desired state." >&2
  exit 1
fi
if [[ -n "$(
  docker compose --project-directory "$INSTALL_ROOT" \
    ps --status running --services
)" ]]; then
  echo "A Yappa service remained running after intentional stop." >&2
  exit 1
fi
RECOVERY_OUTPUT="$("$INSTALL_ROOT/install-yappa.sh" recover)"
if [[ "$RECOVERY_OUTPUT" != *"intentionally stopped; recovery did nothing"* ]]; then
  echo "Recovery did not respect intentional stop." >&2
  exit 1
fi

"$INSTALL_ROOT/install-yappa.sh" start --lan
verify_with_retries
IDENTITY_AFTER_RESTART="$(sha256sum "$IDENTITY_PATH" | awk '{print $1}')"
if [[ "$IDENTITY_AFTER_RESTART" != "$IDENTITY_BEFORE" ]]; then
  echo "Server identity changed across an intentional stop and restart." >&2
  exit 1
fi

docker stop newchat-node >/dev/null
"$INSTALL_ROOT/install-yappa.sh" recover
verify_with_retries
IDENTITY_AFTER_RECOVERY="$(sha256sum "$IDENTITY_PATH" | awk '{print $1}')"
if [[ "$IDENTITY_AFTER_RECOVERY" != "$IDENTITY_BEFORE" ]]; then
  echo "Server identity changed during bounded recovery." >&2
  exit 1
fi

trap - EXIT INT TERM
docker compose \
  --project-directory "$INSTALL_ROOT" \
  down --volumes --remove-orphans
rm -rf -- "$TEMPORARY_ROOT"
echo "Canonical full-stack install, restart, persistence, and recovery contract passed."
