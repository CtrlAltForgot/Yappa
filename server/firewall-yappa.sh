#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ACTION="${1:-}"
BACKEND="${2:-}"
LAN_CIDR="${3:-}"
HOST_STATE_ROOT="$SCRIPT_ROOT/.yappa-host-state"
LOCAL_MARKER="$HOST_STATE_ROOT/firewall-registration"
ROOT_STATE_DIRECTORY="/var/lib/yappa"

for command_name in sha256sum sed tail stat grep; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Yappa firewall lifecycle requires $command_name." >&2
    exit 1
  fi
done
PATH_DIGEST="$(printf '%s' "$SCRIPT_ROOT" | sha256sum | sed 's/[[:space:]].*$//')"
REGISTRATION="$ROOT_STATE_DIRECTORY/firewall-$PATH_DIGEST"

if [[ "$ACTION" == "remove" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Use: ./install-yappa.sh firewall-remove" >&2
    exit 1
  fi
elif [[ ! "$ACTION" =~ ^(plan|apply)$ || $# -ne 3 ||
  ! "$BACKEND" =~ ^(ufw|firewalld)$ ]]; then
  echo "Use: ./firewall-yappa.sh plan|apply ufw|firewalld [LAN_CIDR]" >&2
  exit 1
fi

read_env_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$SCRIPT_ROOT/.env" | tail -n 1
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535))
}

