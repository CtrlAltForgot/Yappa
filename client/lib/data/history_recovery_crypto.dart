import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const historyRecoveryProtocol = 'yappa-history-recovery-v1';

class HistoryRecoveryContext {
  final String transferId;
  final String serverId;
  final String channelId;
  final String accountYuid;
  final String sourceDeviceId;
  final String destinationDeviceId;
  final String sourceRecoveryPublicKey;
  final String destinationRecoveryPublicKey;
  final int firstServerSequence;
  final int lastServerSequence;
  final int eventCount;

  const HistoryRecoveryContext({
    required this.transferId,
    required this.serverId,
    required this.channelId,
    required this.accountYuid,
    required this.sourceDeviceId,
    required this.destinationDeviceId,
    required this.sourceRecoveryPublicKey,
    required this.destinationRecoveryPublicKey,
    required this.firstServerSequence,
    required this.lastServerSequence,
    required this.eventCount,
  });

  factory HistoryRecoveryContext.fromManifest(Uint8List manifestBytes) {
    try {
      final decoded = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(manifestBytes)) as Map,
      );
      final header = Map<String, dynamic>.from(decoded['header'] as Map);
      if (header['protocol'] != historyRecoveryProtocol) {
        throw const FormatException();
      }
      final context = HistoryRecoveryContext(
        transferId: header['transferId']?.toString() ?? '',
        serverId: header['serverId']?.toString() ?? '',
        channelId: header['channelId']?.toString() ?? '',
        accountYuid: header['accountYuid']?.toString() ?? '',
        sourceDeviceId: header['sourceDeviceId']?.toString() ?? '',
        destinationDeviceId: header['destinationDeviceId']?.toString() ?? '',
        sourceRecoveryPublicKey:
            header['sourceRecoveryPublicKey']?.toString() ?? '',
        destinationRecoveryPublicKey:
            header['destinationRecoveryPublicKey']?.toString() ?? '',
        firstServerSequence: header['firstServerSequence'] is int
            ? header['firstServerSequence'] as int
            : -1,
        lastServerSequence: header['lastServerSequence'] is int
            ? header['lastServerSequence'] as int
            : -1,
        eventCount: header['eventCount'] is int
            ? header['eventCount'] as int
            : -1,
      );
      context.validate();
      return context;
    } catch (_) {
      throw const FormatException(
        'Invalid encrypted-history manifest context.',
      );
    }
  }

  void validate() {
    if (!RegExp(r'^recovery_[A-Za-z0-9_-]{22}$').hasMatch(transferId) ||
        serverId.trim().isEmpty ||
        channelId.trim().isEmpty ||
        !RegExp(r'^[A-Za-z0-9_-]{20}$').hasMatch(accountYuid) ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(sourceDeviceId) ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(destinationDeviceId) ||
        sourceDeviceId == destinationDeviceId ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(sourceRecoveryPublicKey) ||
        !RegExp(
          r'^[A-Za-z0-9_-]{43}$',
        ).hasMatch(destinationRecoveryPublicKey) ||
        firstServerSequence < 1 ||
        lastServerSequence < firstServerSequence ||
        eventCount < 1 ||
        eventCount > lastServerSequence - firstServerSequence + 1) {
      throw const FormatException('Invalid history recovery context.');
    }
  }

  Map<String, dynamic> header({
    required String ephemeralPublicKey,
    required int chunkCount,
  }) => {
    'accountYuid': accountYuid,
    'channelId': channelId,
    'chunkCount': chunkCount,
    'destinationDeviceId': destinationDeviceId,
    'destinationRecoveryPublicKey': destinationRecoveryPublicKey,
    'ephemeralPublicKey': ephemeralPublicKey,
    'eventCount': eventCount,
    'firstServerSequence': firstServerSequence,
    'lastServerSequence': lastServerSequence,
    'protocol': historyRecoveryProtocol,
    'serverId': serverId,
    'sourceDeviceId': sourceDeviceId,
    'sourceRecoveryPublicKey': sourceRecoveryPublicKey,
    'transferId': transferId,
  };
}

class SealedHistoryRecoveryTransfer {
  final Uint8List manifest;
  final String manifestSha256;
  final String yuidSignature;
  final List<Uint8List> chunks;

  const SealedHistoryRecoveryTransfer({
    required this.manifest,
    required this.manifestSha256,
    required this.yuidSignature,
    required this.chunks,
  });
}

class HistoryRecoveryCryptor {
  static const maxCiphertextChunkBytes = 256 * 1024;
  static const _nonceBytes = 12;
  static const _macBytes = 16;
  static const _maxPlaintextChunkBytes =
      maxCiphertextChunkBytes - _nonceBytes - _macBytes;

