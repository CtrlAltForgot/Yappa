#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
client_root="$repository_root/client"
safe_version="${1:?safe release version is required}"
release_source="$(mktemp -d "${TMPDIR:-/tmp}/yappa-macos-release.XXXXXX")"
diagnostics="$repository_root/.artifacts/diagnostics/macos"

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
export PUB_CACHE="$release_source/pub-cache"

cd "$release_source/client"
flutter pub get --enforce-lockfile
flutter build macos --release \
  --split-debug-info=build/macos-symbols \
  2>&1 | tee "$diagnostics/flutter-build.log"

app="$release_source/client/build/macos/Build/Products/Release/Yappa.app"
executable="$app/Contents/MacOS/Yappa"
mls="$app/Contents/Frameworks/libyappa_mls.dylib"
test -x "$executable"
test -f "$mls"
otool -L "$mls"
codesign --verify --deep --strict "$app"

while IFS= read -r -d '' binary; do
  if otool -l "$binary" 2>/dev/null \
    | grep -A2 LC_RPATH \
    | grep -E 'path (/Users/|/home/|/tmp/)'; then
    echo "Absolute build path found in macOS runtime search metadata: $binary" >&2
    exit 1
  fi
done < <(find "$app" -type f -perm -111 -print0)

entitlements="$diagnostics/yappa-entitlements.plist"
codesign -d --entitlements :- "$app" >"$entitlements"
for entitlement in \
  com.apple.security.app-sandbox \
  com.apple.security.network.client \
  com.apple.security.device.audio-input \
  com.apple.security.device.camera; do
  test "$(plutil -extract "$entitlement" raw "$entitlements")" = "true"
done

if grep -R -a -E -l \
  '/Users/|/home/|sslip\.io|codex-yappa|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' \
  "$app"; then
  echo "Forbidden builder path, secret, or retired transport marker in macOS bundle." >&2
  exit 1
fi

"$executable" >"$diagnostics/smoke.log" 2>&1 &
pid=$!
sleep 8
if ! kill -0 "$pid" 2>/dev/null; then
  cat "$diagnostics/smoke.log" >&2
  wait "$pid"
  exit 1
fi
kill -TERM "$pid"
wait "$pid" || status=$?
if [[ "${status:-0}" -ne 0 && "${status:-0}" -ne 143 ]]; then
  cat "$diagnostics/smoke.log" >&2
  exit 1
fi

archive="$client_root/dist/Yappa-${safe_version}-macos.zip"
rm -f -- "$archive"
mkdir -p "$client_root/dist"
(
  cd "$(dirname "$app")"
  zip -r "$archive" Yappa.app
)
