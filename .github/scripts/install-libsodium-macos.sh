#!/usr/bin/env bash
set -euo pipefail

version="${1:?libsodium version is required}"
source_url="${2:?libsodium source URL is required}"
expected_sha256="${3:?libsodium source SHA-256 is required}"
temporary_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
work_root="$(mktemp -d "$temporary_root/yappa-libsodium-build.XXXXXX")"
install_root="$temporary_root/yappa-libsodium-$version"
archive="$work_root/libsodium-$version.tar.gz"

cleanup() {
  rm -rf -- "$work_root"
}
trap cleanup EXIT

curl --fail --location --retry 3 --output "$archive" "$source_url"
actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  echo "libsodium source archive checksum mismatch." >&2
  exit 1
fi

tar -xzf "$archive" -C "$work_root"
source_root="$work_root/libsodium-$version"
test -x "$source_root/configure"
rm -rf -- "$install_root"

(
  cd "$source_root"
  ./configure \
    --prefix="$install_root" \
    --disable-static
  make -j"$(sysctl -n hw.ncpu)"
  make install
)

sodium_dylib="$install_root/lib/libsodium.dylib"
test -f "$sodium_dylib"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    printf 'YAPPA_SODIUM_DYLIB=%s\n' "$sodium_dylib"
    printf 'DYLD_LIBRARY_PATH=%s\n' "$install_root/lib"
  } >>"$GITHUB_ENV"
else
  printf 'YAPPA_SODIUM_DYLIB=%s\n' "$sodium_dylib"
  printf 'DYLD_LIBRARY_PATH=%s\n' "$install_root/lib"
fi
