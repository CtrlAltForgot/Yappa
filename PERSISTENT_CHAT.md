# Yappa Persistent Chat

Last verified: 2026-07-28

## Product Contract

Yappa text history is durable by default. Messages remain available across
client restarts, server restarts, reconnects, upgrades, and ordinary device
changes until an authorized person explicitly deletes them. Yappa must not
silently expire message history to control storage.

“Forever” is an operational retention promise, not a claim that hardware can
never fail. Satisfying it requires capacity monitoring, tested backups,
restore verification, migration support, and clear failure states. If a server
cannot safely accept another durable message, it must reject the write
explicitly rather than accept it and later discard history.

Attachments, edits, deletions, thread replies, and the cryptographic state
needed to read encrypted history are part of the chat record. A missing
attachment or undecryptable historical interval must be shown honestly; the
client must not make the conversation look complete when it is not.

## Current Verified Foundation

- SQLite stores legacy message rows without a time-to-live. Message deletion
  occurs only through an authorized message or channel deletion path.
- Encrypted text feeds persist ordered MLS delivery messages and authenticated
  message/edit/delete event metadata. The server assigns a monotonic sequence
  per channel and accepts an idempotent client operation identifier.
- The encrypted delivery API supports bounded cursor reads of up to 200 events
  and stores per-device delivered and acknowledged cursors.
- The legacy plaintext history API now pages backward in bounded windows of up
  to 100 messages. Its authenticated opaque cursor binds protocol version,
  server, channel, direction, message ID, and viewer account; cross-account
  substitution and signature tampering fail closed. Every page re-runs active
  session/ban authorization and rejects plaintext reads after an E2EE cutover.
- The same cursor protocol now pages forward for reconnect catch-up. Direction
  is signed into the cursor; forward rows are ascending, bounded to 100, and
  return authenticated continuation, newest-resume, and oldest-backward
  cursors. Empty catch-up preserves the resume cursor. Automated coverage
  proves multiple forward pages have no gaps, overlap, or direction confusion.
- Plaintext history reads use the composite `(channel_id, id)` index. The
  migration removes the superseded channel-only index, and an automated query
  plan assertion proves the older-than lookup uses the composite index.
- The desktop client exposes explicit older/newer history navigation, validates
  cursor response consistency, deduplicates pages, and preserves chronological
  ordering. Its ordinary plaintext cache persists only the newest 200 messages
  per channel and its active window remains capped at 1,000 messages. Reaching
  either scroll edge can shift that bounded window while retaining an
  authenticated cursor back toward the evicted side; evicted rows remain
  authoritative and recoverable from the server.
- Before shifting either edge, the client records a visible retained message
  boundary. It restores that boundary after the lazy list is rebuilt, including
  when the retained item must first be materialized from its new approximate
  list position. A widget test replaces 100-row windows backward and forward
  and holds the retained item within one logical pixel in both directions.
- Authenticated clients can mint an opaque before/after cursor for an exact
  retained message boundary. The server resolves that message inside the
  requested plaintext channel and binds the cursor to server, channel,
  direction, message, protocol version, and viewer; clients never construct
  numeric cursors locally.
- The client persists viewer-bound forward and backward cursors alongside its
  bounded cache. Reconnect follows every forward continuation with cursor-loop
  detection, deduplicates missed realtime rows, retains the newest 1,000
  messages, and preserves a backward recovery boundary. A cursor invalidated
  by account/server-secret change fails closed and refreshes from a new
  authenticated newest page.
- The complete backend/security/deployment-policy suite, Flutter analysis, and
  all 64 Flutter tests pass with this increment. Production deployment remains
  unverified because approved Unraid SSH access is unavailable.
- The client stores its decrypted MLS event view in an authenticated encrypted
  local store protected by an OS-vault key, and fails closed if that key or
  store authentication is unavailable.
- The backup workflow includes the database and attachment roots and has an
  integration test for encrypted backup/restore orchestration.
