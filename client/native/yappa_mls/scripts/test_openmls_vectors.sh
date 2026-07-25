#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MLS_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
HPKE_ROOT="$MLS_ROOT/vendor/hpke-rs"
HPKE_TOML_PATH="$HPKE_ROOT"
if command -v cygpath >/dev/null 2>&1; then
  HPKE_TOML_PATH="$(cygpath -m "$HPKE_ROOT")"
fi
VECTOR_LOCK="$SCRIPT_DIR/openmls-v0.8.1-rustcrypto.Cargo.lock"
ARCHIVE_URL="https://github.com/openmls/openmls/archive/refs/tags/openmls-v0.8.1.tar.gz"
ARCHIVE_SHA256="29427912c8190c029340194f56178266a04fc76658c03b5ebdad3df23e5d92f0"

if [[ ! -f "$VECTOR_LOCK" ]]; then
  echo "Pinned OpenMLS vector lockfile is missing." >&2
  exit 1
fi

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/yappa-openmls-vectors.XXXXXX")"
trap 'rm -rf -- "$WORK_ROOT"' EXIT
ARCHIVE_PATH="$WORK_ROOT/openmls-v0.8.1.tar.gz"

curl --fail --location --retry 3 --output "$ARCHIVE_PATH" "$ARCHIVE_URL"
printf '%s  %s\n' "$ARCHIVE_SHA256" "$ARCHIVE_PATH" | sha256sum -c -
tar -xzf "$ARCHIVE_PATH" -C "$WORK_ROOT"
SOURCE_ROOT="$WORK_ROOT/openmls-openmls-v0.8.1"

# The upstream test workspace enables both crypto providers and several
# unrelated binaries by default. Yappa uses only RustCrypto. Remove those
# unused members/features so their separate Libcrux dependency graph cannot
# mask or conflict with Yappa's patched HPKE implementation.
perl -0pi -e '
  s/    "libcrux_crypto",\n//;
  s/    "sqlite_storage",\n//;
  s/    "sqlx_storage",\n//;
  s/    "fuzz",\n//;
  s/    "cli",\n//;
  s/    "interop_client",\n//;
  s/    "openmls-wasm",\n//;
  s/    "delivery-service\/ds",\n//;
  s/    "delivery-service\/ds-lib",\n//;
' "$SOURCE_ROOT/Cargo.toml"
perl -0pi -e '
  s/openmls = \{ path = "\.", features = \[\n    "test-utils",\n    "sqlite-provider",\n    "libcrux-provider",\n\] \}/openmls = { path = ".", features = ["test-utils"] }/;
  s/^openmls_libcrux_crypto = .*\n//mg;
  s/^libcrux-provider = \[[\s\S]*?^\]\n//m;
  s/^    "openmls_libcrux_crypto\?\/extensions-draft-08",\n//m;
' "$SOURCE_ROOT/openmls/Cargo.toml"
perl -0pi -e '
  s/^openmls_libcrux_crypto = .*\n//mg;
  s/^libcrux-provider = .*\n//m;
' "$SOURCE_ROOT/openmls_test/Cargo.toml"
perl -0pi -e 's/^openmls_libcrux_crypto = .*\n//mg' \
  "$SOURCE_ROOT/Cargo.toml"
printf '\n[patch.crates-io]\nhpke-rs = { path = "%s" }\n' "$HPKE_TOML_PATH" \
  >> "$SOURCE_ROOT/Cargo.toml"
cp "$VECTOR_LOCK" "$SOURCE_ROOT/Cargo.lock"

TREE_OUTPUT="$(
  cargo tree \
    --manifest-path "$SOURCE_ROOT/openmls/Cargo.toml" \
    --locked \
    -i hpke-rs
)"
printf '%s\n' "$TREE_OUTPUT"
if ! grep -qE '^hpke-rs v0\.6\.1 \(.+\)$' <<<"$TREE_OUTPUT"; then
  echo "OpenMLS vectors did not resolve Yappa's patched HPKE graph." >&2
  exit 1
fi

cargo test \
  --quiet \
  --manifest-path "$SOURCE_ROOT/openmls/Cargo.toml" \
  --locked \
  --lib \
  read_test_vectors \
  -- \
  --nocapture
