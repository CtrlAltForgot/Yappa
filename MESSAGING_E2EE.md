# Yappa Persisted Messaging E2EE

## Status

This document is the implementation contract for end-to-end encrypted text
messages and attachments. As of 2026-07-24, the guarded version `1` MLS
runtime is implemented and its backend contracts are deployed. Legacy version
`0` channels still store plaintext, while E2EE channels store opaque MLS events
and secretstream attachment ciphertext. Yappa must not make a completed E2EE
release claim until the release gates at the end of this document pass.

Yappa will use Messaging Layer Security (MLS), RFC 9420, for asynchronous
group key agreement and application-message protection. Yappa will not create
its own group ratchet. The initial implementation target is OpenMLS behind a
small, versioned native bridge used by Flutter on Linux and Windows.

The native bridge in `client/native/yappa_mls` directly pins OpenMLS 0.8.1,
OpenMLS RustCrypto 0.5.1, and the RFC mandatory-to-implement
X25519/AES-128-GCM/SHA-256/Ed25519 ciphersuite. Its transitive lockfile is
committed. OpenMLS 0.8.1 still selects HPKE 0.6.1, whose published manifest
locks vulnerable libcrux packages even though Yappa uses only its RustCrypto
provider. Yappa therefore carries a source-identical MPL-2.0 HPKE 0.6.1
backport that updates libcrux-sha3 to 0.0.10 and removes the unused libcrux
provider from the dependency graph. On 2026-07-24, `cargo audit` reported zero
vulnerabilities. It reported one reviewed unmaintained warning for
`proc-macro-error2`, reachable only through hax tooling's `cfg(hax)` dependency
and absent from Yappa's normal build graph.

The bridge now implements device creation, one-use KeyPackages, deterministic
group creation, add/Welcome, self-update, credential-targeted removal,
pending-commit accept/reject, commit processing, private application
encryption/decryption, authenticated sender credential and signature-key
output, and encrypted state export/import. Rust contains panics raised while
processing untrusted OpenMLS input and converts them to a generic failure
instead of unwinding across the ABI. Seventeen Rust tests cover the provider,
two-device messaging, rollback, update, removal/future exclusion, new-member
history exclusion, ordered offline commits, concurrent commits, replay,
tamper/context substitution, restart state, and C-ABI ownership/input handling.

The official vector fixtures excluded from the crates.io package were also
tested from the exact signed `openmls-v0.8.1` release source on Linux. The
release archive SHA-256 was
`29427912c8190c029340194f56178266a04fc76658c03b5ebdad3df23e5d92f0`;
all 61 selected upstream vector runners passed, including crypto basics, key
schedule, PSK secret, secret tree, message protection, transcript hashes,
tree operations/validation/TreeKEM, message serialization, and encryption for
the mandatory RustCrypto ciphersuite. A repository script now checksum-verifies
the same archive, removes only unused workspace providers/binaries, installs a
pinned vector lockfile, and proves through `cargo tree` that the test graph uses
Yappa's vendored HPKE `0.6.1`. All 25 RustCrypto vector-reader tests passed
against that exact graph on Linux. The script is enforced by security CI and
the Linux/Windows artifact jobs; a hosted Windows run remains required.

Flutter now has a version-pinned C-ABI wrapper and Linux/Windows build
packaging. Its local-state layer serializes mutations, keeps the 32-byte
wrapping key in OS secret storage, writes only AES-256-GCM state with
server/device-bound associated data, uses atomic pending/previous files, and
requires mode 0700/0600 on Unix. Integration tests exercise restart and
missing-key failure. The KeyPackage bootstrap persists private material before
registration and verifies the returned YUID credential binding client-side
before handing a claimed package to OpenMLS.

The backend storage migration is implemented and deployed. Existing
channels and plaintext messages remain explicitly `legacy` version `0`. New
tables separately store one-use KeyPackages, ordered MLS wire messages,
per-device cursors, encrypted event routing metadata, and encrypted attachment
objects without plaintext content/name/type columns. Database triggers permit
an explicit `legacy` to `e2ee` cutover but reject downgrade, invalid mode,
invalid version, or version rollback. The API serializes mode/version and
rejects legacy plaintext message creation/editing, attachment upload, and
server-side preview fetching after cutover. The client independently refuses
plaintext send/upload/server-preview behavior for `e2ee`, malformed, or
unknown modes. Preview requests must name an authenticated legacy text
channel, so older clients that omit the channel cannot trigger a fetch. No
channel is switched by this migration.

