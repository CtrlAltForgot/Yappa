# Releasing Yappa

## Version and tag format

- Development artifacts use the centralized version in
  `.github/release-versions.json` (`0.1.0-dev` currently).
- Pretest tags use `v0.1.0-dev.YYYYMMDD` with a numeric suffix for same-day
  replacements, for example `v0.1.0-dev.20260802.3`.
- Production-style `v*` tags trigger the exact-release contract, which rejects
  development, mismatched, or unpublished versions. Publication remains a
  separately authorized operation.

## Candidate checklist

1. Freeze the exact commit and update status, limitations, changelog, and notes.
2. Run backend locked install, production audit, full `npm test`, shared client
   validation, and applicable server/platform contract workflows.
3. Run each intended platform's manual packaging workflow on the exact commit.
4. Review native multi-client/platform evidence and every security claim.
5. Verify archive contents, startup smoke results, checksums, SPDX SBOM evidence,
   build provenance/attestations, and absence of secrets/build paths.
6. Confirm database/config schema compatibility, backup/restore requirements,
   signing/notarization status, and rollback instructions.
7. Publish release notes that state audience, support, signing, security review,
   platform validation, exact commit, checksums, known limitations, and replacement.

Current artifacts are unsigned. Do not imply that checksums, SPDX evidence, or
GitHub attestations replace platform signing or independent security review.

## Superseded and rollback handling

Keep historical tags/releases. Mark replaced builds as prereleases and prefix
their titles `[Superseded]`; link prominently to the replacement. Never make an
older test build stable or GitHub's “Latest” release. Roll back application
state only through the matching encrypted backup/configuration and software
revision described in [server/MIGRATIONS.md](../../server/MIGRATIONS.md).

[Project home](../../README.md) · [Documentation index](../README.md) ·
[Release engineering](RELEASE_ENGINEERING.md)
