#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

if [[ $# -ne 1 || ! "$1" =~ ^(ufw|firewalld)$ ]]; then
  echo "Use: test-server-runtime-contract.sh ufw|firewalld" >&2
  exit 64
fi
BACKEND="$1"
REPOSITORY_ROOT="${YAPPA_REPOSITORY_ROOT:-/workspace}"
TEST_USER=yappa-runtime
TEST_UID=18080
TEST_HOME="/home/$TEST_USER"
INSTALLATION="$TEST_HOME/Yappa Server"
ACTION_LOG="$TEST_HOME/actions.log"

[[ "$(id -u)" == 0 ]] ||
  { echo "Runtime contract requires an isolated root container." >&2; exit 1; }
[[ "$(cat /proc/1/comm)" == systemd ]] ||
  { echo "Runtime contract requires systemd as PID 1." >&2; exit 1; }
systemctl is-system-running --wait >/dev/null 2>&1 ||
  [[ "$(systemctl is-system-running)" == degraded ]] ||
  { echo "System systemd manager did not become usable." >&2; exit 1; }
[[ -f "$REPOSITORY_ROOT/server/service-yappa.sh" ]]
[[ -f "$REPOSITORY_ROOT/server/firewall-yappa.sh" ]]

useradd --create-home --uid "$TEST_UID" --shell /bin/bash "$TEST_USER"
install -d -m 700 -o "$TEST_UID" -g "$TEST_UID" "$INSTALLATION"
install -d -m 700 -o "$TEST_UID" -g "$TEST_UID" "$INSTALLATION/data"
install -m 700 -o "$TEST_UID" -g "$TEST_UID" \
  "$REPOSITORY_ROOT/server/service-yappa.sh" \
  "$INSTALLATION/service-yappa.sh"
install -m 700 -o "$TEST_UID" -g "$TEST_UID" \
  "$REPOSITORY_ROOT/server/firewall-yappa.sh" \
  "$INSTALLATION/firewall-yappa.sh"
cat > "$INSTALLATION/.env" <<'EOF'
DB_PATH=./data/yappa.db
YAPPA_ADDRESS_MODE=automatic-ip
YAPPA_HTTP_PORT=80
YAPPA_HTTPS_PORT=443
YAPPA_LIVEKIT_PROXY_PORT=7882
LIVEKIT_TCP_PORT=7881
LIVEKIT_TURN_UDP_PORT=443
LIVEKIT_UDP_PORT_RANGE_START=50000
LIVEKIT_UDP_PORT_RANGE_END=50100
EOF
chown "$TEST_UID:$TEST_UID" "$INSTALLATION/.env"
chmod 600 "$INSTALLATION/.env"
cat > "$INSTALLATION/install-yappa.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${1:-missing}" >> "$(dirname "$0")/../actions.log"
EOF
chown "$TEST_UID:$TEST_UID" "$INSTALLATION/install-yappa.sh"
chmod 700 "$INSTALLATION/install-yappa.sh"
install -m 600 -o "$TEST_UID" -g "$TEST_UID" /dev/null "$ACTION_LOG"

loginctl enable-linger "$TEST_USER"
if ! systemctl start "user@$TEST_UID.service"; then
  systemctl status "user@$TEST_UID.service" --no-pager || true
  journalctl -u "user@$TEST_UID.service" --no-pager -n 80 || true
  MANAGER_STATUS="$(
    systemctl show "user@$TEST_UID.service" \
      --property=ExecMainStatus --value
  )"
  if [[ "$MANAGER_STATUS" != 224 ]]; then
    exit 1
  fi
  echo "Distro PAM wrapper is blocked by the hosted container boundary."
  echo "Removing only its disposable account-policy check and retrying."
  VENDOR_SYSTEMD_PAM=/usr/lib/pam.d/systemd-user
  [[ -f "$VENDOR_SYSTEMD_PAM" ]] ||
    { echo "No vendor systemd-user PAM policy is available." >&2; exit 1; }
  install -d -m 755 /etc/pam.d
  grep -Ev '^-?account[[:space:]]' "$VENDOR_SYSTEMD_PAM" \
    > /etc/pam.d/systemd-user
  chmod 644 /etc/pam.d/systemd-user
  systemctl reset-failed "user@$TEST_UID.service"
  systemctl start "user@$TEST_UID.service"
fi
RUNTIME_DIRECTORY="/run/user/$TEST_UID"
for _ in {1..20}; do
  [[ -S "$RUNTIME_DIRECTORY/bus" ]] && break
  sleep 0.25
done
[[ -S "$RUNTIME_DIRECTORY/bus" ]] ||
  { echo "Per-user systemd bus did not start." >&2; exit 1; }

run_as_test_user() {
  runuser -u "$TEST_USER" -- env \
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="$TEST_HOME/.config" \
    XDG_RUNTIME_DIR="$RUNTIME_DIRECTORY" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIRECTORY/bus" \
    "$@"
}

if ! run_as_test_user "$INSTALLATION/service-yappa.sh" install; then
  journalctl "_UID=$TEST_UID" --no-pager -n 80 || true
  exit 1
fi
REGISTRATION="$INSTALLATION/.yappa-host-state/service-registration"
mapfile -t UNITS < "$REGISTRATION"
[[ ${#UNITS[@]} -eq 3 ]]
if ! run_as_test_user systemctl --user is-active --quiet "${UNITS[0]}"; then
  run_as_test_user systemctl --user status "${UNITS[0]}" --no-pager || true
  journalctl "_UID=$TEST_UID" --no-pager -n 80 || true
  exit 1
fi
run_as_test_user systemctl --user is-active --quiet "${UNITS[2]}"
grep -Fxq start "$ACTION_LOG"
grep -Fxq verify "$ACTION_LOG"
run_as_test_user "$INSTALLATION/service-yappa.sh" status >/dev/null
run_as_test_user "$INSTALLATION/service-yappa.sh" remove
grep -Fxq stop "$ACTION_LOG"
[[ ! -e "$REGISTRATION" ]]
if run_as_test_user systemctl --user is-enabled --quiet "${UNITS[0]}"; then
  echo "Removed Yappa user service remains enabled." >&2
  exit 1
fi
if run_as_test_user systemctl --user is-enabled --quiet "${UNITS[2]}"; then
  echo "Removed Yappa recovery timer remains enabled." >&2
  exit 1
fi

case "$BACKEND" in
  ufw)
    ufw --force enable
    ufw status | grep -Fq 'Status: active'
    ;;
  firewalld)
    systemctl start firewalld
    firewall-cmd --state | grep -Fxq running
    ;;
esac
"$INSTALLATION/firewall-yappa.sh" apply "$BACKEND" ""
LOCAL_MARKER="$INSTALLATION/.yappa-host-state/firewall-registration"
[[ -f "$LOCAL_MARKER" ]]
ROOT_REGISTRATION="$(find /var/lib/yappa -maxdepth 1 -type f -name 'firewall-*')"
[[ -n "$ROOT_REGISTRATION" && -f "$ROOT_REGISTRATION" ]]
"$INSTALLATION/firewall-yappa.sh" remove
[[ ! -e "$LOCAL_MARKER" ]]
[[ ! -e "$ROOT_REGISTRATION" ]]

echo "Real systemd user-service and $BACKEND mutation/removal contract passed."