One-use KeyPackage delivery APIs are now implemented locally, without claiming
that the opaque packages are cryptographically functional yet. An authenticated
session may register bounded batches only for its own active media-device id.
Each package is limited to the selected RFC ciphersuite and 64 KiB, expires
between five minutes and 30 days, and is deduplicated by a server-computed
SHA-256 wire hash. The package's advertised Ed25519 credential key is bound to
`server_id | account_yuid | media_device_id | mls_signature_public_key` by the
account's existing YUID signature. Inventory is capped at 100 unused packages
per device. Any authenticated active device may atomically claim one package
for another active, non-banned, non-revoked device; the same package cannot be
claimed twice, and the response includes the public YUID binding needed for
client verification. Once returned, the stored wire bytes are zeroed while
their hash tombstone remains, preventing both database growth from consumed
64 KiB blobs and re-registration of the same one-use package. Expired packages
are compacted the same way, and per-device historical rows are bounded.
Automated tests cover invalid binding signatures, duplicate wire packages,
inventory, one-use claim behavior, post-claim byte compaction, and rejection
after device revocation.

The opaque ordered delivery-service API is also implemented locally. An
authorized device can idempotently initialize the deterministic channel group,
then submit bounded proposal, commit, Welcome, or application wire messages.
Every submission carries a client-generated operation id scoped to its
authenticated device. An exact retry returns the original accepted row without
advancing sequence/epoch or emitting realtime a second time; reusing that id
for different wire bytes or metadata fails with HTTP 409. This closes the
lost-response ambiguity for durable commit and Welcome outboxes. The server
atomically assigns the canonical per-channel sequence. Proposals
must name the current epoch, and a commit is accepted only when its parent is
the current epoch and its accepted epoch is exactly the next one; a concurrent
or replayed commit receives the current epoch and next sequence in an HTTP 409
response. Application routing metadata uses random event ids and contains no
plaintext. Duplicate ids and references to nonexistent encrypted events fail
transactionally without consuming a sequence. Welcome messages are stored and
delivered only to their named active device, including through realtime
delivery. Device fetch cursors and epoch acknowledgements are monotonic and
cannot acknowledge data that was not delivered.

The server intentionally treats every MLS wire message as opaque. These API
checks provide ordering, routing, and replay boundaries; they do not prove that
a message is valid MLS, that a commit's membership is correct, or that a
Welcome belongs to the named device. Receiving clients must verify those facts
through OpenMLS, compare each accepted epoch's credentials to independently
authenticated server membership, and refuse acknowledgement on any mismatch.
The native bridge, crash-safe add-member coordinator, authenticated member-set
enforcement, receiving replay/resynchronization, and application
materialization are connected through the guarded runtime described below.

The backend now also keeps a bounded credential directory separate from
consumable KeyPackages. Each entry contains a device id, MLS leaf signature
key, and its already-verified YUID authorization signature. Registration of a
new KeyPackage and its credential is transactional; consumed KeyPackage
private material remains erased. Revoked devices and banned accounts disappear
from directory responses. The client independently re-verifies every directory
signature, and native ABI version 4 exports the actual authenticated MLS tree
credentials/signature keys for comparison. An unauthorized or revoked leaf
rolls the local mutation back before it is persisted or acknowledged.

The receiving coordinator can skip the add commit that necessarily
precedes a new device's recipient-scoped Welcome, join at the Welcome epoch,
verify the complete resulting leaf set, persist local MLS state, store its
protected receive cursor, and acknowledge only afterward. Commit replay
reconciles a crash between local state persistence and cursor persistence
without applying an epoch twice.

ABI version 4 also stages each authenticated decrypted application receipt
inside the same AES-GCM-encrypted native state snapshot as its MLS ratchet
update. Flutter then validates canonical JSON, exact server routing metadata,
epoch, device credential/signature key, event ordering, duplicate ids,
references, author-only edits, and author/owner deletes before writing a
separate AES-256-GCM encrypted local history bound to server/device/channel.
Only after that durable write does it clear the native receipt and advance the
protected delivery cursor. A crash at any boundary can resume from the receipt
or idempotent local event without replaying MLS ciphertext. Tests cover staged
receipt restart, encrypted history restart/tamper failure, and complete
Welcome-to-application delivery.

