import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import 'media_device_identity_service.dart';
import 'mls_native.dart';
import 'secret_storage.dart';
import 'yuid_identity_service.dart';

typedef MlsSupportDirectoryProvider = Future<Directory> Function();

class MlsLocalStateException implements Exception {
  final String message;

  const MlsLocalStateException(this.message);

  @override
  String toString() => message;
}

class MlsLocalDevice {
  static const _wrappingKeyPrefix = 'yappa.mls_wrapping_key.v1.';

  final String serverId;
  final String yuid;
  final String deviceId;
  final Uint8List identity;
  MlsNativeDevice native;
  final Uint8List _wrappingKey;
  final Uint8List _stateContext;
  final File _stateFile;
  final File _pendingFile;
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  MlsLocalDevice._({
    required this.serverId,
    required this.yuid,
    required this.deviceId,
    required this.identity,
    required this.native,
    required Uint8List wrappingKey,
    required Uint8List stateContext,
    required File stateFile,
    required File pendingFile,
  }) : _wrappingKey = wrappingKey,
       _stateContext = stateContext,
       _stateFile = stateFile,
       _pendingFile = pendingFile;

  static Future<MlsLocalDevice> open({
    required String serverId,
    SecretStorage secretStorage = const OsSecretStorage(),
    MediaDeviceIdentityService? mediaDeviceIdentity,
    YuidIdentityService? yuidIdentity,
    MlsSupportDirectoryProvider supportDirectory =
        getApplicationSupportDirectory,
  }) async {
    final normalizedServerId = serverId.trim();
    if (normalizedServerId.isEmpty || normalizedServerId.length > 256) {
      throw const MlsLocalStateException('Invalid MLS server identity.');
    }
    final mediaService =
        mediaDeviceIdentity ??
        MediaDeviceIdentityService(secretStorage: secretStorage);
    final yuidService =
        yuidIdentity ?? YuidIdentityService(secretStorage: secretStorage);
    final media = await mediaService.getOrCreateIdentity();
    final account = await yuidService.getOrCreateIdentity();
    final scope = sha256
        .convert(utf8.encode('$normalizedServerId|${media.deviceId}'))
        .toString();
    final directory = Directory(
      '${(await supportDirectory()).path}${Platform.pathSeparator}'
      'mls${Platform.pathSeparator}$scope',
    );
    await directory.create(recursive: true);
    await _restrictDirectory(directory);
    final stateFile = File(
      '${directory.path}${Platform.pathSeparator}state.v1.bin',
    );
    final pendingFile = File('${stateFile.path}.pending');
    final previousFile = File('${stateFile.path}.previous');
    final wrappingKeyName = '$_wrappingKeyPrefix$scope';
    final storedKey = await secretStorage.read(wrappingKeyName);
    final stateExists = await stateFile.exists();
    final pendingExists = await pendingFile.exists();
    final previousExists = await previousFile.exists();

    if (storedKey == null && (stateExists || pendingExists || previousExists)) {
      throw const MlsLocalStateException(
        'Encrypted MLS state exists but its OS-protected key is missing.',
      );
    }

    final stateContext = _lengthPrefixed([
      utf8.encode('yappa-mls-state-context-v1'),
      utf8.encode(normalizedServerId),
      utf8.encode(media.deviceId),
    ]);
    final identity = credentialIdentity(
      serverId: normalizedServerId,
      yuid: account.yuid,
      deviceId: media.deviceId,
    );

    late final Uint8List wrappingKey;
    late final MlsNativeDevice native;
    if (storedKey != null) {
      wrappingKey = _decodeKey(storedKey);
      final source = pendingExists
          ? pendingFile
          : stateExists
          ? stateFile
          : previousFile;
      if (!await source.exists()) {
        wrappingKey.fillRange(0, wrappingKey.length, 0);
        throw const MlsLocalStateException(
          'The MLS wrapping key exists but encrypted state is missing.',
        );
      }
      final encrypted = await source.readAsBytes();
      native = MlsNativeDevice.restore(
        wrappingKey: wrappingKey,
        context: stateContext,
        encryptedState: encrypted,
      );
      if (source.path != stateFile.path) {
        if (await stateFile.exists()) {
          await stateFile.delete();
        }
        await source.rename(stateFile.path);
        await _restrictFile(stateFile);
      }
      if (await previousFile.exists()) {
        await previousFile.delete();
      }
    } else {
      wrappingKey = Uint8List.fromList(
        await SecretKeyData.random(length: 32).extractBytes(),
      );
      native = MlsNativeDevice.create(identity);
      final encrypted = native.exportState(
        wrappingKey: wrappingKey,
        context: stateContext,
      );
      await _writeAndFlush(pendingFile, encrypted);
      await _restrictFile(pendingFile);
      try {
        await secretStorage.write(
          wrappingKeyName,
          base64Url.encode(wrappingKey).replaceAll('=', ''),
        );
        await pendingFile.rename(stateFile.path);
        await _restrictFile(stateFile);
      } catch (_) {
        native.close();
        wrappingKey.fillRange(0, wrappingKey.length, 0);
        rethrow;
      }
    }

    return MlsLocalDevice._(
      serverId: normalizedServerId,
      yuid: account.yuid,
      deviceId: media.deviceId,
      identity: identity,
      native: native,
      wrappingKey: wrappingKey,
      stateContext: stateContext,
      stateFile: stateFile,
      pendingFile: pendingFile,
    );
  }

