import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import 'history_recovery_crypto.dart';
import 'secret_storage.dart';

typedef HistoryRecoveryOutboxDirectoryProvider = Future<Directory> Function();

class HistoryRecoveryOutboxEntry {
  final HistoryRecoveryContext context;
  final SealedHistoryRecoveryTransfer sealed;

  const HistoryRecoveryOutboxEntry({
    required this.context,
    required this.sealed,
  });
}

class HistoryRecoveryOutboxException implements Exception {
  final String message;

  const HistoryRecoveryOutboxException(this.message);

  @override
  String toString() => message;
}

class HistoryRecoveryOutbox {
  static const _keyPrefix = 'yappa.history_recovery_outbox_key.v1.';
  static const _maxEncryptedBytes = 96 * 1024 * 1024;
  static final AesGcm _cipher = AesGcm.with256bits();

  final Uint8List _key;
  final Uint8List _aad;
  final File _file;
  final File _pendingFile;

  HistoryRecoveryOutbox._({
    required Uint8List key,
    required Uint8List aad,
    required File file,
  }) : _key = key,
       _aad = aad,
       _file = file,
       _pendingFile = File('${file.path}.pending');

  static Future<HistoryRecoveryOutbox> open({
    required String serverId,
    required String deviceId,
    required String channelId,
    SecretStorage secretStorage = const OsSecretStorage(),
    HistoryRecoveryOutboxDirectoryProvider supportDirectory =
        getApplicationSupportDirectory,
  }) async {
    if (serverId.trim().isEmpty ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(deviceId) ||
        (int.tryParse(channelId) ?? 0) < 1) {
      throw const HistoryRecoveryOutboxException(
        'Invalid encrypted-history outbox identity.',
      );
    }
    final scope = sha256
        .convert(utf8.encode('$serverId|$deviceId|$channelId'))
        .toString();
    final directory = Directory(
      '${(await supportDirectory()).path}${Platform.pathSeparator}'
      'mls${Platform.pathSeparator}$scope',
    );
    await directory.create(recursive: true);
    await _restrictDirectory(directory);
    final file = File(
      '${directory.path}${Platform.pathSeparator}history-recovery-outbox.v1.bin',
    );
    final pending = File('${file.path}.pending');
    final keyName = '$_keyPrefix$scope';
    var storedKey = await secretStorage.read(keyName);
    final hasFile = await file.exists() || await pending.exists();
    if (storedKey == null && hasFile) {
      throw const HistoryRecoveryOutboxException(
        'An encrypted-history outbox exists but its protected key is missing.',
      );
    }
    if (storedKey != null && !hasFile) {
      await secretStorage.delete(keyName);
      storedKey = null;
    }
    final key = storedKey == null
        ? Uint8List.fromList(
            await SecretKeyData.random(length: 32).extractBytes(),
          )
        : _decodeKey(storedKey);
    if (storedKey == null) {
      await secretStorage.write(
        keyName,
        base64Url.encode(key).replaceAll('=', ''),
      );
    }
    final outbox = HistoryRecoveryOutbox._(
      key: key,
      aad: Uint8List.fromList(
        utf8.encode(
          'yappa-history-recovery-outbox-v1|$serverId|$deviceId|$channelId',
        ),
      ),
      file: file,
    );
    if (await pending.exists()) {
      await outbox._decrypt(await pending.readAsBytes());
      if (await file.exists()) await file.delete();
      await pending.rename(file.path);
      await _restrictFile(file);
    } else if (await file.exists()) {
      await outbox._decrypt(await file.readAsBytes());
    }
    return outbox;
  }

  Future<HistoryRecoveryOutboxEntry?> read() async {
    if (!await _file.exists()) return null;
    return _decodeEntry(await _decrypt(await _file.readAsBytes()));
  }

