import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'ed25519_verifier.dart';

const mediaEnvelopeProtocol = 'yappa-media-envelope-v1';

String _encodeBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List _decodeBase64Url(String value) {
  final normalized = value.padRight(
    value.length + ((4 - value.length % 4) % 4),
    '=',
  );
  return Uint8List.fromList(base64Url.decode(normalized));
}

void _addField(BytesBuilder builder, List<int> value) {
  final length = ByteData(4)..setUint32(0, value.length, Endian.big);
  builder
    ..add(length.buffer.asUint8List())
    ..add(value);
}

Uint8List _fields(Iterable<List<int>> values) {
  final builder = BytesBuilder(copy: false);
  for (final value in values) {
    _addField(builder, value);
  }
  return builder.takeBytes();
}

List<int> _text(String value) => utf8.encode(value);

class MediaRoomContext {
  final String serverId;
  final String channelId;
  final int epoch;
  final String senderDeviceId;
  final String recipientDeviceId;

  const MediaRoomContext({
    required this.serverId,
    required this.channelId,
    required this.epoch,
    required this.senderDeviceId,
    required this.recipientDeviceId,
  });

  void validate() {
    if (serverId.isEmpty ||
        channelId.isEmpty ||
        senderDeviceId.isEmpty ||
        recipientDeviceId.isEmpty ||
        epoch < 1) {
      throw const FormatException('Invalid media room envelope context.');
    }
  }

  Uint8List associatedData(List<int> ephemeralPublicKey) {
    validate();
    return _fields([
      _text(mediaEnvelopeProtocol),
      _text(serverId),
      _text(channelId),
      _text(epoch.toString()),
      _text(senderDeviceId),
      _text(recipientDeviceId),
      ephemeralPublicKey,
    ]);
  }
}

class MediaKeyEnvelope {
  final String protocol;
  final String serverId;
  final String channelId;
  final int epoch;
  final int messageSequence;
  final String senderDeviceId;
  final String recipientDeviceId;
  final String ephemeralPublicKey;
  final String nonce;
  final String ciphertext;
  final String authenticationTag;
  final String signature;

  const MediaKeyEnvelope({
    required this.protocol,
    required this.serverId,
    required this.channelId,
    required this.epoch,
    required this.messageSequence,
    required this.senderDeviceId,
    required this.recipientDeviceId,
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.ciphertext,
    required this.authenticationTag,
    required this.signature,
  });

  MediaRoomContext get context => MediaRoomContext(
    serverId: serverId,
    channelId: channelId,
    epoch: epoch,
    senderDeviceId: senderDeviceId,
    recipientDeviceId: recipientDeviceId,
  );

  Map<String, dynamic> toJson() => {
    'protocol': protocol,
    'serverId': serverId,
    'channelId': channelId,
    'epoch': epoch,
    'messageSequence': messageSequence,
    'senderDeviceId': senderDeviceId,
    'recipientDeviceId': recipientDeviceId,
    'ephemeralPublicKey': ephemeralPublicKey,
    'nonce': nonce,
    'ciphertext': ciphertext,
    'authenticationTag': authenticationTag,
    'signature': signature,
  };

  factory MediaKeyEnvelope.fromJson(Map<String, dynamic> json) {
    return MediaKeyEnvelope(
      protocol: json['protocol']?.toString() ?? '',
      serverId: json['serverId']?.toString() ?? '',
      channelId: json['channelId']?.toString() ?? '',
      epoch: (json['epoch'] as num?)?.toInt() ?? 0,
      messageSequence: (json['messageSequence'] as num?)?.toInt() ?? 0,
      senderDeviceId: json['senderDeviceId']?.toString() ?? '',
      recipientDeviceId: json['recipientDeviceId']?.toString() ?? '',
      ephemeralPublicKey: json['ephemeralPublicKey']?.toString() ?? '',
      nonce: json['nonce']?.toString() ?? '',
      ciphertext: json['ciphertext']?.toString() ?? '',
      authenticationTag: json['authenticationTag']?.toString() ?? '',
      signature: json['signature']?.toString() ?? '',
    );
  }

  Uint8List signedPayload() {
    final ephemeral = _decodeBase64Url(ephemeralPublicKey);
    final aad = context.associatedData(ephemeral);
    return _fields([
      aad,
      _decodeBase64Url(nonce),
      _decodeBase64Url(ciphertext),
      _decodeBase64Url(authenticationTag),
      _text(messageSequence.toString()),
    ]);
  }
}

class OpenedMediaRoomKey {
  final Uint8List roomKey;
  final int keyIndex;
  final DateTime createdAt;

  const OpenedMediaRoomKey({
    required this.roomKey,
    required this.keyIndex,
    required this.createdAt,
  });
}

class MediaKeyEnvelopeCryptor {
  final X25519 _agreement = X25519();
  final Ed25519 _signatures = Ed25519();
  final Ed25519Verifier _signatureVerifier = Ed25519Verifier();
  final AesGcm _cipher = AesGcm.with256bits();
  final Hkdf _kdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final Sha256 _hash = Sha256();