- The production backup and fresh-install restore scripts now have a
  destructive scale fixture with 5,000 linked messages and 128 permanent
  64-KiB attachments. The source installation is erased after encrypted backup;
  the restored current-schema database passes SQLite integrity and foreign-key
  checks, retains both end messages and every attachment link, and every
  restored file matches its pre-backup SHA-256 digest.
- Fresh servers now use indefinite (`0`) retention for ordinary and encrypted
  chat attachments. Schema version 4 clears scheduled expiry from every active
  attachment and resets the server policy to indefinite without resurrecting
  explicitly deleted rows. The API rejects timed-retention settings until a
  visible, prospective, authorized policy is designed and tested.
- The backend measures filesystem headroom before accepting plaintext
  messages, MLS deliveries, and ordinary/encrypted attachment uploads.
  Defaults reserve 512 MiB as critical headroom and warn below 2 GiB; both are
  explicit validated deployment settings. Critical or unavailable inspection
  returns retryable HTTP 507 before the durable write. Real SQLite-full,
  write-I/O, and filesystem-full errors use the same public failure contract,
  and an attachment file is removed if its metadata transaction cannot commit.
- An owner-only storage endpoint reports healthy/warning/critical state,
  filesystem free/total bytes, thresholds, database/WAL/SHM bytes, and separate
  ordinary/encrypted attachment bytes without exposing message content or
  filesystem paths. Backup bytes are reported only when an explicit protected
  backup root is mounted and configured.
- Server Admin now includes a Storage surface with clear healthy/warning/
  critical state, free space, reserves, database and attachment sizes, backup
  monitoring state, and manual refresh. It never displays server paths or chat
  content.

These facts prove a useful persistence foundation, not the complete product
contract.

## Confirmed Gaps

- Encrypted client history needs the same explicit bounded-window UX and
  honest older-history/recovery states; its server delivery cursor alone does
  not complete that product behavior.
- Explicit deletion and authenticated restored-download behavior still need a
  complete multi-page exercise; linked row/file presence, backup, destructive
  restore, and full-file digest integrity now have representative-scale
  evidence.
- MLS gives a newly admitted device access from its admitted epoch forward;
  server-retained ciphertext alone does not give that device authenticated
  access to earlier plaintext. Secure history transfer/recovery semantics are
  required for Discord-like continuity without weakening E2EE.
- A complete read-marker/unread persistence contract, large-history search,
  capacity behavior, backup restore drill, and multi-year scale evidence are
  not yet recorded.
- Real multi-device restart, reinstall, device replacement, removal, and
  restored-server exercises remain required.
- The storage guard has deterministic threshold and real HTTP rejection tests,
  but still needs an actual constrained-filesystem exhaustion/recovery drill,
  configured portable-backup size monitoring, and concurrency evidence at the
  threshold boundary.

## Required Storage Model

### Authoritative server record

- Keep immutable message identities, channel identity, author identity,
  creation time, and ordered server sequence.
- Represent edits and deletes as authenticated mutations with durable audit
  metadata rather than relying on transient realtime events.
- Retain encrypted payloads as opaque ciphertext. The server must never need
  message plaintext to paginate, replicate, back up, or restore history.
- Store large attachment bytes outside hot message rows, addressed by durable
  metadata and integrity hashes. Default chat attachment expiry must be
  disabled; any future retention policy must be explicit, prospective,
  visible, authorized, and tested.
- Enforce transactional message/attachment linking and idempotent client
  operation IDs so retries cannot create duplicates or unattached permanent
  blobs.

### Efficient retrieval

- Use stable cursor pagination, never offset pagination. Cursors bind channel,
  direction, sequence/message ID, and protocol version and are validated
  against current membership on every request.
- Index channel plus server sequence/message ID for history reads, mutation
  target IDs for edit/delete reconstruction, attachment linkage, and durable
  read markers.
- Fetch a bounded recent window, then page backward on demand. Reconnect uses a
  forward cursor. The client keeps a bounded decrypted working set and may
  evict local cache entries only when they remain recoverable from the durable
  encrypted history path.
- Compact only derived indexes, previews, caches, and superseded local render
  state. Never compact away the sole durable ciphertext, required MLS state,
  or attachment needed by the retention contract.