The same ABI retains each outgoing canonical plaintext, generated MLS
ciphertext, epoch, operation id, and group id inside encrypted native state
until the server accepts it and the sender's encrypted local history is
materialized. A lost response or process restart therefore resubmits the exact
operation and ciphertext instead of advancing the MLS generation twice. An
epoch conflict clears the unsendable receipt before resynchronization.
Restart/lost-response tests verify identical wire bytes and operation ids and
prove the receipt clears only after durable local materialization. The guarded
chat UI uses this sender; standalone proposal processing remains inactive.

The Flutter delivery client is implemented for KeyPackage inventory,
registration and claim, deterministic group initialization, ordered
proposal/commit/Welcome/application submission and fetch, realtime delivery,
and monotonic acknowledgement. It strictly parses identifiers, bounds,
classes, epoch relationships, recipient/event combinations, wire hashes, and
increasing server sequences. Submitted wire bytes and routing metadata are
pinned against the server response, claimed KeyPackage bytes are checked
against the server-computed SHA-256, and the deterministic group id is checked
against the already authenticated server/channel identity. Malformed or
substituted responses fail closed before OpenMLS will see them.

The credential directory now carries the backend-authorized server-owner role
for each credential. Receiving clients use that role only after the YUID,
device id, MLS credential, and leaf signature key have all verified; an
arbitrary coordinator callback can no longer grant owner-delete authority.
This role remains server authorization metadata, not a claim that MLS
cryptographically certifies administrative roles.

MLS tree validation now requires exact device coverage rather than accepting
any authorized subset. Every leaf must match exactly one credential, no device
may occupy two leaves, and every distinct active credentialed device in the
directory must appear. Missing newly enrolled devices therefore stop
application processing until a membership commit brings the tree back to the
declared channel intent. Devices that have not enrolled an MLS credential are
still outside this intent set; activation must coordinate enrollment and group
adds before allowing encrypted chat.

The inactive membership reconciler now performs the add side of that
coordination. Among owner devices already represented in the tree, the
lexicographically first device id is the sole deterministic coordinator. It
resumes any encrypted add outbox first, identifies missing enrolled devices,
claims one KeyPackage per device, rechecks the claimed credential and leaf key
against the verified directory, then submits the crash-safe commit and
recipient Welcome sequentially. It refetches the directory and requires exact
final tree coverage before reporting completion. Non-leaders report the
missing set without mutating MLS. Tests cover deterministic leader selection,
absence of an owner leader, substituted claimed credentials, complete
two-device add, final membership, and the existing lost-response recovery.
The backend now permits creation of the initial channel state only from an
owner device that has already enrolled a verified MLS credential. Once state
exists, other authenticated members may read the same idempotent initialization
response. This removes the race where an ordinary member could become the
untracked first group creator before the owner's local MLS state existed.
The guard was deployed to Unraid on 2026-07-24; health, schema/data counts,
non-root/read-only/no-new-privileges isolation, and clean startup logs were
reverified.
Handshake processing permits a converging authorized subset so multiple
sequential add commits can be replayed. Every intermediate leaf must still map
uniquely to the directory, and exact intended membership is mandatory before
an application event is decrypted or written. This avoids both an impossible
"exact after every add" transition and a window where chat content could be
processed while an enrolled device is omitted.
The additive directory response change was deployed to Unraid on 2026-07-24.
Post-restart verification confirmed a healthy schema-3 service, preservation
of one user and ten legacy messages, zero inactive MLS/credential/encrypted
attachment rows, UID/GID 1000, a read-only root, `no-new-privileges`, and
sanitized startup logs.

The ciphertext-only attachment transport is implemented locally but is not
activated. An authenticated active device may upload one bounded opaque object
only to an E2EE version 1 text channel. The request carries a 24-byte
secretstream header, ciphertext SHA-256, and chunk count; the server streams
the stored object back through an authenticated, rate-limited endpoint with a
generic filename and media type. It recomputes the digest before accepting the
upload, applies the shared server storage quota and retention policy, and never
stores a plaintext filename, media type, dimensions, or plaintext size.
Attachment ids are bound atomically to one `attachment` MLS application event
from the same account, device, and channel. Cross-device reuse, duplicate
binding, expired objects, and missing ids roll back the entire event without
consuming its canonical sequence. Expired ciphertext files are deleted by the
normal retention sweep.

