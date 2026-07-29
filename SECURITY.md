# Yappa Security and Privacy Plan

## Reporting Vulnerabilities

Yappa is pre-release software. Only the current `main` development line is
eligible for security fixes; no published build is currently designated as a
supported secure release.

Do not disclose a suspected vulnerability in a public issue, discussion, chat,
or log attachment. Use GitHub's private vulnerability-reporting form at:

<https://github.com/CtrlAltForgot/Yappa/security/advisories/new>

Include the affected revision, platform, reproduction steps, expected impact,
and the minimum diagnostic material necessary. Never include real server
passwords, bearer tokens, private keys, production databases, or private
message/attachment content. Maintainers should acknowledge a report before
requesting additional sensitive evidence, coordinate a fix and regression
test privately, then publish an advisory once affected users can update.

## Mission

Yappa is intended to be a privacy-first, open-source communication platform
that anyone can use and self-host without premium feature gates. Privacy must
come from verifiable architecture and safe defaults, not branding.

This document records the current security truth, threat model, implementation
order, and acceptance criteria. Update it whenever security-relevant behavior
changes.

## Current Security Truth

As of 2026-07-24, Yappa has implemented guarded end-to-end encryption paths,
but must not market messaging or calls as verified E2EE until the platform,
native two-client, inspection, vector, and independent-review gates below pass.

- The current Unraid deployment has trusted direct-IP HTTPS/WSS through its
  bundled Caddy reverse proxy and a short-lived Let's Encrypt IP certificate.
  Loopback-bound raw API/WS and private LiveKit compatibility listeners must
  not be forwarded.
- LiveKit rooms are configured with client-held frame encryption keys for
  microphone, camera, screen video, and screen audio. Publication fails closed
  until the native cryptor reports success and is quarantined on cryptor
  failure. Native two-client, wrong/no-key, SFU/RTP inspection, Windows, and
  independent-review gates remain, so calls are still described as
  transport-encrypted in release claims.
- Legacy text channels still store plaintext in SQLite and are explicitly
  labeled version `0`. Version `1` E2EE channels use MLS application events;
  the server stores opaque wire messages and routing metadata while clients
  authenticate, decrypt, and materialize history locally.
- Legacy attachments remain plaintext at rest behind authenticated,
  short-lived, account-bound HMAC download grants. Version `1` encrypted
  attachments are secretstream ciphertext whose key and display metadata live
  only inside the authenticated MLS event. Branding assets remain public so
  nodes can render before login.
- Passwords are hashed with bcrypt.
- Session tokens are cryptographically random. The server stores only SHA-256
  token digests and upgrades legacy raw-token rows on successful use. The
  client stores reusable bearer tokens in OS-backed secure storage and removes
  legacy preference values only after a successful secure write.
- Temporary connection failures preserve the saved client session so users can
  retry in place. Saved credentials are cleared only when the server explicitly
  rejects them with an authentication or authorization response.
- The backend sends defensive browser/security headers, limits JSON request
  bodies to a configurable size, supports an explicit browser-origin allowlist,
  and rate-limits identity challenges and sign-in attempts by client address.
- YUID uses signed identity proofs. This authenticates an identity claim; it
  does not encrypt conversations.
- The database and server-side files are not encrypted by Yappa at rest.

Self-hosting limits who operates the infrastructure, but does not correct these
cryptographic and transport gaps by itself.

## Threat Model

Yappa must protect against:

- Passive observers on local or public networks.
- Active network attackers attempting token or credential theft.
- Unauthorized users guessing or sharing attachment URLs.
- A compromised or curious hosting provider reading communication content.
- Stolen session tokens and abandoned logged-in devices.
- Malicious members accessing channels or history they are not authorized to
  access.
- Replay, impersonation, downgrade, key-substitution, and membership-change
  attacks.
- Database, backup, log, or attachment-directory disclosure.
- Dependency and supply-chain compromise.
- Accidental secret publication in source control, build artifacts, or logs.

No design can promise protection after an endpoint itself is compromised.
Metadata minimization is a separate goal from content encryption and must be
documented honestly.

## Priority 1: Secure Transport and Authorization

Before public internet exposure:

1. Put the backend and LiveKit signaling behind trusted TLS termination.
   The server bundle now includes Caddy `2.11.4`, persistent certificate
   storage, automatic HTTPS configuration, and path-based reverse proxies for
   the Yappa API/Socket.IO and LiveKit signaling on one origin. Fresh installs bind the raw
   backend to host loopback, preventing a remote plaintext bypass. LAN mode
   works over HTTP only when explicitly selected. The default fresh-install
   path detects the public IPv4 address and obtains a trusted short-lived
   Let's Encrypt certificate for that literal IP. API, Socket.IO, and LiveKit
   signaling share TCP `443` by path, and a separate script switches to one
   optional user-owned domain. The automatic mode queries `api.ipify.org`;
   the certificate is publicly logged in certificate-transparency records. The LAN
   deployment was verified through Caddy on 2026-07-23 while retaining its
   existing direct endpoints; Caddy uses alternate Unraid-safe host ports
   because the Unraid management interface owns host ports 80 and 443.
   The one-command automatic-IP installer and custom-domain helper were also
   deployed and validated without changing the active LAN configuration.
   After router forwarding was configured, multiple external Let's Encrypt
   validators completed certificate challenges. On 2026-07-24 Caddy obtained
   a short-lived certificate whose critical SAN is the literal public IP.
   Direct-IP API, no-SNI TLS, and LiveKit-path probes passed. Full off-LAN API,
   realtime, and media testing remains outstanding.
   The normal client UX and actual TLS origin are the public IP. LAN fallback
   remains bound to the remembered server identity and cannot silently accept
   plaintext or an unrecognized certificate.
   As an interim NAT-loopback fix, a voice-token request received through an
   explicit private/LAN host returns the private LiveKit signaling route; a request
   received through the public TLS host still returns WSS. The LAN compatibility
   listeners must never be forwarded publicly.
2. Require `https://` and `wss://` for non-loopback/non-development servers.
   The client now defaults public hostnames and public IP addresses to HTTPS
   and rejects explicitly insecure public HTTP addresses. Loopback, private
   IPv4/IPv6, single-label, `.local`, and `.internal` development/LAN hosts
   remain eligible for HTTP. Automated normalization/downgrade tests cover both
   allowed and rejected cases.
3. Refuse insecure downgrade for saved public nodes.
   Enforced through the same normalization path used by initial joins and all
   restored-session API calls; Socket.IO inherits the normalized HTTPS scheme.
4. Replace unauthenticated static `/uploads` delivery with an authorized route
   or short-lived signed URLs that verify server membership and channel access.
   Implemented locally on 2026-07-23 with 15-minute per-account HMAC grants,
   constant-time signature checks, expiry enforcement, attachment/channel
   validation, path containment, and a current-ban check on every download.
   Realtime messages receive recipient-specific grants. Tests confirmed valid,
   guessed, tampered, expired, banned, and legacy-static behavior while public
   branding remained available. A full multipart upload → message → signed
   download test also passed byte-for-byte. Deployed to Unraid on 2026-07-23
   with a production-only persistent signing secret. An existing PNG verified
   HTTP 200 and ranged HTTP 206 through a grant, while guessed/tampered grants
   returned 403 and its former static path returned 404.
5. Apply authorization checks consistently to message history, attachments,
   channel mutations, voice tokens, and realtime subscriptions.
   The first automated authorization suite was added on 2026-07-24. Public
   health and pre-login server responses no longer expose channel, settings,
   or voice-presence state, and `/api/channels` now requires authentication.
   Disposable multi-user tests prove protected routes reject logged-out
   callers; members cannot use owner settings, branding/channel, or ban
   routes; sessions cannot be revoked across accounts; messages cannot be
   edited/deleted across accounts; invalid Socket.IO sessions are rejected;
   invalid voice-deck joins fail; and banning immediately invalidates the
   target session. Attachment-grant negatives remain covered by the dedicated
   signed-download regression checks.
6. Restrict CORS to configured trusted origins rather than `*` in production.
   The backend now supports comma-separated allowlisting, permits native
   clients without a browser `Origin`, and uses an empty native-only allowlist
   in generated/example configuration and when Node is launched directly
   without that variable. Wildcard browser access requires an explicit
   development configuration. Deployed to Unraid on 2026-07-23;
   production verification confirmed native access succeeds and an
   unconfigured browser origin receives HTTP 403.
7. Add secure headers, request limits, upload validation, and rate limiting.
   Security headers, configurable JSON limits, upload limits/type checks, and
   IP-based authentication/challenge limits were implemented on
   2026-07-23. Temporary-backend tests confirmed allowed and denied CORS,
   response headers, HTTP 413 for oversized JSON, and HTTP 429 at both
   configured authentication thresholds. Legacy and ciphertext attachment
   limits are now enforced by the streaming multipart parser before an
   oversized body can be fully written to disk. Integration coverage confirms
   HTTP 413 and that rejection leaves no attachment row or partial file.
   Broader controls are implemented locally for content mutations, uploads,
   external preview fetches, voice
   tokens, account/device/admin changes, attachment downloads, realtime
   connection attempts, voice controls, signaling, and media-key envelopes.
   Authenticated budgets are scoped by account and separated by workload;
   unauthenticated connection and signed-download limits are scoped by address.
   Automated tests cover HTTP and realtime exhaustion, retry metadata, account
   isolation, and workload-category isolation. The controls are deployed;
   production tuning after longer observation remains outstanding.
8. Document TLS certificate, reverse-proxy, firewall, and TURN/TLS deployment.
   `server/DEPLOYMENT.md` records the packaged startup flow, DNS settings,
   persistent certificate storage, public firewall allowlist, prohibited raw
   port forwarding, and backup boundaries. Direct UDP, ICE/TCP, and LiveKit's
   authenticated embedded TURN/UDP fallback on UDP `443` are packaged; Caddy
   no longer claims that host UDP socket for optional HTTP/3. TURN/TLS remains
   explicitly outstanding, so restrictive networks that block every UDP path
   and non-HTTPS TCP are not yet guaranteed to connect. The pinned LiveKit
   `v1.13.4` image accepted the generated TURN configuration. The production
   listener is deployed on UDP `443`; an off-LAN relay-only call remains
   required.
9. Bind remembered nodes to a persistent cryptographic server identity rather
   than trusting an address alone.
   Implemented locally on 2026-07-24 with a server-held Ed25519 key generated
   once under the persistent per-server data root with mode `0600`. Before a
   client sends a password, bearer token, or rotation request, it verifies a
   signature over a fresh 256-bit nonce and the expected server id, then pins
   the public key in the saved node record. A mismatch prevents credential
   transmission, disconnects realtime, preserves the local session, and
   reports an identity-change warning. Backend tests verify signatures,
   challenge validation, key permissions, and restart persistence; client
   tests verify valid proofs and changed-key rejection. This is
   trust-on-first-use for direct address entry. Existing nodes pin on their
   first upgraded connection, while a future signed invite format should
   distribute the expected key out of band. Unraid deployment and schema/
   container restart were completed on 2026-07-24. Real-client route migration
   was verified against the production node on the same date.
