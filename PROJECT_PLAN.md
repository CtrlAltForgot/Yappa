# Yappa Project Plan

## Purpose

Yappa consists of:

- A Flutter desktop client in `client/`.
- A Node.js, Express, Socket.IO, and SQLite backend in `server/`.
- A self-hosted LiveKit server for voice, camera, and screen sharing.
- A production-like home deployment on the owner's Unraid server.

This document is the operating guide for future Codex sessions. Read it before
changing client state, backend behavior, database models, realtime events, or
deployment configuration.

## Product Contract

Yappa is a privacy-first communication foundation that is:

- Fully open source.
- Free to use and self-host.
- Free of premium-only features, paid capability gates, advertising, and
  monetized surveillance.
- Designed so communities control their infrastructure and data.
- Honest about its security properties. Self-hosting is valuable, but it is
  not a substitute for transport encryption, end-to-end encryption, access
  control, safe key management, and independent review.

Security and privacy are release requirements, not optional polish. Do not
market or label Yappa as secure, private, or end-to-end encrypted until the
applicable acceptance criteria in `SECURITY.md` are implemented and verified.

## Product Experience Principle

Yappa should feel like one coherent social space rather than a collection of
modules, bots, commands, and configuration panels. Features should be
"melted together": navigation, permissions, identity, presence, notifications,
search, and visual language should connect naturally enough that people do not
need to learn a separate product for each capability.

This principle is part of product acceptance, not only visual polish:

- Prefer direct, discoverable interfaces over text commands or mandatory bots.
- Reuse server identity, roles, people, channels, presence, and notifications
  instead of creating parallel concepts for each feature.
- Let context flow between surfaces—for example, an event may open its related
  conversation or voice deck, and a music session may show the people already
  present—without surprising cross-posts or permission changes.
- Keep advanced administration available without making ordinary participation
  feel like configuration work.
- Apply one interaction and visual system across desktop platforms while
  respecting native accessibility, media, credential, and notification
  behavior.
- A feature is not complete merely because its backend and isolated screen
  work; its entry points, transitions, empty/error states, permissions, and
  relationship to the rest of Yappa must also feel intentional.

## Connection Experience

Yappa is competing with Discord and TeamSpeak, so joining and operating a
self-hosted server must not require users to understand DNS, TLS certificates,
reverse proxies, or WebRTC routing.

- The normal join credential is a public IP address with an optional port.
- Generated wildcard-DNS transport names are not part of Yappa's architecture.
  Public nodes use publicly trusted certificates for their literal IP address.
- A user-owned domain remains optional and should use a separate guided helper.
- The client must remember and verify server identity independently of a
  mutable network address.
- A client on the same LAN must reach its server even when the router lacks
  public-IP NAT loopback. LAN discovery/fallback must preserve identity
  verification and must never silently downgrade a public connection.
- HTTPS/WSS remains mandatory for public authentication, API, and signaling
  traffic. This transport protection is separate from media E2EE.
- Voice, camera, screen video, screen audio, and realtime media data must use
  client-controlled end-to-end encryption by default. The server/SFU must not
  possess the media decryption key, and there is no silent downgrade.
- One-command server startup must generate and persist everything needed;
  ordinary hosts should only start Yappa and forward the documented ports.

The repository contains no generated wildcard-DNS hostname handling in the
server, client, tests, or handoff documents. This is a pre-release reset rather
than an upgrade migration: nodes are saved and shared using their direct IP or
an explicitly configured user-owned domain.

As of 2026-07-24, entering a bare public IPv4 address connects directly over
trusted `https://PUBLIC_IP`; API, Socket.IO, and LiveKit signaling share TCP
443 by path. The server obtains and renews a six-day Let's Encrypt IP
certificate automatically. Default
LiveKit E2EE and automatic LAN fallback are implemented; native two-client
media validation, IP-change migration, and verified invite links remain active
work.
When the backend is reached through an explicitly entered private LAN address,
voice credentials return LiveKit's private signaling listener instead of the
configured public route. For saved public-IP nodes, signed LAN discovery and
certificate-preserving route selection now provide the automatic fallback
without changing the logical HTTPS/WSS origin.

The server now generates a persistent Ed25519 identity under its per-server
data root. Clients pin the public key on first contact and require a valid
signature over a fresh random challenge before sending a password, session
token, or session-rotation request. A changed key or server id disconnects the
realtime client, preserves the saved session locally, and displays an explicit
identity warning rather than treating the endpoint as the remembered server.
Automated client tests cover proof validation and changed-key rejection;
backend tests cover proof validation, restrictive private-key file permissions,
and identity persistence across restart. Existing saved nodes use a one-time
trust-on-first-use migration protected by their current transport; a future
verified invitation format should carry the identity key before first contact.
The backend identity implementation was deployed to Unraid on 2026-07-24 and
survived the schema/container restart. Real-client trust-on-first-use migration
verification remains pending.

Signed LAN discovery and certificate-preserving API/realtime fallback are
implemented locally. The server answers bounded UDP broadcasts on port `41200`
with its server id, public key, advertised public address, LAN TLS port, request
nonce, and an Ed25519 signature. A client accepts only private-address
responses matching its pinned identity and expected public address. Discovery
changes only the TCP dial target: HTTPS/WSS retains the original public
hostname, SNI, and normal certificate validation, so passwords and bearer
tokens are never sent through a plaintext LAN downgrade. The fallback route is
then rechecked using the fresh HTTP identity proof. Tests cover signed
discovery, wrong-address rejection, persistence, and backend response
verification. The same scoped secure-socket override is applied while LiveKit
prepares and connects its signaling session, so voice, camera, and screen
sharing retain the public LiveKit hostname and trusted certificate while
dialing the discovered LAN IP. Branding, legacy attachment, and encrypted
attachment multipart uploads now use the same scoped client transport rather
than opening a separate connection that bypasses the verified LAN route.
Automated client coverage proves encrypted uploads use the configured
transport and reject substituted server metadata. On the production LAN,
accessing the public hostname through the router failed, confirming that this
router lacks NAT loopback. Dialing the server's LAN address on port `8443`
while retaining the public hostname and certificate returned a healthy API
response with successful certificate validation. The original direct Docker
UDP publication accepted unicast traffic but dropped LAN broadcasts on the
production Unraid host. The distributable stack now uses a hardened,
unprivileged host-network discovery relay on UDP `41200`. It accepts only
bounded private IPv4 discovery requests, overwrites rather than trusts
forwarded source metadata, and relays them to the signing backend through
loopback-only UDP `41201`; it holds no identity key or user data. The raw
backend discovery socket is no longer directly published to the LAN.
Automated relay routing and deployment-hardening tests pass. The relay was
deployed to Unraid on 2026-07-24 and a workstation broadcast received the
correct signed response from `192.168.1.254`. The real release client then
removed its saved plaintext `192.168.1.254:4100` route and persisted the secure
public transport origin.
Legacy saved nodes that still name the retired raw LAN backend on port `4100`
now use the signed response's advertised address to derive the secure public
origin before installing the LAN TLS dial override. The migration preserves
the pinned server id/key and remembered session; malformed or private
advertised routes still fail closed. Focused normalization, signature, and
route tests pass. Real-client route migration was verified against the
production Unraid node on 2026-07-24.

Session bearer tokens returned to clients are stored by the backend only as
prefixed SHA-256 digests. Existing raw-token database rows are migrated in
place after their next successful authentication. The client stores bearer
tokens and its YUID Ed25519 identity in the operating-system credential vault,
with write-before-delete migration from legacy plaintext preferences/files.
Sessions now have configurable absolute and idle expiry, rotate on restored
client startup, and can be listed and revoked from the signed-in devices panel.
Revocation, logout, and rotation also disconnect realtime sockets authenticated
by the affected session. This session hardening was deployed to Unraid and
verified on 2026-07-24 without exposing reusable token values. Windows secure
vault/runtime validation remains pending on Windows hardware.

Saved client sessions survive temporary server/network outages. The shell
retains cached server state and presents an in-place retry action; only an
explicit HTTP 401 or 403 response invalidates the local saved session.
Realtime Socket.IO reconnects remain automatic. Connection failure now marks
the selected server unreachable exactly once per outage, exposes the same
in-place retry, and tears down media-key coordination plus local capture
instead of retaining a stale encrypted-media epoch. A recovered socket clears
the warning without requiring the user to leave the server. Client lifecycle
coverage exercises repeated connection failure and intentional disposal.

The backend applies defensive HTTP headers, a configurable JSON body limit,
and in-memory per-address rate limits to sign-in and YUID challenge endpoints.
Browser CORS origins accept a comma-separated allowlist; wildcard mode remains
available only for intentional development/legacy configuration. Direct Node
startup with no CORS variable also defaults to native-only access.
Direct Node startup now binds `127.0.0.1` rather than every host interface.
Compose explicitly selects the private container interface while keeping the
published backend port host-loopback-only for Caddy. The startup helper
migrates older overrides to loopback and responses omit Express identification.
This hardening was deployed to Unraid on 2026-07-23 with native-only CORS.
Production verification confirmed HTTP 200 without a browser origin, HTTP 403
for an unconfigured origin, HTTP 413 for oversized JSON, the expected security
headers, and rate-limit headers on the YUID challenge endpoint.

Authenticated abuse controls are also implemented locally for message
mutations, uploads, link-preview fetches, voice-token issuance, account/device
changes, administrative mutations, attachment downloads, realtime connection
attempts, voice control events, legacy signaling, and media-key envelopes.
Legacy and encrypted attachment size ceilings are enforced while multipart
data is streaming rather than after the request has already been written.
Integration coverage proves oversized uploads receive HTTP 413 and create
neither a database row nor a leftover file.
Authenticated HTTP/realtime event budgets are account-scoped so people behind
one shared public IP do not consume each other's normal usage; pre-auth
connection and signed-download budgets remain address-scoped. Categories have
separate configurable budgets, bounded stale-entry cleanup, HTTP 429 rate
metadata, and structured realtime errors. Integration coverage proves account
isolation, category isolation, HTTP exhaustion, realtime-event exhaustion, and
realtime-handshake exhaustion. These controls and streaming upload limits were
deployed to Unraid on 2026-07-24; deliberate production limit exhaustion and
longer observation remain pending.

New account passwords use configurable bcrypt cost 12 with a 10-character
minimum. Existing bcrypt hashes are upgraded transparently after a successful
login, so older users are not forced through a destructive password reset.
Argon2id remains a future reviewed migration.

The backend security test command now launches disposable multi-user servers
and exercises HTTP and raw Socket.IO authorization boundaries. Public
pre-login responses are limited to branding/server identity, protected
resource routes require a session, owner-only mutations reject members,
cross-account session/message actions fail, invalid realtime authentication is
rejected, and bans invalidate active sessions.

