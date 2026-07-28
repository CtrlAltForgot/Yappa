#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
client_root="$repository_root/client"
safe_version="${1:?safe release version is required}"
release_source="$(mktemp -d "${TMPDIR:-/tmp}/yappa-linux-release.XXXXXX")"
diagnostics="$repository_root/.artifacts/diagnostics/linux"

cleanup() {
  rm -rf -- "$release_source"
}
trap cleanup EXIT

mkdir -p "$diagnostics"
cp -a "$client_root" "$release_source/client"
rm -rf \
  "$release_source/client/.dart_tool" \
  "$release_source/client/build" \
  "$release_source/client/dist"

cd "$release_source/client"
flutter pub get --enforce-lockfile
flutter build linux --release \
  --split-debug-info=build/linux-symbols \
  2>&1 | tee "$diagnostics/flutter-build.log"

bundle="$release_source/client/build/linux/x64/release/bundle"
test -x "$bundle/Yappa"
test -f "$bundle/lib/libyappa_mls.so"

while IFS= read -r -d '' file; do
  dynamic="$(readelf -d "$file" 2>/dev/null || true)"
  if grep -E 'RPATH|RUNPATH' <<<"$dynamic" \
    | grep -E '/home/|/Users/|[A-Za-z]:\\\\'; then
    echo "Absolute build path found in runtime search metadata: $file" >&2
    exit 1
  fi
done < <(find "$bundle" -type f -print0)

while IFS= read -r -d '' library; do
  if ldd "$library" 2>/dev/null | grep -q 'not found'; then
    echo "Unresolved bundled dependency: $library" >&2
    ldd "$library" >&2 || true
    exit 1
  fi
done < <(
  find "$bundle/lib" -maxdepth 1 -type f \
    \( -name '*.so' -o -name '*.so.*' \) -print0
)

if grep -R -a -E -l \
  '/home/|/Users/|[A-Za-z]:\\\\Users\\\\' \
  "$bundle"; then
  echo "Builder home path found in Linux bundle." >&2
  exit 1
fi

if grep -R -a -E -l \
  'sslip\.io|codex-yappa|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' \
  "$bundle"; then
  echo "Forbidden secret or retired transport marker in Linux bundle." >&2
  exit 1
fi

version_dir="$client_root/dist/Yappa-${safe_version}-linux-x64"
archive="$client_root/dist/Yappa-${safe_version}-linux-x64.tar.gz"
rm -rf -- "$version_dir" "$archive"
mkdir -p "$version_dir/assets"
cp -a "$bundle/." "$version_dir/"
cp "$client_root/assets/branding/yappa_logo.png" \
  "$version_dir/assets/yappa_logo.png"
cp "$client_root/packaging/linux/run-yappa.sh" "$version_dir/run-yappa.sh"
chmod +x "$version_dir/run-yappa.sh"
cp "$repository_root/.github/templates/README-Linux.txt" \
  "$version_dir/README-Linux.txt"
tar -C "$client_root/dist" -czf "$archive" \
  "Yappa-${safe_version}-linux-x64"