The client-generated attachment id is also the upload idempotency boundary.
After hashing the complete ciphertext, the server returns the original row for
an exact retry by the same authenticated user/device and discards the duplicate
temporary file. Changed bytes, header, digest, chunk count, channel, or
uploader under that id fail with HTTP 409. Authorization integration tests
cover both paths. This code-only hardening was deployed to Unraid on
2026-07-24; health, schema 3, row counts, UID/GID 1000, and
`no-new-privileges` were reverified.

The standalone client secretstream primitive is also implemented locally
against the platform libsodium library. It generates a fresh 256-bit key,
streams fixed 64 KiB chunks, authenticates each chunk against canonical
length-prefixed server/channel/event/attachment identity, requires the final
secretstream tag, verifies the complete ciphertext SHA-256, zeroizes native
key/state buffers, refuses overwrite, and exposes no partial plaintext after a
failure. Linux tests cover empty and multi-chunk round trips plus tampering,
truncation, digest failure, and context substitution. The client chooses the
random attachment and event ids before encryption so the associated data can
bind them without a circular server-generated identifier.

The client upload/download transport is connected to the ciphertext API and
uses the same verified LAN-aware HTTP route as other API traffic. Upload
responses are pinned against the client-generated id, secretstream header,
digest, size, and chunk count. Downloads are streamed to a private partial
file, bounded by caller-supplied expected metadata that must eventually come
from a verified MLS payload, checked against server metadata and the full
digest, and renamed only after verification. Transport tests cover successful
upload/download plus server metadata substitution.

The attachment coordinator connects these pieces end to end. It
encrypts up to ten selected files before network access, places their
independent random keys plus an optional caption, name/type/plaintext-size,
and authenticated ciphertext metadata inside one canonical MLS attachment
event, and atomically stages that event with its exact MLS ciphertext before
upload. A lost upload response leaves every encrypted object and the MLS
receipt available for exact retry after restart.
Only server acceptance, MLS delivery, and encrypted local-history
materialization clear the receipt and staged ciphertext. The receive side
takes metadata only from a verified, materialized MLS event, pins the
ciphertext download against it, decrypts with the event-bound secretstream
context, and always removes its temporary ciphertext. A Linux integration
test covers lost-response recovery followed by authenticated download and
plaintext round trip.

Encrypted attachment cards and decrypt-to-user-selected-path UI are connected.
Captionless attachment events from earlier clients remain valid, while new
events project their authenticated caption and locked file cards as one
message. Encrypted images offer an explicit local-only preview after full
secretstream verification; they do not decrypt on scroll and no plaintext
thumbnail reaches the server. The preview file lives in a private temporary
lease and is removed on close or failure. The libsodium runtime still needs
Windows packaging/runtime validation.

RFC 9420 is designed for asynchronous groups, provides forward secrecy and
post-compromise security across epochs, and treats the delivery service as
largely untrusted. OpenMLS supplies the state machine, cryptographic provider,
KeyPackage handling, message processing, and persistent storage interfaces:

- <https://www.rfc-editor.org/rfc/rfc9420>
- <https://book.openmls.tech/user_manual/index.html>
- <https://book.openmls.tech/user_manual/persistence.html>

Attachment bodies will use libsodium's reviewed
`crypto_secretstream_xchacha20poly1305` construction. A fresh random stream key
is carried only inside the corresponding MLS application message:

- <https://doc.libsodium.org/secret-key_cryptography/secretstream>

Last updated: 2026-07-24.

## Security Boundary

Protected end to end:

- message text and structured event payloads;
- edit and reply bodies;
- reaction values;
- attachment names, media types, dimensions, and plaintext sizes;
- attachment and thumbnail bytes;
- cryptographic sender identity inside MLS private messages.

Necessarily visible to the Yappa delivery server:

- server and channel routing identifiers;
- the authenticated account and device that uploaded an envelope;
- MLS wire-message size, ordering, and arrival time;
- current authorized channel membership;
- encrypted attachment object size and retention time;
- IP and transport metadata already visible to the self-hosted service.

The server must not receive MLS private state, attachment stream keys,
plaintext previews, plaintext search terms, or decrypted crash diagnostics.
TLS remains mandatory because MLS does not hide all group metadata and does not
prevent denial of service.

## Identity and Device Model

Each installation is a separate MLS client. Its MLS signing credential binds:

```text
server_id | account_yuid | media_device_id | mls_signature_public_key
```