Authentication abuse protection combines per-address request ceilings with a
bounded, account-aware exponential backoff for incorrect passwords. Defaults
allow three failures before delays grow from one to 30 seconds; successful
login clears the account state and stale entries expire. Regression tests cover
lock activation, `Retry-After`, expiry, and success reset without introducing
a permanent account lockout.

Operational logs are minimized and covered by automated leak tests. Server
request and realtime failures use stable public messages rather than returning
raw dependency exceptions; logs retain only bounded sanitized error codes.
The regression suite rejects direct backend `error.message` use. Unexpected
request errors expose only sanitized codes plus random incident ids, file
cleanup does not print private paths, startup omits database/data locations
and server identity, and authentication events omit account names. Static
scanning and runtime sentinels guard passwords, bearer tokens, private keys,
signatures, and message content. Security-sensitive numeric environment values
are bounded safe integers; malformed rate limits, authentication/password
policy, session lifetimes, attachment-grant lifetimes, or ports now refuse
startup with a generic diagnostic instead of silently disabling a control.
Configured attachment-signing and LiveKit API secrets also require at least
32 bytes; weak values fail closed without being copied into diagnostics.

Repository and CI security gates are now implemented locally. The backend
suite scans tracked and unignored files for production environment/database/key
artifacts and common private-key/token formats. GitHub Actions uses read-only
permissions, full-SHA action pins, locked dependency installation, production
npm auditing, backend security tests, Flutter analysis, and Flutter tests.
Desktop packaging is manual-only while Yappa is pre-release, labels artifacts
as `0.1.0-dev` development builds, pins Flutter 3.44.7, and validates before
packaging. The Flutter package version is likewise `0.1.0+1` so local metadata
does not imply that the security release gate has been met.
GitHub run history confirms that an older 2026-03-24 revision packaged Linux,
Windows, and macOS successfully. It predates the current security workflow and
cryptographic implementation, so hosted execution of the current gates,
artifact signing, provenance, and release-policy enforcement remain
unverified.

The distributable startup path no longer includes a tracked LiveKit
configuration with shared development credentials. It creates `.env` and
`livekit.yaml` under a private umask, enforces mode `0600`, never synthesizes
wildcard-DNS transport hostnames, and prints router rules as explicit
external-to-internal mappings. Automated deployment-safety checks
guard those properties and the loopback-only raw backend defaults. Unraid
deployment on 2026-07-24 confirmed `.env`/LiveKit mode `0600`, data mode `0700`
owned by UID/GID `1000`, and a LAN-inaccessible raw application port.

The distributable Compose stack is hardened locally at the container boundary.
The Node runtime image uses `npm ci --omit=dev`, contains only production
dependencies and `src/`, runs as UID/GID `1000:1000`, and has an internal
health check. The build context excludes `.env`, generated LiveKit
configuration, databases/data, backups, tests, and host dependencies. Node,
Caddy, and LiveKit have read-only roots, bounded hardened temporary mounts,
all default capabilities dropped, `no-new-privileges`, and init reaping;
only the two services that intentionally bind low ports receive
`NET_BIND_SERVICE`. Compose rendering and deployment regression checks pass.
The production image was built and started on Unraid on 2026-07-24. Runtime
inspection confirmed a healthy unprivileged Node process, read-only roots,
dropped capabilities, `no-new-privileges`, preserved users/messages, schema
version `3`, and clean startup logs.

Encrypted operational backups are implemented locally through
`server/backup-yappa.sh`. The command briefly pauses the backend for a
consistent SQLite/filesystem snapshot and streams `.env` plus `data/` directly
to passphrase-authenticated `age` encryption with no plaintext archive.
Overwrite refusal, partial-file cleanup, backend restart trapping, recovery
inspection, and the minimal restore set are documented. An isolated
orchestration integration test verifies successful archive contents and mode,
overwrite refusal, cleanup after an encryption failure, and backend
pause/resume behavior. It substitutes the encryption executable and therefore
does not replace a real `age` restore drill.
The bundled isolated restore verifier was deployed to Unraid on 2026-07-24
with mode `0700`. Local orchestration tests prove backup, decrypt-stream
restore, SQLite integrity validation, required identity/config checks, and
cleanup. The checksum-verified upstream `age` v1.3.1 binary is installed
persistently beside the production scripts. A real passphrase-encrypted
production backup and isolated restore verification passed on 2026-07-24:
SQLite integrity was valid at schema `3`, one user and ten legacy messages
were present, the required server identity/configuration passed validation,
and the isolated restored copy was removed. The resulting encrypted file is
mode `0600`, no partial output remained, and the backend automatically resumed
healthy under UID/GID `1000:1000`, a read-only root, and
`no-new-privileges`.

Database initialization now journals schema version `3` and runs base-schema
creation, additive migration, seed/config initialization, and version recording
inside one SQLite transaction. A failed migration leaves the pre-upgrade
schema/data intact, and a binary refuses to mutate or open a database with a
newer schema version. Tests cover legacy preservation, successful journaling,
future-version refusal without mutation, and full DDL rollback after an
injected migration failure. `server/MIGRATIONS.md` defines the forward-only
contract: rollback means restoring the matching encrypted pre-upgrade `.env`
and `data/` together, never opening an upgraded database with an older image.
Version 2 adds crash-safe MLS delivery operation ids without rewriting
existing version-1 wire rows. Version 3 adds the authenticated MLS device
credential directory and backfills verified historical bindings without
restoring consumed KeyPackage wire bytes. Previous-version fixtures verify
preservation and the new boundaries. Startup migration failures emit only a
sanitized reason code rather than a
stack trace, SQL statement, or database path; runtime log tests cover the
future-schema refusal path.
Schema versions 2 and 3 were deployed to Unraid on 2026-07-24 after verified
encrypted pre-upgrade backups. Production preserved one user, ten legacy
messages, and zero pre-activation MLS rows. The operation-id index, credential
directory, healthy loopback endpoint, unprivileged user, read-only root
filesystem, and `no-new-privileges` were verified. The subsequent real
schema-3 encrypted backup and isolated restore drill passed as recorded above.

The backend dependency lockfile was refreshed on 2026-07-23 to resolve all
nine npm audit findings through compatible Express, Multer, Socket.IO,
Engine.IO, WebSocket, and parser updates. The local post-fix audit reported
zero known vulnerabilities and the temporary-backend regression checks passed.
The lockfile was deployed to Unraid on 2026-07-23. The production image install
and a separate in-container audit both reported zero known vulnerabilities;
the API, CORS/security headers, hashed-session state, and post-restart client
session activity were verified.

Message attachments use short-lived, account-bound signed download URLs rather
than public static storage paths. Grants are validated against expiry,
signature, the current account/ban state, the attachment record, its channel,
and the server attachment root. Server branding remains publicly readable for
pre-login node rendering. This was deployed to Unraid on 2026-07-23 with a
production-only persistent signing secret. Verification against an existing
PNG confirmed full and ranged signed reads, rejection of guessed/tampered
grants, and removal of its former static path.

The desktop client requires HTTPS for public connections, including restored
saved sessions, while retaining HTTP support for explicit loopback/private-LAN
and development hosts. A bare public IPv4 join address is translated internally
to the server's literal trusted HTTPS IP origin. Realtime Socket.IO and
LiveKit signaling use the same normalized secure origin.

The distributable server Compose stack includes a pinned Caddy reverse proxy.
Fresh installs generate their application and LiveKit secrets locally, keep
the raw backend bound to host loopback, detect the public IPv4 address, and
configure automatically managed public HTTPS/WSS without DNS. Caddy requests
Let's Encrypt's short-lived profile for the literal public IP, renews it from
persistent state, and serves it as the default certificate for IP clients that
omit SNI. A separate script configures one optional user-owned domain, while
`--lan` retains private-network-only setup.
Certificate state persists in a Docker volume. Direct WebRTC UDP, ICE/TCP, and
authenticated embedded TURN/UDP on UDP `443` are included. Caddy relinquishes
HTTP/3's UDP `443` host mapping for that fallback. TURN/TLS on TCP `443`
remains a documented release-readiness gap because it cannot independently
terminate alongside Caddy on the same single-IP socket. An isolated run of the
exact pinned LiveKit `v1.13.4` image accepted the generated configuration and
started its embedded TURN/UDP listener; the hardened stack is deployed on
Unraid, while off-LAN relay verification remains pending.
The automatic-IP and custom-domain installer scripts were deployed to Unraid
on 2026-07-23 without changing its existing LAN addresses. Remote shell syntax,
Compose rendering, executable permissions, and direct/proxied health checks
passed. After router forwarding was configured, Let's Encrypt independently
reached the deployment and issued trusted certificates. On 2026-07-24 the
deployment migrated to a direct-IP certificate with `70.112.26.136` as its
critical SAN; API returned HTTP 200 and the shared LiveKit `/rtc` route
returned HTTP 401 for an intentionally invalid token, proving routing reached
LiveKit. Public TLS
termination is therefore verified; full off-LAN client and media testing
remains outstanding.

Client OS-backed secret storage was implemented and Linux/KDE migration was
verified on 2026-07-24. Session tokens and the YUID private identity are held
through the platform secure-storage plugin; legacy plaintext entries are
removed only after successful secure writes. A second client start restored
from the keyring with the legacy YUID file and secret preference keys absent.
Linux requires `libsecret` plus an active Secret Service provider such as
KWallet or GNOME Keyring. Windows build/runtime validation remains outstanding.

## Definition of Done

A feature is not complete merely because the Flutter UI appears to work.

For every user-facing value, first classify it as either:

1. **Shared/server state** — other users should see it, it should survive
   reinstalling the client, or it should follow the account to another device.
2. **Local device state** — it only makes sense on the current machine.

Shared/server state is complete only when all applicable layers are updated:

1. Flutter UI input and validation.
2. Flutter model serialization/deserialization.
3. `ApiClient` request and response handling.
4. `AppState` mutation, cache refresh, and error handling.
5. Express route authorization and validation.
6. SQLite schema plus a migration for existing installations.
7. Backend serializers used by HTTP and Socket.IO.
8. Realtime broadcast so other connected clients update immediately.
9. Refresh/reconnect behavior proving the value was persisted.
10. Backend deployment to Unraid and post-deployment verification.

Do not keep a shared customization only in a widget-local map or Flutter
preferences. Optimistic local updates are allowed, but the server remains the
source of truth.

## State Ownership Rules

The following are shared/server state:

- User display name and avatar.
- Server name, description, accent, icon, and banner.
- Channels, channel names, channel types, ordering, and channel glyphs.
- Messages, edits, deletions, and attachments.
- Server media/storage policy.
- Membership, roles, permissions, bans, invites, and access rules when those
  features become functional.
- Any future emoji, sticker, soundboard, or role customization intended to be
  visible to other users.
- Live voice presence and media state while connected.
- Files intentionally hosted in a server file library, including metadata,
  folder organization, permissions, quotas, retention, and audit ownership.

The following are normally local device state:

- Theme and font selection.
- Audio input/output device selection.
- Microphone processing preferences.
- Per-user playback volume.
- Linux capture backend selection.
- Screen-share quality ceiling.
- Window layout and transient UI state.

Channel mute and notification preferences are currently local. If the product
later promises that they sync across devices, move them to authenticated
backend storage instead of maintaining two competing sources of truth.

When uncertain, ask: “Would the user expect this to still exist after signing
in on another computer?” If yes, implement it as shared/server state.

## Client/Backend Change Checklist

For every client change involving a save, create, edit, delete, upload, picker,
toggle, or customization:

- Search for the UI callback.
- Trace it into `AppState`.
- Trace the `ApiClient` method and HTTP or Socket.IO operation.
- Confirm the server route/event exists and checks authorization.
- Confirm the database stores every field.
- Confirm old databases receive a non-destructive migration.
- Confirm server responses include the field.
- Confirm `server:hello`, `server:update`, presence, or the relevant message
  event includes the updated state.
- Confirm a second client receives the update without restarting.
- Confirm reconnecting or rebuilding the client retains the change.

Placeholders must clearly say they are placeholders. Do not present a success
message for a change that was only applied in memory.

## Backend Validation

Before deployment, run the applicable checks:

```bash
cd client
flutter analyze
flutter build linux --debug --no-pub
```

```bash
cd server
node --check src/server.js
node --check src/db.js
```

Also run:

```bash
git diff --check
```

When dependencies are installed, start the stack against temporary data or use
Docker and exercise changed routes. For persistence changes, verify:

- A fresh database.
- Migration from an existing database.
- Read-after-write.
- Realtime propagation where applicable.
- Authorization failure for non-owners or unrelated users.

Never use the production database as an experiment fixture.

## Unraid Deployment

Current LAN host:

```text
192.168.1.254
```

Deployment directory:

```text
/mnt/user/appdata/yappa
```

Containers:

```text
newchat-node
yappa-livekit
yappa-proxy
```

Endpoints and media ports:

```text
Backend HTTP / Socket.IO:  http://192.168.1.254:4100
Caddy LAN API proxy:       http://192.168.1.254:8088
LiveKit signaling:         ws://192.168.1.254:7880
Caddy LAN voice proxy:     ws://192.168.1.254:7882
LiveKit ICE/TCP:           192.168.1.254:7881
LiveKit ICE/UDP:           192.168.1.254:50000-50100
```

Persistent state lives under:

```text
/mnt/user/appdata/yappa/data
```

Production secrets live only in:

```text
/mnt/user/appdata/yappa/.env
/mnt/user/appdata/yappa/livekit.yaml
```

Never copy those files back into the repository or print their secret values.

## Future Codex SSH Access

Do not store a permanent root password or private key in this repository.

For a deployment session:

1. Attempt a read-only SSH connection to `root@192.168.1.254`.
2. If no approved key exists, create a temporary Ed25519 key under `/tmp`.
3. Show only the `.pub` value to the user.
4. Ask the user to append that public key to
   `/root/.ssh/authorized_keys` through the Unraid terminal.
5. Use the temporary private key only for the current deployment.
6. Inspect the existing deployment before writing anything.
7. Preserve `/mnt/user/appdata/yappa/data`, `.env`, and `livekit.yaml`.
8. After verification, remove the exact temporary public-key line from
   `authorized_keys`.
9. Delete the temporary private key and deployment archive.

Never request that the user paste their Unraid root password into chat.

## Deployment Rule

Whenever a completed change affects any of the following, deploy it to Unraid
in the same task:

- `server/src/**`
- `server/package.json` or `server/package-lock.json`
- `server/Dockerfile`
- `server/docker-compose.yml`
- `server/start-yappa.sh`
- LiveKit configuration or backend environment requirements
- Client behavior that requires a new or changed backend contract

The exception is when the user explicitly asks for local-only work, asks not to
deploy, or SSH/deployment access is unavailable. In that case, report clearly
that the repository is ahead of the deployed server.

### Safe update procedure

1. Inspect container status and the current deployment.
2. Back up material data before a risky migration:

   ```bash
   cd /mnt/user/appdata/yappa
   cp -a data "data.backup-$(date +%Y%m%d-%H%M%S)"
   ```

3. Transfer only required source/config templates. Never overwrite production
   `.env`, `livekit.yaml`, or `data/` with repository copies.
4. Rebuild and recreate:

   ```bash
   cd /mnt/user/appdata/yappa
   docker compose up -d --build
   ```

5. Verify both containers remain healthy:

   ```bash
   docker compose ps
   docker logs --tail 100 newchat-node
   docker logs --tail 100 yappa-livekit
   ```

6. Verify LAN endpoints:

   ```bash
   curl --fail http://127.0.0.1:4100/health
   curl --fail http://127.0.0.1:7880
   ```

7. For changed API behavior, perform an authenticated smoke test or test it
   from two Yappa clients.
8. Confirm the database and uploads still exist after container recreation.
9. If verification fails, inspect logs and restore the backup rather than
   deleting or resetting production data.

## Current Deployment Notes

- LiveKit is pinned to `v1.13.4`.
- LiveKit uses UDP range `50000-50100`; single-port UDP mux failed on this
  Unraid host and must not be restored without testing.
- LiveKit binds to `0.0.0.0` and advertises `192.168.1.254` for LAN use.
- The Unraid deployment has working public TLS certificates for its internal
  IP-derived API and LiveKit transport names. Direct LAN HTTP/WS listeners
  remain available for local compatibility.
- Caddy `2.11.4` uses Unraid-safe internal host mappings because the Unraid
  management interface owns host ports 80 and 443; router ports 80 and 443 are
  forwarded to the selected Caddy mappings.
- Public off-LAN client/media, TURN/UDP `443`, and NAT-loopback-safe fallback
  validation, TURN/TLS planning, and security review remain outstanding. See
  `server/DEPLOYMENT.md`.
- Dependency audit findings must be reviewed before public exposure.
- On 2026-07-23, the deployed Node backend was updated so partial
  `voice:state` patches preserve unspecified flags. Previously a speaking,
  mute, or camera update could accidentally reset `screenShareEnabled`.
- The client currently uses a local `flutter_webrtc` 1.5.2 fork under
  `client/packages/flutter_webrtc_yappa`, selected with a dependency override.
  LiveKit client `2.9.0-dev.0` is required because older LiveKit client
  releases pin `flutter_webrtc` 1.3.0.
- Text-channel composers support pasting clipboard images and copied image
  files on desktop. Clipboard data is copied to a temporary file, uploaded
  through the existing authenticated attachment API, displayed as a pending
  attachment, and deleted locally after upload. Plain-text paste behavior is
  preserved. This uses `pasteboard`; `super_clipboard` 0.9.x cannot currently
  coexist with LiveKit's `device_info_plus` 12 constraint.
- Link cards use server-fetched metadata to provide a title, short description,
  favicon, and available preview image. YouTube, TikTok, and Vimeo links expose
  an allowlisted inline player in the desktop client. The third-party player
  is not loaded until the user presses Play, it cannot request camera or
  microphone permission, top-level navigation is restricted to the selected
  provider, and provider-specific aspect ratios keep portrait TikTok media
  vertical. The preview fetcher resolves and pins public DNS targets,
  revalidates redirects, limits response size/time, and rejects loopback,
  private, link-local, and cloud-metadata targets. Linux builds require the
  `webkit2gtk-4.1` development package (`webkit2gtk4.1-devel` on the current
  Nobara host); Windows uses the WebView2 runtime. The Nobara package and its
  development dependencies were installed through the authenticated system
  package manager on 2026-07-24. The current Linux debug and release bundles
  then built successfully, and the release binary launched. Bundle inspection
  confirmed the native MLS, LiveKit/WebRTC, secure-storage, and WebKit plugins;
  its linked dependencies resolved on the validation host.
  After the encrypted caption and private-preview changes, the release bundle
  was rebuilt again from the current worktree. Recursive `ldd` inspection of
  the executable and every bundled shared object reported no unresolved
  dependency. The bundle contained the pinned MLS bridge plus LiveKit/WebRTC,
  Secret Service storage, WebKit, recorder, clipboard, and desktop-drop
  plugins. The packaged executable remained alive for a bounded 12-second
  runtime smoke and was then terminated by the test harness; it emitted no
  loader, cryptography, credential-vault, or crash error and left no core/log
  artifact. A harmless missing cursor-theme asset warning remains host-theme
  specific. Initial inspection also found that generated plugin `RUNPATH`
  entries and native Rust panic-location strings retained the builder's home
  path. Linux packaging now forces relative `$ORIGIN` runtime paths, remaps the
  Rust build home, builds Flutter from a neutral temporary source root, keeps
  split debug information outside the shipped bundle, and rejects absolute
  runtime paths, unresolved libraries, builder-home strings, retired
  `sslip.io` markers, and private-key markers in CI. A complete neutral-root
  local simulation passed those checks on 2026-07-24. This is strong local
  Linux evidence, but the updated hosted workflow has not yet supplied
  reproducible provenance.
  The neutral-root build and complete scan were rerun after the YouTube,
  platform-packaging, and sanitized attachment-error changes on 2026-07-24.
  The exact current 57 MiB bundle again contained no builder-home, retired
  transport, Codex-key-label, private-key, absolute runtime-path, or unresolved
  dependency finding; expected MLS ABI/application/state exports were present.
  Its packaged executable remained alive through a 12-second bounded smoke
  and emitted only the known cosmetic host cursor-theme warning. The
  executable, Flutter AOT library, and MLS library SHA-256 values were recorded
  locally, but remain validation evidence rather than published provenance.
  Linux WebKit must attach through the runner's `GtkOverlay`; using the stock
  plain container invalidates Flutter's OpenGL surface when playback starts.
  Provider playback originally used a contained HTML iframe with
  `strict-origin-when-cross-origin`, matching YouTube's current oEmbed markup.
  A later WebKitGTK runtime check exposed YouTube configuration error `152-4`
  and showed the native GTK surface painting below the message viewport.
  The client now loads the allowlisted embed as an identified WebView request
  with an explicit HTTP referrer, and detaches the native surface whenever the
  whole player is not inside the message scroll viewport. Flutter analysis and
  all 54 client tests pass; final playback/scroll confirmation in the launched
  Linux client remains pending. The backend embed URL is live on Unraid.
- Read `SCREEN_SHARING.md` before changing the native capture stack.
- Read `MEDIA_E2EE.md` before changing realtime encryption keys, device
  authorization, room epochs, key-envelope relay, or LiveKit frame encryption.
- Read `MESSAGING_E2EE.md` before changing persisted message or attachment
  encryption, MLS delivery, encrypted history, previews, or recovery behavior.