validate_port_spec() {
  local spec="$1" start end
  if [[ "$spec" =~ ^[0-9]+$ ]]; then
    validate_port "$spec"
    return
  fi
  [[ "$spec" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  start="${spec%:*}"
  end="${spec#*:}"
  validate_port "$start" && validate_port "$end" &&
    ((10#$start <= 10#$end))
}

validate_ipv4_cidr() {
  local cidr="$1"
  local address prefix octet
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] ||
    return 1
  address="${cidr%/*}"
  prefix="${cidr#*/}"
  IFS='.' read -r -a octets <<< "$address"
  for octet in "${octets[@]}"; do
    ((10#$octet <= 255)) || return 1
  done
  [[ "$prefix" =~ ^[0-9]+$ ]]
}

RULES=()
add_rule() {
  RULES+=("$1|$2|$3")
}

load_current_rules() {
  if [[ ! -f "$SCRIPT_ROOT/.env" || ! -d "$SCRIPT_ROOT/data" ||
    -L "$SCRIPT_ROOT/.env" || -L "$SCRIPT_ROOT/data" ]]; then
    echo "Firewall lifecycle requires a safe initialized installation." >&2
    exit 1
  fi
  local address_mode http_port https_port proxy_port tcp_port
  local turn_port udp_start udp_end
  address_mode="$(read_env_value YAPPA_ADDRESS_MODE)"
  http_port="$(read_env_value YAPPA_HTTP_PORT)"
  https_port="$(read_env_value YAPPA_HTTPS_PORT)"
  proxy_port="$(read_env_value YAPPA_LIVEKIT_PROXY_PORT)"
  tcp_port="$(read_env_value LIVEKIT_TCP_PORT)"
  turn_port="$(read_env_value LIVEKIT_TURN_UDP_PORT)"
  udp_start="$(read_env_value LIVEKIT_UDP_PORT_RANGE_START)"
  udp_end="$(read_env_value LIVEKIT_UDP_PORT_RANGE_END)"
  http_port="${http_port:-80}"
  https_port="${https_port:-443}"
  proxy_port="${proxy_port:-7882}"
  tcp_port="${tcp_port:-7881}"
  turn_port="${turn_port:-443}"
  udp_start="${udp_start:-50000}"
  udp_end="${udp_end:-50100}"
  for port in \
    "$http_port" "$https_port" "$proxy_port" "$tcp_port" \
    "$turn_port" "$udp_start" "$udp_end"; do
    if ! validate_port "$port"; then
      echo "Firewall lifecycle found an invalid configured port." >&2
      exit 1
    fi
  done
  if ((10#$udp_start > 10#$udp_end)); then
    echo "LiveKit UDP firewall range is reversed." >&2
    exit 1
  fi
  if [[ -n "$LAN_CIDR" ]] && ! validate_ipv4_cidr "$LAN_CIDR"; then
    echo "--lan-cidr must be one explicit IPv4 CIDR." >&2
    exit 1
  fi
  case "$address_mode" in
    lan)
      if [[ -z "$LAN_CIDR" ]]; then
        echo "LAN firewall rules require --lan-cidr." >&2
        exit 1
      fi
      add_rule tcp "$http_port" "$LAN_CIDR"
      add_rule tcp "$proxy_port" "$LAN_CIDR"
      add_rule tcp "$tcp_port" "$LAN_CIDR"
      add_rule udp "$turn_port" "$LAN_CIDR"
      add_rule udp "$udp_start:$udp_end" "$LAN_CIDR"
      add_rule udp 41200 "$LAN_CIDR"
      ;;
    automatic-ip | custom-domain)
      add_rule tcp "$http_port" any
      add_rule tcp "$https_port" any
      add_rule udp "$turn_port" any
      add_rule tcp "$tcp_port" any
      add_rule udp "$udp_start:$udp_end" any
      if [[ -n "$LAN_CIDR" ]]; then
        add_rule udp 41200 "$LAN_CIDR"
      fi
      ;;
    *)
      echo "Firewall lifecycle found an unsupported Yappa address mode." >&2
      exit 1
      ;;
  esac
}

print_plan() {
  echo "Yappa firewall backend: $BACKEND"
  echo "Rules to allow:"
  local rule protocol port source
  for rule in "${RULES[@]}"; do
    IFS='|' read -r protocol port source <<< "$rule"
    printf '  %-3s %-11s source %s\n' \
      "${protocol^^}" "$port" "$source"
  done
  echo "Raw backend TCP 4100, raw LiveKit TCP 7880, LAN proxy TCP 7882"
  echo "outside LAN mode, and loopback relay UDP 41201 are never opened."
}

firewalld_rule() {
  local protocol="$1" port="$2" source="$3"
  printf 'rule family="ipv4" source address="%s" port port="%s" protocol="%s" accept' \
    "$source" "$port" "$protocol"
}

query_rule() {
  local protocol="$1" port="$2" source="$3"
  if [[ "$BACKEND" == "ufw" ]]; then
    local pattern
    if [[ "$source" == "any" ]]; then
      pattern="ufw allow $port/$protocol"
    else
      pattern="ufw allow from $source to any port $port proto $protocol"
    fi
    ufw show added | grep -Fqx "$pattern"
  elif [[ "$source" == "any" ]]; then
    firewall-cmd --permanent --zone="$FIREWALL_ZONE" \
      --query-port="$port/$protocol" >/dev/null
  else
    firewall-cmd --permanent --zone="$FIREWALL_ZONE" \
      --query-rich-rule="$(firewalld_rule "$protocol" "$port" "$source")" \
      >/dev/null
  fi
}

mutate_rule() {
  local operation="$1" protocol="$2" port="$3" source="$4"
  if [[ "$BACKEND" == "ufw" ]]; then
    local delete_args=()
    [[ "$operation" == "remove" ]] && delete_args=(--force delete)
    if [[ "$source" == "any" ]]; then
      ufw "${delete_args[@]}" allow "$port/$protocol"
    else
      ufw "${delete_args[@]}" allow from "$source" to any \
        port "$port" proto "$protocol"
    fi
  elif [[ "$source" == "any" ]]; then
    firewall-cmd --permanent --zone="$FIREWALL_ZONE" \
      "--${operation}-port=$port/$protocol"
  else
    firewall-cmd --permanent --zone="$FIREWALL_ZONE" \
      "--${operation}-rich-rule=$(firewalld_rule "$protocol" "$port" "$source")"
  fi
}

if [[ "$ACTION" =~ ^(plan|apply)$ ]]; then
  load_current_rules
  print_plan
fi
if [[ "$ACTION" == "plan" ]]; then
  [[ ! -e "$LOCAL_MARKER" ]] ||
    echo "Warning: this installation already records applied firewall rules."
  exit 0
fi
if ((EUID != 0)); then
  echo "Firewall apply/remove must be launched explicitly as root." >&2
  echo "This script never invokes sudo or asks for a password." >&2
  exit 1
fi
for command_name in mkdir chmod chown rm rmdir; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Yappa firewall mutation requires $command_name." >&2
    exit 1
  fi
done

if [[ "$ACTION" == "apply" ]]; then
  if [[ -e "$REGISTRATION" || -e "$LOCAL_MARKER" ]]; then
    echo "Yappa firewall rules are already registered." >&2
    exit 1
  fi
  INSTALL_OWNER="$(stat -c '%u:%g' "$SCRIPT_ROOT")"
  [[ "$INSTALL_OWNER" =~ ^[0-9]+:[0-9]+$ ]] ||
    { echo "Yappa installation ownership is unsafe." >&2; exit 1; }
  if [[ -e "$HOST_STATE_ROOT" ]] &&
    { [[ ! -d "$HOST_STATE_ROOT" || -L "$HOST_STATE_ROOT" ]] ||
      [[ "$(stat -c '%u:%g:%a' "$HOST_STATE_ROOT")" != "$INSTALL_OWNER:700" ]]; }; then
    echo "Yappa host-state path is unsafe." >&2
    exit 1
  fi
  if [[ "$BACKEND" == "ufw" ]]; then
    command -v ufw >/dev/null 2>&1 ||
      { echo "ufw is unavailable." >&2; exit 1; }
    ufw status | grep -Fq 'Status: active' ||
      { echo "ufw must already be active; Yappa will not enable it." >&2; exit 1; }
  else
    command -v firewall-cmd >/dev/null 2>&1 ||
      { echo "firewalld is unavailable." >&2; exit 1; }
    firewall-cmd --state | grep -Fqx running ||
      { echo "firewalld must already be running; Yappa will not start it." >&2; exit 1; }
    FIREWALL_ZONE="$(firewall-cmd --get-default-zone)"
    [[ "$FIREWALL_ZONE" =~ ^[A-Za-z0-9_-]+$ ]] ||
      { echo "firewalld returned an unsafe default zone." >&2; exit 1; }
  fi
  for rule in "${RULES[@]}"; do
    IFS='|' read -r protocol port source <<< "$rule"
    if query_rule "$protocol" "$port" "$source"; then
      echo "A requested firewall rule already exists; refusing ambiguous ownership." >&2
      exit 1
    fi
  done
  if [[ -e "$ROOT_STATE_DIRECTORY" ]]; then
    if [[ ! -d "$ROOT_STATE_DIRECTORY" ||
      -L "$ROOT_STATE_DIRECTORY" ||
      "$(stat -c '%u:%a' "$ROOT_STATE_DIRECTORY")" != "0:700" ]]; then
      echo "Yappa root firewall-state directory is unsafe." >&2
      exit 1
    fi
  else
    mkdir -m 700 "$ROOT_STATE_DIRECTORY"
  fi
  APPLIED_RULES=()
  rollback_partial_apply() {
    local status=$?
    trap - EXIT INT TERM
    local index rule protocol port source
    for ((index=${#APPLIED_RULES[@]} - 1; index >= 0; index--)); do
      rule="${APPLIED_RULES[index]}"
      IFS='|' read -r protocol port source <<< "$rule"
      mutate_rule remove "$protocol" "$port" "$source" >/dev/null 2>&1 || true
    done
    [[ "$BACKEND" != "firewalld" ]] ||
      firewall-cmd --reload >/dev/null 2>&1 || true
    rm -f -- "$REGISTRATION" "$LOCAL_MARKER"
    rmdir --ignore-fail-on-non-empty \
      "$ROOT_STATE_DIRECTORY" "$HOST_STATE_ROOT" 2>/dev/null || true
    exit "$status"
  }
  trap rollback_partial_apply EXIT INT TERM
  for rule in "${RULES[@]}"; do
    IFS='|' read -r protocol port source <<< "$rule"
    mutate_rule add "$protocol" "$port" "$source"
    APPLIED_RULES+=("$rule")
  done
  [[ "$BACKEND" != "firewalld" ]] || firewall-cmd --reload
  {
    printf 'backend=%s\n' "$BACKEND"
    [[ "$BACKEND" != "firewalld" ]] ||
      printf 'zone=%s\n' "$FIREWALL_ZONE"
    printf 'rule=%s\n' "${RULES[@]}"
  } > "$REGISTRATION"
  chmod 600 "$REGISTRATION"
  mkdir -p -m 700 "$HOST_STATE_ROOT"
  chown "$INSTALL_OWNER" "$HOST_STATE_ROOT"
  chmod 700 "$HOST_STATE_ROOT"
  printf '%s\n' "$PATH_DIGEST" > "$LOCAL_MARKER"
  chmod 600 "$LOCAL_MARKER"
  chown "$INSTALL_OWNER" "$LOCAL_MARKER"
  trap - EXIT INT TERM
  echo "Yappa firewall rules applied and recorded."
  exit 0
fi

if [[ ! -d "$ROOT_STATE_DIRECTORY" ||
  -L "$ROOT_STATE_DIRECTORY" ||
  "$(stat -c '%u:%a' "$ROOT_STATE_DIRECTORY")" != "0:700" ||
  ! -f "$REGISTRATION" ||
  -L "$REGISTRATION" ||
  "$(stat -c '%u:%a' "$REGISTRATION")" != "0:600" ]]; then
  echo "No safe Yappa firewall registration exists." >&2
  exit 1
fi
BACKEND="$(sed -n 's/^backend=//p' "$REGISTRATION")"
FIREWALL_ZONE="$(sed -n 's/^zone=//p' "$REGISTRATION")"
mapfile -t RULES < <(sed -n 's/^rule=//p' "$REGISTRATION")
if [[ ! "$BACKEND" =~ ^(ufw|firewalld)$ || ${#RULES[@]} -eq 0 ]] ||
  [[ "$BACKEND" == "firewalld" && ! "$FIREWALL_ZONE" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "Yappa firewall registration is malformed." >&2
  exit 1
fi
for rule in "${RULES[@]}"; do
  IFS='|' read -r protocol port source <<< "$rule"
  if [[ ! "$protocol" =~ ^(tcp|udp)$ ]] ||
    ! validate_port_spec "$port" ||
    { [[ "$source" != "any" ]] && ! validate_ipv4_cidr "$source"; }; then
    echo "Yappa firewall registration contains an unsafe rule." >&2
    exit 1
  fi
done
for ((index=${#RULES[@]} - 1; index >= 0; index--)); do
  IFS='|' read -r protocol port source <<< "${RULES[index]}"
  mutate_rule remove "$protocol" "$port" "$source"
done
[[ "$BACKEND" != "firewalld" ]] || firewall-cmd --reload
rm -f -- "$REGISTRATION"
rm -f -- "$LOCAL_MARKER"
rmdir --ignore-fail-on-non-empty "$ROOT_STATE_DIRECTORY" 2>/dev/null || true
rmdir --ignore-fail-on-non-empty "$HOST_STATE_ROOT" 2>/dev/null || true
echo "Yappa firewall rules removed. Other host firewall rules were untouched."