10. Preserve transport security during automatic LAN fallback.
    Implemented locally for API and Socket.IO traffic with a bounded signed UDP
    discovery response on port `41200`. Responses bind the request nonce,
    server id, persistent public key, advertised public address, and LAN TLS
    port. Clients reject non-private source addresses, changed identities,
    mismatched advertised addresses, invalid signatures, and stale nonces.
    Docker-published UDP was proven to drop LAN broadcasts on the production
    Unraid host even though unicast worked. The packaged stack therefore uses
    a separate host-network relay on UDP `41200`, with no secrets or stored
    data, and exposes the backend signing responder only on host loopback UDP
    `41201`. The relay accepts bounded private IPv4 requests, overwrites
    untrusted source metadata, prevents pending-nonce replacement, rate-limits
    each source, and forwards only protocol-valid responses. The backend
    trusts forwarded rate-limit identity only from loopback.
    The hardened relay was deployed to Unraid on 2026-07-24, and a workstation
    broadcast received a valid signed response from the expected private
    address.
    Discovery never changes the logical HTTPS/WSS origin: it overrides only the
    TCP dial address while retaining the public hostname for SNI and ordinary
    certificate verification, then repeats the fresh server-identity proof.
    This avoids exposing passwords or bearer tokens through a silent HTTP
    downgrade. API, realtime, and LiveKit signaling apply the scoped secure
    dial override locally; LiveKit retains its public WSS hostname and trusted
    certificate while connecting through the LAN IP. Branding, legacy
    attachment, and encrypted attachment multipart uploads now use that same
    scoped HTTP client instead of bypassing the verified route. Encrypted
    upload responses are pinned against the client-generated id, header,
    digest, size, and chunk count before use. The discovery port is LAN-only
    and must never be forwarded by a router. The backend and discovery
    responder were deployed on 2026-07-24, and raw TCP `4100` was confirmed
    unreachable from another LAN machine. The production LAN cannot reach the
    public hostname through the router, confirming absent NAT loopback. A
    certificate-preserving request that retained the public hostname while
    dialing the server's LAN address on port `8443` returned HTTP 200 with
    successful certificate validation. Port `41200/udp` is listening on the
    host, and an in-container production probe returned a signed response
    containing the persistent server identity, matching nonce, advertised
    address, and LAN TLS port. Legacy saved nodes that still name the retired
    raw LAN backend on port `4100` now derive the HTTPS public origin from the
    signed advertised address before installing the LAN TLS override. This
    preserves the pinned identity and saved session without reopening the raw
    listener; invalid/non-HTTPS advertised routes fail closed. Focused
    normalization, signature, and route tests pass. The real release client
    removed the saved plaintext `:4100` route and persisted the secure public
    origin after production discovery. Realtime and media fallback validation
    remain pending.

Acceptance requires automated negative tests proving unrelated, logged-out,
banned, and insufficiently privileged users cannot retrieve or mutate scoped
resources. The current suite covers the implemented single-community role
model; future private-channel roles must extend the matrix before release.

## Priority 2: Session and Account Hardening

1. Store server-side session-token hashes rather than reusable raw tokens.
   Implemented on 2026-07-23 with transparent migration of active legacy
   sessions; logout, ban revocation, HTTP auth, and Socket.IO auth all use the
   digest lookup. Deployed to Unraid and verified against the production
   database with one hashed session and zero legacy raw-token rows; no token
   values were inspected or printed.
2. Store client credentials in OS-backed secure storage where supported.
   Implemented on 2026-07-24 for session bearer tokens and the YUID Ed25519
   identity. Existing preference/file values migrate into the platform vault
   before their plaintext copies are deleted; YUID public metadata remains in
   preferences. Linux uses Secret Service through `libsecret` and a desktop
   keyring, Windows uses AES-GCM with its key protected by Windows Credential
   Manager, and Apple targets use Keychain. A real KDE migration and a second
   keyring-only restart were verified without reading secret values: the
   plaintext token/private-key preferences and legacy YUID identity file were
   absent afterward. Linux analysis and debug build passed. Windows build and
   runtime migration remain pending on Windows hardware.
3. Add expiry, idle timeout, rotation, per-device session listing, and remote
   revocation.
   Implemented on 2026-07-24. New and migrated sessions have a configurable
   30-day absolute lifetime and seven-day idle timeout. A restored client
   rotates its bearer token before loading account data and saves the
   replacement to the OS credential vault before continuing. Settings lists
   the account's signed-in devices using generic operating-system labels and
   permits remote revocation or logout of the current device. Session queries
   are user-scoped, expired rows are rejected and removed, realtime activity
   refreshes the idle deadline, and logout, rotation, or revocation disconnects
   sockets authenticated by the affected session. The schema migration,
   production deployment, API lifecycle, and token rotation were verified
   without printing reusable token values. Windows vault/runtime validation
   remains pending on Windows hardware.
4. Rate-limit authentication and add progressive abuse resistance.
   Implemented on 2026-07-24 with two layers: the existing per-address fixed
   window limits bound total sign-in and YUID-challenge work, while known
   accounts now receive an in-memory exponential delay after three incorrect
   passwords. The default delay grows from one to 30 seconds, successful
   authentication clears it, stale entries expire after 30 minutes, blocked
   requests do not increase the delay, and cleanup bounds retained state.
   Responses use HTTP 429 plus `Retry-After`; automated tests cover the free
   attempts, increasing block, correct-password blocking during the delay,
   expiry, and reset after success. The in-memory account layer intentionally
   resets on backend restart; the IP layer still limits immediate CPU abuse.
   Additional fixed-window controls now bound authenticated mutation,
   upload/download, resource-fetch, voice-token, realtime-handshake, control,
   signaling, and media-envelope work. These are deliberately separate from
   password backoff: they limit resource exhaustion without turning ordinary
   account activity into a credential lockout. Their state also resets on
   restart and requires production observation before release tuning is final.
5. Upgrade password hashing parameters or adopt a reviewed Argon2id policy with
   a non-destructive migration.
   Implemented on 2026-07-24 as an incremental bcrypt hardening step. New
   accounts use configurable cost 12 and require at least 10 characters.
   Existing accounts retain compatibility with the previous minimum and their
   hash is transparently upgraded after the next successful password login,
   without storing or logging the password. Argon2id evaluation remains a
   future reviewed migration rather than an improvised algorithm switch.
6. Protect YUID private keys with OS-backed secure storage.
   Implemented together with item 2. Startup forces migration even for an
   already-authenticated session rather than waiting for the next sign-in.
7. Define account recovery without silently defeating encrypted-content
   guarantees.
8. Avoid logging credentials, tokens, encryption keys, message bodies, or
   private attachment URLs.
   Implemented and regression-tested on 2026-07-24 for current server/client
   logging. Operational file failures no longer print storage paths or raw
   error messages; unexpected request failures log only a random incident id
   and sanitized error class/code; startup no longer prints database/data
   paths or server identity; and account/YUID events do not print usernames.
   A static source scan rejects sensitive variables inside server/client log
   calls, while a disposable runtime test submits unique password, bearer,
   private-key, signature, and message sentinels and proves none appear in
   captured stdout/stderr. Future logging additions must keep this test green.

## Priority 3: Realtime Media E2EE

The concrete device identity, envelope, room epoch, rotation, failure-state,
and verification contract is maintained in `MEDIA_E2EE.md`. That document is
an implementation plan, not a claim that calls are currently E2EE.
The sealed key-envelope primitive is implemented and unit-tested locally with
ephemeral X25519, HKDF-SHA-256, AES-256-GCM associated-data binding, and an
Ed25519 sender signature.

Authenticated device registration is implemented locally. Each installation
stores one X25519 private key in the operating-system credential vault and
uses its YUID Ed25519 key to authorize the public media key for one server,
account, fresh challenge, and device id. Sessions bind to these records;
authenticated members can retrieve the active public directory; revoked or
banned records are excluded; and revoking a record deletes its sessions and
disconnects matching realtime sockets. Existing sessions register before
their next token rotation. Automated tests cover private-key persistence,
invalid stored identities, legacy-session migration, tampered
authorizations, public-only serialization, cross-account revocation, and
session invalidation. The backend registry/schema was deployed to Unraid on
2026-07-24; active client enrollment and native multi-device validation remain
pending.

Realtime coordination and mandatory LiveKit frame encryption are implemented
locally. LiveKit tokens use the authenticated media-device id as participant
identity. The backend publishes deterministic, device-scoped room membership,
increments the epoch on removal and leader changes, accepts envelopes only
from the current leader, verifies their YUID signature, and rejects replay,
stale epoch, wrong-recipient, and cross-room delivery. Clients independently
verify the directory, distribute client-generated room keys with sealed
envelopes, install per-participant GCM keys before `Room.connect`, discard
frames without a ready cryptor, and quarantine key slots during rotation.
Encrypted-room membership defensively excludes active bans in the membership
query itself. Client coordination is generation-bound so an asynchronous
verification, quarantine, envelope, or key-installation task from a departed
or superseded room cannot restore a stale key.
Leader election uses explicit locale-independent ASCII ordering to match the
client verifier; randomized device ids in the integration suite exposed and
now guard against the former locale-sensitive mismatch.
The UI exposes establishing, encrypted, and failure states without offering a
transport-only fallback.
Microphone unmute, camera enable, and screen/screen-audio enable operations now
also enforce the local ready/non-failed cryptor state directly. This prevents
a later UI toggle from republishing after the failure handler quarantines and
stops tracks; automated coverage checks all state combinations.

Automated backend tests cover device-bound LiveKit tokens, deterministic
membership/leadership, signed recipient relay, replay, cross-room rejection,
tamper rejection, revocation, and removal rotation. Client tests cover
directory substitution, stale state, sealed envelopes, two-device key
agreement, rotation, cancellation of in-flight key establishment on leave,
and fail-closed zeroization/quarantine after a coordination error.
The required `webkit2gtk4.1-devel` package was installed through the
authenticated Nobara package manager on 2026-07-24, after which the current
Linux debug and release bundles built successfully and the release binary
launched. Bundle inspection found the native MLS, LiveKit/WebRTC,
secure-storage, and WebKit plugins with all linked dependencies resolving on
the validation host. The client gates a
successful join on LiveKit's
local `kOk`/`kKeyRatcheted` frame-cryptor event and stops every local media
type on a cryptor error, but this has not been exercised on native hardware.
The backend coordination is deployed. On 2026-07-24 the active Unraid
LiveKit configuration reported TURN enabled on UDP `443`, the host listener
was present, and Caddy remained off that UDP socket. An off-LAN relay-only
call is still required. Two-client native calls, wrong/no-key media tests, RTP/SFU and
packet inspection, Windows runtime validation, and independent review remain
mandatory. Until those gates pass, production calls remain
transport-encrypted and Yappa must not claim completed media E2EE.

Use LiveKit's supported E2EE layer for:

- Microphone audio.
- Camera video.
- Screen video.
- Screen/system audio.
- LiveKit data channels if Yappa uses them.

E2EE is the default product mode, not an administrator opt-in. Its keys must
be created and held by clients and distributed only to authorized room
members. HTTPS/WSS and WebRTC DTLS remain required for transport and signaling
after E2EE is enabled; media E2EE does not protect passwords, bearer tokens,
API responses, or signaling metadata.

Requirements:

1. Encryption keys are generated and owned by clients.
2. The Yappa backend and LiveKit SFU must not receive plaintext room keys.
3. Participants authenticate each other's device keys.
4. Membership changes trigger safe key rotation.
5. New devices and reconnects have explicit, testable key behavior.
6. The UI clearly distinguishes verified E2EE, transport-only encryption, and
   failure/downgrade states.
7. No silent fallback to non-E2EE media.

Acceptance requires packet/server inspection demonstrating that the SFU cannot
decode media, plus multi-client join, leave, reconnect, and rotation tests.