- Persisted messaging E2EE is specified around RFC 9420 MLS with a native
  OpenMLS bridge and libsodium secretstream attachments. OpenMLS 0.8.1,
  RustCrypto 0.5.1, the mandatory RFC ciphersuite, and the transitive lock are
  pinned. A documented MPL-2.0 HPKE 0.6.1 backport removes its unused
  vulnerable libcrux provider chain and updates SHA3 to 0.0.10. The
  2026-07-24 RustSec audit found zero vulnerabilities and one reviewed
  non-runtime `cfg(hax)` unmaintained warning.
- The native MLS state machine and versioned C ABI now cover device creation,
  KeyPackages, group creation, add/Welcome, self-update, removal,
  accept/reject rollback, commit processing, private applications,
  authenticated sender credential/signature-key output, and AES-256-GCM
  state export/import. The locked OpenMLS dependency set was fetched and all
  seventeen Rust tests passed again on 2026-07-24. Flutter integration tests cover
  messaging, state restart, tamper/context failure, rollback,
  removal/future exclusion, new-member history exclusion, offline replay,
  concurrent-commit rollback, application replay, and ABI ownership. Linux and
  Windows CMake builds package the bridge; a real Windows build/runtime test
  remains open. The exact signed OpenMLS `v0.8.1` source archive
  (`SHA-256
  29427912c8190c029340194f56178266a04fc76658c03b5ebdad3df23e5d92f0`)
  passed all 61 selected upstream vector runners on Linux, including the
  mandatory RustCrypto ciphersuite. The new checksum-pinned repository runner
  strips unused providers from a disposable copy, installs its committed
  vector lockfile, and fails unless `cargo tree` proves Yappa's vendored HPKE
  `0.6.1` is active. All 25 RustCrypto vector-reader tests passed against that
  graph on Linux. Security CI plus Linux and Windows artifact jobs now enforce
  the runner; hosted Windows execution remains open.
- Flutter local MLS state now serializes mutations, keeps only the wrapping
  key in OS secret storage, binds ciphertext to server/device context, uses
  recoverable atomic files, and enforces 0700/0600 on Unix. KeyPackage private
  material is persisted before registration and claimed YUID credential
  bindings are verified client-side before OpenMLS input. Add-member commits
  and Welcome messages now use a separate AES-256-GCM encrypted, OS-vault-keyed
  outbox with staged exact-retry recovery. The coordinator persists wire bytes,
  epochs, recipient, and operation ids before submission, reconciles a commit
  accepted before a lost response without double-advancing local state, and
  clears only after Welcome acceptance. Authenticated member-set persistence,
  receiving replay/resynchronization, event materialization, and the guarded
  chat surface are now connected below.
- A non-activating messaging-E2EE database migration is implemented locally.
  Existing content remains honestly labeled `legacy` version `0`; separate
  ciphertext-only tables cover KeyPackages, MLS delivery ordering, device
  cursors, encrypted event routing, and encrypted attachment objects.
  Database triggers allow one-way E2EE cutover but reject downgrade and
  version rollback. Backend plaintext message/edit/upload/preview routes
  return HTTP 409 after cutover, and preview requests must identify a legacy
  channel. The client also refuses plaintext sends, uploads, and server-side
  preview requests for E2EE, malformed, or unknown modes.
  Migration, schema-inspection, server-boundary, cached-legacy, and
  fail-closed client tests pass. E2EE version 1 channels now use the guarded
  runtime; legacy rows remain explicitly separate.
- One-use MLS KeyPackage registration, inventory, and atomic claim APIs are
  implemented locally. Packages are bound to the authenticated session device
  and a YUID-signed MLS credential key, restricted to the selected
  ciphersuite/size/expiry, deduplicated by server-computed SHA-256, capped per
  device, and unavailable after claim, ban, or revocation. Tests cover invalid
  binding signatures, duplicate packages, inventory, one-use claims,
  post-claim wire-byte zeroing with retained hash tombstones, and revoked
  targets. Expired packages compact the same way and historical rows are
  bounded. The server still treats KeyPackage wire bytes as opaque. The client
  now verifies the YUID-signed credential binding before OpenMLS
  receives a claimed package. Exact group-member authorization and guarded
  runtime activation are implemented below.
- The opaque MLS delivery-service API is implemented locally. It idempotently
  initializes the deterministic channel group, assigns one canonical
  per-channel sequence to proposal, commit, Welcome, and application messages,
  advances epochs only for a commit whose parent is the current epoch, and
  rejects stale concurrent commits. Welcome delivery is restricted to one
  active recipient device across both history and realtime paths. Application
  routing records contain event ids/types but no plaintext; duplicate events
  and nonexistent encrypted-event references roll back without consuming a
  sequence. Device delivery and epoch acknowledgements are monotonic and
  cannot advance beyond delivered data. Authorization integration tests cover
  initialization, ordering, stale commits, rollback, recipient isolation, and
  acknowledgement rollback. Every submission now carries a per-device client
  operation id. Exact retries return the original row without advancing the
  sequence/epoch or duplicating realtime delivery; changed data under a reused
  id fails. Schema version 2 migrates existing rows without rewriting their
  wire bytes, closing server-side lost-response ambiguity for the durable
  client outbox.
  The server does not parse MLS wire data, so the
  native OpenMLS client validates every message, credential set, Welcome, and
  membership transition before acknowledging it.
- The Flutter MLS transport is implemented for KeyPackage
  inventory/registration/claim, deterministic group initialization, ordered
  post/fetch, realtime delivery, and monotonic acknowledgements. Strict models
  reject invalid ids, bounds, hashes, epoch/class/recipient combinations,
  routing shapes, non-increasing sequences, wrong group identity, and server
  substitution of submitted wire bytes or routing metadata. Claimed
  KeyPackages are SHA-256 checked by the model and YUID-binding verified before
  the native OpenMLS bridge receives them. Ordered transport is now connected
  to the sender-side add/Welcome coordinator with encrypted durable retry
  state. Receiving-device replay, exact authenticated membership enforcement,
  and application materialization are connected through the channel runtime.
- Schema version 3 adds a durable MLS leaf-credential directory independent of
  consumable KeyPackages. Credential registration is transactional with
  KeyPackage registration, history is capped at eight keys per active device,
  migration backfills existing verified bindings, and revoked/banned devices
  are excluded. Flutter re-verifies every YUID signature. Native ABI version 4
  exports the actual authenticated MLS leaf credential/signature-key set, and
  local mutations now snapshot and roll back if post-operation authorization
  fails. The initial receive coordinator joins recipient-scoped Welcomes,
  verifies the complete tree, reconciles crash replay without applying commits
  twice, protects its cursor in OS secret storage, and acknowledges only after
  persistence. ABI version 4 now durably stages an authenticated decrypted
  event with the MLS ratchet update, after which Flutter validates canonical
  routing/sender/event semantics and writes AES-256-GCM local history before
  clearing the receipt and acknowledging. Restart, tamper, and end-to-end
  application tests pass. The same native state atomically retains outgoing
  canonical plaintext, exact ciphertext, epoch, operation id, and group until
  idempotent server acceptance and sender-history materialization; restart and
  lost-response tests prove exact wire reuse. The credential directory now
  supplies the backend-authorized owner role only alongside a verified
  YUID/device/leaf binding, eliminating the arbitrary receive-side owner
  callback. Tree authorization requires exactly one represented leaf for every
  distinct active credentialed device and rejects missing or duplicate device
  membership. Enrollment/add coordination and the UI lifecycle are implemented
  through explicit waiting/ready states.
  The reconciliation layer now chooses the lowest represented owner
  device as the only add leader, resumes its encrypted outbox, claims and
  directory-verifies missing-device KeyPackages, submits sequential
  commit/Welcome pairs, and requires an exact refetched final tree. Tests cover
  leader determinism, missing-owner and substituted-claim rejection, native
  two-device reconciliation, and lost-response recovery. Enrollment scheduling,
  receive-loop wiring, and UI integration run through AppState.
  First server-side group initialization is now restricted to an already
  credentialed owner device; members may only receive the idempotent existing
  state. Authorization tests cover the member-first race.
  The guard was deployed to Unraid on 2026-07-24 and the healthy schema-3
  service, preserved production counts, hardened container, and clean startup
  log were reverified.
  A new inactive channel runtime composes enrollment, delivery, founder
  initialization, protected cursor setup, reconciliation, local event storage,
  sending, and encrypted attachments behind explicit waiting-for-Welcome,
  waiting-for-membership, and ready states. Server initialization now returns
  a strict allocation bit; existing state cannot trigger a second local group.
  One native server device and add outbox are serialized across channel
  runtimes. The focused native test covers existing-state refusal, fresh
  creation, exact membership, and founder-cursor persistence.
  The strict allocation response was deployed to Unraid on 2026-07-24 after
  complete backend/client validation; health, schema/data counts, container
  isolation, and startup logs were reverified.
  AppState now opens and synchronizes the runtime for E2EE version 1 channels
  on restore/selection and realtime MLS delivery, replaces it after token
  rotation, and closes it on logout/removal/disposal. The chat UI removes its
  plaintext attachment path and displays the exact lifecycle state. Once ready,
  authenticated MLS application events are projected into messages and the
  normal composer supports encrypted text send, edit, and delete. The sender
  account id/name/owner role come only from the reverified credential
  directory. Encrypted files now travel directly through secretstream plus MLS,
  render as locked metadata cards, and decrypt only into a user-selected save
  path after ciphertext metadata/final-tag verification. Authenticated
  reaction events materialize per account and can be added or removed from the
  message surface. The encrypted composer now binds an optional caption and up
  to ten independently secretstream-encrypted files into one canonical MLS
  application event. Lost responses retain the exact event plus every staged
  ciphertext for retry, and projection restores the caption with its locked
  cards. Legacy captionless events remain readable. Encrypted images now offer
  an explicit local preview action: nothing decrypts on scroll, no plaintext
  thumbnail reaches the server, and the authenticated full image is rendered
  from a mode-`0600` temporary lease that is recursively removed when the modal
  closes or fails. Encrypted send/save/preview errors are now reduced to
  actionable authorization, throttling, size, connectivity, local-storage,
  and authentication categories; local paths, raw server text, native
  messages, and cryptographic details are not displayed. Focused mapping and
  widget tests plus all 57 client tests pass. Broader platform validation and
  independent review remain before a release claim.
  Backend routing and local materialization now also forbid mutations from
  targeting other mutation events. Edits accept message roots only; deletes
  and reactions accept message or attachment roots. This closes an
  authenticated history-projection denial-of-service and was deployed to
  Unraid on 2026-07-24 after the full backend suite passed.
  Receive replay now distinguishes safe handshake convergence from application
  authorization: intermediate trees may be authorized subsets while sequential
  adds apply, but every application requires exact directory coverage before
  decryption or local materialization.
  The synchronized directory contract, including authenticated account ids
  needed for message projection, was deployed to Unraid on 2026-07-24. The
  complete backend security suite, Flutter analysis, all 51 Flutter tests, and
  all 17 native MLS tests passed. The restarted node reported healthy with a
  clean bounded startup log.
  The directory now distinguishes active credentials used for exact current
  group membership from signed historical credentials used only to authenticate
  already-decrypted history. Revoking a device therefore removes it from the
  intended MLS tree without making its legitimate older messages
  unrenderable. This contract was deployed to Unraid on 2026-07-24; the
  container remained healthy, non-root, read-only, and no-new-privileges.
  The restarted service is healthy on schema 3 with one user, ten preserved
  legacy messages, zero inactive MLS/credential/encrypted-attachment rows,
  UID/GID 1000, read-only root, `no-new-privileges`, and clean startup logs.
  This additive backend migration was deployed to Unraid on 2026-07-24 after
  a checksum-verified encrypted backup. Production verification confirmed
  schema 3, the new empty pre-activation credential table, preservation of one
  user/ten legacy messages/zero MLS deliveries, healthy service, and unchanged
  non-root/no-new-privileges isolation.