  Future<void> write(HistoryRecoveryOutboxEntry entry) async {
    _validateEntry(entry);
    final plaintext = Uint8List.fromList(
      utf8.encode(jsonEncode(_encodeEntry(entry))),
    );
    try {
      final box = await _cipher.encrypt(
        plaintext,
        secretKey: SecretKey(_key),
        nonce: _cipher.newNonce(),
        aad: _aad,
      );
      final bytes = Uint8List.fromList([
        ...box.nonce,
        ...box.cipherText,
        ...box.mac.bytes,
      ]);
      if (bytes.length > _maxEncryptedBytes) {
        throw const HistoryRecoveryOutboxException(
          'Encrypted-history recovery is too large for the local outbox.',
        );
      }
      await _pendingFile.writeAsBytes(bytes, flush: true);
      await _restrictFile(_pendingFile);
      await _decrypt(bytes);
      if (await _file.exists()) await _file.delete();
      await _pendingFile.rename(_file.path);
      await _restrictFile(_file);
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  Future<void> clear() async {
    if (await _pendingFile.exists()) await _pendingFile.delete();
    if (await _file.exists()) await _file.delete();
  }

  Future<void> close() async {
    _key.fillRange(0, _key.length, 0);
  }

  Future<Uint8List> _decrypt(List<int> bytes) async {
    if (bytes.length < 28 || bytes.length > _maxEncryptedBytes) {
      throw const HistoryRecoveryOutboxException(
        'Invalid encrypted-history outbox.',
      );
    }
    try {
      return Uint8List.fromList(
        await _cipher.decrypt(
          SecretBox(
            bytes.sublist(12, bytes.length - 16),
            nonce: bytes.sublist(0, 12),
            mac: Mac(bytes.sublist(bytes.length - 16)),
          ),
          secretKey: SecretKey(_key),
          aad: _aad,
        ),
      );
    } catch (_) {
      throw const HistoryRecoveryOutboxException(
        'The encrypted-history outbox failed authentication.',
      );
    }
  }

  static Map<String, dynamic> _encodeEntry(HistoryRecoveryOutboxEntry entry) =>
      {
        'context': {
          'accountYuid': entry.context.accountYuid,
          'channelId': entry.context.channelId,
          'destinationDeviceId': entry.context.destinationDeviceId,
          'destinationRecoveryPublicKey':
              entry.context.destinationRecoveryPublicKey,
          'eventCount': entry.context.eventCount,
          'firstServerSequence': entry.context.firstServerSequence,
          'lastServerSequence': entry.context.lastServerSequence,
          'serverId': entry.context.serverId,
          'sourceDeviceId': entry.context.sourceDeviceId,
          'sourceRecoveryPublicKey': entry.context.sourceRecoveryPublicKey,
          'transferId': entry.context.transferId,
        },
        'manifest': _encode(entry.sealed.manifest),
        'manifestSha256': entry.sealed.manifestSha256,
        'yuidSignature': entry.sealed.yuidSignature,
        'chunks': entry.sealed.chunks.map(_encode).toList(growable: false),
        'version': 1,
      };

  static HistoryRecoveryOutboxEntry _decodeEntry(Uint8List plaintext) {
    try {
      final json = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(plaintext)) as Map,
      );
      final contextJson = Map<String, dynamic>.from(json['context'] as Map);
      if (json.length != 6 || json['version'] != 1) {
        throw const FormatException();
      }
      final context = HistoryRecoveryContext(
        transferId: contextJson['transferId']?.toString() ?? '',
        serverId: contextJson['serverId']?.toString() ?? '',
        channelId: contextJson['channelId']?.toString() ?? '',
        accountYuid: contextJson['accountYuid']?.toString() ?? '',
        sourceDeviceId: contextJson['sourceDeviceId']?.toString() ?? '',
        destinationDeviceId:
            contextJson['destinationDeviceId']?.toString() ?? '',
        sourceRecoveryPublicKey:
            contextJson['sourceRecoveryPublicKey']?.toString() ?? '',
        destinationRecoveryPublicKey:
            contextJson['destinationRecoveryPublicKey']?.toString() ?? '',
        firstServerSequence: contextJson['firstServerSequence'] as int,
        lastServerSequence: contextJson['lastServerSequence'] as int,
        eventCount: contextJson['eventCount'] as int,
      );
      final entry = HistoryRecoveryOutboxEntry(
        context: context,
        sealed: SealedHistoryRecoveryTransfer(
          manifest: _decode(json['manifest'] as String),
          manifestSha256: json['manifestSha256'] as String,
          yuidSignature: json['yuidSignature'] as String,
          chunks: (json['chunks'] as List)
              .map((value) => _decode(value as String))
              .toList(growable: false),
        ),
      );
      _validateEntry(entry);
      return entry;
    } catch (error) {
      if (error is HistoryRecoveryOutboxException) rethrow;
      throw const HistoryRecoveryOutboxException(
        'Invalid encrypted-history outbox contents.',
      );
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  static void _validateEntry(HistoryRecoveryOutboxEntry entry) {
    entry.context.validate();
    final sealed = entry.sealed;
    final totalBytes = sealed.chunks.fold<int>(
      0,
      (total, chunk) => total + chunk.length,
    );
    if (sealed.manifest.isEmpty ||
        sealed.manifest.length > 64 * 1024 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sealed.manifestSha256) ||
        !RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(sealed.yuidSignature) ||
        sealed.chunks.isEmpty ||
        sealed.chunks.length > HistoryRecoveryCryptor.maxChunkCount ||
        totalBytes > HistoryRecoveryCryptor.maxCiphertextBytes ||
        sealed.chunks.any(
          (chunk) =>
              chunk.isEmpty ||
              chunk.length > HistoryRecoveryCryptor.maxCiphertextChunkBytes,
        )) {
      throw const HistoryRecoveryOutboxException(
        'Invalid encrypted-history outbox entry.',
      );
    }
  }

  static String _encode(List<int> value) =>
      base64Url.encode(value).replaceAll('=', '');

  static Uint8List _decode(String value) => Uint8List.fromList(
    base64Url.decode(
      value.padRight(value.length + ((4 - value.length % 4) % 4), '='),
    ),
  );

  static Uint8List _decodeKey(String value) {
    try {
      final key = _decode(value);
      if (key.length != 32) throw const FormatException();
      return key;
    } catch (_) {
      throw const HistoryRecoveryOutboxException(
        'Invalid protected encrypted-history outbox key.',
      );
    }
  }

  static Future<void> _restrictDirectory(Directory directory) async {
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', ['700', directory.path]);
      if (result.exitCode != 0) {
        throw const HistoryRecoveryOutboxException(
          'Could not protect the encrypted-history outbox directory.',
        );
      }
    }
  }

  static Future<void> _restrictFile(File file) async {
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) {
        throw const HistoryRecoveryOutboxException(
          'Could not protect the encrypted-history outbox.',
        );
      }
    }
  }
}
