# Contributing to Yappa

Yappa is pre-alpha. Keep contributions small, focused, evidence-based, and
honest about incomplete validation.

## Setup and testing

Use the [development guide](docs/development/DEVELOPMENT.md),
[testing guide](docs/development/TESTING.md), [client README](client/README.md),
and [server README](server/README.md). Run tests appropriate to every affected
component and report exact commands/results in the pull request.

## Pull requests

- Explain the user problem and keep unrelated changes out.
- Use imperative commit subjects such as `docs: clarify Linux prerequisites`.
- Update architecture, status, release, screen-sharing, and security documents
  whenever their confirmed contracts or evidence change.
- Consider backend storage/API/serialization/realtime/migration/deployment
  implications for every shared or cross-device behavior change.
- Never include production data, private messages, attachments, hostnames/IPs,
  passwords, tokens, keys, databases, or personal profile data.
- Do not expand security/support claims without corresponding evidence.

## Security-sensitive contributions

Never report vulnerabilities publicly; follow [SECURITY.md](SECURITY.md).
Security, authentication, encryption, networking, migration, deployment, and
storage changes require focused negative tests and security-plan updates.

## AI-assisted work

AI assistance is welcome, but contributors must understand, inspect, and
validate every submitted change. Do not submit unreviewed bulk-generated code,
documentation, tests, or claims. The contributor—not the tool—is responsible
for correctness, licensing, privacy, and project fit.

[Project home](README.md) · [Documentation index](docs/README.md)
