import 'dart:ffi';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

typedef _VerifyNative =
    Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Uint64, Pointer<Uint8>);
typedef _VerifyDart =
    int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>);

class Ed25519Verifier {
  final Ed25519 _fallback = Ed25519();
  _VerifyDart? _nativeVerify;
  bool _nativeLookupAttempted = false;

  Future<bool> verify({
    required List<int> message,
    required List<int> signature,
    required List<int> publicKey,
  }) async {
    if (signature.length != 64 || publicKey.length != 32) return false;
    final nativeVerify = _loadNativeVerifier();
    if (nativeVerify != null) {
      final signaturePointer = calloc<Uint8>(signature.length);
      final messagePointer = calloc<Uint8>(
        message.isEmpty ? 1 : message.length,
      );
      final publicKeyPointer = calloc<Uint8>(publicKey.length);
      try {
        signaturePointer.asTypedList(signature.length).setAll(0, signature);
        if (message.isNotEmpty) {
          messagePointer.asTypedList(message.length).setAll(0, message);
        }
        publicKeyPointer.asTypedList(publicKey.length).setAll(0, publicKey);
        return nativeVerify(
              signaturePointer,
              messagePointer,
              message.length,
              publicKeyPointer,
            ) ==
            0;
      } finally {
        calloc.free(signaturePointer);
        calloc.free(messagePointer);
        calloc.free(publicKeyPointer);
      }
    }
    if (kReleaseMode &&
        (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      throw StateError(
        'Yappa could not load its required desktop cryptography runtime.',
      );
    }
    return _fallback.verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  }

  _VerifyDart? _loadNativeVerifier() {
    if (_nativeLookupAttempted) return _nativeVerify;
    _nativeLookupAttempted = true;
    for (final name in _libraryNames) {
      try {
        final library = DynamicLibrary.open(name);
        _nativeVerify = library.lookupFunction<_VerifyNative, _VerifyDart>(
          'crypto_sign_verify_detached',
        );
        return _nativeVerify;
      } catch (_) {}
    }
    return null;
  }

  List<String> get _libraryNames {
    if (Platform.isWindows) return const ['libsodium.dll'];
    if (Platform.isMacOS) {
      return [
        '${File(Platform.resolvedExecutable).parent.path}/'
            '../Frameworks/libsodium.dylib',
        'libsodium.26.dylib',
        'libsodium.dylib',
      ];
    }
    return [
      '${File(Platform.resolvedExecutable).parent.path}/lib/libsodium.so.26',
      'libsodium.so.26',
      'libsodium.so.23',
      'libsodium.so',
    ];
  }
}
