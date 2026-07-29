# Yappa Release Engineering

Last reviewed: 2026-07-28

## Current contract

Yappa has development artifact workflows, not a public release pipeline.
`.github/release-versions.json` is the central tool/product version input and
still declares `0.1.0-dev`. The server install manifest remains unpublished,
no support target is release-verified, and no client install command is
enabled.

Every desktop build workflow now generates alongside its archive:

- a SHA-256 sidecar;
- an SPDX 2.3 JSON document covering the archive digest and locked npm, Cargo,
  and hosted Pub dependencies;
- a machine-readable evidence record binding artifact name, size, digest,
  product version, and exact source commit; and
- a GitHub artifact attestation signed with a short-lived Sigstore certificate.

The SPDX document is a locked source-dependency SBOM. It does not claim binary
composition analysis, transitive native system-library completeness, license
conclusion, or vulnerability status. Those remain release review inputs.

The server authenticity workflow applies the same evidence format to the
deterministic canonical server bundle. Pull requests exercise all generators
without minting an attestation. Trusted manual/main runs request only
`id-token: write` and `attestations: write` in the evidence job and use the
official attestation action pinned to an exact commit.

Hosted pull-request run `30415903314` passed deterministic evidence, negative
overwrite, dependency-ecosystem, development-tag rejection, canonical bundle,
and artifact-upload checks on commit `578b0a2`. Trusted manual run
`30415925969` created and uploaded a real server-bundle attestation. The
downloaded bundle independently passed:

```bash
gh attestation verify yappa-server-0.1.0-dev.tar.gz \
  --repo CtrlAltForgot/Yappa
```

This proves repository/workflow provenance for that development artifact. It
does not make the artifact a supported or platform-signed release.

## Exact-tag gate

`.github/workflows/release_gate.yml` runs on every `v*` tag with read-only
repository permissions. It requires all of the following before proceeding:

- central version is release-shaped and contains no `-dev` or build metadata;
- tag is exactly `v{central version}`;
- workflow source is one full Git commit;
- server install-manifest version exactly matches;
- server channel is `stable` and publication is explicitly enabled; and
- every publicly supported server target is `verified-release` with its
  install command enabled.

The gate deliberately has no `contents: write` permission and publishes
nothing. Artifact publication stays separate until every artifact is signed,
all release matrices pass, and production publication is explicitly
authorized.

## Remaining signing and publication gates

Public release engineering is incomplete until:

- a Windows code-signing identity and timestamp policy are selected, stored as
  protected environment secrets, applied to every shipped PE file before
  packaging, and verified after packaging;
- an Apple Developer ID identity, hardened-runtime entitlements, notarization
  credentials, and stapling verification are available in a protected macOS
  release environment;
- Linux distribution/signing policy is selected and the archive/package
  signature is independently verified;
- the server bundle and both installer front ends have detached signatures
  whose public verification root is documented and pinned by clients;
- binary/native dependency and license review supplements the source-lock
  SPDX data;
- exact-tag Windows, macOS, hosted Linux, server, security, E2EE, media,
  screen-sharing, and product-readiness matrices pass;
- attestation verification is repeated on the final downloaded release
  assets, not only workflow-local paths;
- checksums, SBOMs, signatures, provenance, vulnerability/support policy, and
  release notes are attached to one immutable release; and
- a human explicitly authorizes GitHub Release publication and production
  deployment.

Never store a PFX, Apple certificate/private key, signing password, API token,
notarization credential, or production environment file in this repository.