- Encrypted edit/delete/reaction routing now requires an existing same-channel
  target. Only the original sender may edit; the sender or server owner may
  delete. Unauthorized and cross-channel references roll back without
  consuming a delivery sequence. Receiving clients must still prove the
  decrypted event matches its opaque routing label before applying it.
- The inactive encrypted-attachment transport is implemented locally.
  Authenticated active devices can upload bounded ciphertext only to E2EE
  version 1 text channels. The backend recomputes SHA-256 before accepting the
  object, stores a secretstream header/chunk count/ciphertext size under the
  shared quota and retention policy, and exposes only authenticated,
  rate-limited binary download with a generic filename and media type.
  Attachment ids bind atomically to one encrypted application event from the
  same account, device, and channel; invalid, expired, cross-device, or reused
  ids roll back without consuming a sequence. Storage and API tests confirm no
  plaintext filename/type columns and exercise upload, binding isolation,
  ordered response metadata, authenticated download, and byte/digest equality.
  The standalone client cipher now streams 64 KiB chunks through libsodium
  secretstream, authenticates canonical server/channel/event/attachment
  identity per chunk, requires the final tag and full ciphertext digest,
  zeroizes native buffers, refuses overwrite, and withholds partial plaintext
  on failure. Linux tests pass for empty/multi-chunk round trips, tampering,
  truncation, and context substitution. Attachment and event ids are
  client-generated before encryption so they can be bound in associated data.
  Upload is exact-retry safe: the client-generated attachment id returns its
  original row only for identical ciphertext metadata and authenticated
  uploader, while substitution fails with HTTP 409 and duplicate temporary
  bytes are discarded. Authorization tests pass. This code-only change was
  deployed to Unraid on 2026-07-24; health, schema 3, production counts, and
  UID/GID 1000 plus `no-new-privileges` were reverified.
  Ciphertext upload/download now uses the verified LAN-aware API transport,
  pins all returned metadata, streams downloads into a partial file bounded by
  caller-supplied expected size, and renames only after metadata and
  full-digest checks. The inactive coordinator now stages the attachment key,
  user metadata, and authenticated object metadata inside the exact outgoing
  MLS operation before upload. Lost upload responses preserve both ciphertext
  and the MLS receipt for restart-safe exact retry; success clears them only
  after encrypted local-history materialization. Download metadata comes only
  from a verified materialized event, and temporary ciphertext is removed
  after event-bound secretstream decryption. The Linux integration test covers
  lost-response recovery and the complete upload/event/download/plaintext
  round trip. The guarded chat UI now sends encrypted attachments, renders
  locked cards, and decrypts only to a user-selected path. Encrypted images can
  also be previewed explicitly after full authentication in a private local
  temporary lease; the client never uploads or requests a plaintext thumbnail,
  does not decrypt on scroll, and recursively deletes the lease on close or
  failure. Broader user-facing failure handling remains pending. The
  Windows artifact workflow now downloads the official libsodium `1.0.20`
  MSVC archive, verifies SHA-256
  `2ff97f9e3f5b341bdc808e698057bea1ae454f99e29ff6f9b62e14d0eb1b1baa`,
  places the x64 v143 DLL beside Yappa, and refuses packaging unless both
  `libsodium.dll` and `yappa_mls.dll` are present. Windows native Rust paths
  are remapped away from the builder account, Flutter debug symbols remain
  outside the shipped directory, and the artifact job scans every bundled
  file for builder-home, retired `sslip.io`, Codex-key label, and private-key
  markers before packaging. Hosted build and real Windows runtime validation
  remain pending.
- The media E2EE sealed-envelope primitive is implemented locally and has
  tamper, wrong-recipient, unauthorized-sender, and round-trip tests. It is
  now paired with a locally implemented authenticated media-device registry.
  Each client keeps a persistent X25519 private key in OS secret storage,
  authorizes its public key with a fresh YUID signature, and binds sessions to
  that device. Authenticated directory access, legacy-session migration,
  tamper rejection, revocation authorization, and bound-session invalidation
  have automated coverage. Realtime coordination is also implemented locally:
  LiveKit participant tokens are device-bound; clients verify the signed
  directory; the deterministic leader distributes client-generated keys; the
  backend verifies and recipient-scopes envelopes; replay and cross-room
  attempts fail; removals and leader changes rotate epochs; and LiveKit GCM
  frame encryption is configured before connection with no plaintext fallback.
  Membership queries directly exclude banned accounts, and generation-bound
  client coordination prevents stale asynchronous work from installing a key
  after leave or room replacement. Coordination verification failures now
  zeroize the current key, fail pending key waits, invoke quarantine, and stop
  every local media publication instead of leaving a previous epoch active.
  The complete asynchronous join pipeline is generation-bound across
  realtime membership, key establishment, local capture, credential fetch,
  and LiveKit connection. Leave/server-switch/realtime-disconnect paths
  supersede delayed work, immediately stop local media, and serialize cleanup
  before another join may proceed.
  Automated backend and simulated two-device client tests cover this
  fail-closed boundary and pass. The backend coordination contracts are
  deployed on Unraid. Native two-client media and cryptor-error validation, RTP/SFU
  and packet inspection, Windows validation, and independent review remain
  required, so production calls remain transport-encrypted. A successful
  cryptor is now also required at every microphone-unmute, camera-enable, and
  screen/screen-audio-enable boundary, preventing later UI toggles from
  republishing after quarantine. A focused regression test covers the complete
  ready/failure truth table. The local join is also gated on LiveKit's
  microphone frame-cryptor success event.

## Current Release Priorities

Chat timestamps remain stored and transported as UTC. The desktop message
surface now converts them to the operating system's local timezone before
formatting times, grouping consecutive messages by day, or choosing
Today/Yesterday labels. A regression test covers a UTC timestamp crossing a
Central-time midnight boundary; Flutter analysis and all 58 client tests pass.

The authorization, progressive abuse protection, secret/log auditing,
persistent server identity, certificate-preserving LAN fallback, guarded
LiveKit E2EE, persisted MLS message/attachment runtime, hardened production
deployment, and real encrypted backup/restore milestones are implemented,
deployed where backend changes apply, and covered by the evidence recorded
above. Do not reopen those milestones merely because later release validation
is incomplete.

Release stages are intentionally distinct:

- A **friend-test build** is an explicitly unsigned or development-labeled
  artifact shared with a limited group for validation. It must not claim
  verified E2EE or general release readiness.
- The **first full public release** is the supported public product milestone.
  It requires the release gates below, the integrated calendar and shared
  music experiences defined later in this plan, finished onboarding and
  administration paths, accurate security claims, and publishable supported
  artifacts.

The remaining full-public-release work is:

1. Replace the unreliable monolithic desktop artifact workflow rather than
   continuing to patch it in place. Preserve the least-privilege security
   workflow unless evidence shows it also needs replacement. Give Linux,
   Windows, and macOS separate build workflows, and move substantial build and
   validation logic into versioned repository scripts that can be run locally.
   Centralize pinned Flutter/Rust/action/native dependency versions and
   checksums, retain diagnostics from failed jobs, and separate ordinary CI,
   unsigned validation artifacts, signed release packaging, and publishing.
   Exercise the replacements on a branch before merging them to `main`.
2. Run the replacement security and artifact workflows on the exact candidate
   commit. Require successful hosted Linux, Windows, and macOS builds, native
   MLS tests and official vectors, artifact isolation scans, dependency
   resolution, and packaged-executable smoke tests. Validate Windows secure
   storage/libsodium/MLS loading and macOS entitlements and native-library
   packaging on real systems.
3. Complete native two-client media-E2EE verification, including reconnect,
   rotation, cryptor failure, RTP/SFU inspection, and proof that LiveKit cannot
   decode media.
4. Validate the simple IP-join architecture off LAN and through a router
   without NAT loopback, force a TURN/UDP relay call, then cover public-IP
   changes, verified invitations, realtime/media LAN fallback, and the Windows
   client. Decide whether TURN/TLS is required for the first supported network
   matrix and document unsupported restrictive networks if it is deferred.
5. Prove persisted E2EE multi-device cutover/reinstall/removal on real clients,
   and obtain independent protocol review.
6. Complete and soak-test KDE Wayland and Windows screen sharing, including
   1080p60, separate microphone/system audio, repeated start/stop, and
   hours-long broadcasts.
7. Complete the cross-platform server deployment and parity contract in
   `SERVER_PORTABILITY.md`: one canonical server, guided Linux and Windows
   installers, common-distribution validation, cross-platform LAN discovery,
   identical conformance tests, upgrades, backups, support matrix, and an
   integrated client “Create server” wizard for local supervised hosting or
   safe remote-install guidance.
8. Complete the durable-chat contract in `PERSISTENT_CHAT.md`: indefinite
   default history and attachment retention, indexed cursor pagination,
   bounded client caching, explicit storage-full behavior, secure E2EE history
   continuity for new/reinstalled devices, and destructive backup/restore
   validation at representative scale.
9. Design and implement integrated message threads as described below,
   including E2EE inheritance, permissions, realtime synchronization,
   notifications, unread state, search, lifecycle behavior, migrations,
   cross-device validation, and production deployment.
10. Complete the cross-server Yappa identity and direct-message architecture
   described below. Prove that YUID ownership cannot be spoofed, define
   discovery and privacy behavior, implement multi-device E2EE DMs, and cover
   recovery, key change, blocking, reporting, and compromised-server cases.
11. Design and implement the integrated server calendar described below,
   including backend persistence, authorization, realtime synchronization,
   migrations, cross-device client behavior, and production deployment.
12. Design and implement the integrated shared server music experience
   described below, including a legally and technically valid provider model,
   synchronized state, moderation, linked-account protection, and production
   deployment.
13. Complete release engineering: supported-version and vulnerability policy,
   production version numbers, release notes, code signing, checksums,
   provenance, reproducibility evidence, update/distribution guidance, and a
   final secret/dependency/bundle audit. Run the complete candidate matrix from
   the exact tagged commit and retain the evidence.
