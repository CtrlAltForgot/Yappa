#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MANIFEST="$SCRIPT_ROOT/install-manifest.json"
COMMAND="${1:-help}"
shift || true

usage() {
  cat <<'EOF'
Usage:
  ./install-yappa.sh preflight
  ./install-yappa.sh install --local-source [--lan]
  ./install-yappa.sh start [--lan]
  ./install-yappa.sh stop
  ./install-yappa.sh status
  ./install-yappa.sh logs
  ./install-yappa.sh backup /absolute/path/backup.tar.gz.age
  ./install-yappa.sh verify /absolute/path/backup.tar.gz.age

This development installer operates only on the checked-out source tree.
Remote installation remains disabled until the release manifest contains a
signed server bundle, checksums, and release-validated host targets.
EOF
}

require_manifest() {
  if [[ ! -f "$MANIFEST" ]]; then
    echo "Yappa install manifest is missing: $MANIFEST" >&2
    exit 1
  fi
  if command -v node >/dev/null 2>&1; then
    node "$SCRIPT_ROOT/test/install_manifest.js" >/dev/null
  elif ! grep -Eq '"schemaVersion"[[:space:]]*:[[:space:]]*1' "$MANIFEST"; then
    echo "Unsupported or malformed Yappa install manifest." >&2
    exit 1
  fi
}

check_command() {
  local command_name="$1"
  if command -v "$command_name" >/dev/null 2>&1; then
    printf 'ok      %s\n' "$command_name"
  else
    printf 'missing %s\n' "$command_name"
    PREFLIGHT_FAILED=true
  fi
}

preflight() {
  require_manifest
  local architecture
  architecture="$(uname -m)"
  if [[ "$architecture" == "x86_64" || "$architecture" == "amd64" ]]; then
    printf 'ok      architecture %s\n' "$architecture"
  else
    printf 'blocked architecture %s (release target is x86_64)\n' "$architecture"
    PREFLIGHT_FAILED=true
  fi

  for command_name in docker curl tar age sqlite3; do
    check_command "$command_name"
  done
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      printf 'ok      docker compose v2\n'
    else
      printf 'missing docker compose v2\n'
      PREFLIGHT_FAILED=true
    fi
  fi

  local memory_mib
  memory_mib="$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || true)"
  if [[ "$memory_mib" =~ ^[0-9]+$ ]] && ((memory_mib >= 4096)); then
    printf 'ok      memory %s MiB\n' "$memory_mib"
  else
    printf 'blocked memory %s MiB (minimum 4096 MiB)\n' "${memory_mib:-unknown}"
    PREFLIGHT_FAILED=true
  fi

  local free_disk_mib
  free_disk_mib="$(df -Pk "$SCRIPT_ROOT" | awk 'NR == 2 { print int($4 / 1024) }')"
  if [[ "$free_disk_mib" =~ ^[0-9]+$ ]] && ((free_disk_mib >= 10240)); then
    printf 'ok      free disk %s MiB\n' "$free_disk_mib"
  else
    printf 'blocked free disk %s MiB (minimum 10240 MiB)\n' "${free_disk_mib:-unknown}"
    PREFLIGHT_FAILED=true
  fi

  if [[ "$PREFLIGHT_FAILED" == true ]]; then
    echo "Yappa server preflight failed." >&2
    return 1
  fi
  echo "Yappa server preflight passed."
}

require_initialized() {
  require_manifest
  if [[ ! -f "$SCRIPT_ROOT/.env" ]]; then
    echo "No initialized Yappa server exists in $SCRIPT_ROOT." >&2
    echo "Run ./install-yappa.sh install --local-source first." >&2
    exit 1
  fi
}

PREFLIGHT_FAILED=false
case "$COMMAND" in
  help | --help | -h)
    usage
    ;;
  preflight)
    if [[ $# -ne 0 ]]; then
      usage
      exit 1
    fi
    preflight
    ;;
  install)
    LOCAL_SOURCE=false
    LAN_MODE=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --local-source) LOCAL_SOURCE=true ;;
        --lan) LAN_MODE=true ;;
        *)
          echo "Unknown install option: $1" >&2
          usage
          exit 1
          ;;
      esac
      shift
    done
    require_manifest
    if [[ "$LOCAL_SOURCE" != true ]]; then
      echo "Remote installation is unavailable for this development release." >&2
      echo "No signed server bundle or release-validated host target is published." >&2
      exit 1
    fi
    preflight
    echo "Starting the checked-out development server from $SCRIPT_ROOT."
    if [[ "$LAN_MODE" == true ]]; then
      "$SCRIPT_ROOT/start-yappa.sh" --lan
    else
      "$SCRIPT_ROOT/start-yappa.sh"
    fi
    ;;
  start)
    require_manifest
    if [[ "${1:-}" == "--lan" && $# -eq 1 ]]; then
      "$SCRIPT_ROOT/start-yappa.sh" --lan
    elif [[ $# -eq 0 ]]; then
      "$SCRIPT_ROOT/start-yappa.sh"
    else
      usage
      exit 1
    fi
    ;;
  stop)
    require_initialized
    if [[ $# -ne 0 ]]; then
      usage
      exit 1
    fi
    docker compose --project-directory "$SCRIPT_ROOT" down
    ;;
  status)
    require_initialized
    if [[ $# -ne 0 ]]; then
      usage
      exit 1
    fi
    docker compose --project-directory "$SCRIPT_ROOT" ps
    ;;
  logs)
    require_initialized
    if [[ $# -ne 0 ]]; then
      usage
      exit 1
    fi
    docker compose --project-directory "$SCRIPT_ROOT" logs --tail 200
    ;;
  backup)
    require_initialized
    if [[ $# -ne 1 ]]; then
      usage
      exit 1
    fi
    "$SCRIPT_ROOT/backup-yappa.sh" "$1"
    ;;
  verify)
    require_manifest
    if [[ $# -ne 1 ]]; then
      usage
      exit 1
    fi
    "$SCRIPT_ROOT/verify-yappa-backup.sh" "$1"
    ;;
  restore | upgrade | rollback | uninstall)
    require_manifest
    echo "The '$COMMAND' lifecycle command is specified but not implemented safely yet." >&2
    exit 1
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage
    exit 1
    ;;
esac
