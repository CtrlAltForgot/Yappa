#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MANIFEST="$SCRIPT_ROOT/install-manifest.json"
COMMAND="${1:-help}"
shift || true

usage() {
  cat <<'EOF'
Usage:
  ./install-yappa.sh preflight
  ./install-yappa.sh install --local-source [--lan]
  ./install-yappa.sh install --local-bundle ARCHIVE --sha256 DIGEST \
    --install-dir /absolute/new/path [--lan] [--no-start]
  ./install-yappa.sh start [--lan]
  ./install-yappa.sh stop
  ./install-yappa.sh status
  ./install-yappa.sh logs
  ./install-yappa.sh backup /absolute/path/backup.tar.gz.age
  ./install-yappa.sh verify
  ./install-yappa.sh verify-backup /absolute/path/backup.tar.gz.age
  ./install-yappa.sh restore --backup BACKUP --local-bundle BUNDLE \
    --sha256 DIGEST --install-dir /absolute/new/path
  ./install-yappa.sh upgrade --local-bundle BUNDLE --sha256 DIGEST \
    --backup /absolute/new/pre-upgrade-backup.tar.gz.age
  ./install-yappa.sh rollback \
    --backup /absolute/new/pre-rollback-backup.tar.gz.age
  ./install-yappa.sh uninstall \
    --backup /absolute/new/pre-uninstall-backup.tar.gz.age \
    --preserve-data /absolute/new/preserved-state
  ./install-yappa.sh service-install
  ./install-yappa.sh service-status
  ./install-yappa.sh service-remove

This development installer operates only on the locally present server tree or
an explicitly supplied local bundle and checksum. Remote installation remains
disabled until the release manifest contains a signed server bundle, checksums,
and release-validated host targets.
EOF
}

