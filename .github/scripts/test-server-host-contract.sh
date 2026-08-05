#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

REPOSITORY_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
EXPECTED_ID="${1:-}"
EXPECTED_VERSION="${2:-}"
TARGET_ID="${3:-}"
if [[ $# -ne 3 || ! "$EXPECTED_ID" =~ ^[a-z0-9]+$ ||
  ! "$EXPECTED_VERSION" =~ ^[0-9]+([.][0-9]+)*$ ||
  ! "$TARGET_ID" =~ ^[a-z0-9-]+$ ]]; then
  echo "Use: test-server-host-contract.sh OS_ID VERSION_PREFIX TARGET_ID" >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "$EXPECTED_ID" ||
  "${VERSION_ID:-}" != "$EXPECTED_VERSION"* ]]; then
  echo "Conformance container identity does not match its declared target." >&2
  echo "Expected $EXPECTED_ID $EXPECTED_VERSION; found ${ID:-?} ${VERSION_ID:-?}." >&2
  exit 1
fi
if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "Tier-1 Linux conformance currently requires x86_64." >&2
  exit 1
fi

node - "$REPOSITORY_ROOT/server/install-manifest.json" "$TARGET_ID" <<'NODE'
const fs = require('fs');
const [manifestPath, targetId] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const target = manifest.supportTargets.find((entry) => entry.id === targetId);
if (!target || target.os !== 'linux' || target.architecture !== 'x86_64') {
  throw new Error(`Missing matching Linux install target: ${targetId}`);
}
if (target.publiclySupported || target.installCommandAvailable) {
  throw new Error(`Container contract cannot promote release support: ${targetId}`);
}
NODE

for script in \
  "$REPOSITORY_ROOT"/server/*.sh \
  "$REPOSITORY_ROOT"/.github/scripts/build-server-bundle.sh; do
  bash -n "$script"
done

TEMPORARY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/yappa-host-contract.XXXXXXXX")"
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  rm -rf -- "$TEMPORARY_ROOT"
  exit "$status"
}
trap cleanup EXIT INT TERM
FAKE_BIN="$TEMPORARY_ROOT/bin"
mkdir -m 700 "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "compose version" ]]; then
  printf 'Docker Compose version v2.test\n'
  exit 0
fi
echo "Host-contract Docker shim received an unexpected command." >&2
exit 1
EOF
cat > "$FAKE_BIN/age" <<'EOF'
#!/usr/bin/env bash
echo "Host-contract age shim is preflight-only." >&2
exit 1
EOF
chmod 700 "$FAKE_BIN/docker" "$FAKE_BIN/age"

PATH="$FAKE_BIN:$PATH" "$REPOSITORY_ROOT/server/install-yappa.sh" preflight

BUNDLE_OUTPUT="$TEMPORARY_ROOT/bundle"
"$REPOSITORY_ROOT/.github/scripts/build-server-bundle.sh" \
  "0.1.0-$EXPECTED_ID-contract" "$BUNDLE_OUTPUT"
BUNDLE="$BUNDLE_OUTPUT/yappa-server-0.1.0-$EXPECTED_ID-contract.tar.gz"
DIGEST="$(sha256sum "$BUNDLE" | awk '{print $1}')"
INSTALL_ROOT="$TEMPORARY_ROOT/installed"
"$REPOSITORY_ROOT/server/install-yappa.sh" install \
  --local-bundle "$BUNDLE" \
  --sha256 "$DIGEST" \
  --install-dir "$INSTALL_ROOT" \
  --no-start
if [[ "$(stat -c '%a' "$INSTALL_ROOT")" != "700" ||
  ! -x "$INSTALL_ROOT/install-yappa.sh" ||
  ! -x "$INSTALL_ROOT/firewall-yappa.sh" ||
  ! -x "$INSTALL_ROOT/recover-yappa.sh" ]]; then
  echo "Installed host-contract runtime has invalid files or permissions." >&2
  exit 1
fi

cat > "$INSTALL_ROOT/.env" <<'EOF'
YAPPA_ADDRESS_MODE=automatic-ip
DB_PATH=./data/newchat.db
EOF
chmod 600 "$INSTALL_ROOT/.env"
mkdir -m 700 "$INSTALL_ROOT/data" "$INSTALL_ROOT/.yappa-host-state"
printf 'stopped\n' > "$INSTALL_ROOT/.yappa-host-state/desired-state"
chmod 600 "$INSTALL_ROOT/.yappa-host-state/desired-state"
"$INSTALL_ROOT/install-yappa.sh" firewall-plan --backend ufw |
  grep -Fq 'Raw backend TCP 4100'
PATH="$FAKE_BIN:$PATH" "$INSTALL_ROOT/install-yappa.sh" recover |
  grep -Fq 'intentionally stopped'
if "$INSTALL_ROOT/install-yappa.sh" service-install \
  >"$TEMPORARY_ROOT/service.out" 2>"$TEMPORARY_ROOT/service.err"; then
  echo "Container service registration unexpectedly succeeded." >&2
  exit 1
fi
if ((EUID == 0)); then
  grep -Fq 'must not run as root' "$TEMPORARY_ROOT/service.err"
else
  grep -Fq 'No usable per-user systemd manager' "$TEMPORARY_ROOT/service.err"
fi

echo "Yappa $TARGET_ID host packaging/lifecycle contract passed."
echo "This does not claim Docker, media, systemd, or firewall runtime conformance."