The existing YUID Ed25519 identity signs that binding. The backend accepts a
KeyPackage only for the authenticated, non-revoked device named in the
signature. Other clients verify the YUID binding before accepting its MLS
credential. A KeyPackage is one-use, expires, and is replenished before the
device runs out.

MLS private state and unused KeyPackage private material live in OS-backed
secret storage or an encrypted local database whose wrapping key is held by
the OS credential vault. They are never placed in Flutter preferences, logs,
server backups, or portable client settings.

## Channel and Epoch Model

Each text channel maps to one MLS group:

```text
group_id = "yappa-text-v1" | server_id | channel_id
```

The first authorized device creates the group. Adding or removing an account
means adding or removing every currently authorized device for that account.
The backend orders proposals and commits but does not create them or decide
their contents. Clients accept a commit only when its resulting credential set
exactly matches the backend's independently authenticated channel membership.

Concurrent commits require one canonical server order. A commit is not merged
into local state until the delivery server accepts its parent epoch and assigns
the next channel sequence. Rejected or superseded pending commits are discarded
using the MLS implementation's supported rollback path.

Devices periodically issue self-update commits to restore post-compromise
security. Removed devices receive neither the new commit secrets nor future
private messages. Epoch secrets and used message-generation keys are erased as
soon as the MLS implementation permits.

There is no plaintext or legacy-ciphertext fallback inside an encrypted
channel. A client that cannot reach the current MLS epoch shows an explicit
resynchronization state and cannot send.

## Offline Delivery and History

The delivery server persists ordered MLS handshake and private application
messages. An offline device replays the missing sequence from its last accepted
epoch and processes it locally.

MLS intentionally prevents a newly added device from decrypting messages sent
before it joined. Yappa preserves that property:

- existing devices can synchronize ciphertext for epochs in which they were
  members;
- a brand-new or reinstalled device starts readable history at its join epoch;
- the server cannot escrow or recover earlier plaintext;
- first-public-release recovery uses the explicit same-account device-assisted
  protocol in `ENCRYPTED_HISTORY_RECOVERY.md`; it is separate from MLS and must
  not be disguised as ordinary MLS behavior.

This limitation must be visible before a user removes their last functioning
device. Account recovery restores account access, not old E2EE content. If no
authorized device or encrypted client export retains the old epochs, the
history remains unrecoverable.

## Application Events

Every MLS application plaintext is canonical, versioned data:

```text
{
  "protocol": "yappa-message-v1",
  "eventId": "<128-bit random id>",
  "channelId": "<channel id>",
  "kind": "message|edit|delete|reaction|attachment",
  "targetEventId": "<optional prior event id>",
  "createdAt": "<client timestamp>",
  "body": { ... }
}
```

The MLS signature authenticates the sending device. The server's ordered
sequence is authoritative for display order; client timestamps are
informational. Clients reject duplicate event ids, wrong-channel payloads,
invalid schemas, impossible references, and events from credentials that were
not authorized in that epoch.

Edits, deletes, replies, and reactions are new encrypted events. The client
materializes current state after decryption and applies the same author/owner
authorization rules enforced by the server's routing metadata. Server-side
deletion can remove ciphertext for retention or moderation but cannot prove
what plaintext it removed.

The delivery server now requires edit, delete, and reaction routing events to
name an existing target in the same channel. Only the original sender may
submit an edit; the original sender or server owner may submit a delete.
Invalid or unauthorized references roll back the complete transaction without
consuming a sequence. Clients must compare the decrypted event schema and
target with this routing metadata before applying it, because the opaque server
cannot prove that ciphertext labeled `message` does not decrypt to an edit.
Edits target only message roots. Deletes and reactions target only message or
attachment roots; mutation events can never target other mutations. The
backend and local encrypted event store enforce this independently so a nested
mutation cannot poison deterministic projection.

Search is local over decrypted content. The backend receives no search query
and maintains no plaintext index.

## Attachments and Thumbnails

For each attachment the sender:

1. creates a random 256-bit secretstream key;
2. encodes authenticated metadata inside the MLS application message;
3. streams fixed-size encrypted chunks with a final tag;
4. uploads only the secretstream header and ciphertext;
5. includes a SHA-256 digest of the complete ciphertext object in the MLS
   message.

Authenticated metadata binds the attachment id, server id, channel id, message
event id, chunk index, and protocol version. Clients verify the final stream
tag, ciphertext digest, expected chunk count, and authenticated metadata before
exposing a completed file.

