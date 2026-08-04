# Development Guide

## Prerequisites

- Flutter `3.44.7` and its desktop toolchain.
- Rust `1.96.1` for the native MLS bridge.
- Node.js `22.22.1` for CI parity (the package declares Node 18 or newer).
- Platform-native libraries documented in workflows and
  [screen-sharing notes](../platform/SCREEN_SHARING.md).

## Client

```bash
cd client
flutter pub get
flutter run -d linux
```

Select another available desktop device only after installing its supported
toolchain. See [client/README.md](../../client/README.md).

## Server

```bash
cd server
npm ci
npm run dev
```

Direct development startup is loopback-only by default. Use the documented
deployment path for a real self-hosted node; do not treat development defaults
as public deployment guidance.

## Before submitting

Run the applicable commands in [TESTING.md](TESTING.md), update affected
documentation, and inspect `git diff` for secrets, personal data, generated
outputs, and unintended dependency changes.

[Project home](../../README.md) · [Documentation index](../README.md)