### Encrypted history continuity

- Existing devices keep authenticated encrypted local history and MLS state.
- A new or reinstalled device requires an explicit, end-to-end authenticated
  history transfer or encrypted recovery package authorized by an existing
  account device. The server may store opaque transfer material but cannot
  possess a universal history-decryption key.
- `ENCRYPTED_HISTORY_RECOVERY.md` defines the selected same-account,
  device-assisted protocol, its dedicated YUID-bound X25519 recovery keys,
  signed manifests, resumable encrypted chunks, destination merge rules,
  fail-closed states, limits, and required evidence.
- Schema 6 implements the bounded opaque server relay, and the client transfer
  cryptor implements canonical-header-bound X25519/HKDF/AES-256-GCM chunks plus
  final signed-manifest verification. Client transport pins relay metadata and
  chunk bytes, supports safe exact-retry upload/download, and cannot consume
  server material merely by downloading it. Canonical contiguous event export,
  credential-reauthenticated atomic destination merge, overlap/replay
  protection, and durable recovery receipts are implemented. User-facing
  recovery states and the remaining scale/real-device matrix remain
  incomplete.
- Recovery preserves legitimate gaps created by MLS commits and Welcomes:
  signed range width and application-event count are distinct, while exported
  application sequences must remain strictly increasing and within the exact
  authenticated boundaries.
- Ready encrypted channels now expose live recovery discovery and explicit
  source/destination confirmation. A finalized relay wakes only the exact
  destination device, which re-fetches authoritative metadata before merge.
  Existing projected history changes only after the encrypted store commits.
  Source upload state is now separately encrypted and restart-durable before
  network mutation; exact lost-response replay clears it only after ready
  confirmation. A confirmed stop removes both relay material and the local
  retry, but ambiguous cancellation responses retain the retry so ciphertext
  is never silently abandoned. Wrong keys/signers, reordered/truncated chunks,
  conflicting transfer replay, and conflicting overlap are now rejected
  without partially changing durable history. Revocation/ban expansion,
  ceiling-scale behavior, and real two-device evidence remain.
- Transfers bind account/YUID, destination device key, server, channel, source
  device, history range, and version; use chunk integrity and resumable
  cursors; and reject replay, rollback, substitution, and removed devices.
- The UI distinguishes “history is still syncing,” “history begins when this
  device joined,” “attachment was explicitly deleted,” and “history recovery
  failed.” It never silently shows a truncated conversation as complete.

## Capacity and Operations

- Expose database, attachment, encrypted-attachment, and backup sizes plus
  available disk headroom to owners without exposing message content.
- Define warning and critical thresholds. At the critical threshold, reject
  new durable writes with a clear retryable storage error before SQLite or the
  filesystem is exhausted.
- Use WAL/checkpoint and maintenance settings based on measured workloads, not
  unbounded in-memory loading. Run integrity checks and retain migration
  rollback/restore instructions.
- Backups are not proven until a separate restore target passes schema
  migration, row/count/integrity checks, attachment hash checks, and real
  encrypted-history decryption from an authorized client.

## Release Evidence

Public-release persistence requires automated and real-system evidence for:

1. More than one API page in both directions with no gaps or duplicates.
2. Concurrent sends, offline retry, edit, delete, attachment linking, and
   reconnect catch-up.
3. Client and server restart at each write boundary.
4. Multi-device history, authorized new-device transfer, reinstall, removed
   device, failed transfer, and key-loss behavior.
5. Indefinite default attachment retention and explicit deletion.
6. Database growth, indexed query plans, memory bounds, and storage-full
   behavior at a representative large-server history size.
7. Encrypted backup, destructive test-environment loss, restore to a separate
   target, attachment verification, and client decryption.
8. Authorization failures for unrelated, removed, banned, and stale-session
   users across pagination, mutations, attachments, cursors, and transfers.

Confirmed implementation and verification results belong here and in
`PROJECT_PLAN.md`; security-boundary changes also belong in `SECURITY.md`.