Realtime loss now explicitly notifies application state while Socket.IO keeps
retrying. The client marks the saved server unreachable without deleting its
session, exposes an immediate retry, ends media-key coordination, stops local
capture, and leaves LiveKit so a stale room key cannot survive loss of the
authenticated coordination channel. A recovered socket clears the outage
state in place. Lifecycle coverage proves repeated connection errors generate
one outage transition and intentional disposal generates none. Native
two-client reconnect and key-rotation validation remains part of the media
release gate.

## Priority 4: Persisted Message and Attachment E2EE

Do not improvise a home-grown cipher. Adopt reviewed primitives and a
documented protocol suitable for asynchronous groups and multiple devices.
The concrete protocol contract is now maintained in `MESSAGING_E2EE.md`.
Yappa uses RFC 9420 MLS through a pinned OpenMLS native bridge foundation for
group state and private application messages, plus libsodium secretstream for
streaming attachments whose random keys will be carried inside MLS messages.
The foundation, encrypted text projection/send/edit/delete/reaction path, and
encrypted attachment send/decrypt-save path are implemented and tested.
Platform validation and independent cryptographic review remain release
blockers.

Encrypted attachment application events now authenticate an optional caption
and up to ten files together. Every file receives an independent random
secretstream key and event/attachment-bound context, while one canonical MLS
operation binds the caption, keys, filenames, types, sizes, headers, digests,
and chunk counts. If an upload response is lost, the exact MLS ciphertext and
complete ciphertext set remain staged for idempotent retry; no caption is
resubmitted as a separate plaintext or encrypted message. Projection restores
the caption and locked file cards from the verified event. Legacy attachment
events without a caption remain readable. Flutter analysis, all 52 client
tests, the multi-file lost-response/download integration test, and all 17
locked native MLS tests passed on Linux on 2026-07-24. This changed no backend
contract because the server continues to receive only opaque MLS ciphertext
and authenticated attachment routing ids.

Encrypted-image previews use an explicit local-only privacy model. Yappa never
uploads a plaintext thumbnail, asks the server to derive one, or decrypts an
image merely because its message becomes visible. The user must select
`Decrypt local preview`; only then does the client fetch the authenticated
ciphertext, verify and decrypt it through the normal event-bound secretstream
path, and render a local file. The preview lease uses a fresh private temporary
directory, mode `0700` on Unix, and a mode-`0600` file. Closing the modal,
render/decrypt failure, or widget teardown reaches a `finally` cleanup that
recursively removes the lease. The normal save action remains separate and
explicit. Tests prove plaintext/non-image inputs are rejected, Unix modes are
private, cleanup is idempotent and recursive, the encrypted card has no
automatic network image, and the preview action is available only for
encrypted images. Encrypted attachment send/save/preview failures are mapped
to bounded authorization, rate-limit, size, connectivity, storage, and
authentication messages. Tests prove raw server detail, local paths, and
secretstream diagnostics do not reach the UI, while authentication failure
states that no file was opened or saved. Flutter analysis and all 57 client
tests passed on Linux on 2026-07-24. Crash remnants may persist in the
operating-system temporary
directory until its ordinary cleanup/reboot policy runs; Yappa does not claim
secure deletion from SSDs or journaling filesystems.

OpenMLS 0.8.1 and its RustCrypto provider are locked to exact versions and the
RFC mandatory X25519/AES-128-GCM/SHA-256/Ed25519 suite. A local MPL-2.0
source-compatible HPKE 0.6.1 backport is necessary because the published
manifest locks vulnerable, unused libcrux-provider packages and libcrux-sha3
0.0.8. The backport keeps the HPKE implementation unchanged, removes that
unused provider dependency, and selects fixed libcrux-sha3 0.0.10. The
2026-07-24 RustSec run found zero vulnerabilities and one reviewed
non-runtime `cfg(hax)` unmaintained proc-macro warning.

The inactive storage boundary is implemented locally. Channel rows carry an
explicit encryption mode/version, existing rows migrate to legacy version
zero, and dedicated tables store MLS wire data and encrypted attachment/event
routing metadata without plaintext body/name/type fields. SQLite triggers
forbid an E2EE-to-legacy transition or version rollback. Both backend and
client reject plaintext send/edit/upload behavior for a channel once its mode
is E2EE; the preview endpoint requires and verifies a legacy channel before
fetching, and malformed/future unknown modes fail closed in the client.
Automated migration and HTTP tests prove legacy preservation, schema shape,
one-way cutover, downgrade rejection, and plaintext rejection. This is
preparatory storage enforcement, not functioning message E2EE.

The first delivery-service API layer is also implemented locally for one-use
MLS KeyPackages. Registration is restricted to the authenticated active
session device; the existing YUID signs the MLS credential key binding to the
server, account YUID, and device id. The server restricts ciphersuite, wire
size, expiry, duplicate hashes, and unused inventory, then atomically marks a
package claimed by another active device. Banned/revoked targets and replayed
claims fail. Claimed/expired wire bytes are zeroed while a hash tombstone is
retained to prevent one-use replay without accumulating large consumed blobs;
unused and historical per-device inventory is bounded. The server
intentionally does not parse or attest that the opaque
wire package contains the advertised credential; receiving clients must do so
through the OpenMLS bridge. The client now verifies the claimed package's YUID
signature before passing its wire bytes to OpenMLS, and KeyPackage private
  material is durably encrypted before registration. Exact member-set
  verification and durable handshake orchestration are connected through the
  guarded channel runtime.

The second delivery-service layer is implemented locally for opaque ordered
MLS wire messages. Group initialization is deterministic and idempotent.
Proposal and commit submissions are serialized in a SQLite transaction;
commits advance only from the canonical current epoch, so a competing stale
commit fails without consuming a delivery sequence. Welcome messages are
recipient-device scoped in stored history and realtime delivery. Application
event routing stores only a random id, event kind, optional encrypted-event
reference, sender, epoch, and sequence; duplicate or nonexistent references
roll back atomically. Per-device delivered and acknowledged sequence/epoch
cursors are monotonic and cannot acknowledge unseen data. Tests cover these
boundaries. Schema version 2 adds a per-device client operation id: exact
retries return the original row without consuming another sequence/epoch or
duplicating realtime delivery, while substitution under a reused id fails.
This is required for crash-safe commit/Welcome outboxes. Because the server
cannot authenticate the contents of opaque MLS
  wire data, the native OpenMLS client must
validate protocol messages and require the resulting credential set to exactly
match independently authenticated channel membership before it acknowledges
or displays anything.

The Flutter MLS transport layer is implemented locally. It strictly
parses KeyPackages, group state, delivery messages, events, cursors, hashes,
epoch relationships, recipient scoping, and increasing sequence order;
validates deterministic group identity; pins submitted wire bytes/routing
metadata against responses; and exposes recipient-scoped realtime deliveries
to the future coordinator. Malformed or substituted server responses fail
closed before OpenMLS processing. A panic-contained native C ABI now performs
actual OpenMLS parsing and operations and returns both the authenticated sender
credential and leaf signature key. Local MLS state is AES-256-GCM encrypted
under an OS-vault wrapping key, bound to server/device context, atomically
persisted, and Unix permission-restricted. Linux integration tests cover
restart, missing/wrong key, tamper, removal, and sender-key output. The chat
runtime consumes this path only after exact membership is ready. A separate encrypted add-member
outbox now persists the exact commit, Welcome, epochs, recipient, and
independent retry ids before network submission. Its staged coordinator safely
retries a lost commit response, reconciles an already-accepted local epoch
without double-advancing it, rejects a pending local commit on a canonical
server epoch conflict, and clears the outbox only after the recipient-scoped
Welcome is accepted. Tests cover encrypted restart, tamper failure, stage
transition, and lost-response retry.

Schema version 3 adds a durable MLS credential directory populated
transactionally from verified KeyPackage registrations and backfilled from
existing package history. It is limited to eight leaf signing keys per active
device; revoked devices and banned accounts are excluded from reads. Flutter
re-verifies every YUID binding rather than trusting the directory label.
Native bridge ABI version 4 exports the authenticated credential/signature-key
set from each MLS tree. Receiving Welcome/commit mutations compare that entire
set against the verified active directory inside a rollback-capable local
transaction before persistence or acknowledgement. The first replay path
handles the pre-Welcome commit ordering and crash reconciliation; encrypted
application materialization now uses a two-phase encrypted receipt. The
decrypted event and MLS ratchet update are persisted atomically inside native
AES-GCM state; canonical routing/sender/schema validation then precedes an
AES-256-GCM local-history write, receipt clearance, cursor advancement, and
acknowledgement in that order. Restart and tamper tests cover each durable
component. ABI version 4 also persists outgoing canonical plaintext,
ciphertext, epoch, operation id, and group id with the sender ratchet update.
Lost responses and restarts reuse the exact ciphertext; local history is
durable before the receipt clears. The guarded UI projection consumes this
history.

The credential directory now attaches the backend-authorized owner role to
each YUID/device/MLS credential row. Flutter consumes that role only after
verifying the YUID signature and matching the authenticated MLS sender leaf;
the receive coordinator no longer accepts a caller-supplied owner predicate.
This protects client authorization consistency but does not turn a
server-issued role into cryptographically self-certified MLS metadata.

Group authorization now enforces exact coverage of the distinct active,
credentialed device directory. Every leaf must match one credential, duplicate
device leaves fail, and omission of any enrolled device fails closed. This
prevents the delivery service from silently presenting an authorized subset as
the intended channel membership. Enrollment and membership commits must still
be coordinated before activation because a device with no registered MLS
credential is not part of that directory until enrollment completes.

The deterministic membership reconciler closes the add-operation
gap below the UI. The lowest represented owner-device id is the only leader;
non-leaders do not mutate the group. The leader resumes its encrypted outbox,
claims packages only for missing directory devices, revalidates each claimed
credential/leaf key against the current directory, submits crash-safe
commit/Welcome pairs sequentially, then refetches policy and demands exact
final coverage. Missing owner leadership and substituted claims fail closed.
Native integration and adversarial tests cover these boundaries. The channel
runtime invokes it during enrollment and delivery.
Initial MLS channel-state creation is now owner-only and requires that owner's
active device to have a verified credential row. Existing initialized state
remains idempotently readable by members. Authorization integration covers the
member-first denial and owner initialization.
This guard was deployed to Unraid on 2026-07-24. The healthy schema-3 service,
production counts, UID/GID 1000, read-only root, `no-new-privileges`, and
sanitized startup log were reverified after restart.

The initialization API now explicitly reports whether this request allocated
the server state. The inactive channel runtime creates local founder state only
for that fresh allocation, verifies the initializer device and epoch zero, and
persists a protected joined cursor. A 200 response for existing state leaves
the local device waiting for its recipient Welcome, preventing same-id group
divergence after reinstall or state loss. Per-server native state and the add
outbox are serialized across channel runtimes. The lifecycle test covers both
the existing-state refusal and fresh owner creation through exact membership.
The updated API contract was deployed to Unraid on 2026-07-24; the healthy
schema-3 service, production counts, hardened container, and clean startup log
were reverified.