  Future<T> mutate<T>(T Function(MlsNativeDevice native) operation) {
    return _exclusive(() async {
      _ensureOpen();
      final snapshot = native.exportState(
        wrappingKey: _wrappingKey,
        context: _stateContext,
      );
      late final T value;
      try {
        value = operation(native);
      } catch (_) {
        native.close();
        try {
          native = MlsNativeDevice.restore(
            wrappingKey: _wrappingKey,
            context: _stateContext,
            encryptedState: snapshot,
          );
        } catch (_) {
          _wrappingKey.fillRange(0, _wrappingKey.length, 0);
          _closed = true;
          rethrow;
        } finally {
          snapshot.fillRange(0, snapshot.length, 0);
        }
        rethrow;
      }
      snapshot.fillRange(0, snapshot.length, 0);
      try {
        await _persist();
      } catch (_) {
        native.close();
        _wrappingKey.fillRange(0, _wrappingKey.length, 0);
        _closed = true;
        rethrow;
      }
      return value;
    });
  }

  Future<T> read<T>(T Function(MlsNativeDevice native) operation) {
    return _exclusive(() async {
      _ensureOpen();
      return operation(native);
    });
  }

  Future<void> close() {
    return _exclusive(() async {
      if (_closed) return;
      native.close();
      _wrappingKey.fillRange(0, _wrappingKey.length, 0);
      _closed = true;
    });
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    final previous = _tail;
    final complete = Completer<void>();
    _tail = complete.future;
    await previous;
    try {
      return await operation();
    } finally {
      complete.complete();
    }
  }

  Future<void> _persist() async {
    final encrypted = native.exportState(
      wrappingKey: _wrappingKey,
      context: _stateContext,
    );
    await _writeAndFlush(_pendingFile, encrypted);
    await _restrictFile(_pendingFile);
    if (await _stateFile.exists()) {
      final backup = File('${_stateFile.path}.previous');
      if (await backup.exists()) {
        await backup.delete();
      }
      await _stateFile.rename(backup.path);
      try {
        await _pendingFile.rename(_stateFile.path);
        await _restrictFile(_stateFile);
        await backup.delete();
      } catch (_) {
        if (!await _stateFile.exists() && await backup.exists()) {
          await backup.rename(_stateFile.path);
        }
        rethrow;
      }
    } else {
      await _pendingFile.rename(_stateFile.path);
      await _restrictFile(_stateFile);
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw const MlsLocalStateException('The MLS local device is closed.');
    }
  }

  static Uint8List _decodeKey(String value) {
    try {
      final normalized = value.padRight(
        value.length + ((4 - value.length % 4) % 4),
        '=',
      );
      final decoded = Uint8List.fromList(base64Url.decode(normalized));
      if (decoded.length != 32) throw const FormatException();
      return decoded;
    } catch (_) {
      throw const MlsLocalStateException(
        'The OS-protected MLS wrapping key is invalid.',
      );
    }
  }

  static Uint8List _lengthPrefixed(List<List<int>> values) {
    final output = BytesBuilder(copy: false);
    for (final value in values) {
      final length = ByteData(4)..setUint32(0, value.length);
      output
        ..add(length.buffer.asUint8List())
        ..add(value);
    }
    return output.takeBytes();
  }

  static Uint8List credentialIdentity({
    required String serverId,
    required String yuid,
    required String deviceId,
  }) => _lengthPrefixed([
    utf8.encode('yappa-mls-basic-credential-v1'),
    utf8.encode(serverId),
    utf8.encode(yuid),
    utf8.encode(deviceId),
  ]);

  static Future<void> _writeAndFlush(File file, Uint8List bytes) async {
    final sink = await file.open(mode: FileMode.write);
    try {
      await sink.writeFrom(bytes);
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  static Future<void> _restrictDirectory(Directory directory) async {
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', ['700', directory.path]);
      if (result.exitCode != 0) {
        throw const MlsLocalStateException(
          'Could not protect the local MLS state directory.',
        );
      }
    }
  }

  static Future<void> _restrictFile(File file) async {
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) {
        throw const MlsLocalStateException(
          'Could not protect the encrypted MLS state file.',
        );
      }
    }
  }
}
