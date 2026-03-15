#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT_DIR"

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

if [[ ! -f .env ]]; then
  API_KEY="lk_$(random_string 24)"
  API_SECRET="$(random_string 48)"

  cat > .env <<ENVEOF
PORT=4100
SERVER_NAME="Default"
SERVER_DESCRIPTION="Description"
DB_PATH=./data/newchat.db
CORS_ORIGIN='*'
LIVEKIT_SIGNAL_PORT=7880
LIVEKIT_TCP_PORT=7881
LIVEKIT_UDP_PORT=7882
LIVEKIT_TOKEN_TTL=12h
LIVEKIT_PUBLIC_HOST=
LIVEKIT_PUBLIC_SCHEME=
LIVEKIT_USE_EXTERNAL_IP=false
LIVEKIT_URL=
LIVEKIT_API_KEY=${API_KEY}
LIVEKIT_API_SECRET=${API_SECRET}
ENVEOF

  echo "Created .env with fresh LiveKit credentials."
fi

set -a
source ./.env
set +a

cat > livekit.yaml <<EOF2
port: ${LIVEKIT_SIGNAL_PORT:-7880}
log_level: info

rtc:
  tcp_port: ${LIVEKIT_TCP_PORT:-7881}
  udp_port: ${LIVEKIT_UDP_PORT:-7882}
  use_external_ip: ${LIVEKIT_USE_EXTERNAL_IP:-false}

keys:
  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}
EOF2

echo "Wrote livekit.yaml from .env."
docker compose up -d --build
echo
echo "Yappa server stack is starting."
echo "Backend:  http://$(hostname -I | awk '{print $1}'):${PORT:-4100}"
echo "Voice WS: ws://$(hostname -I | awk '{print $1}'):${LIVEKIT_SIGNAL_PORT:-7880}"