The runtime is now connected to authenticated AppState lifecycle and
realtime MLS notifications only for E2EE version 1 channels. Token rotation
replaces the runtime rather than retaining stale credentials, and logout,
server removal, and disposal close encrypted native state. The UI removes the
plaintext drag-upload path for encrypted channels and shows
waiting-for-Welcome, waiting-for-membership, or ready status. At ready, it
projects authenticated MLS message/edit/delete events and enables encrypted
text composition. Sender account identity and owner status are accepted only
from the YUID-reverified credential directory matched to the authenticated MLS
leaf. Encrypted attachment events send files through secretstream and MLS,
render only locked authenticated metadata, and decrypt to an explicitly chosen
path; no ciphertext URL reaches legacy media preview widgets. Reaction state
is derived from ordered authenticated per-device events and deduplicated by
account. This is still not a completed messaging-E2EE release claim pending
platform validation and independent review.
Receive-side handshake replay allows only authorized, non-duplicate subsets
while sequential adds converge; exact directory coverage is checked before
every application decryption/materialization. Thus intermediate commits can
advance without permitting content under incomplete membership.
The role/directory contract, including account identity for authenticated
message projection, was deployed to Unraid on 2026-07-24 after the complete
backend suite, Flutter analysis, all 51 Flutter tests, and all 17 locked native
OpenMLS tests passed. The restarted container reported healthy and its bounded
startup log remained sanitized.
The credential response now marks active entries instead of deleting
historical public bindings from authenticated responses. Exact MLS membership
uses active entries only, while history projection may authenticate old events
against inactive signed bindings. Revoked devices still cannot claim packages,
receive new membership, or send events. Backend authorization coverage proves
the inactive classification. The contract was deployed to Unraid on
2026-07-24 and health/non-root/read-only/no-new-privileges checks passed.
Schema 3 was deployed to Unraid on 2026-07-24 only after a fresh encrypted
archive passed checksum verification. Post-migration inspection confirmed
expected row preservation, the empty pre-activation credential directory,
healthy service, and unchanged UID/GID 1000 plus `no-new-privileges`.

New text feeds now enter the encrypted boundary at creation: the backend stores
`encryption_mode = 'e2ee'` and `encryption_version = 1` in the same insert that
creates the feed, eliminating a temporary plaintext window while MLS
initializes. Every legacy message, attachment, preview, edit, and delete
endpoint rejects the feed immediately; the database trigger independently
forbids a later downgrade. The creating owner client enrolls its device,
initializes the deterministic MLS group, and reconciles membership before
enabling encrypted composition. Existing feeds and historical rows remain
honestly labeled version `0`. Authorization and schema integration tests cover
the encrypted default, immediate plaintext rejection, and downgrade attempts.
The backend behavior was deployed to Unraid on 2026-07-24 and the hardened
container returned healthy after rebuild. Real multi-device cutover,
reinstallation, and removal validation remain release gates.

Encrypted edit, delete, and reaction routing now requires an existing target
in the same channel. The backend transaction permits edits only by the target
author and deletes only by that author or the server owner. Invalid,
cross-channel, or unauthorized mutations roll back without advancing the
canonical sequence. Because routing labels remain untrusted metadata, clients
must also require the decrypted authenticated event to match its label and
target.
Mutation targets are also restricted to materialized roots: edits may target
only message events, while deletes and reactions may target only message or
attachment events. Both the backend transaction and encrypted local event
store reject mutations of edits/deletes/reactions. This prevents an
authenticated member from creating an accepted but unprojectable nested
mutation that would fail-close history for every client. The authorization
regression suite covers the nested-event rejection, and the backend protection
was deployed to Unraid on 2026-07-24 with health and container isolation
reverified.

An inactive ciphertext-only attachment transport is implemented locally.
Uploads are accepted only from an active authenticated device into an E2EE
version 1 text channel. The backend recomputes the complete ciphertext SHA-256,
enforces ciphertext size, shared storage quota, and retention, stores only the
secretstream header/chunk count/ciphertext metadata, and serves bytes through
an authenticated rate-limited endpoint with a generic filename/type.
Attachment ids bind transactionally to one encrypted application event owned
by the same account, device, and channel; reuse, expiry, missing ids, and
cross-device binding fail without consuming a delivery sequence.
Exact retry of a client-generated encrypted attachment id returns the original
row only when ciphertext size/digest, secretstream header, chunk count,
channel, user, and device all match. The duplicate temporary upload is
discarded; substitution receives HTTP 409. The backend security suite covers
exact retry and conflict. This was deployed to Unraid on 2026-07-24 and
health, schema/data preservation, and non-root/no-new-privileges isolation
were verified.

The standalone client secretstream primitive is implemented locally against
libsodium. It generates a fresh key, streams 64 KiB chunks, authenticates
canonical server/channel/event/attachment identity for every chunk, requires
the final tag and complete ciphertext SHA-256, zeroizes native state/key
buffers, refuses overwrite, and never renames partial plaintext into place.
Linux tests prove empty and multi-chunk round trips and fail-closed tampering,
truncation, and context substitution. Ciphertext upload/download uses the
verified LAN-aware transport, pins server metadata, bounds streamed download
bytes to caller-supplied expected metadata, verifies the full digest, and only
then renames the partial file. Those expected values must come from a verified
MLS payload before activation. The inactive attachment coordinator now stages
the key, name, type, plaintext size, and authenticated object metadata inside
the exact outgoing MLS operation before upload. It retains ciphertext and the
MLS receipt across a lost response and clears them only after encrypted local
materialization. Downloads accept metadata only from a verified materialized
MLS event, pin the server object, decrypt with canonical event-bound associated
data, and remove temporary ciphertext on every outcome. Linux integration
covers upload-response loss, restart retry, event materialization,
authenticated download, and plaintext round trip. This is not cryptographic
completion: Windows runtime validation and complete UI failure behavior remain
required. Windows packaging now pins and
checksum-verifies the official libsodium `1.0.20` MSVC archive and fails the
artifact job if either the sodium or MLS runtime DLL is missing.
The hosted Windows job also launches the packaged executable and requires it
to remain alive for eight seconds, catching immediate loader/runtime failures
before upload. Native Rust diagnostics remap the Windows builder account,
Flutter debug symbols stay outside the distributable directory, and a binary
scan rejects builder-home, retired `sslip.io`, Codex-key-label, and private-key
markers before upload. An exact-candidate hosted artifact run now passes this
packaging and loader gate. Real Windows connection, credential-vault, and media
validation remain required.
The first current hosted run exposed MSVC 14.51 error `STL1011` in
`webview_all_windows` 1.2.1 because that dependency still opts into legacy
`/await`. The compatibility definition recommended by the STL diagnostic is
applied only to `webview_all_windows_plugin`; Yappa and every other dependency
retain normal deprecation enforcement. The exact-candidate hosted rerun
compiled and packaged successfully with that scoped compatibility fix.

The design must cover:

- Per-device identity keys and verification.
- Group/channel key creation and rotation.
- Forward secrecy and post-compromise recovery goals.
- Adding and removing members.
- Offline delivery and history synchronization.
- Message edits, deletions, replies, reactions, previews, and search.
- Attachment streaming encryption with authenticated metadata.
- Encrypted thumbnails or the explicit privacy tradeoff if previews leak.
- Backup/export and recovery behavior.
- What metadata the server necessarily retains.

Servers should store ciphertext and the minimum routing metadata. Link previews
must not cause the server to fetch private URLs or learn encrypted message
content. The current plaintext-message preview service now resolves each
hostname before connecting, pins the approved public address for the request,
revalidates every redirect, rejects URL credentials and non-public targets,
and bounds fetch time and response size. Authorization tests cover loopback,
localhost, IPv6 loopback, and the common link-local cloud metadata endpoint.
Preview metadata remains a privacy disclosure to the linked website from the
self-hosted server. Allowlisted YouTube, TikTok, and Vimeo embeds are loaded by
the client only after an explicit Play action; arbitrary sites are not embedded,
camera/microphone permission is denied, and external navigation is blocked.
Encrypted messages will need an explicit preview privacy design because
server-side fetching would otherwise reveal their links.
The pinned lookup supports both Node's single-address and `all` callback
contracts; this fixed a Node 22 regression without reopening DNS rebinding or
private-address access. Public sites that deny metadata fetching now receive a
validated compact hostname/favicon fallback, while private, malformed, or
unresolvable targets still fail closed.
The client removes failed preview requests from its in-memory cache so a
temporary backend or network failure can recover without restarting Yappa.

Acceptance requires published protocol documentation, test vectors, migration
tests, tamper detection, and independent review.

## Future Calendar and Shared-Music Security Gates

The integrated server calendar and shared music space are intended for the
first full public release, but their detailed designs are not yet approved.
They extend Yappa's security and privacy surface and must not be treated as
presentation-only client features.

Calendar implementation must define:

- Authorization for creating, editing, cancelling, deleting, inviting,
  moderating, and viewing events and attendee lists.
- The privacy boundary for event descriptions, locations, links, attendance,
  reminders, and related channel or voice-deck references.
- Whether any event content is end-to-end encrypted; no calendar surface may
  inherit an E2EE claim merely because it is linked from encrypted chat.
- Safe recurrence/time-zone processing, input and URL handling, notification
  delivery, rate limits, audit requirements, retention, deletion, export, and
  backup/restore behavior.
- Cross-device serialization, realtime authorization, migrations, downgrade
  behavior, and negative tests for unrelated, removed, banned, and
  insufficiently privileged accounts.

Shared music implementation must define:

- A provider-by-provider legal and technical playback model based on current
  official APIs, SDKs, licenses, embedding requirements, and terms. Yappa must
  not assume that metadata access, a linked subscription, or an embeddable
  video authorizes server-side downloading or rebroadcasting.
- OAuth authorization with minimum scopes, platform credential-vault storage,
  server-side storage only when unavoidable, encrypted transport, token
  rotation and revocation, unlinking, CSRF/state protection, redirect
  validation, and strict exclusion of provider tokens from logs, telemetry,
  databases not designed for them, and release artifacts.
- Linked-provider identity, imported library data, and reusable rich-presence
  activity are separate consent surfaces. Linking an account must not
  automatically publish listening activity, and presence visibility must be
  revocable without unlinking the provider.
- Catalog matching across providers must treat metadata as untrusted until the
  user-visible title, artist, duration, explicit-content state, and playback
  source are resolved. Provider linking never authorizes extraction, proxying,
  or redistribution through an unrelated service.
- What listening activity, provider identity, playback state, search queries,
  queue history, votes, and external requests are visible to the server,
  Yappa members, and each provider.
- Authorization and abuse controls for queue changes, vote skip, moderation,
  provider lookup, embeds, metadata/artwork fetching, and realtime playback
  control. External media URLs and provider responses require SSRF, redirect,
  content-size/type, and untrusted-markup defenses.
- Fail-closed handling for expired or substituted credentials and provider
  responses, plus cross-account, cross-server, replay, reconnect, and
  synchronization tests.

Both features require explicit threat-model review, secure storage and
migration designs, automated negative tests, real multi-client validation,
production deployment verification, accurate user disclosures, and
documentation before they can satisfy the full-public-release gate.

### Message-Thread Security Gate

Threads are part of their parent text feed's security domain, not independent
channels. Before release:

- Every thread operation must reauthorize current parent-feed membership and
  permissions. Stored thread membership or knowledge of a thread/root ID is
  never sufficient access.
- Threads inherit the parent feed's E2EE version without a downgrade option.
  Encrypted replies must authenticate the server, channel, root message,
  thread, sender device, message identity, and MLS epoch so ciphertext cannot
  be replayed or transplanted across those contexts.
- Realtime events, notifications, unread counters, previews, search indexes,
  link targets, moderation records, logs, and push payloads must not disclose
  encrypted reply text or private thread participation to unauthorized users.
