#!/bin/sh
set -eu

MLS_ROOT="$PROJECT_DIR/../native/yappa_mls"
MLS_TARGET_DIR="$PROJECT_DIR/../build/macos/yappa_mls"

case "$CONFIGURATION" in
  Debug)
    MLS_PROFILE="dev"
    MLS_OUTPUT_DIR="debug"
    ;;
  *)
    MLS_PROFILE="release"
    MLS_OUTPUT_DIR="release"
    ;;
esac

mkdir -p "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"

RUSTFLAGS="--remap-path-prefix=$HOME=/_yappa_build_home" \
  cargo build \
    --locked \
    --profile "$MLS_PROFILE" \
    --manifest-path "$MLS_ROOT/Cargo.toml" \
    --target-dir "$MLS_TARGET_DIR"

install -m 755 \
  "$MLS_TARGET_DIR/$MLS_OUTPUT_DIR/libyappa_mls.dylib" \
  "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libyappa_mls.dylib"

SODIUM_SOURCE="${YAPPA_SODIUM_DYLIB:-}"
if [ -z "$SODIUM_SOURCE" ]; then
  for candidate in \
    /opt/homebrew/lib/libsodium.dylib \
    /usr/local/lib/libsodium.dylib; do
    if [ -f "$candidate" ]; then
      SODIUM_SOURCE="$candidate"
      break
    fi
  done
fi
if [ -z "$SODIUM_SOURCE" ] || [ ! -f "$SODIUM_SOURCE" ]; then
  echo "A pinned libsodium dylib is required for the macOS bundle." >&2
  exit 1
fi
install -m 755 \
  "$SODIUM_SOURCE" \
  "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libsodium.dylib"
install_name_tool -id @rpath/libsodium.dylib \
  "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libsodium.dylib"

# The outer app is signed later by Xcode. Sign the nested native library here
# so the hardened app bundle does not contain an unsigned executable image.
codesign --force --sign - \
  "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libyappa_mls.dylib"
codesign --force --sign - \
  "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libsodium.dylib"