14. Perform a full product-readiness pass across onboarding, joining,
    administration, accessibility, empty/error/offline states, data migration,
    backup/restore, and the connections among chat, voice, calendar, and music.
    Update all handoff and user-facing documentation before declaring the
    candidate complete.

### Active Full-Public-Release Handoff — 2026-07-28

This is the concise continuation checkpoint if conversational context is lost.
The active branch is `codex/rebuild-desktop-workflows`; draft PR 4 is the
current review surface.

Completed and evidenced:

- The monolithic desktop workflow is replaced by independent manual Linux,
  Windows, and macOS workflows backed by repository-owned scripts and one
  shared MLS/vector/Flutter gate.
- Exact-commit Windows artifact run `30405281982`, macOS artifact run
  `30405281961`, and security run `30405285412` passed on commit `4140abd`.
  Windows/macOS produced inspected, smoke-tested development artifacts.
- Local Linux neutral-source packaging, native dependency/path/marker
  inspection, and startup smoke pass. Hosted Linux remains pending because its
  self-hosted runner was unavailable.
- The portable-server contract, JSON Schema, Tier-1 support truth, Linux and
  WSL2-dispatching Windows front ends, deterministic server bundle, and
  checksum-pinned fresh-directory local installation are implemented.
- Exact-head security run `30407691102` passed on commit `fb5cae6`, including
  the complete backend suite, locked production audit, real deterministic
  server bundle build, Flutter analysis/tests, native MLS/official vectors,
  and native dependency audit.

Current implementation slice:

- The operational verifier is committed and pushed. Its backend job passed in
  run `30408590340`; exact-head run `30409072042` passed completely for restore
  commit `d65545f`, including backend security/bundle, Flutter/native MLS,
  official vectors, and dependency audits.
- `verify-yappa-install.sh` verifies Linux container health, schema and
  SQLite integrity, persistent identity and private storage modes, an actual
  Ed25519 server proof, API/TLS identity consistency, Socket.IO WebSocket
  upgrade, and guarded LiveKit routing. Its end-to-end LAN fixture and
  tampered-proof/schema negative tests pass locally.
- This host-local verifier deliberately does not claim external reachability,
  forced TURN, or real media. Those remain native/external matrix tests.
- `verify` means operational install verification; encrypted backup restore
  inspection remains independently available as `verify-backup`.
- Safe Linux fresh-install restore is now implemented locally and its focused
  and complete backend/security suites pass. It combines an encrypted backup
  with a checksum-pinned local bundle in private staging, validates the
  configured database, integrity, supported schema and persistent identity,
  rejects overwrite/links/special files/path escape, atomically places the
  completed runtime, and leaves it stopped. Exact-head security run
  `30409072042` passed all jobs for restore commit `d65545f`.
- Transactional Linux upgrade and rollback are implemented locally. Upgrade
  requires current health, a verified encrypted recovery point, a
  checksum-pinned candidate, stopped state copying, schema/integrity checks,
  and candidate operational verification; failure restores the old
  installation. Rollback protects and retains the newer state before
  reactivating the prior snapshot. Focused success/rollback/failure tests and
  the complete local backend/security suite pass. Exact-head security run
  `30409422326` passed all jobs for upgrade commit `58ca781`, including
  backend/bundle, Flutter/native MLS, official vectors, and dependency audits.
- Data-preserving Linux uninstall is implemented locally. It requires current
  operational health, a new verified encrypted backup, a separate fresh state
  destination, and no unresolved lifecycle snapshots. Runtime removal occurs
  only after `.env` and `data/` are privately preserved; placement failure
  restores the installation. Focused tests and the complete local
  backend/security suite pass. Exact-head run `30409845909` passed all jobs for
  uninstall commit `2d7fee3`, including backend/bundle, Flutter/native MLS,
  official vectors, and dependency audits.
- Explicit Linux sign-in autostart is implemented locally for per-user systemd
  hosts. It refuses root and privilege escalation, creates a deterministic
  hardened user unit, requires operational verification on start, stops
  cleanly, removes registration without deleting data, and does not silently
  enable lingering or change firewall state. Container exit/daemon recovery is
  defined by `restart: unless-stopped`. Focused tests and the complete local
  backend/security suite pass. Exact-head run `30410273106` passed all jobs for
  service commit `f9417cc`, including backend/bundle, Flutter/native MLS,
  official vectors, and dependency audits. Unattended boot, hung-container,
  sleep/network, Unraid, and Windows recovery remain open.
- Explicit Linux firewall preview/apply/remove is implemented locally for UFW
  and firewalld. It validates configuration and CIDRs, scopes LAN rules,
  excludes internal ports, refuses ambiguous pre-existing rules, rolls back
  partial application, never invokes privilege escalation or firewall
  enablement, and stores authoritative ownership in root-only host state that
  portable backup/restore excludes. Focused plan/negative tests and a complete
  namespace-isolated root UFW apply/remove cycle pass together with the
  complete local backend/security suite. Exact-head run `30411276865` passed
  the portable hosted fallback plus all backend/client jobs for firewall and
  recovery commit `bb632fa`; real-distribution UFW/firewalld matrices are still
  required.
- Firewall run `30410797088` passed the entire Flutter/native job and every
  backend test before the root-mutation fixture, then failed because GitHub's
  hosted kernel rejects unprivileged `/proc/self/uid_map`. The fixture now
  skips only for that exact kernel policy while plan/negative/static gates
  remain mandatory; local namespace-root mutation still passes. Follow-up
  exact-head run `30411276865` passed.
- Bounded Linux recovery is implemented locally. Lifecycle start/stop records
  private host-local desired state, so intentional stop is never treated as a
  fault. Recovery is single-instance, performs at most one Compose repair,
  allows twelve bounded health/full-verifier attempts, and cools down for 15
  minutes after three failures. The explicit user service installs a hardened
  one-minute recovery timer and removes it atomically with autostart. Focused
  healthy/stopped/recovered/cooldown tests and the complete local
  backend/security suite pass. Exact-head run `30411276865` passed all jobs;
  real sleep/network/systemd matrices remain required.
- A hosted Tier-1 Linux host-contract workflow is implemented locally with
  digest-pinned Ubuntu 24.04, Debian 13, Fedora 44, and Rocky Linux 10 x86-64
  containers. Every non-optional job binds OS identity to the matching
  unpublished manifest target and exercises shell portability, preflight,
  deterministic bundle creation, checksum-pinned fresh installation, private
  modes, firewall planning, intentional-stop recovery, and privileged service
  refusal. It explicitly does not claim Docker/LiveKit/systemd/firewall/media
  runtime conformance. Local Fedora-derived and exact pinned Rocky Linux 10
  execution pass. Initial hosted run `30411754843` reached and passed preflight
  on all four distributions, then every job failed at Git's container
  ownership guard before bundle construction. The workflow now marks only the
  exact GitHub workspace as safe after checkout. Corrected exact-head run
  `30411894908` passed all four non-optional jobs on commit `77397cb`; those
  targets are now `verified-development` for this bounded contract, while
  public support and install commands remain disabled.
- A non-optional isolated Linux runtime workflow is implemented locally for
  the same four digest-pinned distributions. Each job boots systemd as PID 1,
  starts a real lingering unprivileged user manager, activates and removes the
  generated Yappa service/recovery timer from a path containing a space, and
  applies/removes real UFW or firewalld rules inside its disposable network
  namespace. Local execution passes all four targets. It exposed and fixed two
  release defects: invalid quoted systemd working directories and colon-form
  firewalld port ranges. Service registration now also checks that both units
  are active before claiming success. Initial hosted run `30412562488` passed
  Ubuntu and Debian. Fedora and Rocky's distribution `user@.service` wrappers
  are blocked by GitHub at PAM setup with systemd status `224/PAM`, despite
  passing locally. Their hosted jobs now leave user-service runtime explicitly
  unclaimed only for that exact failure and continue to mandatory real
  firewalld mutation/removal; every other manager failure remains fatal. A
  corrected exact-head run `30413430381` passed all four non-optional jobs on
  commit `c5522f9`: Ubuntu and Debian proved the complete real user-service
  plus UFW contract, while Fedora and Rocky proved real firewalld mutation and
  removal with the hosted `224/PAM` limitation reported explicitly. The same
  commit also passed the four-target host contract in run `30413430382` and
  the backend security suite in run `30413430380`. This is not full
  Docker/media, bare-metal reboot, sleep/network, or unattended recovery
  evidence.
- The PowerShell front end now dispatches the canonical checksum-pinned
  install/start/stop/status/logs/backup/restore/upgrade/rollback/uninstall/
  recover/verify lifecycle inside one explicit WSL2 distribution. It converts
  Windows bundle and backup paths with `wslpath`, preserves every value as a
  discrete process argument rather than a shell command string, requires the
  durable installation and preserved state to live on the WSL Linux
  filesystem, and never requests an Administrator credential. Exact-head
  Windows run `30414007960` passed parser, shared-manifest, injection-shaped
  path, distribution-selection, installed-path, and fail-closed negative
  contracts on commit `dd322a7`. This proves the PowerShell bridge only; real
  WSL2 Docker, restart/network behavior, Windows Firewall, Windows service
  supervision, and Windows Server hardware remain unverified.
- A mandatory Ubuntu 24.04 full-stack workflow now builds the deterministic
  release-shaped server bundle, checksum-installs it into a new path containing
  a space, starts the real Node/Caddy/LiveKit/discovery workload, and runs the
  operational schema/storage/signed-identity/API/WebSocket/LiveKit-route
  verifier. It then proves intentional stop suppresses recovery, restarts with
  the same persistent identity, forcibly stops the backend, and requires
  bounded recovery plus the full verifier to pass before deleting containers
  and volumes. Exact-head run `30415529328` passed on commit `d5d920c`. This gate exposed
  and fixed hard-coded host UID/GID `1000`, secure extraction accidentally
  making runtime assets unreadable to containers, LiveKit TURN/config
  isolation incompatibilities, and fresh databases generating a legacy
  64-bit `node_` ID while the signed verifier required a 128-bit `srv_` ID.
  Fresh servers now use 128-bit `srv_` IDs; immutable deployed 64-bit `node_`
  IDs remain verifiable. The complete backend/security suite also passes
  locally. These backend/deployment
  changes are not yet deployed to Unraid because approved SSH access remains
  unavailable.
- Release evidence foundations now generate a SHA-256 sidecar, SPDX 2.3 locked
  npm/Cargo/Pub source-dependency SBOM, and exact version/commit evidence record
  for every desktop archive and the deterministic server bundle. Trusted
  desktop builds and the server authenticity workflow use the official
  GitHub/Sigstore provenance action pinned to commit `0f67c3f`. Pull-request
  run `30415903314` passed deterministic/negative/tag-guard/bundle evidence on
  commit `578b0a2`; trusted manual run `30415925969` created a real
  server-bundle attestation, and independent `gh attestation verify` against
  `CtrlAltForgot/Yappa` succeeded. A read-only `v*` workflow now rejects
  development versions, non-exact tags, unpublished server state, and public
  targets lacking release verification. It cannot publish. Platform code
  signing, notarization, detached installer/server signatures, binary/license
  SBOM review, final-asset verification, and explicit publication remain open
  as detailed in `RELEASE_ENGINEERING.md`.

