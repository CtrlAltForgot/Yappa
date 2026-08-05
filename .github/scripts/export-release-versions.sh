#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$repository_root/.github/release-versions.json"
output_file="${GITHUB_OUTPUT:-}"

if [[ -z "$output_file" ]]; then
  echo "GITHUB_OUTPUT is required." >&2
  exit 1
fi

node -e '
  const fs = require("fs");
  const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const required = [
    ["yappa", manifest.yappa],
    ["flutter", manifest.flutter],
    ["rust", manifest.rust],
    ["libsodium_version", manifest.libsodium?.version],
    ["libsodium_url", manifest.libsodium?.url],
    ["libsodium_sha256", manifest.libsodium?.sha256],
    ["libsodium_source_url", manifest.libsodium?.sourceUrl],
    ["libsodium_source_sha256", manifest.libsodium?.sourceSha256],
  ];
  for (const [name, value] of required) {
    if (typeof value !== "string" || value.length === 0 || value.includes("\n")) {
      throw new Error(`Invalid release version field: ${name}`);
    }
    fs.appendFileSync(process.argv[2], `${name}=${value}\n`);
  }
  fs.appendFileSync(
    process.argv[2],
    `safe_yappa=${manifest.yappa.replaceAll("+", "-")}\n`,
  );
' "$manifest" "$output_file"
