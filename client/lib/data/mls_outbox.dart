import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import 'secret_storage.dart';

typedef MlsOutboxDirectoryProvider = Future<Directory> Function();

enum MlsAddOutboxStage { commitPending, commitAccepted, welcomePending }

class MlsAddOutboxEntry {
  final String channelId;
  final String recipientDeviceId;
  final int parentEpoch;
  final int acceptedEpoch;
  final String commitOperationId;
  final String welcomeOperationId;
  final Uint8List commit;
  final Uint8List welcome;
  final MlsAddOutboxStage stage;

  const MlsAddOutboxEntry({
    required this.channelId,
    required this.recipientDeviceId,
    required this.parentEpoch,
    required this.acceptedEpoch,
    required this.commitOperationId,
    required this.welcomeOperationId,
    required this.commit,
    required this.welcome,
    required this.stage,
  });

  MlsAddOutboxEntry welcomePending() => MlsAddOutboxEntry(
    channelId: channelId,
    recipientDeviceId: recipientDeviceId,
    parentEpoch: parentEpoch,
    acceptedEpoch: acceptedEpoch,
    commitOperationId: commitOperationId,
    welcomeOperationId: welcomeOperationId,
    commit: Uint8List.fromList(commit),
    welcome: Uint8List.fromList(welcome),
    stage: MlsAddOutboxStage.welcomePending,
  );

  MlsAddOutboxEntry commitAccepted() => MlsAddOutboxEntry(
    channelId: channelId,
    recipientDeviceId: recipientDeviceId,
    parentEpoch: parentEpoch,
    acceptedEpoch: acceptedEpoch,
    commitOperationId: commitOperationId,
    welcomeOperationId: welcomeOperationId,
    commit: Uint8List.fromList(commit),
    welcome: Uint8List.fromList(welcome),
    stage: MlsAddOutboxStage.commitAccepted,
  );
}

class MlsOutboxException implements Exception {
  final String message;

  const MlsOutboxException(this.message);

  @override
  String toString() => message;
}

class MlsOutbox {
  static const _keyPrefix = 'yappa.mls_outbox_key.v1.';
  static const _maxCiphertextBytes = 300000;
  static final AesGcm _cipher = AesGcm.with256bits();

  final Uint8List _key;
  final Uint8List _aad;
  final File _file;
  final File _pendingFile;

  MlsOutbox._({
    required Uint8List key,
    required Uint8List aad,
    required File file,
  }) : _key = key,
       _aad = aad,
       _file = file,
       _pendingFile = File('${file.path}.pending');