Next work, in order:

1. Add bare-metal/reboot and sleep/network-transition evidence; validate the
   Windows bridge on real WSL2; then implement and test Windows Firewall and
   background-supervision parity.
2. Obtain hosted Linux desktop evidence and finish signed release engineering:
   production versions, platform/detached signing, binary/license SBOM review,
   final provenance verification, tagged publication,
   supported-version/vulnerability policy, and update/distribution behavior.
3. Complete durable chat/history, threads, unspoofable cross-server
   YUID/multi-device DMs, calendar, and the provider-neutral shared music room.
4. Complete native networking/media E2EE, Windows/KDE screen-sharing soak,
   cross-feature product readiness, exact-tag matrix, production deployment,
   and all user/security/handoff documentation.

No public-release claim is justified yet. In particular, real Windows/WSL2
runtime mutation and native host integration, hosted Linux artifacts, public
installer signing, external/TURN
media, real multi-device E2EE, screen-sharing soak, persistent-history
completion, threads, DMs, calendar, and music remain open.

As of 2026-07-28, the local workflow replacement is implemented. The retired
`build_desktop.yml` has been replaced by independent manual Linux, Windows, and
macOS workflows. Each is a thin wrapper around repository-owned scripts and
the same shared native MLS/vector/Flutter validation entry point. Release,
Flutter, and Windows libsodium versions and the sodium checksum are centralized
in `.github/release-versions.json`; action SHAs remain pinned at each `uses`
boundary where GitHub Actions requires a literal reference. Platform scripts
retain neutral-source builds, split symbols, native-library presence,
builder-path/secret/retired-transport scans, runtime-path inspection, and
packaged startup smoke tests. Failed build diagnostics are retained for 14
days. The deployment-safety test now reads all replacement workflows and
scripts collectively so splitting files cannot silently remove a gate.
The security workflow invokes that same shared client gate instead of
duplicating native/vector/Flutter commands. The release-critical Rust
toolchain is pinned to `1.96.1` in `rust-toolchain.toml`, mirrored in the
release version manifest, and protected against drift by the deployment policy
test.

Local verification passed YAML parsing, shell syntax, `git diff --check`, the
complete backend security suite, all 17 native MLS tests, all 25 pinned
official vector-reader tests, Flutter analysis, and all 58 Flutter tests. The
extracted Linux script also completed a neutral-source release build, bundle
inspection, and development artifact package. PowerShell syntax/runtime and
the Windows/macOS build scripts still require their hosted native runners, and
none of the three new workflows is release evidence until it passes on the
candidate branch and exact candidate commit. Later signed publishing workflows
remain separate release-engineering work.

The first hosted branch run on 2026-07-28 confirmed that the split Windows and
macOS wrappers, version exporter, exact Rust toolchain installation, and shared
client gate start correctly. Windows passed the complete native MLS, pinned
official vector, Flutter analysis, and Flutter test gate before entering its
release build. The macOS gate passed native Rust and official vectors, then
exposed three real portability gaps: libsodium was neither installed for Dart
tests nor bundled into the app, Dart MLS integration tests still skipped
macOS, and the LAN discovery test depended on the runner having a broadcast
route. The local follow-up now checksum-pins and builds the official libsodium
`1.0.20` source, exposes it to tests, installs and signs it in the app
Frameworks directory, enables the Dart MLS integration suite on macOS, and
targets loopback explicitly for protocol-level discovery tests while
production discovery retains broadcast. Linux analysis and all 58 tests plus
the deployment/secret policies pass after the fix.
The same first hosted Windows run passed the complete shared validation gate
and compiled `yappa.exe`; its bundle scan then correctly rejected a
runner-account path retained in Dart AOT through the default Pub cache. The
follow-up assigns clean neutral Pub caches to Linux, Windows, and macOS release
builds and removes Windows generated metadata before artifact compilation
rather than weakening the builder-path scan.

Hosted macOS run `30403399013` on commit `124cb3a` subsequently passed the
complete shared native MLS, official vector, Flutter analysis, and 58-test
gate; built the release app with checksum-pinned libsodium; verified code
signing, literal dotted entitlements, runtime search paths, and forbidden
bundle markers; kept the packaged executable alive through its smoke test; and
uploaded both the development artifact and diagnostics. This is valid hosted
macOS workflow evidence for that commit. Security run `30403401906` on the
same commit also passed. Windows again compiled the release executable and
packaged native dependencies, but its strict scan still found a builder-path
class in `app.so`. The scan remains enforced and now reports only the matched
marker class, without disclosing surrounding binary content, so the retained
path can be identified and removed on the next hosted run.

Exact-commit security run `30404138566` and macOS artifact run `30404136922`
also passed on commit `a46be12`. Windows run `30404136852` again passed shared
validation and compiled `yappa.exe`, then the enhanced diagnostic proved its
only match was lowercase `/users/`: a legitimate Yappa API route. The Windows
regex had applied case-insensitivity globally, causing its macOS `/Users/`
builder-path alternative to reject `/users/`. The local correction scopes
case-insensitivity to drive-letter `C:\Users\...` paths and retired hostname
markers while retaining case-sensitive `/Users/`, `/home/`, and private-key
checks. A policy regression test prevents the false-positive pattern from
returning.

Exact-commit security run `30405285412`, macOS artifact run `30405281961`,
and Windows artifact run `30405281982` passed on commit `4140abd`. The Windows
run passed the complete shared native MLS, official-vector, Flutter analysis,
and 58-test gate; built the release executable with its pinned native
dependencies; passed the corrected builder-path and secret-marker inspection;
kept the packaged executable alive through its smoke test; and uploaded the
development artifact and bounded diagnostics. The macOS run repeated its
signing, entitlement, runtime-path, bundle inspection, smoke, and artifact
checks successfully. The temporary candidate-branch push triggers used to
collect this evidence were then removed; desktop artifact workflows are manual
again. Hosted Linux remains pending because its required self-hosted runner was
unavailable; the equivalent repository-owned Linux script has passed locally
from a neutral source tree, including native dependency, path, marker,
packaging, and startup-smoke checks.

The portable-server phase began on 2026-07-28 with a versioned shared install
manifest and JSON Schema under `server/`. The manifest binds the centralized
development version to exact Tier-1 targets, artifact publication state,
configuration/database schemas, prerequisites, network exposure, required
capabilities, health checks, and lifecycle commands. Its validator rejects
support/command generation before a target is release-verified and rejects a
published artifact without HTTPS download, SHA-256, and detached-signature
metadata. The current manifest remains explicitly unpublished and disables
client command generation and local supervision.

The Linux wrapper preflights the local development server tree and provides
safe start/stop/status/log/backup/verify plus checksum-pinned fresh-install
restore. Restore assembles the selected runtime and decrypted state privately,
validates its configured database, integrity, schema and identity, refuses
merge/overwrite, and leaves the atomic final installation stopped. Focused
positive and adversarial tests and the complete backend/security suite pass
locally. The PowerShell wrapper reads the same contract and safely dispatches
the implemented canonical lifecycle into an explicit WSL2 distribution. Its
hosted argument contract passes, but no real WSL2 workload or native Windows
service/firewall behavior is support evidence yet. Signed bundles, remote
installation, native Windows service/firewall integration, cross-platform
discovery, and every release Tier-1 conformance run remain required.

A deterministic canonical server bundle is now implemented behind
`.github/scripts/build-server-bundle.sh`. It stages only runtime files,
normalizes archive order, ownership, timestamps, and gzip metadata, embeds the
centralized development version plus exact source commit/timestamp, rejects
generated state and secret markers, refuses overwrite, and emits a SHA-256
sidecar. The backend suite proves repeat builds are byte-identical, validates
the checksum/content/metadata, and runs the extracted non-mutating installer;
security CI performs the real build. The artifact remains deliberately
unpublished and unsigned. Signing, SBOM/provenance, tagged-release publication,
manifest activation, and remote installer consumption remain open.

The Linux front end now consumes that development artifact locally: a caller
must supply the bundle, exact SHA-256, and a new absolute install directory.
The installer verifies digest, single versioned root and embedded metadata;
rejects traversal, links, special files, merge and overwrite; installs under a
private root; and runs normal preflight before startup. Tests prove wrong
digests, existing destinations, and a checksum-valid symlink archive fail
without creating the requested install. Remote fetching remains disabled until
publisher authentication exists.

Operational installation verification is now implemented locally. It requires
private configuration/data/identity modes, one persistent identity, writable
storage, current schema and SQLite integrity, all canonical containers running
with a healthy backend, a valid Ed25519 server challenge proof, matching routed
API identity over the configured LAN or certificate-verified public origin, a
real Socket.IO HTTP/1.1 WebSocket upgrade, and a reachable guarded LiveKit
route. Focused tests exercise the complete LAN verifier, tampered identity
signature, wrong schema, and extracted bundle inclusion. External
reachability, forced TURN, and real media remain explicit separate gates.
The documented read-only SSH attempt to `root@192.168.1.254` on 2026-07-28
was denied because no approved key was available. No password was requested.
This verifier is therefore committed but not deployed to Unraid; the repository
is ahead of production for these operator-only files.

As of 2026-07-24, newly created text feeds default to the non-downgradable
`e2ee` version `1` contract. The backend writes that mode at channel creation,
rejects every legacy plaintext message, upload, edit, preview, or delete path
for the feed immediately, and relies on the database downgrade trigger as a
second boundary. The creating owner client enrolls its MLS device, initializes
the group, and synchronizes membership before treating the selected feed as
ready. Voice decks and existing text feeds are unaffected; existing plaintext
history remains explicitly `legacy` version `0` rather than being relabeled or
silently copied. Backend authorization and schema tests prove the default,
plaintext rejection, and downgrade failure. The backend change is deployed and
healthy on Unraid. A real second-device join/removal/reinstall exercise remains
part of release priority 4 above.

### 2026-07-24 Friend-Test Checkpoint

The production node and current Linux release client now use literal public-IP
HTTPS/WSS with no generated DNS connection. The trusted short-lived IP
certificate, API route, Socket.IO upgrade, LiveKit `/rtc` route, signed LAN
fallback, and saved LAN-route migration are verified. Node 22 link-preview
lookup compatibility and safe fallback cards are deployed; private-target
blocking remains covered by the authorization suite.

The manual Windows artifact workflow now pins and checksum-verifies the
official libsodium runtime, validates the MLS and sodium DLLs are packaged, and
launches the packaged executable for an eight-second runtime smoke test before
including a friend-test README. It also separates Flutter debug symbols,
remaps Cargo registry paths out of the MLS DLL, and rejects builder-account,
retired-hostname, Codex-key-label, and private-key markers across the bundle.
A current hosted Windows workflow run and real Windows
connection/vault/media execution are still required before treating that
artifact as a validated release.