- Root deletion, reply deletion, membership removal, bans, channel deletion,
  retention, backups, and restore must have explicit fail-closed semantics;
  orphaned records must not bypass authorization or become globally
  addressable.
- Negative tests must cover unrelated accounts, removed and banned members,
  stale sockets, guessed IDs, cross-server/channel/thread substitution,
  replay, duplicate offline sends, root deletion, epoch rotation, and
  legacy/plaintext downgrade attempts.

### Durable-Chat Security Gate

The public product contract is indefinite message and attachment retention
until explicit authorized deletion. Efficiency work may compact derived caches
and indexes, but must not silently remove the sole durable ciphertext,
attachment, authenticated mutation, or cryptographic recovery material.

`PERSISTENT_CHAT.md` defines the storage and verification contract. Security
completion additionally requires:

- Current membership authorization on every history page, cursor, attachment,
  mutation, read-marker, search, and device-history-transfer request.
- Opaque server storage for E2EE content and device-to-device encrypted history
  recovery; the server must not hold a universal key that can impersonate a
  device or decrypt retained chat.
- Cursor integrity, idempotent operations, replay/rollback/substitution
  rejection, bounded requests, storage quotas/headroom checks, and explicit
  fail-closed storage-full behavior.
- Backup confidentiality and integrity, separate-target restore verification,
  authenticated attachment hashes, and proof that an authorized client can
  decrypt restored history.
- Honest client states for incomplete sync, pre-membership history, explicit
  deletion, missing attachments, key loss, and failed recovery. Truncation
  must not be presented as a complete conversation.

Verified plaintext-history increment, 2026-07-28:

- Backward history cursors are HMAC-authenticated with a domain-separated
  history-cursor context and the deployment's protected attachment-signing
  secret. The payload binds cursor version, persistent server identity,
  channel, exclusive message boundary, backward direction, and viewer account.
- Active session and ban authorization runs before cursor processing on every
  request. A cursor copied to another account or altered in transit is rejected
  without reading a history page.
- The legacy plaintext endpoint resolves the current channel and rejects
  non-text or E2EE channels, closing the post-cutover legacy-row disclosure
  path. Limits outside 1–100 and malformed cursors fail closed.
- Automated integration coverage exercises multi-page ordering, no overlap,
  viewer substitution, tampering, invalid bounds, unauthenticated access, and
  E2EE cutover rejection. A schema test asserts the composite history index
  and its SQLite query plan.

This increment does not complete durable-chat security. Forward catch-up,
channel-specific membership if private channel ACLs are introduced, durable
attachment scale/restore evidence, storage exhaustion, encrypted
device-history recovery,
large-scale behavior, and destructive restore proof remain required.

Verified attachment-retention increment, 2026-07-28:

- Schema version 4 makes indefinite retention the only accepted public-release
  policy. Fresh settings use `0`; migration resets existing settings and
  removes `expires_at` from every active ordinary and encrypted attachment.
  Explicit deletion markers are not changed or resurrected.
- The owner settings API rejects any nonzero timed-retention value. This avoids
  presenting a hidden API-only deletion policy as an informed server choice;
  a future retention feature must be prospective, visible, authorized, and
  independently tested before this restriction changes.
- A version-3 migration fixture proves an active attachment row survives with
  expiry removed. Authorization coverage proves the default and rejection
  boundary, and encrypted-upload coverage proves new ciphertext has no expiry.

Schema version 4 is not deployed to Unraid because approved SSH access remains
unavailable. A verified encrypted pre-upgrade backup and post-migration
attachment/file/integrity checks are mandatory before production activation.

Verified durable-storage headroom increment, 2026-07-28:

- Plaintext messages, MLS deliveries, and ordinary/encrypted uploads pass an
  immediate filesystem-headroom gate. Validated deployment thresholds default
  to a 2 GiB warning and a 512 MiB critical reserve; warning must be strictly
  greater than critical or startup fails closed.
- Capacity inspection failure and critical headroom return retryable HTTP 507
  before mutation. The guard reserves declared request bytes, rechecks after
  multipart persistence, and removes uploaded bytes if metadata cannot commit.
  SQLite-full, SQLite write-I/O, and filesystem-full races map to the same
  bounded public error rather than exposing paths or database details.
- Owner-only status exposes state, byte counts, and thresholds but no content
  or paths. Other members are forbidden. Unit tests cover size accounting and
  every state; a disposable real backend proves critical status, HTTP 507,
  retry guidance, and zero inserted message rows.
- Server Admin renders the owner-only state, thresholds, database and
  attachment categories, and explicit backup-monitoring availability without
  receiving paths or content. Client parsing and Flutter analysis pass.

Actual constrained-filesystem exhaustion/recovery, simultaneous boundary
writes, portable backup-root monitoring, and production deployment remain
required before this gate is complete.

Verified destructive durable-chat restore increment, 2026-07-28:

- The distributable install manifest now tracks the backend's current schema,
  including attachment retention and history-recovery device keys. Restore and
  upgrade guards therefore accept current backups and reject the next unknown
  schema rather than treating current data as future data.
- A disposable current-schema installation writes 5,000 messages and 128 linked,
  non-expiring 64-KiB attachments, runs the production encrypted backup script,
  and then deletes the entire source installation before fresh restore.
- The restored database passes SQLite quick and foreign-key checks, retains
  exact first/last message sentinels and all active links, and all 128 files
  reproduce their independently recorded SHA-256 digests.

This is deterministic destructive-restore evidence, not a substitute for a
production backup drill or authenticated post-restore client download test.

Encrypted-history recovery design decision, 2026-07-28:

- Public-release recovery will be explicit and same-account
  device-assisted. It does not alter MLS history secrecy and introduces no
  server, administrator, or universal recovery key.
- Every device uses a dedicated X25519 recovery key independently authorized
  by its YUID Ed25519 identity. Signed manifests and per-chunk authenticated
  encryption bind account, server, channel, source/destination devices,
  sequence range, chunk order, and ciphertext digests.
- The server may retain only bounded opaque resumable chunks. A destination
  exposes no partial projection and acknowledges consumption only after
  signature/key-binding checks, complete authenticated decryption, event-rule
  revalidation, rollback-safe merge, and durable encrypted local storage.

The complete contract and negative-test matrix are in
`ENCRYPTED_HISTORY_RECOVERY.md`. Schema 5 implements the dedicated
recovery-key directory: registration verifies the YUID signature for the
authenticated active device, exact retry is idempotent, conflicting rebinding
fails closed, and directory reads expose only active devices belonging to the
same account. The client stores a separate per-server/device X25519 private key
through OS-protected storage, pins registration, verifies every directory
signature with the local YUID key, rejects duplicate/substituted entries, and
requires its own exact key.

Schema 6 implements the opaque transfer relay. Only an authenticated active
same-account source device can create, upload, finalize, or cancel its
unfinished transfer; only the exact active destination can list, download, or
consume a ready transfer. Creation and chunk writes have exact idempotent
retries and reject conflicting reuse. Finalization verifies declared chunk
count, byte total, ordered hashes, the final manifest hash, and its YUID
signature before publication. Transfer/chunk/manifest sizes, active-transfer
cardinality, and unfinished/ready lifetimes are bounded; expiry, cancellation,
and consumption remove stored chunks. The schema contains routing metadata and
opaque bytes, never recovered plaintext or recovery private keys.

The client transfer cryptor uses a fresh ephemeral X25519 key, HKDF-SHA-256,
and independently nonced AES-256-GCM chunks. Its canonical immutable header
hash is the chunk associated-data root; the final YUID-signed manifest binds
that header and every ordered ciphertext size and SHA-256 digest without a
circular hash dependency. Automated round trips cover multi-chunk data, size
limits, ciphertext tampering, and channel substitution. Client API
transport now pins the full returned transfer identity and lifecycle, validates
binary upload receipts, checks downloaded bytes against signed-manifest size
and digest metadata, resumes by safely replaying exact chunks, and exposes
consumption only as a separate post-merge acknowledgement. Canonical event
export and the end-to-end coordinator are also implemented: destination/device
context is pinned again, every sender credential and signature key must match
exactly one retained YUID-authorized MLS credential, edit/delete ownership is
rechecked, conflicting overlap and transfer-id replay fail closed, and the
encrypted store commits events plus the manifest receipt in one restart-safe
write before relay consumption. Recovery UI, the remaining adversarial/scale
matrix, real-device evidence, and a release claim remain incomplete.

Live recovery UI increment, 2026-07-28:

- AppState creates a recovery controller only for a ready E2EE channel and
  obtains candidate keys through the fully verified same-account directory.
- Sharing requires explicit selection and confirmation of the exact
  destination device and signed application-event range. Receiving requires a
  second explicit confirmation.
- Finalization emits only routing identifiers to sockets belonging to the
  exact authenticated destination device. The client refreshes authoritative
  transfer data rather than trusting the notification as recovery authority.
- UI failures use bounded text and preserve existing history. Restart-durable
  source ciphertext/outbox state and the remaining adversarial/real-device
  evidence are still required.
- Flutter analysis, all 74 client tests, and the complete backend
  security/storage/backup/deployment/recovery suite pass with this increment.

Restart-durable recovery upload increment, 2026-07-28:

- The source persists the exact context, YUID-signed manifest, and ciphertext
  chunks in an independently keyed AES-256-GCM outbox before contacting the
  relay. Its key is held through protected storage and is scoped to the exact
  server, source device, and channel.
- Pending-file promotion is authenticated and restart-safe. Resume rechecks
  the current account, source recovery key, and active destination directory
  binding before replaying the original transfer id and bytes.
- The outbox remains after a failed/lost upload response and is removed only
  after the relay confirms ready. Tampering and missing-key states fail closed.
  Focused crash/restart evidence and the full 76-test client suite pass.
- A failed source upload offers a confirmed stop action. The client removes
  its protected retry only after the authenticated relay confirms cancellation
  or returns the exact not-found result proving that transfer never reached
  it. Network errors and every other ambiguous response preserve the retry.
  Flutter analysis and all 77 client tests pass, including controller and
  confirmation-widget evidence. The remaining adversarial/real-device matrix
  remains open.
- Recovery adversarial coverage now also rejects a wrong destination private
  key, wrong authorized YUID signing key, reordered or truncated chunks,
  altered manifest signatures, conflicting transfer-id replay, and
  non-identical overlap with already durable local history. Rejected overlap
  and replay attempts leave events and receipts unchanged. Flutter analysis
  and all 78 client tests pass. Revocation/ban lifecycle, representative
  ceiling-scale behavior, and real-device evidence remain open.
- The recovery size contract now matches the live storage path. The prior
  256 MiB relay allowance exceeded both the 64 MiB encrypted event-store
  ceiling and the 96 MiB protected-outbox envelope. Cryptography, client
  transfer/outbox validation, and the backend now enforce 64 MiB of canonical
  history, no more than 257 chunks, and no more than 67,116,060 ciphertext
  bytes. Client and server boundary rejections are automated. Flutter
  analysis, all 79 client tests, and the complete backend
  security/storage/backup/deployment/recovery suite pass.
- A Linux opt-in scale gate exercises a 60 MiB canonical payload through
  sealing, protected persistence, restart/reopen, authentication, and
  decryption. Compact authenticated binary-v2 outbox storage reduced measured
  disk use from 83,935,683 to 62,952,989 bytes and peak test-process RSS from
  1,874,452 to 769,464 KiB versus the prior JSON/base64 representation.
  Existing protected v1 outboxes remain readable, while malformed or tampered
  storage fails closed. Flutter analysis, all 80 routine client tests, and the
  opt-in scale gate pass. The backend correction is not yet deployed to Unraid
  because approved deployment access remains unavailable.

