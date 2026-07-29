# Yappa Encrypted History Recovery

## Status

This document defines the first-public-release design for recovering encrypted
channel history on a new or reinstalled device. The schema-5 recovery-key
directory and authenticated registration/read APIs are implemented. Schema 6
adds the bounded opaque transfer/chunk relay. The client
creates a separate per-server/device X25519 key in OS-protected storage, signs
its canonical binding with YUID, pins registration responses, independently
verifies the same-account directory, and registers during encrypted-server
session setup. Its transfer cryptor now derives a per-transfer X25519/HKDF key,
encrypts bounded chunks with AES-256-GCM, binds them to an immutable canonical
header, and verifies the final YUID-signed manifest before decryption.
The client transport pins every create/list/lifecycle response, verifies every
downloaded chunk against the manifest, resumes uploads through exact retries,
and keeps server consumption separate from download so it can occur only after
a durable local merge. Existing devices export a canonical contiguous range.
The destination coordinator verifies and decrypts the complete transfer,
reauthorizes every recovered sender against the historical YUID-bound MLS
credential directory, rejects conflicting sequences/event ids and invalid
mutations, and atomically persists the merged projection plus a replay receipt
before acknowledging consumption. Recovery UI and the full
negative/scale/real-device matrix remain incomplete.

The recovery notice is connected to live encrypted-channel state. Existing
devices discover every active same-account recovery destination and require the
user to select and confirm the exact device and range. Destinations receive an
exact-device realtime ready notification, independently refresh and verify the
directory/manifest context, and require confirmation before merge. The UI
reports honest local-start, sharing, receiving, safe failure, and
recovered-through states.

Before its first network mutation, the source now writes the exact signed
manifest, context, and ciphertext chunks to a separately keyed AES-256-GCM
outbox whose key is held in protected storage. Pending-file promotion is
restart-safe. A fresh controller re-verifies the current account and both
device-key bindings, then replays the exact transfer/chunks through the
idempotent relay contract. The outbox is erased only after ready confirmation.
Tampering or a missing protected key fails closed. A failed upload offers a
confirmed stop action; the local retry is erased only after authenticated
relay cancellation or an exact not-found response proving the transfer never
reached the relay. An uncertain or conflicting server response preserves the
retry. The remaining negative/scale/real-device matrix and product polish
remain incomplete.

Automated adversarial client evidence rejects wrong destination recovery keys,
wrong authorized YUID signing keys, reordered or truncated ciphertext chunks,
altered manifest signatures, conflicting transfer-id replay, and
non-identical overlap with already durable local history. Rejected merge
attempts leave the existing event set and recovery receipts unchanged.
Revocation/ban lifecycle expansion, representative behavior at the storage
ceiling, and real-device evidence remain outstanding.

Yappa will use explicit, same-account, device-assisted recovery. An existing
authorized device decrypts its authenticated local event history and
re-encrypts it directly to a separately authorized recovery key belonging to
the destination device. The server stores and relays only opaque, bounded
transfer material. It never receives a history key or plaintext and there is
no administrator, server, or universal recovery key.

If no authorized device or user-created encrypted client export still has the
old epochs, those epochs cannot be recovered. Account recovery alone does not
recover old encrypted history. The UI must say this before the last
history-capable device is removed.

## Key Separation and Authorization

Each installation creates a dedicated X25519 history-recovery key pair. It is
separate from MLS state, YUID signing keys, media E2EE keys, and attachment
keys. The private key is stored through the OS credential vault with the same
fail-closed local protection required for MLS state.

The account's YUID Ed25519 key authorizes the recovery public key with:

```text
yappa-history-recovery-device-v1 |
server_id |
account_yuid |
media_device_id |
recovery_x25519_public_key
```

The backend accepts the binding only from the matching authenticated active
device and stores the public key and YUID signature in the device directory.
Every client independently verifies the YUID, device id, server id, and key
binding before using it. Registration or use fails closed for banned,
revoked, unrelated, or mismatched devices.

Recovery is restricted to two active devices belonging to the same YUID on the
same server. It is not a general member-to-member export mechanism.

## Transfer Manifest

The source creates a random 128-bit transfer id and one canonical manifest:

```text
{
  "protocol": "yappa-history-recovery-v1",
  "transferId": "...",
  "serverId": "...",
  "channelId": "...",
  "accountYuid": "...",
  "sourceDeviceId": "...",
  "destinationDeviceId": "...",
  "sourceRecoveryPublicKey": "...",
  "destinationRecoveryPublicKey": "...",
  "firstServerSequence": 1,
  "lastServerSequence": 5000,
  "eventCount": 4821,
  "chunkCount": 40,
  "plaintextBytes": 9000000,
  "chunkCiphertextSha256": ["...", "..."],
  "createdAt": "...",
  "expiresAt": "..."
}
```

`firstServerSequence` and `lastServerSequence` bind the enclosing MLS delivery
range. `eventCount` counts recovered application events and may be smaller
because commits, Welcomes, and other non-application MLS deliveries occupy
sequence numbers but do not belong in the application-event history export.
The exported events remain strictly increasing, start and end at the declared
application-event boundaries, and may contain only those authenticated gaps.

The source signs the canonical manifest hash with its YUID Ed25519 key. The
destination requires that signature and both verified recovery-key bindings.
Server metadata is routing and quota input only; it is never sufficient to
authenticate transferred history.