  static Future<MlsOutbox> open({
    required String serverId,
    required String deviceId,
    SecretStorage secretStorage = const OsSecretStorage(),
    MlsOutboxDirectoryProvider supportDirectory =
        getApplicationSupportDirectory,
  }) async {
    if (serverId.trim().isEmpty ||
        serverId.length > 256 ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(deviceId)) {
      throw const MlsOutboxException('Invalid MLS outbox identity.');
    }
    final scope = sha256.convert(utf8.encode('$serverId|$deviceId')).toString();
    final directory = Directory(
      '${(await supportDirectory()).path}${Platform.pathSeparator}'
      'mls${Platform.pathSeparator}$scope',
    );
    await directory.create(recursive: true);
    await _restrictDirectory(directory);
    final file = File(
      '${directory.path}${Platform.pathSeparator}add-outbox.v1.bin',
    );
    final pending = File('${file.path}.pending');
    final keyName = '$_keyPrefix$scope';
    var storedKey = await secretStorage.read(keyName);
    final hasFile = await file.exists() || await pending.exists();
    if (storedKey == null && hasFile) {
      throw const MlsOutboxException(
        'An encrypted MLS outbox exists but its OS-protected key is missing.',
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
    final outbox = MlsOutbox._(
      key: key,
      aad: Uint8List.fromList(
        utf8.encode('yappa-mls-add-outbox-v1|$serverId|$deviceId'),
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

  Future<MlsAddOutboxEntry?> read() async {
    if (!await _file.exists()) return null;
    return _decodeEntry(await _decrypt(await _file.readAsBytes()));
  }

  Future<void> write(MlsAddOutboxEntry entry) async {
    _validateEntry(entry);
    final plaintext = Uint8List.fromList(
      utf8.encode(jsonEncode(_encodeEntry(entry))),
    );
    final nonce = _cipher.newNonce();
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: SecretKey(_key),
      nonce: nonce,
      aad: _aad,
    );
    plaintext.fillRange(0, plaintext.length, 0);
    final bytes = Uint8List.fromList([
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    await _pendingFile.writeAsBytes(bytes, flush: true);
    await _restrictFile(_pendingFile);
    await _decrypt(bytes);
    if (await _file.exists()) await _file.delete();
    await _pendingFile.rename(_file.path);
    await _restrictFile(_file);
  }

  Future<void> clear() async {
    if (await _pendingFile.exists()) await _pendingFile.delete();
    if (await _file.exists()) await _file.delete();
  }

  Future<void> close() async {
    _key.fillRange(0, _key.length, 0);
  }

  Future<Uint8List> _decrypt(List<int> bytes) async {
    if (bytes.length < 12 + 16 || bytes.length > _maxCiphertextBytes) {
      throw const MlsOutboxException('Invalid encrypted MLS outbox.');
    }
    try {
      final nonce = bytes.sublist(0, 12);
      final ciphertext = bytes.sublist(12, bytes.length - 16);
      final mac = Mac(bytes.sublist(bytes.length - 16));
      return Uint8List.fromList(
        await _cipher.decrypt(
          SecretBox(ciphertext, nonce: nonce, mac: mac),
          secretKey: SecretKey(_key),
          aad: _aad,
        ),
      );
    } catch (_) {
      throw const MlsOutboxException(
        'The encrypted MLS outbox failed authentication.',
      );
    }
  }

  static Map<String, Object> _encodeEntry(MlsAddOutboxEntry entry) => {
    'channelId': entry.channelId,
    'recipientDeviceId': entry.recipientDeviceId,
    'parentEpoch': entry.parentEpoch,
    'acceptedEpoch': entry.acceptedEpoch,
    'commitOperationId': entry.commitOperationId,
    'welcomeOperationId': entry.welcomeOperationId,
    'commit': base64Url.encode(entry.commit).replaceAll('=', ''),
    'welcome': base64Url.encode(entry.welcome).replaceAll('=', ''),
    'stage': entry.stage.name,
  };

  static MlsAddOutboxEntry _decodeEntry(Uint8List plaintext) {
    try {
      final json = jsonDecode(utf8.decode(plaintext));
      final map = Map<String, dynamic>.from(json as Map);
      final entry = MlsAddOutboxEntry(
        channelId: map['channelId'] as String,
        recipientDeviceId: map['recipientDeviceId'] as String,
        parentEpoch: map['parentEpoch'] as int,
        acceptedEpoch: map['acceptedEpoch'] as int,
        commitOperationId: map['commitOperationId'] as String,
        welcomeOperationId: map['welcomeOperationId'] as String,
        commit: _decodeBytes(map['commit'] as String),
        welcome: _decodeBytes(map['welcome'] as String),
        stage: MlsAddOutboxStage.values.byName(map['stage'] as String),
      );
      _validateEntry(entry);
      return entry;
    } catch (error) {
      if (error is MlsOutboxException) rethrow;
      throw const MlsOutboxException('Invalid MLS outbox contents.');
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  static void _validateEntry(MlsAddOutboxEntry entry) {
    if ((int.tryParse(entry.channelId) ?? 0) < 1 ||
        !RegExp(
          r'^device_[A-Za-z0-9_-]{24}$',
        ).hasMatch(entry.recipientDeviceId) ||
        entry.parentEpoch < 0 ||
        entry.acceptedEpoch != entry.parentEpoch + 1 ||
        !RegExp(
          r'^mlsop_[A-Za-z0-9_-]{22}$',
        ).hasMatch(entry.commitOperationId) ||
        !RegExp(
          r'^mlsop_[A-Za-z0-9_-]{22}$',
        ).hasMatch(entry.welcomeOperationId) ||
        entry.commitOperationId == entry.welcomeOperationId ||
        entry.commit.isEmpty ||
        entry.commit.length > 131072 ||
        entry.welcome.isEmpty ||
        entry.welcome.length > 131072) {
      throw const MlsOutboxException('Invalid MLS outbox entry.');
    }
  }

  static Uint8List _decodeBytes(String value) {
    final normalized = value.padRight(
      value.length + ((4 - value.length % 4) % 4),
      '=',
    );
    return Uint8List.fromList(base64Url.decode(normalized));
  }

  static Uint8List _decodeKey(String value) {
    try {
      final key = _decodeBytes(value);
      if (key.length != 32) throw const FormatException();
      return key;
    } catch (_) {
      throw const MlsOutboxException('Invalid OS-protected MLS outbox key.');
    }
  }

  static Future<void> _restrictDirectory(Directory directory) async {
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', ['700', directory.path]);
      if (result.exitCode != 0) {
        throw const MlsOutboxException(
          'Could not protect the MLS outbox directory.',
        );
      }
    }
  }

  static Future<void> _restrictFile(File file) async {
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) {
        throw const MlsOutboxException('Could not protect the MLS outbox.');
      }
    }
  }
}