require_manifest() {
  if [[ ! -f "$MANIFEST" ]]; then
    echo "Yappa install manifest is missing: $MANIFEST" >&2
    exit 1
  fi
  if ! grep -Eq '"schemaVersion"[[:space:]]*:[[:space:]]*1' "$MANIFEST" ||
    ! grep -Eq '"product"[[:space:]]*:[[:space:]]*"Yappa Server"' "$MANIFEST"; then
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

install_local_bundle() {
  local archive="$1"
  local expected_sha256="$2"
  local install_directory="$3"
  local no_start="$4"
  local lan_mode="$5"

  if [[ ! "$expected_sha256" =~ ^[a-f0-9]{64}$ ]]; then
    echo "--sha256 must be one full lowercase SHA-256 digest." >&2
    exit 1
  fi
  if [[ "$archive" != /* ]]; then
    archive="$PWD/$archive"
  fi
  if [[ ! -f "$archive" ]]; then
    echo "Local Yappa server bundle was not found: $archive" >&2
    exit 1
  fi
  if [[ "$install_directory" != /* || "$install_directory" == "/" ]]; then
    echo "--install-dir must be a new absolute directory other than /." >&2
    exit 1
  fi
  if [[ -e "$install_directory" ]]; then
    echo "Install directory already exists; refusing to merge or overwrite it." >&2
    exit 1
  fi
  local install_parent
  install_parent="$(dirname -- "$install_directory")"
  if [[ ! -d "$install_parent" || ! -w "$install_parent" ]]; then
    echo "Install directory parent is missing or not writable: $install_parent" >&2
    exit 1
  fi
  for command_name in sha256sum tar mktemp find cp sed awk grep cut dirname mkdir chmod; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Local bundle installation requires $command_name." >&2
      exit 1
    fi
  done

  local actual_sha256
  actual_sha256="$(sha256sum "$archive" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "Local Yappa server bundle checksum did not match." >&2
    exit 1
  fi

  local archive_listing
  archive_listing="$(tar -tzf "$archive")"
  if [[ -z "$archive_listing" ]] ||
    grep -Eq '(^|/)\.\.(/|$)|^/' <<< "$archive_listing"; then
    echo "Local Yappa server bundle contains an unsafe path." >&2
    exit 1
  fi
  local bundle_root_name
  bundle_root_name="${archive_listing%%/*}"
  if [[ ! "$bundle_root_name" =~ ^yappa-server-[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
    echo "Local Yappa server bundle must contain exactly one versioned root." >&2
    exit 1
  fi
  while IFS= read -r archive_entry; do
    if [[ "$archive_entry" != "$bundle_root_name" &&
      "$archive_entry" != "$bundle_root_name/"* ]]; then
      echo "Local Yappa server bundle must contain exactly one versioned root." >&2
      exit 1
    fi
  done <<< "$archive_listing"
  if tar -tvzf "$archive" | cut -c1 | grep -Ev '^[-d]$' | grep -q .; then
    echo "Local Yappa server bundle contains an unsupported file type." >&2
    exit 1
  fi
  if [[ "$no_start" != true ]]; then
    preflight
  fi

  local extraction_root
  extraction_root="$(mktemp -d "${TMPDIR:-/tmp}/yappa-local-install.XXXXXXXX")"
  chmod 700 "$extraction_root"
  cleanup_local_bundle() {
    local status=$?
    trap - EXIT INT TERM
    rm -rf -- "$extraction_root"
    exit "$status"
  }
  trap cleanup_local_bundle EXIT INT TERM

  tar \
    --extract \
    --gzip \
    --file="$archive" \
    --directory="$extraction_root" \
    --no-same-owner \
    --no-same-permissions
  local extracted_bundle="$extraction_root/$bundle_root_name"
  if [[ ! -d "$extracted_bundle" ]] ||
    [[ ! -f "$extracted_bundle/BUILD-METADATA.json" ]] ||
    [[ ! -f "$extracted_bundle/install-manifest.json" ]] ||
    [[ ! -x "$extracted_bundle/install-yappa.sh" ]]; then
    echo "Local Yappa server bundle is incomplete." >&2
    exit 1
  fi
  if find "$extracted_bundle" \
    \( -type l -o \( ! -type f -a ! -type d \) \) \
    -print -quit |
    grep -q .; then
    echo "Local Yappa server bundle contains an unsupported file type." >&2
    exit 1
  fi
  local metadata_version
  metadata_version="$(
    sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)",*[[:space:]]*$/\1/p' \
      "$extracted_bundle/BUILD-METADATA.json"
  )"
  if [[ "$bundle_root_name" != "yappa-server-$metadata_version" ]]; then
    echo "Local Yappa server bundle metadata does not match its root." >&2
    exit 1
  fi

  mkdir -m 700 "$install_directory"
  if ! cp -a "$extracted_bundle/." "$install_directory/"; then
    echo "Bundle copy failed; inspect and remove the new partial directory:" >&2
    echo "$install_directory" >&2
    exit 1
  fi
  chmod 700 "$install_directory"

  trap - EXIT INT TERM
  rm -rf -- "$extraction_root"
  echo "Local Yappa development bundle checksum verified."
  echo "Verified local Yappa development bundle installed at $install_directory."
  if [[ "$no_start" == true ]]; then
    echo "Startup was skipped; the installation has not passed runtime health checks."
    return
  fi
  (
    cd "$install_directory"
    if [[ "$lan_mode" == true ]]; then
      ./install-yappa.sh start --lan
    else
      ./install-yappa.sh start
    fi
  )
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
    LOCAL_BUNDLE=""
    EXPECTED_SHA256=""
    INSTALL_DIRECTORY=""
    LAN_MODE=false
    NO_START=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --local-source) LOCAL_SOURCE=true ;;
        --local-bundle)
          if [[ $# -lt 2 ]]; then
            echo "--local-bundle requires a path." >&2
            exit 1
          fi
          LOCAL_BUNDLE="$2"
          shift
          ;;
        --sha256)
          if [[ $# -lt 2 ]]; then
            echo "--sha256 requires a digest." >&2
            exit 1
          fi
          EXPECTED_SHA256="$2"
          shift
          ;;
        --install-dir)
          if [[ $# -lt 2 ]]; then
            echo "--install-dir requires a path." >&2
            exit 1
          fi
          INSTALL_DIRECTORY="$2"
          shift
          ;;
        --lan) LAN_MODE=true ;;
        --no-start) NO_START=true ;;
        *)
          echo "Unknown install option: $1" >&2
          usage
          exit 1
          ;;
      esac
      shift
    done
    require_manifest
    if [[ "$LOCAL_SOURCE" == true && -n "$LOCAL_BUNDLE" ]]; then
      echo "--local-source and --local-bundle are mutually exclusive." >&2
      exit 1
    fi
    if [[ -n "$LOCAL_BUNDLE" ]]; then
      if [[ -z "$EXPECTED_SHA256" || -z "$INSTALL_DIRECTORY" ]]; then
        echo "--local-bundle requires --sha256 and --install-dir." >&2
        exit 1
      fi
      install_local_bundle \
        "$LOCAL_BUNDLE" \
        "$EXPECTED_SHA256" \
        "$INSTALL_DIRECTORY" \
        "$NO_START" \
        "$LAN_MODE"
      exit 0
    fi
    if [[ -n "$EXPECTED_SHA256" || -n "$INSTALL_DIRECTORY" || "$NO_START" == true ]]; then
      echo "Bundle-only options require --local-bundle." >&2
      exit 1
    fi
    if [[ "$LOCAL_SOURCE" != true ]]; then
      echo "Remote installation is unavailable for this development release." >&2
      echo "No signed server bundle or release-validated host target is published." >&2
      exit 1
    fi
    preflight
    echo "Starting the local development server from $SCRIPT_ROOT."
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
    require_initialized
    if [[ $# -ne 0 ]]; then
      usage
      exit 1
    fi
    "$SCRIPT_ROOT/verify-yappa-install.sh"
    ;;
  verify-backup)
    require_manifest
    if [[ $# -ne 1 ]]; then
      usage
      exit 1
    fi
    "$SCRIPT_ROOT/verify-yappa-backup.sh" "$1"
    ;;
  restore)
    BACKUP_PATH=""
    LOCAL_BUNDLE=""
    EXPECTED_SHA256=""
    INSTALL_DIRECTORY=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --backup | --local-bundle | --sha256 | --install-dir)
          if [[ $# -lt 2 ]]; then
            echo "$1 requires a value." >&2
            exit 1
          fi
          case "$1" in
            --backup) BACKUP_PATH="$2" ;;
            --local-bundle) LOCAL_BUNDLE="$2" ;;
            --sha256) EXPECTED_SHA256="$2" ;;
            --install-dir) INSTALL_DIRECTORY="$2" ;;
          esac
          shift
          ;;
        *)
          echo "Unknown restore option: $1" >&2
          usage
          exit 1
          ;;
      esac
      shift
    done
    require_manifest
    if [[ -z "$BACKUP_PATH" || -z "$LOCAL_BUNDLE" ||
      -z "$EXPECTED_SHA256" || -z "$INSTALL_DIRECTORY" ]]; then
      echo "Restore requires --backup, --local-bundle, --sha256, and --install-dir." >&2
      exit 1
    fi
    if [[ "$INSTALL_DIRECTORY" != /* || "$INSTALL_DIRECTORY" == "/" ]]; then
      echo "--install-dir must be a new absolute directory other than /." >&2
      exit 1
    fi
    INSTALL_PARENT="$(dirname -- "$INSTALL_DIRECTORY")"
    "$SCRIPT_ROOT/restore-yappa-backup.sh" \
      "$BACKUP_PATH" \
      "$LOCAL_BUNDLE" \
      "$EXPECTED_SHA256" \
      "$INSTALL_DIRECTORY" \
      "$INSTALL_PARENT"
    ;;
  upgrade)
    LOCAL_BUNDLE=""
    EXPECTED_SHA256=""
    BACKUP_PATH=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --local-bundle | --sha256 | --backup)
          if [[ $# -lt 2 ]]; then
            echo "$1 requires a value." >&2
            exit 1
          fi
          case "$1" in
            --local-bundle) LOCAL_BUNDLE="$2" ;;
            --sha256) EXPECTED_SHA256="$2" ;;
            --backup) BACKUP_PATH="$2" ;;
          esac
          shift
          ;;
        *)
          echo "Unknown upgrade option: $1" >&2
          usage
          exit 1
          ;;
      esac
      shift
    done
    require_initialized
    if [[ -z "$LOCAL_BUNDLE" || -z "$EXPECTED_SHA256" ||
      -z "$BACKUP_PATH" ]]; then
      echo "Upgrade requires --local-bundle, --sha256, and --backup." >&2
      exit 1
    fi
    "$SCRIPT_ROOT/upgrade-yappa.sh" \
      "$LOCAL_BUNDLE" "$EXPECTED_SHA256" "$BACKUP_PATH"
    ;;
  rollback)
    BACKUP_PATH=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --backup)
          if [[ $# -lt 2 ]]; then
            echo "--backup requires a value." >&2
            exit 1
          fi
          BACKUP_PATH="$2"
          shift
          ;;
        *)
          echo "Unknown rollback option: $1" >&2
          usage
          exit 1
          ;;
      esac
      shift
    done
    require_initialized
    if [[ -z "$BACKUP_PATH" ]]; then
      echo "Rollback requires --backup." >&2
      exit 1
    fi
    "$SCRIPT_ROOT/rollback-yappa.sh" "$BACKUP_PATH"
    ;;
  service-install | service-status | service-remove)
    require_initialized
    if [[ $# -ne 0 ]]; then
      usage
      exit 1
    fi
    "$SCRIPT_ROOT/service-yappa.sh" "${COMMAND#service-}"
    ;;
  uninstall)
    BACKUP_PATH=""
    PRESERVE_DIRECTORY=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --backup | --preserve-data)
          if [[ $# -lt 2 ]]; then
            echo "$1 requires a value." >&2
            exit 1
          fi
          case "$1" in
            --backup) BACKUP_PATH="$2" ;;
            --preserve-data) PRESERVE_DIRECTORY="$2" ;;
          esac
          shift
          ;;
        *)
          echo "Unknown uninstall option: $1" >&2
          usage
          exit 1
          ;;
      esac
      shift
    done
    require_initialized
    if [[ -z "$BACKUP_PATH" || -z "$PRESERVE_DIRECTORY" ]]; then
      echo "Uninstall requires --backup and --preserve-data." >&2
      exit 1
    fi
    "$SCRIPT_ROOT/uninstall-yappa.sh" \
      "$BACKUP_PATH" "$PRESERVE_DIRECTORY"
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage
    exit 1
    ;;
esac