Sparse MLS-sequence correction, 2026-07-28:

- Recovery ranges no longer incorrectly require one application event for
  every MLS delivery sequence. Commits and Welcomes legitimately create gaps.
- The signed context and relay now require `1 <= eventCount <= range width`.
  Canonical records must contain exactly `eventCount` strictly increasing
  application events, match the declared first/last application boundaries,
  and stay inside the signed range. Focused client cryptography/store tests and
  the backend authorization integration test cover a sparse range.

Verified plaintext reconnect increment, 2026-07-28:

- History cursors authenticate backward or forward direction in addition to
  server, channel, boundary message, viewer, and protocol version. A cursor
  cannot be transplanted across account/channel/server or have its direction
  changed without failing authentication.
- Forward reads use the composite `(channel_id, id)` index, return ascending
  bounded pages, preserve an empty resume boundary, and issue separate
  continuation/backward/newest cursors. Every page re-runs active session/ban
  authorization and the plaintext/E2EE channel boundary.
- The client persists opaque cursors, detects repeated continuations, checks
  response direction and shape, deduplicates catch-up, and bounds the retained
  window. Invalid persisted cursors fail closed to a newly authenticated
  newest-page refresh rather than being trusted or numerically reconstructed.
- Integration tests cover multiple missed pages, ordering, no overlap, empty
  catch-up, viewer substitution, tampering, E2EE cutover, and both backward and
  forward indexed query plans.

Interactive bidirectional window sliding, viewport continuity, long-offline
scale, concurrent catch-up/realtime races, and production deployment remain.

Verified plaintext bounded-window increment, 2026-07-28:

- An authenticated cursor-anchor endpoint mints an opaque before/after cursor
  only after resolving the retained message inside the requested plaintext
  channel. Invalid directions, missing boundaries, non-text channels, and
  post-E2EE-cutover plaintext access fail closed.
- Anchor cursors retain the existing HMAC binding to persistent server,
  channel, direction, message, viewer, and protocol version. The client
  validates the echoed direction and message boundary and never derives cursor
  contents from a numeric message identifier.
- The client can evict the opposite edge of its 1,000-message working window
  and persist the exact authenticated return boundary. New realtime rows do
  not silently alter an older visible window; reconnect catch-up advances its
  durable resume checkpoint until the user returns toward current history.

Focused anchor, tamper/substitution, direction, boundary, and client parsing
coverage is present. Bidirectional 100-row replacement widget coverage proves
the retained visible message boundary remains within one logical pixel.
Scale/race evidence and production deployment remain required.

### Cross-Platform Server Deployment Gate

`SERVER_PORTABILITY.md` defines the supported-host and parity contract. Windows
and Linux packages must run the same backend, migrations, protocols, and
security/conformance suite. Platform wrappers may not omit TLS, TURN, LAN
identity verification, backup encryption, rate limits, or other controls.

Before either platform is supported:

- The client “Create server” flow must use a signed machine-readable release
  manifest and checksum-pinned installers. Generated remote commands must not
  contain passwords, private keys, server secrets, provider tokens, or client
  sessions, and the client must independently verify the resulting TLS/server
  identity before trusting it.
- Local hosting must use protected per-server data/secrets, bind internal
  services safely, prevent duplicate supervisors, expose firewall/public-
  reachability choices, and stop or recover deterministically across crashes,
  sleep, network changes, upgrades, and OS shutdown.
- Tray/background operation and sign-in autostart require explicit informed
  opt-in, an OS-visible registration, least privilege, a clear running
  indicator, and complete removal without deleting server data by default.
- Yappa must not accept or retain remote root/administrator passwords. Any
  future automated SSH deployment requires verified host keys, scoped
  credentials, previewed actions, and post-operation credential cleanup.
- Installers and upgrades must pin/checksum inputs, protect secret files with
  OS-appropriate permissions or ACLs, avoid command-line secret exposure, and
  fail closed on missing prerequisites or occupied/public internal ports.
- Container, native-service, firewall, reverse-proxy, filesystem, symlink/path,
  process-user, and service-restart boundaries require platform-specific
  negative tests. Windows path and ACL behavior must not be inferred from
  Linux mode-bit tests.
- A cross-platform LAN discovery implementation must preserve the signed
  server-identity proof. Docker Desktop host networking is not accepted as a
  parity assumption.
- Clean install, upgrade, rollback, backup, destructive isolated restore,
  schema verification, HTTPS/WSS, LiveKit, forced TURN, and restart persistence
  must pass on every Tier-1 host.
- Signed artifacts, checksums, SBOM/provenance, exact support versions, and
  unsupported/best-effort combinations must be published from the tagged
  release.

As of 2026-07-28, the first machine-readable server installation contract is
implemented in `server/install-manifest.json` and its versioned JSON Schema.
The backend security suite enforces centralized version parity, exact unique
Tier-1 target identifiers, release-validation-before-support, HTTPS/checksum/
signature requirements for published artifacts, private raw ports, required
capabilities, lifecycle parity, and fail-closed client policy. The current
development release truthfully publishes no artifacts or install commands and
permits neither public support claims nor client supervision.

The Linux front end uses strict shell failure behavior and a private umask,
validates the manifest, checks architecture/resources and required tools, and
requires the explicit `--local-source` development path before initialization.
It never pipes downloaded content into a shell. The PowerShell front end uses
strict/error-stop behavior, reads the same manifest, requests no administrator
credential, and now dispatches the implemented canonical lifecycle into an
explicit WSL2 distribution. It uses discrete process arguments rather than
interpolated shell commands, converts only bundle/backup paths, and rejects
durable installs or preserved state on `/mnt` where Linux permission
guarantees can differ. Exact-head hosted run `30414007960` passed parser,
manifest, injection-shaped path, distribution, and negative path contracts on
commit `dd322a7`. Windows support remains disabled until a real WSL2 workload
and native service/firewall negative tests and conformance evidence exist.

The canonical development server bundle is now built from an explicit runtime
allowlist with a private umask, normalized ownership/order/timestamps/gzip
headers, full source-commit metadata, overwrite refusal, secret/generated-state
screening, and a SHA-256 sidecar. Automated coverage requires byte-identical
archives from identical inputs, validates the digest and metadata, rejects
tests/dependencies/generated secrets/data, and executes the extracted
non-mutating installer. Security CI builds and inspects it after the backend
suite. This checksum is not presented as authenticity: detached signing, SBOM,
trusted provenance, tagged publication, and manifest activation remain release
gates.

The hosted Linux host-contract workflow uses exact digest-pinned x86-64
containers for Ubuntu 24.04, Debian 13, Fedora 44, and Rocky Linux 10. It binds
each observed OS identity to the matching unpublished manifest target and
requires shell/preflight/bundle/checksum/fresh-install/private-mode/firewall
plan/stopped-recovery behavior on all four. The contract explicitly rejects
promotion of public support or install-command flags and labels the result as
packaging/lifecycle evidence, not Docker, systemd, firewall, TLS, TURN, or
media conformance. Exact-head run `30411894908` passed all four non-optional
jobs on commit `77397cb`; the manifest records only
`verified-development`, while public support and install commands remain
disabled.

The isolated Linux runtime contract uses a read-only repository mount and a
disposable privileged container because real systemd, UFW, and firewalld
mutation require cgroup and network-administration capabilities. It verifies
systemd is PID 1, exercises a real unprivileged user manager, activates and
removes the generated Yappa service/timer, and applies/removes owned firewall
rules on all four Tier-1 Linux distributions. Container deletion is mandatory
cleanup. Local execution exposed and corrected two production defects that
mocked tests missed: quoted `WorkingDirectory=` values broke installations in
paths containing spaces, and firewalld requires hyphenated port ranges rather
than UFW's colon syntax. Registration now verifies that both units are
actually active before reporting success. Hosted runtime evidence is bounded:
exact-head run `30413430381` passed all four jobs on commit `c5522f9`. Ubuntu
and Debian proved the complete user-service plus UFW contract; Fedora and
Rocky proved real firewalld mutation/removal while reporting the hosted
limitation below. Isolated privilege is not evidence of a safe bare-metal
firewall policy or full Docker/media operation.

GitHub's container host permits the Ubuntu/Debian `user@.service` wrapper but
blocks Fedora/Rocky's wrapper at PAM setup with systemd status `224/PAM`.
The contract does not alter or bypass authentication policy and does not turn
that result into user-service evidence. Those jobs continue only for mandatory
real firewalld mutation/removal and print that user-service runtime is
unclaimed; any other manager failure remains fatal. Local Fedora/Rocky
execution still passes the complete real user-manager contract.
The same exact head passed the backend security suite in run `30413430380`.

The canonical full-stack contract now exercises a checksum-installed bundle
and the actual Node, Caddy, LiveKit, and discovery workload on Ubuntu 24.04.
It requires operational verification, intentional-stop suppression, identity
persistence across restart, and successful bounded recovery after forcibly
stopping the backend. Exact-head run `30415529328` passed on commit `d5d920c`. Real
execution exposed and corrected four security/reliability defects: a
hard-coded UID/GID `1000`, owner-only extraction modes on non-secret runtime
assets, an unusable LiveKit TURN/config permission boundary, and disagreement
between fresh server-ID generation and the signed verifier. Node and discovery
now run as the unprivileged installation owner. LiveKit's UDP-443 exception is
explicit root with all capabilities dropped except `NET_BIND_SERVICE`, a
read-only root, `no-new-privileges`, no writable host-data mount, and only the
installation group supplemented to read mode-`0640` `livekit.yaml` beneath the
mode-`0700` install root. Fresh identities use 128-bit `srv_` IDs; immutable
legacy 64-bit `node_` identities remain accepted by cryptographic verification.
This does not prove outside-network reachability, forced TURN media, a real
call, bare-metal firewall policy, reboot, or sleep/network transitions.

Release evidence generation now binds each desktop archive and canonical
server bundle to a SHA-256, exact version/source commit, and SPDX 2.3 document
covering locked npm, Cargo, and hosted Pub dependencies. It refuses overwrite
and labels signature/provenance state explicitly. Pull-request run
`30415903314` passed deterministic generation and adversarial guard checks on
commit `578b0a2`. Trusted manual run `30415925969` then generated a real
GitHub/Sigstore build-provenance attestation for the server bundle; the
downloaded artifact passed independent `gh attestation verify --repo
CtrlAltForgot/Yappa`. OIDC and attestation permissions are scoped to build
jobs, and the official action is exact-commit pinned. The tag gate is
read-only and rejects development/non-exact/unpublished state. This provenance
does not substitute for Windows/Apple/Linux platform signing, notarization,
detached server/installer signatures, binary dependency/license review, final
release-asset verification, or publication authorization. The complete
contract and remaining credential boundaries are in `RELEASE_ENGINEERING.md`.

Local development bundle installation now requires a caller-supplied full
lowercase SHA-256, one versioned archive root matching embedded metadata, a
brand-new absolute destination, and a private installed root. Extraction occurs
in a private temporary directory and rejects traversal, symbolic links and
special files before copying. Wrong-digest, existing-destination, and
checksum-valid malicious-symlink fixtures fail without creating the requested
install root. Normal installation runs preflight before startup; isolated CI
may use `--no-start`, which clearly reports that runtime health is unverified.
Remote download remains disabled because a user-supplied checksum is integrity,
not publisher authenticity.

