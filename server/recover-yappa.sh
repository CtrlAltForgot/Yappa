#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
HOST_STATE_ROOT="$SCRIPT_ROOT/.yappa-host-state"
DESIRED_STATE_PATH="$HOST_STATE_ROOT/desired-state"
RECOVERY_STATE_PATH="$HOST_STATE_ROOT/recovery-state"
LOCK_PATH="$HOST_STATE_ROOT/recovery.lock"
MAX_FAILURES=3
COOLDOWN_SECONDS=900
VERIFY_ATTEMPTS=12

if [[ $# -ne 0 ]]; then
  echo "Use: ./install-yappa.sh recover" >&2
  exit 1
fi
for command_name in docker flock date sed stat chmod mv rm sleep sort grep; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Yappa recovery requires $command_name." >&2
    exit 1
  fi
done
if [[ ! -d "$HOST_STATE_ROOT" || -L "$HOST_STATE_ROOT" ||
  "$(stat -c '%a' "$HOST_STATE_ROOT")" != "700" ]]; then
  echo "Yappa recovery has no safe host-local desired state." >&2
  exit 1
fi
DESIRED_STATE="$(sed -n '1p' "$DESIRED_STATE_PATH" 2>/dev/null || true)"
if [[ "$DESIRED_STATE" == "stopped" ]]; then
  echo "Yappa is intentionally stopped; recovery did nothing."
  exit 0
fi
if [[ "$DESIRED_STATE" != "running" ]]; then
  echo "Yappa recovery requires an explicit prior start." >&2
  exit 1
fi

exec 9>"$LOCK_PATH"
chmod 600 "$LOCK_PATH"
if ! flock -n 9; then
  echo "Another Yappa recovery check is already running." >&2
  exit 1
fi

FAILURE_COUNT=0
LAST_FAILURE=0
if [[ -f "$RECOVERY_STATE_PATH" && ! -L "$RECOVERY_STATE_PATH" ]]; then
  FAILURE_COUNT="$(
    sed -n 's/^failures=\([0-9][0-9]*\)$/\1/p' "$RECOVERY_STATE_PATH"
  )"
  LAST_FAILURE="$(
    sed -n 's/^last_failure=\([0-9][0-9]*\)$/\1/p' "$RECOVERY_STATE_PATH"
  )"
  FAILURE_COUNT="${FAILURE_COUNT:-0}"
  LAST_FAILURE="${LAST_FAILURE:-0}"
fi
if [[ ! "$FAILURE_COUNT" =~ ^[0-9]+$ ||
  ! "$LAST_FAILURE" =~ ^[0-9]+$ ]]; then
  echo "Yappa recovery state is malformed." >&2
  exit 1
fi
NOW="$(date +%s)"
if ((FAILURE_COUNT >= MAX_FAILURES &&
  NOW - LAST_FAILURE < COOLDOWN_SECONDS)); then
  echo "Yappa automatic recovery is cooling down after repeated failures." >&2
  exit 1
fi
if ((NOW - LAST_FAILURE >= COOLDOWN_SECONDS)); then
  FAILURE_COUNT=0
fi

EXPECTED_SERVICES=(
  newchat-node
  yappa-discovery
  yappa-livekit
  yappa-proxy
)
basic_health_passes() {
  local running_services service_name
  running_services="$(docker compose --project-directory "$SCRIPT_ROOT" \
    ps --status running --services | sort)"
  for service_name in "${EXPECTED_SERVICES[@]}"; do
    grep -Fxq "$service_name" <<< "$running_services" || return 1
  done
  [[ "$(docker inspect -f '{{.State.Health.Status}}' newchat-node 2>/dev/null)" == "healthy" ]]
}

if basic_health_passes &&
  "$SCRIPT_ROOT/verify-yappa-install.sh" >/dev/null; then
  rm -f -- "$RECOVERY_STATE_PATH"
  echo "Yappa is healthy; recovery did nothing."
  exit 0
fi

echo "Yappa is degraded; attempting one bounded Compose recovery."
docker compose --project-directory "$SCRIPT_ROOT" up -d
RECOVERED=false
for ((attempt=1; attempt<=VERIFY_ATTEMPTS; attempt++)); do
  if basic_health_passes &&
    "$SCRIPT_ROOT/verify-yappa-install.sh" >/dev/null; then
    RECOVERED=true
    break
  fi
  if ((attempt < VERIFY_ATTEMPTS)); then
    sleep 5
  fi
done
if [[ "$RECOVERED" == true ]]; then
  rm -f -- "$RECOVERY_STATE_PATH"
  echo "Yappa recovery completed and passed operational verification."
  exit 0
fi

FAILURE_COUNT=$((FAILURE_COUNT + 1))
TEMPORARY_STATE="$RECOVERY_STATE_PATH.partial"
{
  printf 'failures=%s\n' "$FAILURE_COUNT"
  printf 'last_failure=%s\n' "$NOW"
} > "$TEMPORARY_STATE"
chmod 600 "$TEMPORARY_STATE"
mv -- "$TEMPORARY_STATE" "$RECOVERY_STATE_PATH"
echo "Yappa recovery failed operational verification." >&2
if ((FAILURE_COUNT >= MAX_FAILURES)); then
  echo "Automatic recovery is now cooling down for 15 minutes." >&2
fi
exit 1
