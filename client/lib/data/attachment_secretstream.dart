import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

const int attachmentSecretstreamChunkBytes = 64 * 1024;

class AttachmentEncryptionContext {
  final String serverId;
  final String channelId;
  final String eventId;
  final String attachmentId;

  const AttachmentEncryptionContext({
    required this.serverId,
    required this.channelId,
    required this.eventId,
    required this.attachmentId,
  });

  Uint8List associatedData(int chunkIndex) {
    if (chunkIndex < 0) {
      throw ArgumentError.value(chunkIndex, 'chunkIndex');
    }
    final values = [
      'yappa-attachment-v1',
      serverId,
      channelId,
      eventId,
      attachmentId,
      chunkIndex.toString(),
    ].map(utf8.encode).toList(growable: false);
    final builder = BytesBuilder(copy: false);
    for (final value in values) {
      final length = ByteData(4)..setUint32(0, value.length, Endian.big);
      builder
        ..add(length.buffer.asUint8List())
        ..add(value);
    }
    return builder.takeBytes();
  }
}

class EncryptedAttachmentObject {
  final String ciphertextPath;
  final Uint8List key;
  final Uint8List header;
  final String ciphertextSha256;
  final int ciphertextSizeBytes;
  final int chunkCount;
  final int plaintextSizeBytes;

  const EncryptedAttachmentObject({
    required this.ciphertextPath,
    required this.key,
    required this.header,
    required this.ciphertextSha256,
    required this.ciphertextSizeBytes,
    required this.chunkCount,
    required this.plaintextSizeBytes,
  });
}

class AttachmentSecretstreamException implements Exception {
  final String message;

  const AttachmentSecretstreamException(this.message);

  @override
  String toString() => message;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    if (value != null) {
      throw StateError('A digest was emitted more than once.');
    }
    value = data;
  }

  @override
  void close() {}
}

typedef _NoArgsNative = Int32 Function();
typedef _NoArgsDart = int Function();
typedef _SizeNative = UintPtr Function();
typedef _SizeDart = int Function();
typedef _KeygenNative = Void Function(Pointer<Uint8>);
typedef _KeygenDart = void Function(Pointer<Uint8>);
typedef _InitPushNative =
    Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _InitPushDart =
    int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _PushNative =
    Int32 Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint64>,
      Pointer<Uint8>,
      Uint64,
      Pointer<Uint8>,
      Uint64,
      Uint8,
    );
typedef _PushDart =
    int Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint64>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      int,
    );
typedef _InitPullNative =
    Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _InitPullDart =
    int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _PullNative =
    Int32 Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint64>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Uint64,
      Pointer<Uint8>,
      Uint64,
    );
typedef _PullDart =
    int Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint64>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
    );
typedef _MemzeroNative = Void Function(Pointer<Void>, UintPtr);
typedef _MemzeroDart = void Function(Pointer<Void>, int);

class _Sodium {
  static final _Sodium instance = _Sodium._();

  late final DynamicLibrary library;
  late final _KeygenDart keygen;
  late final _InitPushDart initPush;
  late final _PushDart push;
  late final _InitPullDart initPull;
  late final _PullDart pull;
  late final _MemzeroDart memzero;
  late final int stateBytes;
  late final int keyBytes;
  late final int headerBytes;
  late final int authenticationBytes;

  _Sodium._() {
    library = _open();
    final initialize = library.lookupFunction<_NoArgsNative, _NoArgsDart>(
      'sodium_init',
    );
    if (initialize() < 0) {
      throw const AttachmentSecretstreamException(
        'The system cryptography library could not initialize.',
      );
    }
    stateBytes = _size('crypto_secretstream_xchacha20poly1305_statebytes');
    keyBytes = _size('crypto_secretstream_xchacha20poly1305_keybytes');
    headerBytes = _size('crypto_secretstream_xchacha20poly1305_headerbytes');
    authenticationBytes = _size('crypto_secretstream_xchacha20poly1305_abytes');
    if (keyBytes != 32 || headerBytes != 24 || authenticationBytes != 17) {
      throw const AttachmentSecretstreamException(
        'The system cryptography library has incompatible secretstream sizes.',
      );
    }
    keygen = library.lookupFunction<_KeygenNative, _KeygenDart>(
      'crypto_secretstream_xchacha20poly1305_keygen',
    );
    initPush = library.lookupFunction<_InitPushNative, _InitPushDart>(
      'crypto_secretstream_xchacha20poly1305_init_push',
    );
    push = library.lookupFunction<_PushNative, _PushDart>(
      'crypto_secretstream_xchacha20poly1305_push',
    );
    initPull = library.lookupFunction<_InitPullNative, _InitPullDart>(
      'crypto_secretstream_xchacha20poly1305_init_pull',
    );
    pull = library.lookupFunction<_PullNative, _PullDart>(
      'crypto_secretstream_xchacha20poly1305_pull',
    );
    memzero = library.lookupFunction<_MemzeroNative, _MemzeroDart>(
      'sodium_memzero',
    );
  }

  int _size(String symbol) =>
      library.lookupFunction<_SizeNative, _SizeDart>(symbol)();