Operational Linux install verification now fails closed on symlinked or
mis-permissioned configuration/data, a database outside the data root, wrong
schema, SQLite corruption, missing/multiple/mis-permissioned identities,
unwritable storage, missing services, unhealthy backend, invalid Ed25519 proof,
routed identity substitution, failed TLS/API access, failed Socket.IO upgrade,
or dead LiveKit routing. The identity helper bounds requests, validates the
origin shape, generates a fresh nonce, checks canonical server id/key/signature
encodings, and verifies the domain-separated Ed25519 proof. Tests cover the
complete LAN verification flow plus tampered proof and schema mismatch.
Host-local success explicitly excludes external reachability, forced TURN, and
real media; those still require separate external/native evidence.
The read-only Unraid SSH attempt on 2026-07-28 was denied because no approved
key was available, so the verifier has not been copied into or run against
production. No password or long-lived credential was requested.

### Cross-Server Identity and Direct-Message Gate

The existing YUID is derived from the first 20 base64url characters of a
SHA-256 digest of an Ed25519 public key. Authentication proofs are signed over
the destination server identity, normalized username, and a single-use nonce,
and the server derives the claimed YUID from the verified full key. This is a
real anti-spoofing foundation for current server login and device bindings; it
does not by itself establish a safe global directory, recovery authority, or
DM protocol.

Before public DMs, Yappa must additionally define and verify:

- Full-public-key comparison at every security boundary. The shortened YUID is
  a display/discovery handle, not sufficient cryptographic identity evidence.
- Domain-separated signed identity documents, protocol downgrade resistance,
  canonical encoding, key-purpose separation, replay rejection, and test
  vectors shared by client and server implementations.
- Contact verification and conspicuous key-change handling, including recovery
  and new-device events. No server may silently replace a known contact key.
- Multi-device authorization, device removal, lost-device response, encrypted
  identity backup, rotation, and post-compromise recovery without a universal
  server-held impersonation key.
- Private, abuse-resistant discovery that prevents YUID enumeration, server
  membership correlation, unsolicited-message flooding, and block evasion.
- An explicit DM trust and routing model plus reviewed E2EE session design,
  metadata analysis, attachment encryption, offline queues, deletion and
  retention semantics, reporting tradeoffs, and compromised-relay tests.
- Independent protocol review and real cross-server, multi-device validation
  covering interception, substitution, replay, rollback, reinstall, recovery,
  device removal, server outage, and malicious-server scenarios.

## Priority 5: At-Rest, Supply-Chain, and Operational Security

- Define encrypted backup and filesystem guidance for self-hosters.
- The server bundle now includes an `age`-based encrypted backup command. It
  pauses the backend for SQLite consistency, streams `.env` and `data/`
  directly into authenticated passphrase encryption, refuses overwrite,
  removes partial outputs, and resumes the backend through an error trap.
  Deployment documentation defines the minimal recovery set and an
  access-controlled restore procedure. An isolated orchestration integration
  test covers success, overwrite refusal, archive contents and permissions,
  encryption failure cleanup, and backend restart behavior.
- A bundled `verify-yappa-backup.sh` decrypts directly into a private
  temporary directory without writing a plaintext archive, requires `.env`,
  exactly one database, and exactly one persistent server identity, runs
  SQLite `quick_check`, prints only schema/user/message counts, and removes the
  restored copy on every exit. Its fake-age integration test covers a complete
  backup-to-restore round trip and cleanup. The verifier was deployed to
  Unraid on 2026-07-24 with mode `0700`. Checksum-verified upstream `age`
  v1.3.1 was installed persistently, then a real passphrase-encrypted
  production backup and isolated restore verification passed. The verifier
  confirmed SQLite integrity, schema `3`, one user, ten legacy messages, and
  the required server identity/configuration before removing the restored
  copy. The encrypted file is mode `0600`, no partial output remained, and the
  backend automatically resumed healthy with its hardened runtime settings.
- The Linux `restore` lifecycle now restores into a new installation without
  writing a plaintext archive or merging with existing state. It first
  installs a checksum-pinned local runtime into private staging, then requires
  the backup's configured database to remain inside `data/`, rejects links and
  special files, verifies SQLite integrity and supported schema, and requires
  exactly one persistent server identity. Only a fully assembled runtime is
  renamed into the requested fresh destination, and it remains stopped for
  configuration review. Negative integration tests cover checksum failure,
  overwrite attempts, future schemas, escaped `DB_PATH`, malicious symlinks,
  and cleanup. Artifact authenticity, Windows restore, and production
  deployment verification remain open.
- Linux upgrade and rollback now fail closed around whole-installation
  snapshots rather than running an older binary against a migrated database.
  Upgrade requires a healthy current server, a newly encrypted and
  independently verified recovery point, a checksum-pinned candidate, stopped
  state copying, safe `DB_PATH`, supported schema, SQLite integrity, and
  successful candidate startup plus operational verification. Failure restores
  and verifies the previous installation and retains the candidate. Explicit
  rollback first encrypts and verifies the newer state and retains it after
  activating the old snapshot, preventing silent deletion of post-upgrade
  activity. Tests cover success, state continuity, deliberate rollback, and
  automatic recovery from failed candidate verification. Bundle signatures,
  Windows parity, and real-host upgrade evidence remain required.
- Linux uninstall now preserves state by default and requires two independent
  recovery locations: a newly encrypted backup that passes isolated
  verification and a fresh private directory containing `.env` plus `data/`.
  It verifies current health, refuses overwrite and unresolved lifecycle
  snapshots, stops the stack, places the preserved copy, and only then removes
  runtime files. A state-placement failure restores and restarts the original
  installation. Tests confirm permissions, attachment/state continuity,
  refusal paths, and cleanup. Service/firewall registration removal and
  Windows ACL parity remain open.
- Linux sign-in autostart is now an explicit, reversible, least-privilege
  per-user systemd registration. It refuses root, invokes no `sudo`, `pkexec`,
  or `loginctl`, stores a deterministic mode-`0600` unit, and uses only
  `systemctl --user`. Startup must pass the full operational verifier;
  disabling the unit stops the stack, removal preserves data, and uninstall
  refuses active registration. Unit hardening enables `NoNewPrivileges`,
  `PrivateTmp`, and a private umask without embedding configuration or
  credentials. Every container has `restart: unless-stopped` for exited-process
  and Docker-daemon recovery. The registration also installs a hardened
  one-minute recovery timer. Recovery reads private desired state and never
  restarts an intentionally stopped server, takes a nonblocking lock, performs
  only one Compose recovery, requires bounded service/backend checks plus the
  full operational verifier, and enters a 15-minute cooldown after three
  failures. Tests cover healthy no-op, stopped no-op, successful degraded
  recovery, repeated-failure cooldown, and unit/timer removal. Unattended boot,
  real sleep/network transitions, systemd distribution matrices, Unraid, and
  Windows service parity remain unproven.
- Linux firewall lifecycle now separates unprivileged preview from explicit
  root apply/remove and never runs `sudo`, `pkexec`, firewall enablement, or
  default-policy changes. Configured ports and IPv4 CIDRs are strictly
  validated; LAN rules are source-scoped, public rules omit raw backend,
  raw LiveKit, LAN-proxy, and loopback-relay ports, and pre-existing rules are
  refused rather than claimed. Partial application rolls back. Exact rule
  ownership is stored only in root-owned mode-`0700` `/var/lib/yappa` with a
  mode-`0600` registration; the user-writable install contains only a
  non-authoritative removal marker. Host-local registration is excluded from
  bundles and encrypted portable backups and carried only across same-host
  upgrades. Tests cover plan shape, invalid ports/CIDRs/modes, privilege
  refusal, forbidden exposure, state boundaries, uninstall refusal, and a
  complete namespace-isolated root UFW apply/remove cycle where user namespaces
  are permitted. Hosted kernels that reject UID mapping skip only that isolated
  root mutation fixture while retaining plan/negative/static rollback gates.
  Real distribution UFW/firewalld mutation/removal matrices remain required.
- Ensure production secrets never live in the repository or images.
- Add dependency auditing, secret scanning, static analysis, and reproducible
  release provenance to CI.
- A repository secret gate now scans tracked and unignored files during the
  backend security suite, rejects production `.env`/database/key/identity
  artifacts, and detects common private-key and provider-token formats. The
  server ignore rules exclude generated secrets and data by default.
- Server setup now creates `.env` and generated LiveKit configuration with a
  private umask and mode `0600`. The former tracked LiveKit development
  credential file was removed; fresh credentials exist only after the startup
  script generates them. Deployment regression tests enforce the private raw
  backend bindings, secret-file handling, IP-only public join output, and
  external-to-internal router guidance.
- A least-privilege GitHub Actions security workflow now runs locked backend
  installation, production dependency audit, the backend security suite,
  Flutter analysis, and Flutter tests for pushes and pull requests. Every
  action is pinned to a full commit SHA and checkout persistence is disabled.
  As of 2026-07-28, the unreliable monolithic desktop artifact workflow has
  been replaced locally by separate manual Linux, Windows, and macOS workflows.
  Thin workflow wrappers call repository-owned validation and platform
  packaging scripts. All three run the shared native MLS, pinned official
  vector, Flutter analysis, and Flutter test gate before packaging. Release,
  Flutter, and verified Windows libsodium inputs are centralized in
  `.github/release-versions.json`; action references remain full literal SHAs.
  Platform scripts retain split symbols, neutral build roots where applicable,
  native-library checks, artifact content/runtime-path scans, and startup smoke
  tests. Failure diagnostics are uploaded with bounded retention. Development
  artifacts remain explicitly `0.1.0-dev`/`0.1.0+1`; hosted execution of the
  replacements, production signing, provenance, and publishing policy remain
  release gates. The release-critical Rust toolchain is pinned to `1.96.1` in
  `rust-toolchain.toml`, mirrored in the release manifest, and checked by the
  deployment policy test. Security CI uses the same shared native
  MLS/vector/Flutter entry point as every artifact workflow, preventing the
  security and packaging gates from drifting apart. Exact-candidate Windows,
  macOS, and security runs now pass; hosted Linux, production signing,
  provenance, and publishing policy remain release gates.
- GitHub run history was inspected on 2026-07-24. Workflow run
  `23470775087` successfully built Linux, Windows, and macOS artifacts for
  revision `d3e2ebeead049a96d6cac5cf7b41e799cd045246` on 2026-03-24. That
  predates the current security workflow, OpenMLS bridge, media E2EE, and
  validation steps. It proves only historical packaging capability; it is not
  evidence that the current worktree builds or passes on those platforms. No
  hosted run of the current security workflow exists yet because the workflow
  and implementation are not present on the remote revision.
- The complete local operational gate was rerun on 2026-07-24 after
  connectivity and attachment-coordination changes: all backend authorization,
  identity, password, abuse, migration, log, secret, deployment, and backup
  tests passed; `npm audit --omit=dev` reported zero vulnerabilities; Compose
  rendered from `.env.example`; Flutter analysis and all 51 client tests
  passed; and the native MLS bridge passed all 17 tests plus a debug build.
  RustSec reported zero vulnerabilities and the documented allowed
  non-runtime `proc-macro-error2` maintenance warning.
- The split workflow implementation was validated locally on 2026-07-28.
  Workflow YAML and shell syntax parsed, the deployment policy test proved
  every platform wrapper invokes the common client gate, and the complete
  backend security suite passed. The extracted client gate passed all 17
  native MLS tests, all 25 checksum-pinned official vector-reader tests,
  Flutter analysis, and all 58 Flutter tests. The extracted Linux packaging
  script then completed a neutral-source release build and its native
  dependency, path, secret-marker, and packaging inspections. Exact-candidate
  hosted Windows and macOS artifact evidence is recorded below; hosted Linux
  remains pending because its required self-hosted runner was unavailable.