An immutable canonical header binds the exact source/destination devices,
account, server, channel, sequence range, protocol, transfer id, key material,
and chunk count. Its SHA-256 digest is the chunk-encryption associated-data
root. The final manifest contains that header, its digest, and the ordered
ciphertext sizes/digests, then receives the YUID signature. This avoids a
circular dependency between ciphertext digests and their own authenticated
data. Changing or transplanting any field invalidates authenticated encryption,
the final signature, or both.

## Encryption and Chunking

The source generates a fresh ephemeral X25519 key for each transfer and derives
a transfer key from the ephemeral/destination shared secret with HKDF-SHA-256.
The salt and info bind the protocol, transfer id, server, channel, account, and
both devices. The source erases the ephemeral private key and derived key after
the resumable upload is complete.

History is encoded as canonical, length-delimited records and split into
bounded chunks no larger than 256 KiB before encryption. Each chunk uses
AES-256-GCM with a fresh random 96-bit nonce and associated data binding the
immutable header hash, transfer id, chunk index, and total chunk count. The
final manifest contains the SHA-256 digest of every complete ciphertext chunk.
A destination
authenticates the manifest and all chunk digests before committing any
recovered range.

Transferred records contain the already authenticated encrypted-event
materialization needed to reproduce message, edit, delete, reaction, and
attachment state. Attachment records include the secretstream key and
authenticated metadata originally carried inside MLS; attachment bodies remain
the existing server-held secretstream ciphertext. Explicitly deleted or
missing attachment bodies remain visibly unavailable.

## Opaque Delivery Service

The backend stores:

- transfer identity and immutable routing/range metadata;
- source and destination device ids;
- signed manifest bytes and hash;
- independently hashed ciphertext chunks;
- bounded byte/chunk counts and upload state;
- creation, ready, expiry, cancellation, and consumption timestamps.

Only the authenticated source device may create, upload, finalize, or cancel
an unfinished transfer. Only the authenticated destination device may list,
read, or consume a ready transfer. Every request rechecks the current account,
ban, device-revocation, channel, and encryption-mode boundary.

Creation and chunk upload are idempotent. An exact retry returns the existing
object; reuse of a transfer id or chunk index with different bytes or metadata
fails with HTTP 409. Finalization verifies every declared chunk, digest, count,
and byte total transactionally before making the transfer visible.

Limits for the first release:

- 256 KiB maximum ciphertext chunk;
- 1,024 chunks and 256 MiB per transfer;
- one uploading and one ready transfer per destination/channel;
- seven-day expiry for unfinished transfers and 30-day expiry for ready
  transfers;
- durable-storage headroom checks before every accepted chunk.

Expiry or cancellation removes opaque chunks. Consumption is acknowledged only
after the destination has authenticated, decrypted, merged, and durably stored
the complete range.

## Destination Merge and Rollback Protection

The destination downloads chunks resumably, pins every server response to the
signed manifest, verifies the source YUID signature and both key bindings,
derives the transfer key, and decrypts chunks in order. No partial history is
exposed to the chat projection.

The local encrypted history store applies the complete range in one
restart-safe staged operation:

1. validate canonical schemas and strictly increasing server sequences;
2. authenticate every historical sender against the retained credential
   directory and original event routing metadata;
3. reject duplicate event ids with different canonical bytes;
4. enforce edit/delete/reaction target and author/owner rules again;
5. merge exact duplicates idempotently;
6. persist the transfer id, manifest hash, source/destination devices, and
   recovered sequence range inside the encrypted local store;
7. expose the recovered projection and acknowledge consumption.

A completed transfer id cannot be replayed with another manifest. Overlapping
ranges are accepted only when every overlapping event is byte-identical.
Rollback, gaps presented as complete history, invalid signatures, missing
chunks, digest failures, revoked destinations, and key loss produce an honest
failed/incomplete state.

## User Experience

The destination shows:

- `History begins when this device joined` before recovery;
- `Waiting for one of your existing devices`;
- source-device approval with server, channel, range, and destination device;
- bounded transfer progress and resumable retry;
- `Recovered through sequence …` only after durable merge;
- explicit partial, failed, expired, removed-device, missing-attachment, and
  key-loss states.

Recovery is opt-in and never silently initiated by a server owner. The source
device requires a local confirmation for the destination and range. Removing
the last capable device requires a warning that unrecovered epochs may become
permanently unreadable.

## Required Evidence

The feature is incomplete until automated and real-device evidence covers:

1. two existing devices, a newly added device, and a reinstalled device;
2. multi-page history with edits, deletes, reactions, and attachments;
3. interruption and restart after every source, server, and destination stage;
4. exact upload/download retry and conflicting reuse rejection;
5. unrelated account, substituted destination, revoked source/destination,
   banned account, wrong server/channel, replay, rollback, and overlap
   rejection;
6. ciphertext, manifest, nonce, digest, signature, and truncation tampering;
7. bounded memory/disk behavior at the 256-MiB transfer ceiling;
8. database, upload directory, logs, backups, notifications, and diagnostics
   containing no recovered plaintext or recovery private key;
9. restored-server transfer continuation and authenticated attachment
   decryption;
10. Linux and Windows OS-vault behavior plus an independent cryptographic
    review.