The server continues to authorize downloads by account, channel, ban state,
expiry, and path containment. Signed URLs protect transport access but are not
the E2EE boundary.

Thumbnails are generated on the sender device and encrypted as separate
secretstream objects. The server never generates previews from encrypted
uploads. Decrypted temporary files should be avoided; where a platform API
requires one, it must use a private temporary directory and best-effort
immediate cleanup.

## Link Preview Privacy

The server cannot inspect encrypted message bodies to discover URLs. It must
not receive plaintext URLs solely to preserve previews.

Encrypted channels default to no automatic preview fetch. A user may explicitly
select a link after decryption and request a preview directly from their own
client, with a warning that the destination learns their IP address. Relaying a
preview through the Yappa server would reveal the URL to the server and is not
the default encrypted-channel design. Preview metadata shared with the group
must itself be included in the MLS application message.

## Backend Storage Contract

Migration introduces new tables/columns rather than reinterpreting plaintext:

- one-use device KeyPackages and expiry;
- ordered per-channel MLS delivery messages with wire format, message class,
  accepted epoch, uploader device id, and server sequence;
- per-device delivery cursors and acknowledgements;
- encrypted message event objects with no plaintext `content`;
- encrypted attachment objects with ciphertext size, digest, chunk count,
  retention fields, and no plaintext name/type;
- a channel encryption-mode/version field that cannot silently downgrade.

This schema and its non-downgrade triggers now exist locally. Migration tests
start from a pre-encryption database, preserve its plaintext and label it
legacy, inspect the ciphertext-only table columns, perform a one-way cutover,
and prove downgrade/version rollback fail at the database boundary. HTTP
integration tests additionally prove old plaintext message clients receive
HTTP 409 after cutover and that the server refuses link-preview fetching in
the encrypted mode. The KeyPackage registration/claim layer is implemented as
described above. Ordered opaque handshake/application delivery, recipient-only
Welcome handling, atomic epoch conflict handling, realtime notification, and
monotonic per-device cursors are implemented as described above. Ciphertext
attachment transport and atomic attachment-event binding are also implemented.
The client now writes add-member commit and Welcome wire bytes, epochs,
recipient, and independent operation ids to an AES-256-GCM encrypted outbox
before submission. The outbox key lives in OS secret storage, ciphertext is
bound to server/device context, Unix files are permission-restricted, and
authenticated staged recovery handles a lost commit response without
duplicating the accepted server row or advancing local state twice. Epoch
conflict rejects the still-pending local commit before clearing the operation.
Standalone proposal handling, Windows runtime validation, official vectors,
and independent cryptographic review remain pending. Channel enrollment,
receive-loop integration, guarded chat UI, and
cryptographic activation are implemented.

The per-server/per-channel runtime composes the previously separate primitives
behind a fail-closed UI gate. One encrypted native device
and one add outbox are shared across channels and serialized to prevent state
snapshot races. Startup replenishes KeyPackages, replays delivery, and returns
one of three explicit states: waiting for Welcome, waiting for exact
membership, or ready. The initialization response includes an authenticated
`created` bit. Only the client receiving `created: true` creates local founder
state and persists its protected receive cursor at epoch zero; an existing
server group always waits for a Welcome and can never be silently recreated
under the same id. The ready path then runs delivery and deterministic
membership reconciliation and exposes the durable sender, receiver, event
store, and attachment coordinator as one channel lifecycle.
The allocation contract was deployed to Unraid on 2026-07-24 after both full
suites passed. Health, schema/data preservation, non-root/read-only/
no-new-privileges isolation, and sanitized startup logs were reverified.

AppState now opens this lifecycle only for E2EE version 1 text channels during
session restore or channel selection, reopens it when a rotated token changes
the authenticated transport, and synchronizes again on realtime MLS delivery.
Logout, server removal, token replacement, and application disposal close and
zeroize the per-server runtime. Legacy channels continue using the plaintext
history API. The chat surface shows an honest waiting/ready lifecycle notice
and keeps the composer unavailable until exact membership is ready. It then
projects authenticated MLS message/edit/delete events and enables encrypted
text send/edit/delete. The projection resolves the sender only by matching the
MLS credential and signature key to the YUID-reverified directory's account
identity. The legacy upload path stays unavailable. Selected files instead
stream through secretstream, bind their keys, caption, and display metadata
inside one MLS event, render as locked cards, and decrypt only to a
user-selected path after the authenticated ciphertext checks pass. The exact
event and all ciphertexts survive a lost upload response together. Reaction
chips are materialized from ordered authenticated reaction events and toggle
per account. Encrypted images use an explicit click-to-decrypt local preview;
automatic thumbnails remain intentionally absent to avoid background
decryption and plaintext server disclosure. Send, decrypt/save, and preview
failures are mapped to bounded user-facing categories for authorization,
rate limits, oversized files, connectivity, local permissions/storage, and
authentication failure. Raw server text, local paths, native errors, and
secretstream details never reach the composer or attachment card. Integrity
failure explicitly says the attachment was not opened or saved.