  static DynamicLibrary _open() {
    final names = Platform.isWindows
        ? const ['libsodium.dll']
        : Platform.isMacOS
        ? const ['libsodium.26.dylib', 'libsodium.dylib']
        : const ['libsodium.so.26', 'libsodium.so.23', 'libsodium.so'];
    Object? lastError;
    for (final name in names) {
      try {
        return DynamicLibrary.open(name);
      } catch (error) {
        lastError = error;
      }
    }
    throw AttachmentSecretstreamException(
      'Yappa could not load its secretstream cryptography library: $lastError',
    );
  }
}

class AttachmentSecretstream {
  static const int _tagMessage = 0;
  static const int _tagFinal = 3;

  final _Sodium _sodium;

  AttachmentSecretstream() : _sodium = _Sodium.instance;

  Future<EncryptedAttachmentObject> encryptFile({
    required String plaintextPath,
    required String ciphertextPath,
    required AttachmentEncryptionContext context,
  }) async {
    final input = File(plaintextPath);
    final output = File(ciphertextPath);
    if (await output.exists()) {
      throw const AttachmentSecretstreamException(
        'Refusing to overwrite an existing ciphertext file.',
      );
    }
    final partial = File('$ciphertextPath.partial');
    if (await partial.exists()) {
      throw const AttachmentSecretstreamException(
        'Refusing to overwrite an existing partial ciphertext file.',
      );
    }

    final state = calloc<Uint8>(_sodium.stateBytes);
    final key = calloc<Uint8>(_sodium.keyBytes);
    final header = calloc<Uint8>(_sodium.headerBytes);
    RandomAccessFile? source;
    RandomAccessFile? destination;
    try {
      _sodium.keygen(key);
      if (_sodium.initPush(state, header, key) != 0) {
        throw const AttachmentSecretstreamException(
          'Could not initialize attachment encryption.',
        );
      }
      source = await input.open();
      destination = await partial.open(mode: FileMode.writeOnly);
      final plaintextLength = await source.length();
      var plaintextRead = 0;
      var chunkIndex = 0;
      final digestSink = _DigestSink();
      final digestInput = sha256.startChunkedConversion(digestSink);

      do {
        final message = Uint8List.fromList(
          await source.read(attachmentSecretstreamChunkBytes),
        );
        plaintextRead += message.length;
        final finalChunk = plaintextRead >= plaintextLength;
        final associatedData = context.associatedData(chunkIndex);
        final messagePointer = calloc<Uint8>(message.length);
        final adPointer = calloc<Uint8>(associatedData.length);
        final ciphertextPointer = calloc<Uint8>(
          message.length + _sodium.authenticationBytes,
        );
        final ciphertextLength = calloc<Uint64>();
        try {
          messagePointer.asTypedList(message.length).setAll(0, message);
          adPointer
              .asTypedList(associatedData.length)
              .setAll(0, associatedData);
          final result = _sodium.push(
            state,
            ciphertextPointer,
            ciphertextLength,
            messagePointer,
            message.length,
            adPointer,
            associatedData.length,
            finalChunk ? _tagFinal : _tagMessage,
          );
          if (result != 0) {
            throw const AttachmentSecretstreamException(
              'Attachment encryption failed.',
            );
          }
          final ciphertext = Uint8List.fromList(
            ciphertextPointer.asTypedList(ciphertextLength.value),
          );
          await destination.writeFrom(ciphertext);
          digestInput.add(ciphertext);
        } finally {
          _sodium.memzero(messagePointer.cast(), message.length);
          calloc.free(messagePointer);
          calloc.free(adPointer);
          calloc.free(ciphertextPointer);
          calloc.free(ciphertextLength);
        }
        chunkIndex += 1;
      } while (plaintextRead < plaintextLength);

      digestInput.close();
      await source.close();
      source = null;
      await destination.close();
      destination = null;
      await partial.rename(ciphertextPath);
      final keyBytes = Uint8List.fromList(key.asTypedList(_sodium.keyBytes));
      final headerBytes = Uint8List.fromList(
        header.asTypedList(_sodium.headerBytes),
      );
      final ciphertextSize = await output.length();
      return EncryptedAttachmentObject(
        ciphertextPath: ciphertextPath,
        key: keyBytes,
        header: headerBytes,
        ciphertextSha256: digestSink.value!.toString(),
        ciphertextSizeBytes: ciphertextSize,
        chunkCount: chunkIndex,
        plaintextSizeBytes: plaintextLength,
      );
    } catch (_) {
      await source?.close();
      await destination?.close();
      if (await partial.exists()) {
        await partial.delete();
      }
      rethrow;
    } finally {
      _sodium.memzero(state.cast(), _sodium.stateBytes);
      _sodium.memzero(key.cast(), _sodium.keyBytes);
      _sodium.memzero(header.cast(), _sodium.headerBytes);
      calloc.free(state);
      calloc.free(key);
      calloc.free(header);
    }
  }

