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
- Plaintext history reads use the composite `(channel_id, id)` index. The
  migration removes the superseded channel-only index, and an automated query
  plan assertion proves the older-than lookup uses the composite index.
- The desktop client exposes an explicit load-older action, validates cursor
  response consistency, deduplicates pages, and preserves chronological
  ordering. Its ordinary plaintext cache persists only the newest 200 messages
  per channel and its interactive backward-history window is capped at 1,000
  messages with an honest limit notice; evicted persisted rows remain
  authoritative and recoverable from the server.
- The complete backend/security/deployment-policy suite, Flutter analysis, and
  all 60 Flutter tests pass with this increment. Production deployment remains
  unverified because approved Unraid SSH access is unavailable.
- The client stores its decrypted MLS event view in an authenticated encrypted
  local store protected by an OS-vault key, and fails closed if that key or
  store authentication is unavailable.
- The backup workflow includes the database and attachment roots and has an
  integration test for encrypted backup/restore orchestration.

These facts prove a useful persistence foundation, not the complete product
contract.

## Confirmed Gaps

- Plaintext reconnect catch-up does not yet use a forward cursor. The current
  client refreshes the newest page and can page backward, but it cannot slide
  beyond its explicit 1,000-message interactive window without reconnecting.
- Encrypted client history needs the same explicit bounded-window UX and
  honest older-history/recovery states; its server delivery cursor alone does
  not complete that product behavior.
- Ordinary and encrypted attachment retention defaults to 30 days. That does
  not satisfy durable chat history for attachments.
- MLS gives a newly admitted device access from its admitted epoch forward;
  server-retained ciphertext alone does not give that device authenticated
  access to earlier plaintext. Secure history transfer/recovery semantics are
  required for Discord-like continuity without weakening E2EE.
- A complete read-marker/unread persistence contract, large-history search,
  capacity behavior, backup restore drill, and multi-year scale evidence are
  not yet recorded.
- Real multi-device restart, reinstall, device replacement, removal, and
  restored-server exercises remain required.

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
