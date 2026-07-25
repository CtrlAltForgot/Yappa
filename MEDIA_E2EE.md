# Yappa Realtime Media E2EE

## Status

This is the implementation contract for microphone, camera, screen video,
screen audio, and LiveKit realtime data encryption. It is not yet a completed
or independently reviewed protocol. Yappa must continue to describe current
calls as transport-encrypted until every acceptance condition below is met.

The client now creates a persistent per-installation X25519 identity in
OS-backed secret storage. Sign-in binds its public key and device id to the
account using a fresh YUID Ed25519 authorization, and existing authenticated
sessions perform the same registration before token rotation. The backend
stores public device metadata, binds sessions to devices, exposes the active
verified directory only to authenticated members, and removes every bound
session when an account owner or server owner revokes a device. Tests cover
private-key persistence, invalid stored identities, legacy-session migration,
tampered authorizations, cross-account revocation, and session invalidation.

The sealed room-key envelope primitive in
`client/lib/data/media_key_envelope.dart` uses ephemeral X25519,
HKDF-SHA-256, AES-256-GCM with bound associated data, an Ed25519 sender
signature, and an epoch-scoped monotonic message sequence.

Room coordination and LiveKit frame-encryption activation are implemented
locally. The backend derives active device membership from authenticated
realtime voice presence, elects the lexicographically smallest device id,
increments epochs on removal or leader change, verifies leader envelope
signatures, and rejects stale, replayed, cross-room, non-recipient, and
non-leader delivery. Clients independently verify every advertised device's
YUID authorization, generate room keys only on the elected leader, seal one
copy per recipient, install per-participant LiveKit GCM keys before connecting,
and configure frame discard when a cryptor has no key. During rotation they
install a random local quarantine key before accepting the new epoch key, so
media never falls back to plaintext.

Any room-state, device-authorization, envelope, replay, or key-installation
failure now clears and zeroizes the coordinator's current room key, completes
pending joins with the actual error, installs the quarantine path where a room
exists, and explicitly disables microphone, camera, screen video, and screen
audio publication. A previously completed key future cannot be reused after
failure. Publication controls independently require the local frame cryptor to
be ready and non-failed before they can unmute the microphone or enable camera,
screen video, or screen audio, so a later UI action cannot re-enable media
after quarantine. A focused truth-table regression test covers every
ready/failed combination.

The application also generation-binds the full asynchronous join pipeline,
not only key coordination. After every realtime join, key wait, local capture,
credential fetch, and LiveKit connection boundary it confirms that the same
realtime client, server, deck, and join generation remain active. Leaving,
switching servers, disconnecting realtime, or starting a replacement join
supersedes old work. Realtime disconnect cleanup is serialized and must stop
publication and local capture before a later join can proceed.

Unit and integration tests cover two-device key agreement and rotation,
deterministic leadership, membership epochs, key substitution, stale state,
signed relay, replay, cross-room delivery, wrong recipients, and ciphertext
tampering. A generation-bound coordinator now prevents an asynchronous key
exchange from installing a stale key after the client leaves or switches
rooms. Active room membership also excludes banned accounts directly in its
database query, in addition to session invalidation, socket disconnection, and
epoch rotation. The client exposes `Establishing encryption`,
`End-to-end encrypted`, and `Encryption failed` states.

The backend coordination is deployed to Unraid. The active LiveKit
configuration was verified on 2026-07-24 with authenticated TURN enabled on
UDP `443`, and the host has an active LiveKit UDP `443` listener. Client frame
encryption has not passed a native two-client media test,
RTP/SFU inspection, packet inspection, Windows validation, or independent
review. The current production deployment therefore must still be described
as transport-encrypted rather than E2EE.

Last updated: 2026-07-24.

## Security Goals

- Every published media frame is encrypted by a Yappa client before LiveKit's
  SFU receives it.
- Only currently authorized devices in the voice deck possess the room key.
- The Yappa backend and LiveKit never receive a plaintext room key.
- A server cannot silently disable frame encryption or substitute device keys.
- Joining, leaving, banning, revoking a device, and reconnecting have explicit
  epoch and rotation behavior.
- A captured key envelope cannot be replayed into another server, deck,
  device, or epoch.
- Failure to establish verified E2EE prevents media publication and is visible
  to the user.
- A delayed join cannot publish after the user leaves, changes servers, loses
  realtime coordination, or begins joining another deck.

This design does not hide connection metadata, participant membership, timing,
or media sizes from the self-hosted services. It cannot protect a conversation
after an authorized endpoint is compromised.

## Cryptographic Building Blocks

Use the audited implementations supplied by Dart `cryptography` and LiveKit:

- Ed25519: existing YUID signing identity and device-key authorization.
- X25519: per-device key agreement.
- HKDF-SHA-256: envelope-key derivation.
- AES-256-GCM: authenticated room-key envelopes.
- 256-bit random LiveKit room keys.
- LiveKit frame E2EE `EncryptionType.kGcm` with a raw shared key.

Do not replace these with custom ciphers, XOR, password-derived room keys, a
server-known secret, or deterministic keys derived from public metadata.

## Device Identity

Each installation creates one X25519 media-encryption key pair in OS-backed
secure storage. The private key never leaves the device.

During the existing YUID challenge flow, the client signs:

```text
yappa-media-device-v1
| server_id
| normalized_username
| challenge_nonce
| media_public_key
| device_instance_id
```

