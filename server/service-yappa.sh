#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ACTION="${1:-}"
if [[ $# -ne 1 || ! "$ACTION" =~ ^(install|status|remove)$ ]]; then
  echo "Use: ./service-yappa.sh install|status|remove" >&2
  exit 1
fi
if ((EUID == 0)); then
  echo "Yappa user-service registration must not run as root." >&2
  exit 1
fi
for command_name in systemctl sha256sum sed mkdir chmod mv rm dirname; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Yappa service registration requires $command_name." >&2
    exit 1
  fi
done
if [[ ! -f "$SCRIPT_ROOT/.env" || ! -d "$SCRIPT_ROOT/data" ||
  -L "$SCRIPT_ROOT/.env" || -L "$SCRIPT_ROOT/data" ]]; then
  echo "Yappa service registration requires a safe initialized installation." >&2
  exit 1
fi
if [[ "$SCRIPT_ROOT" == *$'\n'* || "$SCRIPT_ROOT" == *$'\r'* ||
  "$SCRIPT_ROOT" == *$'\t'* ]]; then
  echo "Yappa installation path contains unsupported control characters." >&2
  exit 1
fi

CONFIG_ROOT="${XDG_CONFIG_HOME:-${HOME:?HOME is required}/.config}"
UNIT_DIRECTORY="$CONFIG_ROOT/systemd/user"
PATH_DIGEST="$(printf '%s' "$SCRIPT_ROOT" | sha256sum | sed 's/[[:space:]].*$//')"
UNIT_NAME="yappa-server-${PATH_DIGEST:0:16}.service"
UNIT_PATH="$UNIT_DIRECTORY/$UNIT_NAME"
REGISTRATION_PATH="$SCRIPT_ROOT/data/service-registration"

systemd_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//%/%%}"
  printf '"%s"' "$value"
}

case "$ACTION" in
  install)
    if [[ -e "$UNIT_PATH" || -e "$REGISTRATION_PATH" ]]; then
      echo "This Yappa installation already has service registration state." >&2
      exit 1
    fi
    if ! systemctl --user show-environment >/dev/null 2>&1; then
      echo "No usable per-user systemd manager is available." >&2
      exit 1
    fi
    mkdir -p -m 700 "$UNIT_DIRECTORY"
    TEMPORARY_UNIT="$UNIT_PATH.partial"
    trap 'rm -f -- "$TEMPORARY_UNIT"' EXIT INT TERM
    cat > "$TEMPORARY_UNIT" <<EOF
[Unit]
Description=Yappa Server (${PATH_DIGEST:0:16})
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$(systemd_quote "$SCRIPT_ROOT")
ExecStart=$(systemd_quote "$SCRIPT_ROOT/install-yappa.sh") start
ExecStartPost=$(systemd_quote "$SCRIPT_ROOT/install-yappa.sh") verify
ExecStop=$(systemd_quote "$SCRIPT_ROOT/install-yappa.sh") stop
RemainAfterExit=yes
TimeoutStartSec=300
TimeoutStopSec=120
NoNewPrivileges=yes
PrivateTmp=yes
UMask=0077

[Install]
WantedBy=default.target
EOF
    chmod 600 "$TEMPORARY_UNIT"
    mv -- "$TEMPORARY_UNIT" "$UNIT_PATH"
    printf '%s\n' "$UNIT_NAME" > "$REGISTRATION_PATH"
    chmod 600 "$REGISTRATION_PATH"
    trap - EXIT INT TERM
    if ! systemctl --user daemon-reload ||
      ! systemctl --user enable --now "$UNIT_NAME"; then
      systemctl --user disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
      rm -f -- "$UNIT_PATH" "$REGISTRATION_PATH"
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      echo "Yappa service registration failed and was removed." >&2
      exit 1
    fi
    echo "Yappa sign-in autostart enabled as $UNIT_NAME."
    echo "This is a per-user service visible to systemctl --user."
    ;;
  status)
    if [[ ! -f "$UNIT_PATH" || ! -f "$REGISTRATION_PATH" ]] ||
      [[ "$(sed -n '1p' "$REGISTRATION_PATH")" != "$UNIT_NAME" ]]; then
      echo "Yappa sign-in autostart is not registered."
      exit 3
    fi
    systemctl --user status "$UNIT_NAME" --no-pager
    ;;
  remove)
    if [[ ! -f "$UNIT_PATH" || ! -f "$REGISTRATION_PATH" ]] ||
      [[ "$(sed -n '1p' "$REGISTRATION_PATH")" != "$UNIT_NAME" ]]; then
      echo "Yappa service registration is missing or inconsistent." >&2
      exit 1
    fi
    systemctl --user disable --now "$UNIT_NAME"
    rm -f -- "$UNIT_PATH" "$REGISTRATION_PATH"
    systemctl --user daemon-reload
    systemctl --user reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true
    echo "Yappa sign-in autostart registration removed."
    echo "Server data was not deleted."
    ;;
esac
