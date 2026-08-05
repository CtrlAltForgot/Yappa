#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_ROOT"

if [[ $# -ne 0 ]]; then
  echo "Usage: ./verify-yappa-install.sh" >&2
  exit 1
fi

for command_name in docker curl sqlite3 stat find mktemp sed grep; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Yappa installation verification requires $command_name." >&2
    exit 1
  fi
done
if [[ ! -f .env || ! -d data ]]; then
  echo "No initialized Yappa installation was found in $SCRIPT_ROOT." >&2
  exit 1
fi
if [[ -L .env || -L data ]]; then
  echo "Yappa configuration and data roots must not be symbolic links." >&2
  exit 1
fi
if [[ "$(stat -c '%a' .env)" != "600" ]]; then
  echo "Yappa .env must have mode 0600." >&2
  exit 1
fi
if [[ "$(stat -c '%a' data)" != "700" ]]; then
  echo "Yappa data must have mode 0700." >&2
  exit 1
fi

read_env_value() {
  local key="$1"
  sed -n "s/^${key}=//p" .env | tail -n 1
}

DB_PATH="$(read_env_value DB_PATH)"
if [[ "$DB_PATH" == ./* ]]; then
  DB_PATH="$SCRIPT_ROOT/${DB_PATH#./}"
fi
if [[ "$DB_PATH" != "$SCRIPT_ROOT"/data/* ]] ||
  [[ "$DB_PATH" == *'/../'* ]] ||
  [[ ! -f "$DB_PATH" ]] ||
  [[ -L "$DB_PATH" ]]; then
  echo "Yappa database must be a regular file inside the installation data root." >&2
  exit 1
fi
SCHEMA_VERSION="$(
  sqlite3 "$DB_PATH" \
    "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;"
)"
EXPECTED_SCHEMA="$(
  sed -n \
    's/^[[:space:]]*"databaseSchemaVersion":[[:space:]]*\([0-9][0-9]*\),*[[:space:]]*$/\1/p' \
    install-manifest.json
)"
if [[ -z "$EXPECTED_SCHEMA" || "$SCHEMA_VERSION" != "$EXPECTED_SCHEMA" ]]; then
  echo "Yappa database schema does not match the install manifest." >&2
  exit 1
fi
if [[ "$(sqlite3 "$DB_PATH" 'PRAGMA quick_check;')" != "ok" ]]; then
  echo "Yappa database failed its integrity check." >&2
  exit 1
fi

mapfile -d '' IDENTITY_FILES < <(
  find data -type f -name 'server-identity.json' -print0
)
if [[ ${#IDENTITY_FILES[@]} -ne 1 ]] ||
  [[ -L "${IDENTITY_FILES[0]}" ]] ||
  [[ "$(stat -c '%a' "${IDENTITY_FILES[0]}")" != "600" ]]; then
  echo "Yappa must have exactly one private persistent server identity." >&2
  exit 1
fi

WRITE_TEST="$(mktemp "$SCRIPT_ROOT/data/.yappa-write-test.XXXXXXXX")"
chmod 600 "$WRITE_TEST"
rm -f -- "$WRITE_TEST"

EXPECTED_SERVICES=(
  newchat-node
  yappa-discovery
  yappa-livekit
  yappa-proxy
)
mapfile -t RUNNING_SERVICES < <(
  docker compose ps --status running --services | sort
)
for service_name in "${EXPECTED_SERVICES[@]}"; do
  if ! printf '%s\n' "${RUNNING_SERVICES[@]}" |
    grep -Fxq "$service_name"; then
    echo "Yappa service is not running: $service_name" >&2
    exit 1
  fi
done
if [[ "$(docker inspect -f '{{.State.Health.Status}}' newchat-node)" != "healthy" ]]; then
  echo "Yappa backend container is not healthy." >&2
  exit 1
fi

INTERNAL_IDENTITY="$(
  docker compose exec -T newchat-node \
    node src/verify-server-identity.js http://127.0.0.1:4100
)"
INTERNAL_SERVER_ID="$(
  sed -n 's/.*"serverId":"\([^"]*\)".*/\1/p' <<< "$INTERNAL_IDENTITY"
)"
INTERNAL_PUBLIC_KEY="$(
  sed -n 's/.*"publicKey":"\([^"]*\)".*/\1/p' <<< "$INTERNAL_IDENTITY"
)"
if [[ ! "$INTERNAL_SERVER_ID" =~ ^(srv_[a-f0-9]{32}|node_[a-f0-9]{16})$ ]] ||
  [[ ! "$INTERNAL_PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
  echo "Yappa backend returned invalid verified identity metadata." >&2
  exit 1
fi

ADDRESS_MODE="$(read_env_value YAPPA_ADDRESS_MODE)"
HTTP_PORT="$(read_env_value YAPPA_HTTP_PORT)"
HTTPS_PORT="$(read_env_value YAPPA_HTTPS_PORT)"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
CURL_ROUTE_ARGS=()
if [[ "$ADDRESS_MODE" == "lan" ]]; then
  ROUTE_ORIGIN="http://127.0.0.1:$HTTP_PORT"
else
  ROUTE_HOST="$(read_env_value YAPPA_ADVERTISED_ADDRESS)"
  if [[ -z "$ROUTE_HOST" ]]; then
    ROUTE_HOST="$(read_env_value YAPPA_SITE_ADDRESS)"
  fi
  if [[ ! "$ROUTE_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "Yappa public route host is invalid." >&2
    exit 1
  fi
  ROUTE_ORIGIN="https://$ROUTE_HOST"
  CURL_ROUTE_ARGS=(--connect-to "$ROUTE_HOST:443:127.0.0.1:$HTTPS_PORT")
fi

ROUTE_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/yappa-route-verify.XXXXXXXX")"
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  rm -rf -- "$ROUTE_TEMP"
  exit "$status"
}
trap cleanup EXIT INT TERM

curl \
  --fail \
  --silent \
  --show-error \
  --connect-timeout 5 \
  --max-time 15 \
  "${CURL_ROUTE_ARGS[@]}" \
  "$ROUTE_ORIGIN/health" \
  --output "$ROUTE_TEMP/health.json"
if ! grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$ROUTE_TEMP/health.json"; then
  echo "Yappa routed health response is invalid." >&2
  exit 1
fi
curl \
  --fail \
  --silent \
  --show-error \
  --connect-timeout 5 \
  --max-time 15 \
  "${CURL_ROUTE_ARGS[@]}" \
  "$ROUTE_ORIGIN/api/server" \
  --output "$ROUTE_TEMP/server.json"
if ! grep -Fq "\"id\":\"$INTERNAL_SERVER_ID\"" "$ROUTE_TEMP/server.json"; then
  echo "Yappa routed server identity does not match the backend." >&2
  exit 1
fi

ROUTE_NONCE="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
curl \
  --fail \
  --silent \
  --show-error \
  --connect-timeout 5 \
  --max-time 15 \
  "${CURL_ROUTE_ARGS[@]}" \
  "$ROUTE_ORIGIN/api/server/identity?nonce=$ROUTE_NONCE" \
  --output "$ROUTE_TEMP/identity.json"
if ! grep -Fq "\"serverId\":\"$INTERNAL_SERVER_ID\"" "$ROUTE_TEMP/identity.json" ||
  ! grep -Fq "\"publicKey\":\"$INTERNAL_PUBLIC_KEY\"" "$ROUTE_TEMP/identity.json"; then
  echo "Yappa routed identity proof does not match the verified backend." >&2
  exit 1
fi

set +e
curl \
  --silent \
  --show-error \
  --http1.1 \
  --connect-timeout 5 \
  --max-time 3 \
  "${CURL_ROUTE_ARGS[@]}" \
  --header 'Connection: Upgrade' \
  --header 'Upgrade: websocket' \
  --header 'Sec-WebSocket-Version: 13' \
  --header 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "$ROUTE_ORIGIN/socket.io/?EIO=4&transport=websocket" \
  --dump-header "$ROUTE_TEMP/socket-headers.txt" \
  --output /dev/null \
  2> "$ROUTE_TEMP/socket-curl.stderr"
SOCKET_CURL_STATUS=$?
set -e
if [[ "$SOCKET_CURL_STATUS" -ne 0 && "$SOCKET_CURL_STATUS" -ne 28 ]] ||
  ! grep -Eq '^HTTP/[0-9.]+ 101([[:space:]]|$)' "$ROUTE_TEMP/socket-headers.txt"; then
  echo "Yappa realtime WebSocket upgrade failed." >&2
  exit 1
fi

LIVEKIT_STATUS="$(
  curl \
    --silent \
    --show-error \
    --connect-timeout 5 \
    --max-time 15 \
    "${CURL_ROUTE_ARGS[@]}" \
    "$ROUTE_ORIGIN/rtc" \
    --output /dev/null \
    --write-out '%{http_code}'
)"
if [[ ! "$LIVEKIT_STATUS" =~ ^4[0-9][0-9]$ ]]; then
  echo "Yappa LiveKit route did not reach its guarded endpoint." >&2
  exit 1
fi

trap - EXIT INT TERM
rm -rf -- "$ROUTE_TEMP"
echo "Yappa installation verification passed."
echo "Schema:          $SCHEMA_VERSION"
echo "Server identity: $INTERNAL_SERVER_ID"
echo "API/TLS route:   verified"
echo "Realtime route:  WebSocket upgrade verified"
echo "LiveKit route:   guarded endpoint reached"
echo "External reachability, forced TURN, and real media remain separate release tests."