  Future<MediaKeyEnvelope> seal({
    required MediaRoomContext context,
    required int messageSequence,
    required Uint8List roomKey,
    required int keyIndex,
    required DateTime createdAt,
    required SimplePublicKey recipientMediaPublicKey,
    required KeyPair senderYuidKeyPair,
  }) async {
    context.validate();
    if (roomKey.length != 32 ||
        keyIndex < 0 ||
        keyIndex > 255 ||
        messageSequence < 1) {
      throw const FormatException('Invalid media room key material.');
    }
    if (recipientMediaPublicKey.type != KeyPairType.x25519) {
      throw const FormatException('Recipient media key must use X25519.');
    }

    final ephemeralKeyPair = await _agreement.newKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();
    final sharedSecret = await _agreement.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientMediaPublicKey,
    );
    final envelopeKey = await _deriveEnvelopeKey(
      context: context,
      sharedSecret: sharedSecret,
    );
    final plaintext = ByteData(44)
      ..buffer.asUint8List(0, 32).setAll(0, roomKey)
      ..setUint32(32, keyIndex, Endian.big)
      ..setInt64(36, createdAt.toUtc().millisecondsSinceEpoch, Endian.big);
    final aad = context.associatedData(ephemeralPublicKey.bytes);
    final secretBox = await _cipher.encrypt(
      plaintext.buffer.asUint8List(),
      secretKey: envelopeKey,
      aad: aad,
    );

    final unsigned = MediaKeyEnvelope(
      protocol: mediaEnvelopeProtocol,
      serverId: context.serverId,
      channelId: context.channelId,
      epoch: context.epoch,
      messageSequence: messageSequence,
      senderDeviceId: context.senderDeviceId,
      recipientDeviceId: context.recipientDeviceId,
      ephemeralPublicKey: _encodeBase64Url(ephemeralPublicKey.bytes),
      nonce: _encodeBase64Url(secretBox.nonce),
      ciphertext: _encodeBase64Url(secretBox.cipherText),
      authenticationTag: _encodeBase64Url(secretBox.mac.bytes),
      signature: '',
    );
    final signature = await _signatures.sign(
      unsigned.signedPayload(),
      keyPair: senderYuidKeyPair,
    );
    return MediaKeyEnvelope(
      protocol: unsigned.protocol,
      serverId: unsigned.serverId,
      channelId: unsigned.channelId,
      epoch: unsigned.epoch,
      messageSequence: unsigned.messageSequence,
      senderDeviceId: unsigned.senderDeviceId,
      recipientDeviceId: unsigned.recipientDeviceId,
      ephemeralPublicKey: unsigned.ephemeralPublicKey,
      nonce: unsigned.nonce,
      ciphertext: unsigned.ciphertext,
      authenticationTag: unsigned.authenticationTag,
      signature: _encodeBase64Url(signature.bytes),
    );
  }

  Future<OpenedMediaRoomKey> open({
    required MediaKeyEnvelope envelope,
    required MediaRoomContext expectedContext,
    required KeyPair recipientMediaKeyPair,
    required SimplePublicKey authorizedSenderYuidPublicKey,
  }) async {
    expectedContext.validate();
    if (envelope.protocol != mediaEnvelopeProtocol ||
        envelope.serverId != expectedContext.serverId ||
        envelope.channelId != expectedContext.channelId ||
        envelope.epoch != expectedContext.epoch ||
        envelope.messageSequence < 1 ||
        envelope.senderDeviceId != expectedContext.senderDeviceId ||
        envelope.recipientDeviceId != expectedContext.recipientDeviceId) {
      throw const FormatException('Media envelope context does not match.');
    }

    final signatureValid = await _signatureVerifier.verify(
      message: envelope.signedPayload(),
      signature: _decodeBase64Url(envelope.signature),
      publicKey: authorizedSenderYuidPublicKey.bytes,
    );
    if (!signatureValid) {
      throw SecretBoxAuthenticationError();
    }

    final ephemeralPublicKey = SimplePublicKey(
      _decodeBase64Url(envelope.ephemeralPublicKey),
      type: KeyPairType.x25519,
    );
    final sharedSecret = await _agreement.sharedSecretKey(
      keyPair: recipientMediaKeyPair,
      remotePublicKey: ephemeralPublicKey,
    );
    final envelopeKey = await _deriveEnvelopeKey(
      context: expectedContext,
      sharedSecret: sharedSecret,
    );
    final plaintext = await _cipher.decrypt(
      SecretBox(
        _decodeBase64Url(envelope.ciphertext),
        nonce: _decodeBase64Url(envelope.nonce),
        mac: Mac(_decodeBase64Url(envelope.authenticationTag)),
      ),
      secretKey: envelopeKey,
      aad: expectedContext.associatedData(ephemeralPublicKey.bytes),
    );
    if (plaintext.length != 44) {
      throw const FormatException('Invalid decrypted media key payload.');
    }
    final bytes = Uint8List.fromList(plaintext);
    final data = ByteData.sublistView(bytes);
    final keyIndex = data.getUint32(32, Endian.big);
    if (keyIndex > 255) {
      throw const FormatException('Invalid media key index.');
    }
    return OpenedMediaRoomKey(
      roomKey: Uint8List.fromList(bytes.sublist(0, 32)),
      keyIndex: keyIndex,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        data.getInt64(36, Endian.big),
        isUtc: true,
      ),
    );
  }

  Future<SecretKey> _deriveEnvelopeKey({
    required MediaRoomContext context,
    required SecretKey sharedSecret,
  }) async {
    final saltMaterial = _fields([
      _text(mediaEnvelopeProtocol),
      _text(context.serverId),
      _text(context.channelId),
      _text(context.epoch.toString()),
    ]);
    final salt = await _hash.hash(saltMaterial);
    final info = _fields([
      _text(context.senderDeviceId),
      _text(context.recipientDeviceId),
    ]);
    return _kdf.deriveKey(
      secretKey: sharedSecret,
      nonce: salt.bytes,
      info: info,
    );
  }
}
