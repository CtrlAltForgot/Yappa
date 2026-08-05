#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT_DIR"

RUNTIME_UID="$(id -u)"
RUNTIME_GID="$(id -g)"
if [[ "$RUNTIME_UID" == "0" ]]; then
  echo "Yappa server startup must run as an unprivileged installation owner." >&2
  exit 1
fi
if [[ "$(stat -c '%u' "$ROOT_DIR")" != "$RUNTIME_UID" ]]; then
  echo "Yappa server startup must run as the installation owner." >&2
  exit 1
fi

random_string() {
  local len="$1"
  local out
  set +o pipefail
  out="$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "$len")"
  set -o pipefail
  printf '%s' "$out"
}

shell_quote() {
  printf "%q" "$1"
}

detect_public_ipv4() {
  local candidate
  candidate="$(curl --fail --silent --show-error --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local octet
    IFS='.' read -r -a octets <<< "$candidate"
    for octet in "${octets[@]}"; do
      if ((octet > 255)); then
        return 1
      fi
    done
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

set_env_value() {
  local key="$1"
  local value="$2"
  local escaped_value="${value//&/\\&}"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${escaped_value}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

LAN_ADDRESS="$(hostname -I | awk '{print $1}')"
if [[ -z "$LAN_ADDRESS" ]]; then
  LAN_ADDRESS="127.0.0.1"
fi

if [[ ! -f .env ]]; then
  SETUP_MODE="automatic-ip"
  if [[ "${1:-}" == "--lan" ]]; then
    SETUP_MODE="lan"
  elif [[ -n "${1:-}" ]]; then
    echo "Usage: ./start-yappa.sh [--lan]"
    exit 1
  fi

  API_KEY="lk_$(random_string 24)"
  API_SECRET="$(random_string 48)"
  ATTACHMENT_SECRET="$(random_string 64)"

  if [[ "$SETUP_MODE" == "automatic-ip" ]]; then
    PUBLIC_IP="$(detect_public_ipv4 || true)"
    if [[ -z "$PUBLIC_IP" ]]; then
      echo "Could not detect a public IPv4 address."
      echo "Check internet access, or run ./start-yappa.sh --lan for private-network-only setup."
      exit 1
    fi
    INITIAL_YAPPA_SITE="${PUBLIC_IP}"
    INITIAL_LIVEKIT_SITE="${PUBLIC_IP}"
    INITIAL_LIVEKIT_URL="wss://${PUBLIC_IP}"
    INITIAL_LIVEKIT_HOST="$PUBLIC_IP"
    INITIAL_EXTERNAL_IP="false"
  else
    INITIAL_YAPPA_SITE="http://:80"
    INITIAL_LIVEKIT_SITE="http://:7882"
    INITIAL_LIVEKIT_URL="ws://${LAN_ADDRESS}:7882"
    INITIAL_LIVEKIT_HOST="$LAN_ADDRESS"
    INITIAL_EXTERNAL_IP="false"
  fi

  cat > .env <<ENVEOF
PORT=4100
BACKEND_BIND_ADDRESS=127.0.0.1
YAPPA_ADDRESS_MODE=${SETUP_MODE}
YAPPA_SITE_ADDRESS=${INITIAL_YAPPA_SITE}
YAPPA_DEFAULT_SNI=${PUBLIC_IP:-localhost}
YAPPA_ADVERTISED_ADDRESS=${PUBLIC_IP:-}
LIVEKIT_SITE_ADDRESS=${INITIAL_LIVEKIT_SITE}
YAPPA_HTTP_PORT=80
YAPPA_HTTPS_PORT=443
YAPPA_LIVEKIT_PROXY_PORT=7882
YAPPA_RUNTIME_UID=${RUNTIME_UID}
YAPPA_RUNTIME_GID=${RUNTIME_GID}
SERVER_NAME="Default"
SERVER_DESCRIPTION="Description"
DB_PATH=./data/newchat.db
CORS_ORIGIN=
TRUST_PROXY=true
JSON_BODY_LIMIT=256kb
AUTH_RATE_LIMIT_WINDOW_MS=900000
AUTH_RATE_LIMIT_MAX=10
AUTH_BACKOFF_FREE_FAILURES=3
AUTH_BACKOFF_BASE_MS=1000
AUTH_BACKOFF_MAX_MS=30000
AUTH_BACKOFF_RESET_MS=1800000
BCRYPT_COST=12
NEW_ACCOUNT_PASSWORD_MIN_LENGTH=10
CHALLENGE_RATE_LIMIT_WINDOW_MS=60000
CHALLENGE_RATE_LIMIT_MAX=30
CONTENT_MUTATION_RATE_LIMIT_WINDOW_MS=60000
CONTENT_MUTATION_RATE_LIMIT_MAX=120
EXPENSIVE_OPERATION_RATE_LIMIT_WINDOW_MS=60000
EXPENSIVE_OPERATION_RATE_LIMIT_MAX=30
UPLOAD_RATE_LIMIT_WINDOW_MS=600000
UPLOAD_RATE_LIMIT_MAX=20
ACCOUNT_MUTATION_RATE_LIMIT_WINDOW_MS=60000
ACCOUNT_MUTATION_RATE_LIMIT_MAX=30
ATTACHMENT_DOWNLOAD_RATE_LIMIT_WINDOW_MS=60000
ATTACHMENT_DOWNLOAD_RATE_LIMIT_MAX=300
SOCKET_CONTROL_RATE_LIMIT_WINDOW_MS=60000
SOCKET_CONTROL_RATE_LIMIT_MAX=240
SOCKET_SIGNAL_RATE_LIMIT_WINDOW_MS=60000
SOCKET_SIGNAL_RATE_LIMIT_MAX=1200
MEDIA_ENVELOPE_RATE_LIMIT_WINDOW_MS=60000
MEDIA_ENVELOPE_RATE_LIMIT_MAX=240
SOCKET_CONNECTION_RATE_LIMIT_WINDOW_MS=60000
SOCKET_CONNECTION_RATE_LIMIT_MAX=120
SESSION_ABSOLUTE_TTL_MS=2592000000
SESSION_IDLE_TTL_MS=604800000
ATTACHMENT_URL_TTL_SECONDS=900
ATTACHMENT_SIGNING_SECRET=${ATTACHMENT_SECRET}
DURABLE_STORAGE_CRITICAL_FREE_BYTES=536870912
DURABLE_STORAGE_WARNING_FREE_BYTES=2147483648
LAN_DISCOVERY_ENABLED=true
LIVEKIT_SIGNAL_PORT=7880
LIVEKIT_TCP_PORT=7881
LIVEKIT_UDP_PORT_RANGE_START=50000
LIVEKIT_UDP_PORT_RANGE_END=50100
LIVEKIT_TURN_UDP_PORT=443
LIVEKIT_TOKEN_TTL=12h
LIVEKIT_PUBLIC_HOST=${INITIAL_LIVEKIT_HOST}
LIVEKIT_PUBLIC_SCHEME=
LIVEKIT_USE_EXTERNAL_IP=${INITIAL_EXTERNAL_IP}
LIVEKIT_URL=${INITIAL_LIVEKIT_URL}
LIVEKIT_API_KEY=${API_KEY}
LIVEKIT_API_SECRET=${API_SECRET}
ENVEOF

  echo "Created .env with fresh server credentials."
fi
chmod 600 .env
mkdir -p -m 700 data
if [[ "$(stat -c '%u:%g' data)" != "$RUNTIME_UID:$RUNTIME_GID" ]]; then
  echo "Yappa data must be owned by the installation owner." >&2
  exit 1
fi
chmod 700 data
set_env_value YAPPA_RUNTIME_UID "$RUNTIME_UID"
set_env_value YAPPA_RUNTIME_GID "$RUNTIME_GID"

# The raw application port is an internal maintenance path. Public and LAN
# clients must enter through Caddy so transport and routing policy are applied.
set_env_value BACKEND_BIND_ADDRESS "127.0.0.1"

set -a
source ./.env
set +a

if [[ "${YAPPA_ADDRESS_MODE:-}" == "automatic-ip" ]]; then
  CURRENT_PUBLIC_IP="$(detect_public_ipv4 || true)"
  if [[ -z "$CURRENT_PUBLIC_IP" ]]; then
    echo "Could not refresh the public IPv4 address."
    echo "Check internet access, or set YAPPA_ADDRESS_MODE=custom-domain and configure stable domains."
    exit 1
  fi
  EXPECTED_YAPPA_SITE="${CURRENT_PUBLIC_IP}"
  EXPECTED_LIVEKIT_SITE="${CURRENT_PUBLIC_IP}"
  if [[ "${YAPPA_ADVERTISED_ADDRESS:-}" != "$CURRENT_PUBLIC_IP" ]]; then
    set_env_value YAPPA_ADVERTISED_ADDRESS "$CURRENT_PUBLIC_IP"
    YAPPA_ADVERTISED_ADDRESS="$CURRENT_PUBLIC_IP"
  fi
  if [[ "${YAPPA_DEFAULT_SNI:-}" != "$CURRENT_PUBLIC_IP" ]]; then
    set_env_value YAPPA_DEFAULT_SNI "$CURRENT_PUBLIC_IP"
    YAPPA_DEFAULT_SNI="$CURRENT_PUBLIC_IP"
  fi
  if [[ "${YAPPA_SITE_ADDRESS:-}" != "$EXPECTED_YAPPA_SITE" ||
        "${LIVEKIT_SITE_ADDRESS:-}" != "$EXPECTED_LIVEKIT_SITE" ]]; then
    set_env_value YAPPA_SITE_ADDRESS "$EXPECTED_YAPPA_SITE"
    set_env_value YAPPA_DEFAULT_SNI "$CURRENT_PUBLIC_IP"
    set_env_value LIVEKIT_SITE_ADDRESS "$EXPECTED_LIVEKIT_SITE"
    set_env_value LIVEKIT_URL "wss://${CURRENT_PUBLIC_IP}"
    set_env_value LIVEKIT_PUBLIC_HOST "$CURRENT_PUBLIC_IP"
    echo "Updated the automatic address for public IP ${CURRENT_PUBLIC_IP}."
    set -a
    source ./.env
    set +a
  fi
fi

if [[ "${YAPPA_ADDRESS_MODE:-}" == "lan" ]]; then
  set_env_value YAPPA_ADVERTISED_ADDRESS ""
  set_env_value YAPPA_DEFAULT_SNI "localhost"
fi

YAPPA_SITE_ADDRESS="${YAPPA_SITE_ADDRESS:-http://:80}"
LIVEKIT_SITE_ADDRESS="${LIVEKIT_SITE_ADDRESS:-http://:7882}"

if [[ "$YAPPA_SITE_ADDRESS" == https://* || "$LIVEKIT_SITE_ADDRESS" == https://* ]]; then
  echo "Do not include https:// in Caddy site addresses; use bare public hostnames."
  exit 1
fi

if [[ "$YAPPA_SITE_ADDRESS" != http://* && "$LIVEKIT_SITE_ADDRESS" != http://* ]]; then
  if [[ "$LIVEKIT_URL" != wss://* ]]; then
    echo "Public mode requires LIVEKIT_URL=wss://${LIVEKIT_SITE_ADDRESS}"
    exit 1
  fi
fi

cat > livekit.yaml <<EOF2
port: ${LIVEKIT_SIGNAL_PORT:-7880}
bind_addresses:
  - 0.0.0.0
log_level: info

rtc:
  node_ip: ${LIVEKIT_PUBLIC_HOST:-127.0.0.1}
  tcp_port: ${LIVEKIT_TCP_PORT:-7881}
  port_range_start: ${LIVEKIT_UDP_PORT_RANGE_START:-50000}
  port_range_end: ${LIVEKIT_UDP_PORT_RANGE_END:-50100}
  use_external_ip: ${LIVEKIT_USE_EXTERNAL_IP:-false}

turn:
  enabled: true
  udp_port: ${LIVEKIT_TURN_UDP_PORT:-443}

keys:
  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}
EOF2
chmod 640 livekit.yaml

echo "Wrote livekit.yaml from .env."
docker compose up -d --build
echo
echo "Yappa server stack is starting."
if [[ "$YAPPA_SITE_ADDRESS" == http://* ]]; then
  LAN_HTTP_PORT="${YAPPA_HTTP_PORT:-80}"
  LAN_HTTP_SUFFIX=":${LAN_HTTP_PORT}"
  if [[ "$LAN_HTTP_PORT" == "80" ]]; then
    LAN_HTTP_SUFFIX=""
  fi
  echo "LAN client address: http://${LAN_ADDRESS}${LAN_HTTP_SUFFIX}"
  echo "LAN voice signal:   ws://${LAN_ADDRESS}:${LIVEKIT_SIGNAL_PORT:-7880}"
else
  if [[ "${YAPPA_ADDRESS_MODE:-}" == "automatic-ip" ]]; then
    echo "Public join address: ${YAPPA_ADVERTISED_ADDRESS}"
  else
    echo "Public join address: https://${YAPPA_SITE_ADDRESS}"
  fi
  echo "Trusted HTTPS and secure voice signaling are configured automatically."
  echo
  echo "Router port forwarding (external -> internal):"
  echo "  TCP 80 -> ${YAPPA_HTTP_PORT:-80}"
  echo "  TCP 443 -> ${YAPPA_HTTPS_PORT:-443}"
  echo "  UDP ${LIVEKIT_TURN_UDP_PORT:-443} -> ${LIVEKIT_TURN_UDP_PORT:-443} (voice fallback)"
  echo "  TCP ${LIVEKIT_TCP_PORT:-7881} -> ${LIVEKIT_TCP_PORT:-7881}"
  echo "  UDP ${LIVEKIT_UDP_PORT_RANGE_START:-50000}-${LIVEKIT_UDP_PORT_RANGE_END:-50100} -> ${LIVEKIT_UDP_PORT_RANGE_START:-50000}-${LIVEKIT_UDP_PORT_RANGE_END:-50100}"
fi