  Future<void> decryptFile({
    required String ciphertextPath,
    required String plaintextPath,
    required Uint8List key,
    required Uint8List header,
    required String expectedCiphertextSha256,
    required int expectedChunkCount,
    required AttachmentEncryptionContext context,
  }) async {
    if (key.length != _sodium.keyBytes ||
        header.length != _sodium.headerBytes ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedCiphertextSha256) ||
        expectedChunkCount < 1) {
      throw const AttachmentSecretstreamException(
        'Invalid encrypted attachment metadata.',
      );
    }
    final output = File(plaintextPath);
    if (await output.exists()) {
      throw const AttachmentSecretstreamException(
        'Refusing to overwrite an existing plaintext file.',
      );
    }
    final partial = File('$plaintextPath.partial');
    if (await partial.exists()) {
      throw const AttachmentSecretstreamException(
        'Refusing to overwrite an existing partial plaintext file.',
      );
    }

    final state = calloc<Uint8>(_sodium.stateBytes);
    final keyPointer = calloc<Uint8>(_sodium.keyBytes);
    final headerPointer = calloc<Uint8>(_sodium.headerBytes);
    RandomAccessFile? source;
    RandomAccessFile? destination;
    try {
      keyPointer.asTypedList(key.length).setAll(0, key);
      headerPointer.asTypedList(header.length).setAll(0, header);
      if (_sodium.initPull(state, headerPointer, keyPointer) != 0) {
        throw const AttachmentSecretstreamException(
          'Could not initialize attachment decryption.',
        );
      }
      source = await File(ciphertextPath).open();
      destination = await partial.open(mode: FileMode.writeOnly);
      final totalLength = await source.length();
      final minimumLength = expectedChunkCount * _sodium.authenticationBytes;
      if (totalLength < minimumLength) {
        throw const AttachmentSecretstreamException(
          'Encrypted attachment is truncated.',
        );
      }
      final digestSink = _DigestSink();
      final digestInput = sha256.startChunkedConversion(digestSink);
      var consumed = 0;

      for (var chunkIndex = 0; chunkIndex < expectedChunkCount; chunkIndex++) {
        final chunksAfter = expectedChunkCount - chunkIndex - 1;
        final remaining = totalLength - consumed;
        final ciphertextLength = chunksAfter > 0
            ? attachmentSecretstreamChunkBytes + _sodium.authenticationBytes
            : remaining;
        if (ciphertextLength < _sodium.authenticationBytes) {
          throw const AttachmentSecretstreamException(
            'Encrypted attachment is truncated.',
          );
        }
        final ciphertext = Uint8List.fromList(
          await source.read(ciphertextLength),
        );
        if (ciphertext.length != ciphertextLength) {
          throw const AttachmentSecretstreamException(
            'Encrypted attachment is truncated.',
          );
        }
        consumed += ciphertext.length;
        digestInput.add(ciphertext);
        final associatedData = context.associatedData(chunkIndex);
        final ciphertextPointer = calloc<Uint8>(ciphertext.length);
        final adPointer = calloc<Uint8>(associatedData.length);
        final plaintextPointer = calloc<Uint8>(
          ciphertext.length - _sodium.authenticationBytes,
        );
        final plaintextLength = calloc<Uint64>();
        final tag = calloc<Uint8>();
        try {
          ciphertextPointer
              .asTypedList(ciphertext.length)
              .setAll(0, ciphertext);
          adPointer
              .asTypedList(associatedData.length)
              .setAll(0, associatedData);
          final result = _sodium.pull(
            state,
            plaintextPointer,
            plaintextLength,
            tag,
            ciphertextPointer,
            ciphertext.length,
            adPointer,
            associatedData.length,
          );
          final expectedTag = chunkIndex == expectedChunkCount - 1
              ? _tagFinal
              : _tagMessage;
          if (result != 0 || tag.value != expectedTag) {
            throw const AttachmentSecretstreamException(
              'Encrypted attachment authentication failed.',
            );
          }
          await destination.writeFrom(
            plaintextPointer.asTypedList(plaintextLength.value),
          );
        } finally {
          _sodium.memzero(
            plaintextPointer.cast(),
            ciphertext.length - _sodium.authenticationBytes,
          );
          calloc.free(ciphertextPointer);
          calloc.free(adPointer);
          calloc.free(plaintextPointer);
          calloc.free(plaintextLength);
          calloc.free(tag);
        }
      }
      digestInput.close();
      if (consumed != totalLength ||
          digestSink.value!.toString() != expectedCiphertextSha256) {
        throw const AttachmentSecretstreamException(
          'Encrypted attachment digest verification failed.',
        );
      }
      await source.close();
      source = null;
      await destination.close();
      destination = null;
      await partial.rename(plaintextPath);
    } catch (_) {
      await source?.close();
      await destination?.close();
      if (await partial.exists()) {
        await partial.delete();
      }
      rethrow;
    } finally {
      _sodium.memzero(state.cast(), _sodium.stateBytes);
      _sodium.memzero(keyPointer.cast(), _sodium.keyBytes);
      _sodium.memzero(headerPointer.cast(), _sodium.headerBytes);
      calloc.free(state);
      calloc.free(keyPointer);
      calloc.free(headerPointer);
    }
  }
}
