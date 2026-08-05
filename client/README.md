# Yappa Desktop Client

This directory contains the Flutter desktop client, platform runners, native
MLS bridge, maintained Flutter WebRTC fork, assets, tests, and packaging inputs.

## Development platforms

Linux, Windows, and macOS desktop build workflows exist. Current public pretest
artifacts target Linux x64 and Windows x64; this does not make either platform
production-supported. Native media, secure-storage, WebView, and cryptographic
dependencies require platform-specific validation.

## Toolchain and setup

CI pins Flutter `3.44.7` and Rust `1.96.1`. Install the platform desktop
toolchain and native packages shown in the corresponding workflow.

```bash
flutter pub get
flutter run -d linux
```

Use the appropriate Flutter desktop device on Windows or macOS.

## Analysis and tests

From the repository root, the complete shared client gate is:

```bash
.github/scripts/validate-client.sh
```

For the routine Flutter portion:

```bash
cd client
flutter analyze
flutter test
```

## Release packaging

Manual GitHub Actions workflows build Linux, Windows, and macOS development
artifacts. Repository-owned scripts validate native dependencies, isolate
build paths, smoke-test packages, generate checksums/SPDX evidence, and request
GitHub provenance attestations. Builds remain unsigned pre-alpha artifacts.

[Project home](../README.md) · [Development guide](../docs/development/DEVELOPMENT.md) ·
[Testing](../docs/development/TESTING.md) · [Screen sharing](../docs/platform/SCREEN_SHARING.md)
