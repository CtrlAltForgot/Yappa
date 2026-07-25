#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT_DIR"

if [[ $# -ne 1 ]]; then
  echo "Usage: ./setup-domain.sh <domain>"
  echo "Example: ./setup-domain.sh chat.example.com"
  exit 1
fi

if [[ ! -f .env ]]; then
  echo "Run ./start-yappa.sh once before selecting custom domains."
  exit 1
fi

YAPPA_DOMAIN="${1,,}"
DOMAIN_PATTERN='^([a-z0-9][a-z0-9-]*\.)+[a-z]{2,63}$'

if [[ ! "$YAPPA_DOMAIN" =~ $DOMAIN_PATTERN ]]; then
  echo "Invalid Yappa domain: $YAPPA_DOMAIN"
  exit 1
fi
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

set_env_value YAPPA_ADDRESS_MODE custom-domain
set_env_value YAPPA_SITE_ADDRESS "$YAPPA_DOMAIN"
set_env_value YAPPA_DEFAULT_SNI "$YAPPA_DOMAIN"
set_env_value YAPPA_ADVERTISED_ADDRESS "$YAPPA_DOMAIN"
set_env_value LIVEKIT_SITE_ADDRESS "$YAPPA_DOMAIN"
set_env_value LIVEKIT_URL "wss://${YAPPA_DOMAIN}"
set_env_value LIVEKIT_USE_EXTERNAL_IP true
set_env_value BACKEND_BIND_ADDRESS 127.0.0.1
set_env_value TRUST_PROXY true
chmod 600 .env

echo "Configured custom domains:"
echo "  https://${YAPPA_DOMAIN}"
echo "  wss://${YAPPA_DOMAIN}"
echo
exec ./start-yappa.sh
