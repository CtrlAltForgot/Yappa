#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cargo build \
  --locked \
  --manifest-path "$repository_root/client/native/yappa_mls/Cargo.toml"
cargo test \
  --locked \
  --manifest-path "$repository_root/client/native/yappa_mls/Cargo.toml"
"$repository_root/client/native/yappa_mls/scripts/test_openmls_vectors.sh"

cd "$repository_root/client"
flutter pub get --enforce-lockfile
flutter analyze
flutter test
