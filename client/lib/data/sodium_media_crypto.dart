import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _SodiumInitNative = Int32 Function();
typedef _SodiumInitDart = int Function();
typedef _RandomBytesNative = Void Function(Pointer<Void>, Size);
typedef _RandomBytesDart = void Function(Pointer<Void>, int);
typedef _ScalarMultNative =
    Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _ScalarMultDart =
    int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _ScalarMultBaseNative = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _ScalarMultBaseDart = int Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _SignSeedKeyPairNative =
    Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _SignSeedKeyPairDart =
    int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _SignDetachedNative =
    Int32 Function(
      Pointer<Uint8>,
      Pointer<Uint64>,
      Pointer<Uint8>,
      Uint64,
      Pointer<Uint8>,
    );
typedef _SignDetachedDart =
    int Function(
      Pointer<Uint8>,
      Pointer<Uint64>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
    );

class SodiumMediaCrypto {
  static SodiumMediaCrypto? _instance;

  final _RandomBytesDart _randomBytes;
  final _ScalarMultDart _scalarMult;
  final _ScalarMultBaseDart _scalarMultBase;
  final _SignSeedKeyPairDart _signSeedKeyPair;
  final _SignDetachedDart _signDetached;

  SodiumMediaCrypto._(
    this._randomBytes,
    this._scalarMult,
    this._scalarMultBase,
    this._signSeedKeyPair,
    this._signDetached,
  );

  static SodiumMediaCrypto? tryLoad() {
    final existing = _instance;
    if (existing != null) return existing;
    for (final name in _libraryNames) {
      try {
        final library = DynamicLibrary.open(name);
        final init = library.lookupFunction<_SodiumInitNative, _SodiumInitDart>(
          'sodium_init',
        );
        if (init() < 0) continue;
        return _instance = SodiumMediaCrypto._(
          library.lookupFunction<_RandomBytesNative, _RandomBytesDart>(
            'randombytes_buf',
          ),
          library.lookupFunction<_ScalarMultNative, _ScalarMultDart>(
            'crypto_scalarmult_curve25519',
          ),
          library.lookupFunction<_ScalarMultBaseNative, _ScalarMultBaseDart>(
            'crypto_scalarmult_curve25519_base',
          ),
          library.lookupFunction<_SignSeedKeyPairNative, _SignSeedKeyPairDart>(
            'crypto_sign_seed_keypair',
          ),
          library.lookupFunction<_SignDetachedNative, _SignDetachedDart>(
            'crypto_sign_detached',
          ),
        );
      } catch (_) {}
    }
    return null;
  }

  ({Uint8List privateKey, Uint8List publicKey}) newX25519KeyPair() {
    final privatePointer = calloc<Uint8>(32);
    final publicPointer = calloc<Uint8>(32);
    try {
      _randomBytes(privatePointer.cast(), 32);
      if (_scalarMultBase(publicPointer, privatePointer) != 0) {
        throw StateError('Could not create a native media envelope key.');
      }
      return (
        privateKey: Uint8List.fromList(privatePointer.asTypedList(32)),
        publicKey: Uint8List.fromList(publicPointer.asTypedList(32)),
      );
    } finally {
      privatePointer.asTypedList(32).fillRange(0, 32, 0);
      calloc.free(privatePointer);
      calloc.free(publicPointer);
    }
  }

  Uint8List sharedSecret({
    required List<int> privateKey,
    required List<int> publicKey,
  }) {
    if (privateKey.length != 32 || publicKey.length != 32) {
      throw const FormatException('Invalid X25519 key material.');
    }
    final privatePointer = calloc<Uint8>(32);
    final publicPointer = calloc<Uint8>(32);
    final outputPointer = calloc<Uint8>(32);
    try {
      privatePointer.asTypedList(32).setAll(0, privateKey);
      publicPointer.asTypedList(32).setAll(0, publicKey);
      if (_scalarMult(outputPointer, privatePointer, publicPointer) != 0) {
        throw const FormatException('Invalid media envelope public key.');
      }
      return Uint8List.fromList(outputPointer.asTypedList(32));
    } finally {
      privatePointer.asTypedList(32).fillRange(0, 32, 0);
      outputPointer.asTypedList(32).fillRange(0, 32, 0);
      calloc.free(privatePointer);
      calloc.free(publicPointer);
      calloc.free(outputPointer);
    }
  }

  Uint8List sign({required List<int> message, required List<int> seed}) {
    if (seed.length != 32) {
      throw const FormatException('Invalid Ed25519 signing seed.');
    }
    final seedPointer = calloc<Uint8>(32);
    final publicPointer = calloc<Uint8>(32);
    final secretPointer = calloc<Uint8>(64);
    final messagePointer = calloc<Uint8>(message.isEmpty ? 1 : message.length);
    final signaturePointer = calloc<Uint8>(64);
    final signatureLengthPointer = calloc<Uint64>();
    try {
      seedPointer.asTypedList(32).setAll(0, seed);
      if (_signSeedKeyPair(publicPointer, secretPointer, seedPointer) != 0) {
        throw StateError('Could not prepare the native signing key.');
      }
      if (message.isNotEmpty) {
        messagePointer.asTypedList(message.length).setAll(0, message);
      }
      if (_signDetached(
            signaturePointer,
            signatureLengthPointer,
            messagePointer,
            message.length,
            secretPointer,
          ) !=
          0) {
        throw StateError('Could not sign the media envelope.');
      }
      return Uint8List.fromList(signaturePointer.asTypedList(64));
    } finally {
      seedPointer.asTypedList(32).fillRange(0, 32, 0);
      secretPointer.asTypedList(64).fillRange(0, 64, 0);
      calloc.free(seedPointer);
      calloc.free(publicPointer);
      calloc.free(secretPointer);
      calloc.free(messagePointer);
      calloc.free(signaturePointer);
      calloc.free(signatureLengthPointer);
    }
  }

  static List<String> get _libraryNames {
    if (Platform.isWindows) return const ['libsodium.dll'];
    if (Platform.isMacOS) {
      return [
        '${File(Platform.resolvedExecutable).parent.path}/'
            '../Frameworks/libsodium.dylib',
        'libsodium.26.dylib',
        'libsodium.dylib',
      ];
    }
    return const ['libsodium.so.26', 'libsodium.so.23', 'libsodium.so'];
  }
}