The credential directory distinguishes current active membership from
historical authentication. Exact tree checks and add/remove reconciliation use
only active device bindings. Projection may use inactive signed bindings to
authenticate events already accepted while that device was a member. This
prevents revocation from erasing the ability to attribute legitimate history
without allowing the revoked device back into the current group.

Plaintext channels remain explicitly labeled legacy during migration. Enabling
E2EE creates a new MLS group and a visible cutover marker. Old rows are not
claimed to be encrypted and are not automatically copied into the new group.
Downgrading an encrypted channel in place is forbidden.

New text feeds are created directly as `e2ee` version `1`; there is no
intermediate plaintext window. The owner client immediately enrolls its MLS
device, initializes the deterministic group, and reconciles membership. Until
that succeeds, the feed remains unavailable for sending rather than falling
back to legacy chat. The backend's legacy message, attachment, preview, edit,
and delete paths reject the feed from creation, and a database trigger forbids
downgrade. Existing version-0 feeds and history are not relabeled. Backend
authorization/schema tests cover this boundary, and the server change was
deployed to Unraid on 2026-07-24.

## Backup, Export, and Recovery

Normal server backups contain ciphertext, routing metadata, public credentials,
and MLS delivery messages, but no client private state.

An optional future encrypted client export must use a memory-hard
password-based KDF, authenticated encryption, explicit versioning, and a
prominent warning that the export can decrypt all included epochs. It is not
part of the first release. There is no server-side recovery key, hidden master
key, or administrator decryption.

## Delivery Order

1. Pin an independently reviewed OpenMLS release and audited native
   dependencies. *(Pinned and locally audited; independent review remains.)*
2. Build a minimal Linux/Windows bridge with deterministic RFC test vectors.
   *(Bridge and build integration exist; official vectors and Windows runtime
   validation remain.)*
3. Add secure local MLS state persistence and YUID-bound device credentials.
   *(Implemented and Linux-tested; Windows vault/filesystem validation
   remains.)*
4. Add KeyPackage, ordered handshake, Welcome, and resynchronization APIs.
   *(KeyPackage, ordered transport, and durable sender-side add/Welcome retry
   plus receiving replay/resynchronization are implemented.)*
5. Implement encrypted application events and local materialization.
   *(Implemented through the guarded UI, including durable incoming and
   outgoing crash recovery.)*
6. Implement secretstream attachment upload/download and encrypted thumbnails.
   *(Upload/download, MLS binding, locked cards, explicit decrypt/save, and
   private click-to-decrypt local image previews are implemented. Automatic
   thumbnails are intentionally excluded by the documented privacy model.)*
7. Migrate channels through an explicit, non-downgradable cutover.
   *(New text feeds now start as non-downgradable E2EE v1 and initialize MLS
   client-side; existing version-0 history is retained honestly. A user-facing
   conversion flow for existing feeds is intentionally not implemented because
   it could misrepresent old plaintext as encrypted.)*
8. Add multi-device, offline, concurrent-commit, removal, reinstall, tamper,
   and backup tests.
9. Perform packet/database/server inspection and independent review.

## Release Gate

Persisted E2EE is not complete until:

- official MLS vectors and Yappa binding vectors pass on Linux and Windows;
- unrelated, removed, banned, revoked, and newly added devices fail the
  applicable history/future-message tests;
- offline replay, concurrent commits, rejected commits, and state restoration
  are deterministic;
- ciphertext/message/attachment tampering and truncation always fail closed;
- database, uploads, logs, backups, previews, notifications, and crash paths
  contain no message or attachment plaintext;
- migration and rollback tests prove an encrypted channel cannot silently
  become plaintext;
- an independent cryptographic review has been completed and findings fixed.