- The official fixtures omitted from the OpenMLS crates.io package were run
  from the exact signed `openmls-v0.8.1` release archive on Linux. Its
  SHA-256 was
  `29427912c8190c029340194f56178266a04fc76658c03b5ebdad3df23e5d92f0`;
  61 upstream vector runners passed with zero failures, including the
  mandatory RustCrypto ciphersuite. A checksum-pinned repository runner now
  creates a RustCrypto-only disposable workspace, uses a committed vector
  lockfile, and fails unless `cargo tree` proves Yappa's vendored HPKE `0.6.1`
  is active. All 25 official vector-reader tests passed against that exact
  graph on Linux. Security CI and every desktop artifact job enforce the
  runner. Exact-candidate hosted Windows and macOS jobs now enforce it
  successfully; hosted Linux remains a release gate.
- Pin and verify critical dependencies and container images.
- The 2026-07-23 backend audit originally reported nine dependency advisories
  (four moderate and five high) across Express, Multer, Socket.IO, Engine.IO,
  WebSocket, and parser dependencies. Compatible patch/minor updates resolved
  all nine without a major-version upgrade. A post-fix `npm audit` reported
  zero known vulnerabilities, and fresh-database HTTP/CORS/rate-limit runtime
  checks passed. The audited lockfile was deployed to Unraid on 2026-07-23;
  production installation and a separate in-container audit both reported zero
  known vulnerabilities. API/security checks passed and the existing hashed
  client session resumed activity after the backend restart.
- Publish a vulnerability-reporting process and supported-version policy.
- Add database migrations and rollback plans for all security changes.
- Schema version `2` is now journaled. Base creation, additive migrations,
  seed/config initialization, and the version record execute in one SQLite
  transaction, so an injected migration failure leaves the old schema and data
  unchanged. The backend refuses a database newer than its supported version
  without creating application tables. Migration tests cover the legacy
  fixture, successful versioning, future-version refusal, and atomic DDL
  rollback. `server/MIGRATIONS.md` defines rollback as a complete encrypted
  pre-upgrade `.env` plus `data/` restore using the matching software revision;
  running an older image against a migrated database is forbidden. Startup
  failures expose only a sanitized reason code, and a runtime sentinel test
  proves the database path and detailed migration error do not reach logs.
  Version 2 adds the nullable-on-upgrade MLS client operation id plus its
  partial unique index without rewriting existing opaque rows; version 3 adds
  the authenticated MLS device credential directory and safe historical
  backfill; version 4 removes implicit active chat-attachment expiry.
  Previous-version fixtures prove row preservation. Versions 2 and 3
  were deployed to Unraid on 2026-07-24 after encrypted pre-upgrade backups.
  Production reached schema 3 while preserving one user and ten messages; the
  operation index, credential table, and healthy hardened container were
  reverified. A subsequent real encrypted schema-3 backup and isolated restore
  verification passed.
- Review logs, crash reports, metrics, and update checks for privacy leakage.
- HTTP and realtime failure paths return stable public error text rather than
  raw dependency exception messages. Operational diagnostics record only a
  bounded alphanumeric error code; a static regression gate rejects direct
  `error.message` use in the backend so DNS, parser, filesystem, or dependency
  details cannot accidentally reach clients or logs.
- Security-sensitive numeric configuration—including rate ceilings/windows,
  authentication backoff, password policy, session lifetimes, attachment grant
  lifetime, and listener ports—is parsed as a bounded safe integer. Invalid
  values refuse startup with a generic code rather than becoming `NaN`,
  silently weakening a limit, or printing the value. Runtime coverage proves
  this fail-closed behavior.
- Configured attachment-signing and LiveKit API secrets must contain at least
  32 UTF-8 bytes and are length-bounded. Short or malformed values refuse
  startup without echoing the secret or its variable name; the packaged script
  continues to generate high-entropy values automatically.
- Provide secure-by-default example configuration without development keys.
- Direct Node startup binds only `127.0.0.1` and refuses a malformed listen
  address. Compose explicitly listens on the private container interface while
  startup migrates even older `.env` files to the host-side `127.0.0.1` port
  publication for Caddy; raw backend HTTP is therefore not exposed merely by
  bypassing or upgrading through the startup script. Express framework
  identification is removed from responses.
- The packaged Node image is now a two-stage production image using locked
  `npm ci --omit=dev`, only runtime source/dependencies, an unprivileged
  UID/GID, and an internal health check. Its build context excludes secrets,
  generated config, data/databases, encrypted backups, tests, and host
  dependencies. Node, Caddy, and LiveKit use read-only root filesystems,
  bounded `noexec,nosuid,nodev` temporary mounts, dropped default
  capabilities, init reaping, and `no-new-privileges`; only Caddy and LiveKit
  regain `NET_BIND_SERVICE`. LiveKit's current UDP-443 host-network exception
  is the explicitly bounded root case described above; Node and discovery use
  the installation owner's numeric IDs. The startup script restricts the
  persistent data directory to that owner. Static deployment tests
  and Compose rendering pass. Unraid deployment on 2026-07-24 confirmed the
  locked image build, healthy UID/GID `1000` runtime, read-only roots, dropped
  capabilities, `no-new-privileges`, private secret/data modes, schema `1`,
  preserved application data, loopback-only TCP `4100`, and clean logs.

The local Linux debug and release desktop bundles built successfully on
2026-07-24 after installing the required `webkit2gtk-4.1` development package.
The release binary launched, and inspection confirmed the native MLS,
LiveKit/WebRTC, secure-storage, and WebKit plugins with resolved dependencies
on the validation host. Reproducible runner packaging still requires CI
evidence. Windows and macOS artifact jobs and runtime validation remain
unproven.

The release bundle was rebuilt from the current post-preview worktree on
2026-07-24. It contains `libyappa_mls.so`, the Flutter AOT library, and the
LiveKit/WebRTC, Secret Service secure-storage, WebKit, recorder, clipboard,
desktop-drop, and URL-launcher plugins. Recursive `ldd` inspection of the
executable and bundled shared objects found no unresolved dependency, and the
expected exported MLS group/application/state symbols were present. The
packaged executable remained alive until a bounded 12-second harness timeout,
then exited only because the harness sent `TERM`; no loader, cryptography,
vault, or crash diagnostic appeared and no core/log artifact remained. The
host emitted one cosmetic cursor-theme warning. The 59 MiB local bundle's
executable and MLS-library SHA-256 values were recorded during validation, but
they are not published provenance and must not be treated as reproducible CI
artifacts.

That inspection initially exposed absolute build-home paths in generated
plugin runtime metadata and Rust dependency panic-location strings. Linux
packaging now uses only bundle-relative `$ORIGIN` runtime paths, remaps the
Rust build home, builds Flutter from a neutral temporary source root, and
keeps split debug information out of the shipped bundle. The artifact workflow
fails if any bundled file contains a builder home, retired `sslip.io` marker,
private-key marker, absolute runtime search path, or unresolved shared-library
dependency. A full neutral-root local build passed this isolation gate on
2026-07-24. The updated hosted workflow still needs a successful run before
this becomes reproducible release provenance.

The macOS artifact definition previously omitted `libyappa_mls.dylib`, while
the Dart loader had no macOS candidate and the release sandbox permitted
neither outbound networking nor camera/microphone capture. The current source
build now compiles the locked Rust bridge inside Xcode, remaps its builder
home, signs and installs it under the app's `Frameworks` directory, and loads
that exact dylib on macOS. The first hosted split-workflow run on 2026-07-28
proved the native Rust and official vector portions, then failed safely because
the runner lacked libsodium for Dart secretstream tests. The follow-up pins
the official libsodium `1.0.20` source archive by SHA-256, builds it for the
runner, enables the previously skipped Dart MLS integration suite on macOS,
and installs and signs `libsodium.dylib` beside the MLS dylib under the app's
`Frameworks` directory. The Dart loaders first resolve those app-local
libraries and retain development candidates for tests. Release and debug
entitlements explicitly retain the app sandbox while granting only outbound
network, microphone, and camera access needed by Yappa; user-facing privacy
descriptions are present.
macOS CI now runs the native MLS tests and pinned official vectors, verifies
the app and nested signature, required entitlements, native library presence,
builder-path/secret-marker isolation, and an eight-second packaged startup
smoke. Release compilation occurs from a neutral `/tmp` source root, keeps
split debug information outside the app, and rejects absolute build paths in
Mach-O runtime search metadata. Static deployment policy, XML, shell,
workflow-YAML, and Flutter analysis checks pass locally. Exact-candidate macOS
artifact run `30405281961` on commit `4140abd` completed the native/Dart
integration, bundle, signature, entitlement, path/marker, startup-smoke, and
artifact-upload gates.

The first split Windows run on 2026-07-28 passed native MLS, official vectors,
Flutter analysis/tests, and the full MSVC release compile. The artifact scan
then rejected `app.so` because the default Pub cache retained the GitHub runner
account in AOT metadata. Release scripts now use clean neutral Pub caches on
all three platforms, and Windows removes generated package/build metadata
before compiling the artifact. A later diagnostic proved the remaining
lowercase `/users/` match was a legitimate API route rejected by an
over-broad case-insensitive `/Users/` alternative. That correction is guarded
by a regression test rather than a weaker scan. Exact-candidate Windows run
`30405281982` on commit `4140abd` passed shared validation, native packaging,
the corrected path/secret inspection, the packaged startup smoke test, and
artifact/diagnostic upload. Security run `30405285412` passed on the same
commit. Temporary candidate-branch push triggers were removed after collecting
this evidence; desktop artifact workflows are manual again.

After the player, cross-platform packaging, and encrypted-attachment failure
changes, the exact current Linux client was rebuilt once more from a neutral
temporary source root on 2026-07-24. The 57 MiB bundle passed whole-artifact
builder-home, retired-hostname, Codex-key-label, private-key, and runtime-path
scans; recursive native dependency resolution found nothing missing, and the
expected MLS ABI/application/state exports were present. The packaged process
survived a bounded 12-second launch with no loader, cryptography, vault, or
crash diagnostic and no core/log artifact. Only the already documented
cosmetic cursor-theme warning appeared. Local SHA-256 values were recorded for
the executable, Flutter AOT library, and MLS library; they are not a substitute
for hosted signed provenance.

The 2026-07-24 direct-IP checkpoint reran Flutter analysis, all 52 client
tests, the Linux release build, and the complete backend security suite.
Production Caddy obtained a Let's Encrypt short-lived certificate with the
literal public IPv4 address as a critical SAN. Workstation probes verified
certificate validation with and without hostname-style SNI, HTTP 200 API
routing, a Socket.IO WebSocket upgrade, and LiveKit rejection of an invalid
token through the shared `/rtc` route. The release client persisted only the
direct HTTPS IP and no generated wildcard-DNS address.

## Security Claim Gate

Before Yappa calls a feature “secure” or “end-to-end encrypted,” record:

1. The exact content and metadata protected.
2. Who holds keys and who can decrypt.
3. Threats explicitly out of scope.
4. Automated test evidence.
5. Migration and downgrade behavior.
6. Independent review findings and remediation.

Until then, user-facing language must describe the narrower confirmed property,
such as “encrypted in transit to the self-hosted media server.”