  final X25519 _agreement = X25519();
  final AesGcm _cipher = AesGcm.with256bits();
  final Hkdf _kdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final Sha256 _hash = Sha256();
  final Ed25519 _signatures = Ed25519();

  Future<SealedHistoryRecoveryTransfer> seal({
    required HistoryRecoveryContext context,
    required Uint8List canonicalRecords,
    required SimplePublicKey destinationRecoveryPublicKey,
    required KeyPair sourceYuidKeyPair,
  }) async {
    context.validate();
    if (canonicalRecords.isEmpty ||
        canonicalRecords.length > 256 * 1024 * 1024 ||
        destinationRecoveryPublicKey.type != KeyPairType.x25519 ||
        !_constantTimeEquals(
          destinationRecoveryPublicKey.bytes,
          _decode(context.destinationRecoveryPublicKey),
        )) {
      throw const FormatException('Invalid history recovery payload.');
    }
    final chunkCount =
        (canonicalRecords.length + _maxPlaintextChunkBytes - 1) ~/
        _maxPlaintextChunkBytes;
    if (chunkCount < 1 || chunkCount > 1024) {
      throw const FormatException('History recovery payload is too large.');
    }

    final ephemeral = await _agreement.newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    final ephemeralText = _encode(ephemeralPublic.bytes);
    final header = context.header(
      ephemeralPublicKey: ephemeralText,
      chunkCount: chunkCount,
    );
    final headerBytes = Uint8List.fromList(utf8.encode(_canonicalJson(header)));
    final headerHash = await _hash.hash(headerBytes);
    final shared = await _agreement.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: destinationRecoveryPublicKey,
    );
    final transferKey = await _deriveTransferKey(
      sharedSecret: shared,
      headerHash: headerHash.bytes,
    );
    final chunks = <Uint8List>[];
    final chunkMetadata = <Map<String, dynamic>>[];
    for (var index = 0; index < chunkCount; index += 1) {
      final start = index * _maxPlaintextChunkBytes;
      final end = (start + _maxPlaintextChunkBytes).clamp(
        0,
        canonicalRecords.length,
      );
      final box = await _cipher.encrypt(
        canonicalRecords.sublist(start, end),
        secretKey: transferKey,
        aad: _chunkAad(
          headerHash: headerHash.bytes,
          transferId: context.transferId,
          index: index,
          count: chunkCount,
        ),
      );
      final complete =
          Uint8List(
              box.nonce.length + box.cipherText.length + box.mac.bytes.length,
            )
            ..setRange(0, box.nonce.length, box.nonce)
            ..setRange(
              box.nonce.length,
              box.nonce.length + box.cipherText.length,
              box.cipherText,
            )
            ..setRange(
              box.nonce.length + box.cipherText.length,
              box.nonce.length + box.cipherText.length + box.mac.bytes.length,
              box.mac.bytes,
            );
      final digest = await _hash.hash(complete);
      chunks.add(complete);
      chunkMetadata.add({
        'ciphertextSha256': _hex(digest.bytes),
        'index': index,
        'sizeBytes': complete.length,
      });
    }
    final manifestMap = {
      'chunks': chunkMetadata,
      'header': header,
      'headerSha256': _hex(headerHash.bytes),
    };
    final manifest = Uint8List.fromList(
      utf8.encode(_canonicalJson(manifestMap)),
    );
    final manifestHash = await _hash.hash(manifest);
    final signature = await _signatures.sign(
      manifestHash.bytes,
      keyPair: sourceYuidKeyPair,
    );
    return SealedHistoryRecoveryTransfer(
      manifest: manifest,
      manifestSha256: _hex(manifestHash.bytes),
      yuidSignature: _encode(signature.bytes),
      chunks: List.unmodifiable(chunks),
    );
  }

  Future<Uint8List> open({
    required HistoryRecoveryContext expectedContext,
    required SealedHistoryRecoveryTransfer transfer,
    required KeyPair destinationRecoveryKeyPair,
    required SimplePublicKey authorizedSourceYuidPublicKey,
  }) async {
    expectedContext.validate();
    if (authorizedSourceYuidPublicKey.type != KeyPairType.ed25519 ||
        transfer.manifest.isEmpty ||
        transfer.chunks.isEmpty ||
        transfer.chunks.length > 1024) {
      throw const FormatException('Invalid history recovery transfer.');
    }
    final manifestHash = await _hash.hash(transfer.manifest);
    if (_hex(manifestHash.bytes) != transfer.manifestSha256) {
      throw SecretBoxAuthenticationError();
    }
    final signatureValid = await _signatures.verify(
      manifestHash.bytes,
      signature: Signature(
        _decode(transfer.yuidSignature),
        publicKey: authorizedSourceYuidPublicKey,
      ),
    );
    if (!signatureValid) {
      throw SecretBoxAuthenticationError();
    }
    final decoded = jsonDecode(utf8.decode(transfer.manifest));
    if (decoded is! Map) {
      throw const FormatException('Invalid recovery manifest.');
    }
    final manifest = Map<String, dynamic>.from(decoded);
    if (_canonicalJson(manifest) != utf8.decode(transfer.manifest)) {
      throw const FormatException('Recovery manifest is not canonical.');
    }
    final header = Map<String, dynamic>.from(manifest['header'] as Map);
    final chunksJson = manifest['chunks'];
    final chunkCount = (header['chunkCount'] as num?)?.toInt() ?? -1;
    final ephemeralText = header['ephemeralPublicKey']?.toString() ?? '';
    final expectedHeader = expectedContext.header(
      ephemeralPublicKey: ephemeralText,
      chunkCount: chunkCount,
    );
    if (_canonicalJson(header) != _canonicalJson(expectedHeader) ||
        chunksJson is! List ||
        chunksJson.length != chunkCount ||
        transfer.chunks.length != chunkCount) {
      throw const FormatException('Recovery manifest context does not match.');
    }
    final headerBytes = Uint8List.fromList(utf8.encode(_canonicalJson(header)));
    final headerHash = await _hash.hash(headerBytes);
    if (_hex(headerHash.bytes) != manifest['headerSha256']) {
      throw SecretBoxAuthenticationError();
    }
    final ephemeralPublicKey = SimplePublicKey(
      _decode(ephemeralText),
      type: KeyPairType.x25519,
    );
    final shared = await _agreement.sharedSecretKey(
      keyPair: destinationRecoveryKeyPair,
      remotePublicKey: ephemeralPublicKey,
    );
    final transferKey = await _deriveTransferKey(
      sharedSecret: shared,
      headerHash: headerHash.bytes,
    );
    final plaintext = BytesBuilder(copy: false);
    for (var index = 0; index < chunkCount; index += 1) {
      final metadata = Map<String, dynamic>.from(chunksJson[index] as Map);
      final complete = transfer.chunks[index];
      final digest = await _hash.hash(complete);
      if (metadata['index'] != index ||
          metadata['sizeBytes'] != complete.length ||
          metadata['ciphertextSha256'] != _hex(digest.bytes) ||
          complete.length <= _nonceBytes + _macBytes ||
          complete.length > maxCiphertextChunkBytes) {
        throw SecretBoxAuthenticationError();
      }
      final nonce = complete.sublist(0, _nonceBytes);
      final mac = complete.sublist(complete.length - _macBytes);
      final ciphertext = complete.sublist(
        _nonceBytes,
        complete.length - _macBytes,
      );
      plaintext.add(
        await _cipher.decrypt(
          SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
          secretKey: transferKey,
          aad: _chunkAad(
            headerHash: headerHash.bytes,
            transferId: expectedContext.transferId,
            index: index,
            count: chunkCount,
          ),
        ),
      );
    }
    return plaintext.takeBytes();
  }

  Future<SecretKey> _deriveTransferKey({
    required SecretKey sharedSecret,
    required List<int> headerHash,
  }) => _kdf.deriveKey(
    secretKey: sharedSecret,
    nonce: headerHash,
    info: utf8.encode('$historyRecoveryProtocol|transfer-key'),
  );

  Uint8List _chunkAad({
    required List<int> headerHash,
    required String transferId,
    required int index,
    required int count,
  }) {
    final suffix = ByteData(8)
      ..setUint32(0, index, Endian.big)
      ..setUint32(4, count, Endian.big);
    return Uint8List.fromList([
      ...headerHash,
      ...utf8.encode(transferId),
      ...suffix.buffer.asUint8List(),
    ]);
  }

  String _canonicalJson(dynamic value) {
    dynamic normalize(dynamic item) {
      if (item is Map) {
        final keys = item.keys.map((key) => key.toString()).toList()..sort();
        return {for (final key in keys) key: normalize(item[key])};
      }
      if (item is List) {
        return item.map(normalize).toList(growable: false);
      }
      if (item is String || item is int || item is bool || item == null) {
        return item;
      }
      throw const FormatException('Unsupported canonical recovery value.');
    }

    return jsonEncode(normalize(value));
  }

  String _encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  Uint8List _decode(String value) {
    final padding = (4 - value.length % 4) % 4;
    return Uint8List.fromList(
      base64Url.decode(value.padRight(value.length + padding, '=')),
    );
  }

  String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  bool _constantTimeEquals(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var index = 0; index < first.length; index += 1) {
      difference |= first[index] ^ second[index];
    }
    return difference == 0;
  }
}