The first current hosted Windows attempt reached compilation but failed under
Visual Studio 18 / MSVC 14.51 because `webview_all_windows` 1.2.1 still enables
legacy `/await`, and the updated STL promotes its experimental-coroutine
deprecation to error `STL1011`. Yappa now scopes Microsoft's documented
compatibility definition only to the WebView plugin target; no project-wide
warning suppression was added. Static policy checks pass, but the hosted
Windows job must be rerun to prove compilation and packaging.

## First Public Release Product Pillars

The following capabilities are part of the intended first full public
release, not commitments for the next friend-test artifact. Their detailed
product and technical designs must be completed before implementation.

### Integrated Message Threads

Text feeds should support focused, message-rooted side conversations without
forcing people to create or configure another channel. A thread should feel
like a natural expansion of its root message: visible context, one-click
opening and reply, predictable back navigation, and useful activity previews
in the parent feed. The first design is for threads inside ordinary text
feeds; forum-style post channels are a separate future product decision.

The design must resolve and implement:

- Thread creation from eligible messages, replies, editing and deletion,
  participant views, links, compact parent-feed previews, and clear behavior
  when the root message or its author is deleted.
- Exact inheritance of the parent feed's membership, role permissions,
  retention, moderation, and E2EE mode. A thread must never become a hidden
  route around channel access or expose encrypted root/reply content as
  plaintext metadata.
- For E2EE feeds, authenticated encrypted thread context and reply envelopes
  that bind each reply to the server, channel, root message, sender device, and
  current MLS epoch without creating a downgrade or cross-thread replay path.
- Realtime creation/reply/edit/delete propagation, deterministic ordering,
  pagination, offline send/retry and deduplication, reconnect catch-up,
  cross-device drafts where supported, and conflict handling.
- Per-thread follow/mute state, mention behavior, notification policy, unread
  counts, read markers, jump-to-message behavior, and parent-feed activity
  indicators that remain understandable at large-server scale.
- Search and moderation that respect encryption and access boundaries,
  rate/size limits, spam controls, auditability for moderator actions, and
  retention/backup/restore behavior.
- Accessible keyboard and screen-reader navigation, narrow-window behavior,
  empty/error/offline states, and a responsive presentation that does not
  permanently split the chat surface into competing modules.
- Backend schema, migrations, authorization, serialization, APIs, realtime
  events, negative tests, client state, and production deployment, followed by
  real multi-client and cross-device validation.

### Cross-Server Identity and Direct Messages

Yappa IDs (YUIDs) are intended to identify the same person across independently
hosted servers and to support private relationships that are not owned by one
server. The current foundation derives the 20-character YUID from a SHA-256
digest of an Ed25519 public key and requires a server-specific, nonce-bound
signature during authentication. That prevents a server client from choosing
another person's YUID without the corresponding private key, but it is not yet
a complete global identity or DM system.

The design must resolve and implement:

- A canonical identity document and proof format that binds the full public
  key, YUID, protocol version, and key purpose. Security checks must compare
  and verify the full key rather than trusting the shortened display
  identifier alone, with collision and malformed-encoding tests.
- A discovery model that does not require publishing every user's server
  memberships or making YUIDs globally enumerable. Contact codes, invitations,
  mutual-server discovery, and explicit lookup consent must be evaluated
  against spam, stalking, scraping, and account-correlation risks.
- A user-verifiable identity view with safety-number or QR comparison,
  verified-contact state, clear key-change warnings, and no implication that a
  cryptographic key proves a person's civil identity.
- Multi-device identity and recovery semantics. New devices, reinstall,
  backup/restore, lost or stolen devices, revocation, rotation, and deliberate
  identity replacement must not silently let a server or attacker impersonate
  an established contact.
- A server-independent DM routing model or an explicitly trusted home-service
  model, including offline delivery, retries, ordering, attachments,
  notifications, retention, deletion, portability, and behavior when one
  participant's usual server is unavailable.
- End-to-end encrypted one-to-one and group-DM sessions built on reviewed
  protocols, with authenticated device membership, forward secrecy,
  post-compromise recovery, replay protection, transcript consistency, and
  fail-closed handling. Existing server-channel MLS code is useful evidence,
  not automatic proof that the DM topology is safe.
- Blocking, message requests, rate limits, spam controls, reporting that does
  not silently expose unrelated plaintext, abuse-evidence choices, and
  protection against blocked users evading controls through another server.
- Backend storage, authenticated APIs, realtime delivery, migrations,
  cross-device synchronization, backup/restore boundaries, negative
  authorization tests, independent protocol review, and real clients on
  separate servers before public-release claims.

### Integrated Server Calendar

Each server should have a first-class calendar that works equally well for a
small friend group and for organized, large-scale community events. It should
not feel like an embedded third-party calendar or an isolated administration
module.

The design must resolve and implement:

- Calendar browsing with useful agenda, day, week, and month presentations
  appropriate to desktop window sizes.
- Event creation, editing, cancellation, duplication, and deletion with clear
  ownership and server-role permissions.
- Titles, descriptions, locations or links, start/end times, all-day events,
  time zones, recurrence, capacity, and reminders without ambiguous daylight
  saving behavior.
- RSVP states, attendee visibility, waitlists or capacity behavior where
  appropriate, and realtime updates across devices.
- Connections to existing server concepts such as channels, voice decks,
  people, roles, notifications, and presence without silently expanding access
  to private content.
- Search, filtering, accessible notifications, conflict/change handling,
  offline/retry behavior, auditability for important organizer actions, and
  sensible behavior for deleted users or channels.
- Backend storage, APIs, serialization, realtime propagation, migrations,
  authorization/abuse tests, backup/restore coverage, and deployment
  verification.
- A documented privacy model for event content and attendance. Whether any
  calendar fields require E2EE must be decided explicitly rather than implied
  by Yappa's encrypted messaging.
- Later import/export or interoperability, such as standards-based calendar
  files, only after the native Yappa experience and security boundaries are
  defined.

### Integrated Shared Music

Each server should be able to host a persistent social listening space inspired
by the best parts of the early plug.dj experience: people can discover, queue,
listen, vote, and watch together through a dedicated interface without typing
commands in chat or making a bot join a voice deck.

The experience should include a visible current track, ordered shared queue,
who queued each item, participant/presence context, playback progress, vote
skip and moderation controls, provider/source attribution, and either an
available music video or an intentional visualizer/artwork experience. Queue
and playback transitions should feel connected to the server rather than like
an external player pasted into Yappa.

The detailed design must be provider-neutral until current APIs, licenses, and
playback terms are verified. YouTube, SoundCloud, and Spotify differ
substantially: a linked Spotify account may only permit playback through that
member's authorized player and subscription, and one provider's URL or search
result does not imply Yappa may restream its audio to everyone. Before choosing
an architecture, verify each provider's current official SDK/API terms,
embedding rules, account requirements, quotas, attribution, commercial-use
limits, and synchronization restrictions.

The design must resolve and implement:

- A reusable rich-presence model rather than a music-only status field.
  Optional Spotify linking may power consented listening presence, while the
  same presence foundation can later represent other Yappa activities without
  exposing them by default. Spotify linking and library access are not
  prerequisites for the shared music experience.
- A strict separation between catalog identity and playback delivery. A track
  identified through any provider may be mapped to an authorized playback
  source only where both providers permit that integration, and then only with
  deterministic metadata matching, explicit source attribution, mismatch
  reporting, and user control. Catalog access never grants Yappa permission to
  obtain or redistribute the recording from elsewhere.
- Whether playback is synchronized individual provider playback, an approved
  embed, server-relayed content, or another licensed model for each source.
  Yappa must not download, rebroadcast, proxy, or strip protection from media
  without explicit authorization. Command-line extraction or downloader tools
  such as `yt-dlp` are not an approved public-release playback architecture
  unless the applicable provider and rights holders explicitly authorize the
  exact use.
- OAuth/account linking with minimum scopes, secure token storage, revocation,
  expiry/refresh handling, account unlinking, log redaction, and a useful
  experience for people who do not link a provider.
- Canonical queue items across providers, duplicate handling, unavailable or
  region-restricted tracks, explicit-content information where available,
  videos, artwork/metadata, and a local visualizer fallback.
- Authoritative synchronized playback state, clock drift correction,
  reconnect/late-join behavior, host failure, provider errors, and a clear
  distinction between shared queue state and playback occurring on each
  person's device.
- Vote-skip policy, thresholds, rate limits, queue permissions, owner/moderator
  controls, history, abuse resistance, and fair behavior as participants join
  or leave.
- Connections to server presence, profiles, notifications, and chat that are
  useful but never require command syntax or a voice bot.
- Privacy controls for listening activity and linked-provider identity, plus
  clear disclosure of data sent to external providers.
- Backend persistence, APIs, serialization, realtime propagation, migrations,
  authorization tests, provider-adapter tests, failure simulation,
  cross-device runtime validation, backup/restore boundaries, and production
  deployment.

An original Yappa interaction and visual design should be developed rather
than cloning plug.dj or another product's protected assets or exact interface.

As a preliminary provider constraint check on 2026-07-28, Spotify's official
Developer Policy prohibited non-interactive internet webcasting and products
integrated with streams or content from another service, while YouTube's
official API Developer Policies prohibited downloading, separating, or
redistributing YouTube audiovisual content without the required approval.
Consequently, optional Spotify rich presence is not coupled to music-room
playback, and `yt-dlp`-style extraction is not a release architecture. These
policies must be rechecked during detailed adapter design because provider
terms can change.

## Future Hosted File Sharing

Yappa should eventually let a server host durable files independently of chat
attachments. This is a future subsystem, not permission to expose the existing
data directory or reuse public static paths.

The design must include:

- Server-wide enable/disable controls and total/per-file quotas.
- Explicit upload, browse, folder, rename, move, download, and delete APIs.
- Member/role permissions for reading, uploading, organizing, and deleting.
- Authenticated or short-lived signed downloads with path containment.
- File type policy, malware-scanning integration points, and abuse limits.
- Persistent metadata, migrations, ownership, timestamps, and optional expiry.
- Atomic writes, duplicate-name behavior, interrupted-upload cleanup, and
  storage accounting that survives restart.
- Realtime updates so multiple clients see library changes.
- Backup/restore guidance and a clear distinction from ephemeral attachments.
- A later client-side encryption design consistent with Yappa's message and
  attachment E2EE direction.

The existing `file_storage_*` server settings are only policy groundwork; no
user-facing hosted file library should be claimed until the complete storage,
authorization, API, realtime, migration, client, and verification path exists.

## Release Principle

Repository code, deployed backend behavior, database schema, and client
expectations must move together. If one of those is behind, the feature is not
finished.
