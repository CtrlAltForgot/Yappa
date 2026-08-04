# Project Status

_Snapshot: 2026-08-04_

Yappa is in pre-alpha stabilization and limited friend testing. It is intended
for contributors and informed testers who accept data loss, compatibility
breakage, unsigned binaries, and incomplete security/platform validation.

## Working capabilities

- Desktop server connection, identity pinning, accounts, sessions, roles,
  channels, messages, attachments, profiles, and moderation.
- Persistent SQLite-backed server state with forward migrations and encrypted
  operator backup/restore tooling.
- LiveKit-backed voice, camera, screen video, and screen-audio integration.
- Automated backend authorization/security tests and Flutter analysis/tests.
- Manual Linux, Windows, and macOS development-artifact workflows with
  checksum, SPDX evidence, inspection, smoke-test, and provenance steps.

## Experimental capabilities

- MLS-based encrypted text feeds and encrypted attachments.
- Client-held LiveKit media frame-encryption keys.
- Signed LAN discovery and certificate-preserving LAN fallback.
- Cross-device encrypted-history recovery.
- Desktop server installation/lifecycle tooling beyond the proven Unraid path.

## Validation recorded

- Extensive local backend/security, migration, deployment, backup, and client
  test results are recorded in the internal project and security plans.
- Hosted Linux and Windows development artifacts were published as August 2026
  prereleases with checksums/evidence at recorded commits.
- Hosted macOS packaging gates passed at a recorded candidate revision.
- The production-like Unraid deployment has received targeted operator checks.

## Validation still missing

- Independent security and cryptographic review.
- Complete native two-client media, wrong/no-key, and traffic-inspection gates.
- Broad off-LAN, restrictive-network, TURN, NAT, and recovery testing.
- Real Windows/macOS secure-storage and complete client behavior validation.
- Code signing/notarization and supported upgrade/rollback releases.

## Published platforms and signing

Current prerelease user artifacts target Linux x64 and Windows x64. They are
unsigned development/pretest builds. macOS has build evidence but is not
currently presented as a published user build. No platform is production
supported.

## Security review

No independent security review is complete. Do not describe Yappa or any
current build as secure, audited, or verified E2EE.

[Project home](../README.md) · [Documentation index](README.md) · [Limitations](KNOWN_LIMITATIONS.md)
