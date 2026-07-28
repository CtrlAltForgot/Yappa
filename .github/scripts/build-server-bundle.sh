#!/usr/bin/env bash
set -euo pipefail
umask 077

REPOSITORY_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
SERVER_ROOT="$REPOSITORY_ROOT/server"
RELEASE_MANIFEST="$REPOSITORY_ROOT/.github/release-versions.json"

VERSION="${1:-}"
OUTPUT_DIRECTORY="${2:-$REPOSITORY_ROOT/dist/server}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(node -e '
    const fs = require("fs");
    const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(manifest.yappa);
  ' "$RELEASE_MANIFEST")"
fi
if [[ ! "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
  echo "Invalid Yappa server bundle version: $VERSION" >&2
  exit 1
fi

SOURCE_COMMIT="${YAPPA_SOURCE_COMMIT:-}"
if [[ -z "$SOURCE_COMMIT" ]]; then
  SOURCE_COMMIT="$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)"
fi
if [[ ! "$SOURCE_COMMIT" =~ ^[a-f0-9]{40}$ ]]; then
  echo "YAPPA_SOURCE_COMMIT must be a full lowercase Git commit." >&2
  exit 1
fi

SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}"
if [[ -z "$SOURCE_DATE_EPOCH" ]]; then
  SOURCE_DATE_EPOCH="$(git -C "$REPOSITORY_ROOT" show -s --format=%ct "$SOURCE_COMMIT")"
fi
if [[ ! "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]]; then
  echo "SOURCE_DATE_EPOCH must be an integer." >&2
  exit 1
fi

for command_name in git install tar gzip sha256sum node find; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Server bundle creation requires $command_name." >&2
    exit 1
  fi
done

BUNDLE_NAME="yappa-server-$VERSION"
ARCHIVE_NAME="$BUNDLE_NAME.tar.gz"
TEMPORARY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/yappa-server-bundle.XXXXXXXX")"
STAGING_ROOT="$TEMPORARY_ROOT/$BUNDLE_NAME"
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  rm -rf -- "$TEMPORARY_ROOT"
  exit "$status"
}
trap cleanup EXIT INT TERM

RUNTIME_FILES=(
  ".dockerignore"
  ".env.example"
  "Caddyfile"
  "DEPLOYMENT.md"
  "Dockerfile"
  "Install-Yappa.ps1"
  "MIGRATIONS.md"
  "backup-yappa.sh"
  "docker-compose.yml"
  "install-manifest.json"
  "install-manifest.schema.json"
  "install-yappa.sh"
  "package-lock.json"
  "package.json"
  "setup-domain.sh"
  "src/auth.js"
  "src/config.js"
  "src/db.js"
  "src/lan-discovery-relay.js"
  "src/safe-preview-lookup.js"
  "src/server.js"
  "start-yappa.sh"
  "verify-yappa-backup.sh"
)

for relative_path in "${RUNTIME_FILES[@]}"; do
  source_path="$SERVER_ROOT/$relative_path"
  if [[ ! -f "$source_path" ]]; then
    echo "Required server bundle input is missing: $relative_path" >&2
    exit 1
  fi
  install -D -m 0644 "$source_path" "$STAGING_ROOT/$relative_path"
done
for executable_name in \
  install-yappa.sh \
  start-yappa.sh \
  setup-domain.sh \
  backup-yappa.sh \
  verify-yappa-backup.sh; do
  chmod 0755 "$STAGING_ROOT/$executable_name"
done

cat > "$STAGING_ROOT/BUILD-METADATA.json" <<EOF
{
  "schemaVersion": 1,
  "product": "Yappa Server",
  "version": "$VERSION",
  "sourceCommit": "$SOURCE_COMMIT",
  "sourceDateEpoch": $SOURCE_DATE_EPOCH
}
EOF
chmod 0644 "$STAGING_ROOT/BUILD-METADATA.json"

if find "$STAGING_ROOT" \
  \( -name '.env' -o -name 'livekit.yaml' -o -name 'node_modules' \
     -o -name 'data' -o -name '*.db' -o -name '*.age' \) \
  -print -quit |
  grep -q .; then
  echo "Server bundle contains generated state, secrets, or dependencies." >&2
  exit 1
fi
if grep -RIE \
  --exclude='.env.example' \
  --exclude='package-lock.json' \
  --exclude='install-manifest.json' \
  --exclude='install-manifest.schema.json' \
  '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,})' \
  "$STAGING_ROOT" >/dev/null; then
  echo "Server bundle contains a forbidden secret marker." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIRECTORY"
TEMPORARY_ARCHIVE="$OUTPUT_DIRECTORY/.$ARCHIVE_NAME.partial"
FINAL_ARCHIVE="$OUTPUT_DIRECTORY/$ARCHIVE_NAME"
CHECKSUM_FILE="$FINAL_ARCHIVE.sha256"
if [[ -e "$FINAL_ARCHIVE" || -e "$CHECKSUM_FILE" ]]; then
  echo "Refusing to overwrite an existing server bundle." >&2
  exit 1
fi
trap 'rm -f -- "$TEMPORARY_ARCHIVE" "$FINAL_ARCHIVE" "$CHECKSUM_FILE"; cleanup' EXIT INT TERM

tar \
  --sort=name \
  --format=posix \
  --mtime="@$SOURCE_DATE_EPOCH" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --pax-option=delete=atime,delete=ctime \
  --directory="$TEMPORARY_ROOT" \
  --create \
  "$BUNDLE_NAME" |
  gzip -n > "$TEMPORARY_ARCHIVE"
chmod 0644 "$TEMPORARY_ARCHIVE"
mv -- "$TEMPORARY_ARCHIVE" "$FINAL_ARCHIVE"

(
  cd "$OUTPUT_DIRECTORY"
  sha256sum "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)

ARCHIVE_LISTING="$(tar -tzf "$FINAL_ARCHIVE")"
for required_entry in \
  "$BUNDLE_NAME/BUILD-METADATA.json" \
  "$BUNDLE_NAME/install-manifest.json" \
  "$BUNDLE_NAME/docker-compose.yml" \
  "$BUNDLE_NAME/src/server.js"; do
  if ! grep -Fxq "$required_entry" <<< "$ARCHIVE_LISTING"; then
    echo "Packaged server archive is missing $required_entry." >&2
    exit 1
  fi
done
if grep -Eq \
  '(^|/)(\.env|livekit\.yaml|node_modules|data)(/|$)|\.(db|age)$' \
  <<< "$ARCHIVE_LISTING"; then
  echo "Packaged server archive contains forbidden generated state." >&2
  exit 1
fi

trap - EXIT INT TERM
rm -rf -- "$TEMPORARY_ROOT"
echo "Server bundle: $FINAL_ARCHIVE"
echo "Checksum:      $CHECKSUM_FILE"
