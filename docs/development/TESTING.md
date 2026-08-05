# Testing

Use the same entry points as the repository workflows where practical.

## Server

```bash
cd server
npm ci
npm audit --omit=dev --audit-level=moderate
npm test
```

`npm test` runs the repository's backend security, authorization, migration,
deployment, backup/recovery, secret-scan, and lifecycle integration suite.

## Client

The shared CI gate is:

```bash
.github/scripts/validate-client.sh
```

It includes the native MLS/vector gates plus Flutter analysis and tests. For a
smaller client-only check:

```bash
cd client
flutter analyze
flutter test
```

Desktop packaging workflows are manual and platform-specific. Do not claim a
platform passed unless the exact command/workflow and revision succeeded.

[Development](DEVELOPMENT.md) · [Project home](../../README.md) · [Documentation index](../README.md)
