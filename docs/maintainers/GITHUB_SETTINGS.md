# GitHub Repository Settings

_Verified locally on 2026-08-04: GitHub CLI is installed, but its saved token is
invalid and API/network access failed. The remote settings below were therefore
not changed or verified during this cleanup._

## Metadata commands after re-authentication

```bash
gh auth login -h github.com
gh repo edit CtrlAltForgot/Yappa \
  --description "Open-source, self-hosted community chat with desktop clients, voice, video, screen sharing, and user-owned infrastructure. Pre-alpha." \
  --add-topic self-hosted,flutter,dart,nodejs,socket-io,livekit,voice-chat,video-chat,screen-sharing,community-platform,discord-alternative,desktop-app,unraid,open-source \
  --enable-issues \
  --enable-discussions \
  --enable-wiki=false \
  --delete-branch-on-merge
```

Verify the default branch is `main`. Keep Projects enabled only if actively
used. Review Actions permissions and allow only the minimum required by the
pinned workflows.

## Security and merge settings (manual review)

- Enable private vulnerability reporting.
- Enable Dependabot alerts and security updates where appropriate.
- Enable secret scanning and push protection when the repository/account tier
  supports them.
- Enable squash merging. Configure merge/rebase methods consistently with the
  maintainer's chosen history style.
- Add a `main` ruleset that blocks force pushes and deletion, requires the
  existing CI checks for pull requests, permits an explicit owner bypass, and
  does not require multiple reviewers for this solo-maintained pre-alpha project.

Do not activate a ruleset until the exact required check names have succeeded
on `main`; otherwise the owner can be trapped by stale or unavailable checks.

## Recommended labels

Normalize this compact set after authentication: `bug`, `enhancement`,
`documentation`, `security`, `client`, `server`, `voice-video`,
`screen-sharing`, `deployment`, `windows`, `linux`, `needs-reproduction`,
`good first issue`, `help wanted`, `blocked`, and `pre-alpha`.

## Release metadata plan

First inspect immutable tag names and release IDs:

```bash
gh release list --repo CtrlAltForgot/Yappa --limit 100
```

Apply only title/prerelease/body metadata, never delete tags/assets:

- `chat_editing` → `[Legacy Pre-Alpha] Chat Editing Test Build`, prerelease.
- `release` → `[Legacy Pre-Alpha] Initial Windows and Nobara Client Build`, prerelease.
- August releases earlier than `v0.1.0-dev.20260802.3` → prefix
  `[Superseded]`, keep as prereleases, and link to `.3`.
- Keep `v0.1.0-dev.20260802.3` as the newest usable prerelease; do not mark stable.

Use `gh release edit TAG --title TITLE --prerelease --notes-file FILE` only
after saving and reviewing the existing body so historical evidence is not lost.

## Social preview (manual)

GitHub provides no supported `gh repo edit` option for social preview upload.
Open **Settings → General → Social preview → Edit**, upload
`docs/assets/yappa-social-preview.png`, crop only if necessary, and save.

Finally verify the description, topics, Discussions choice, branch rules,
Actions permissions, security features, and public release ordering in the web UI.

[Project home](../../README.md) · [Documentation index](../README.md)