The backend verifies this with the already authenticated YUID Ed25519 public
key. It stores the media public key, device instance id, YUID authorization
signature, and revocation timestamps as public device metadata. Sessions bind
to a device record. A new device does not overwrite another device's key.

Clients accept a peer media key only when its YUID authorization verifies and
the backend associates that device with a current, non-banned member and active
session. Key changes create a new device identity; they are never silently
treated as the old device.

## Room and Epoch Model

The cryptographic room id is:

```text
server_id | voice_channel_id
```

Each active room has a monotonically increasing 64-bit epoch. The elected key
leader is the lexicographically smallest active device id using
locale-independent ASCII/code-point ordering. Leadership is only coordination;
it grants no additional decryption privilege.

- The first device creates epoch 1 and a random 256-bit room key.
- A joining device receives the current key in a sealed envelope. If its
  lexicographically smaller id changes the deterministic leader, the room
  rotates immediately instead.
- Removal, ban, device revocation, or an intentional hard rotation creates a
  new random key and increments the epoch.
- A normal transient reconnect may recover the current epoch after its device
  identity and room membership are revalidated.
- A leader departure elects the next device, which immediately creates a new
  key and epoch.
- Old keys remain only for LiveKit's bounded transition window and are erased
  from application memory as soon as the switch is complete.

The server may assign and broadcast membership sequence numbers, but it cannot
choose room-key bytes.

## Sealed Key Envelope

For each recipient, the sender creates an ephemeral X25519 key pair and derives:

```text
shared_secret = X25519(ephemeral_private, recipient_media_public)
salt = SHA-256("yappa-media-envelope-v1" | server_id | channel_id | epoch)
info = sender_device_id | recipient_device_id
envelope_key = HKDF-SHA-256(shared_secret, salt, info, 32)
```

AES-256-GCM encrypts:

```text
room_key | key_index | created_at
```

with a fresh 96-bit nonce. Associated data binds:

```text
protocol_version
server_id
channel_id
epoch
sender_device_id
recipient_device_id
sender_ephemeral_public_key
```

The sender signs the complete envelope (including ciphertext, nonce, and tag)
with its YUID Ed25519 key. The recipient verifies the YUID-authorized sender
device, signature, exact recipient id, current membership, epoch, and monotonic
message id before decrypting.

The backend relays the envelope to the recipient's authenticated socket. It
stores no plaintext key and should not persist envelopes beyond a short bounded
reconnect window.

## LiveKit Integration

The local client now performs the following before `Room.connect`:

1. Create a non-shared `BaseKeyProvider` with frame discard enabled until
   ready. Each verified LiveKit device identity receives the same room key in
   its own participant slot so key-index transitions work with the pinned SDK.
2. Install the current raw room key at the selected key index for every
   verified participant device.
3. Construct `RoomOptions(encryption: E2EEOptions(...))`.
4. Refuse a successful join until LiveKit reports the local microphone frame
   cryptor at `kOk`/`kKeyRatcheted`. Missing-key, encryption, decryption, or
   internal failures stop microphone, camera, screen video, and screen audio.
   Coordination verification failures take the same fail-closed publication
   path and zeroize the coordinator key. Automated tests cover this key
   invalidation and quarantine callback; native two-client runtime validation
   of cryptor events remains required.

The same provider protects microphone, camera, screen video, and screen audio.
If LiveKit data packets are used for sensitive Yappa payloads, confirm that the
selected SDK version encrypts them or encrypt those payloads separately.

The UI has three explicit states:

- `Establishing E2EE` — joined for coordination but media cannot publish.
- `End-to-end encrypted` — current epoch installed and frame cryptors active.
- `Encryption failed` — media stopped; retry or leave is required.

There is no transport-only fallback button for a normal production room.

## Backend Responsibilities

The backend may:

- authenticate devices and store public device metadata;
- authorize current deck membership;
- assign bounded membership sequence numbers;
- elect/broadcast the deterministic leader;
- relay signed encrypted envelopes to a specific active device;
- expire queued envelopes and reject stale epochs;
- audit non-secret protocol events without keys or ciphertext bodies.

The backend must never:

- generate or receive a room key;
- accept an unsigned device encryption key;
- broadcast an envelope outside its exact room/recipient;
- allow a banned/revoked device to request or receive envelopes;
- log public-key signatures, ciphertext envelopes, or key material.

## Recovery Boundaries

Media keys are intentionally ephemeral and are not backed up. Losing a device
key requires registering a new device and receiving a fresh current-room
envelope. Account recovery does not recover past calls. This boundary must not
be weakened to make recovery appear seamless.

## Verification and Release Gate

Completion requires:

1. Unit vectors for device authorization, X25519/HKDF/AES-GCM envelopes,
   signature validation, associated-data tamper rejection, wrong-recipient
   rejection, replay rejection, and epoch changes.
2. Backend authorization tests for cross-room, logged-out, banned, revoked,
   stale-session, and non-recipient envelope operations.
3. Two-device tests for first join, second join, leader change, leave, ban,
   reconnect, simultaneous join, rotation, and failed verification.
4. Microphone, camera, screen video, and screen audio tests with no key and with
   a wrong key proving that plaintext does not render.
5. LiveKit/SFU inspection proving it cannot decode recorded RTP payloads.
6. Packet inspection proving room keys never traverse backend or LiveKit APIs
   in plaintext.
7. Linux and Windows runtime validation.
8. Independent cryptographic and protocol review.

Only after these gates pass may the client label calls as end-to-end encrypted
without qualification.
