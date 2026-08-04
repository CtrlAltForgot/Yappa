# Yappa Agent Instructions

Before changing this repository, read `docs/internal/PROJECT_PLAN.md`.
For voice, camera, desktop audio, or screen-sharing work, also read
`docs/platform/SCREEN_SHARING.md`.
For authentication, networking, encryption, messages, attachments, sessions,
storage, deployment exposure, or release-readiness work, also read
`docs/security/SECURITY_PLAN.md`.

The deployment and client/backend synchronization rules in that file are part
of the definition of done. In particular:

- Any shared or cross-device client customization must have matching backend
  storage, API, serialization, realtime propagation, and migration support.
- Any completed change that affects the deployed backend must also be deployed
  to the Unraid server and verified, unless the user explicitly requests a
  local-only change or deployment access is unavailable.
- Never commit server credentials, private SSH keys, tokens, or production
  `.env` contents.

## Documentation Is Part of the Work

Keep the repository handoff documents synchronized with the implementation:

- Update `docs/internal/PROJECT_PLAN.md` when deployment state, architecture, release scope,
  backend contracts, or major priorities change.
- Update `docs/platform/SCREEN_SHARING.md` whenever capture state, native dependencies,
  platform behavior, known defects, or the test matrix changes.
- Update `docs/security/SECURITY_PLAN.md` whenever Yappa's threat model, transport, encryption,
  authentication, authorization, key management, storage protection, or
  security verification changes.
- Update `client_information.txt` whenever user-visible client behavior
  changes. Keep it as the current dated release summary shown inside Yappa:
  replace superseded entries instead of accumulating a development diary, and
  write for ordinary Yappa users rather than developers.
- Add a focused Markdown document for another subsystem when its design or
  operational history is too detailed for `docs/internal/PROJECT_PLAN.md`.
- Record confirmed facts and verification results, not guesses.
- Remove or clearly mark superseded plans so a future agent does not repeat an
  abandoned approach.
- Documentation updates are required before declaring a material subsystem
  change complete.
