import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/sodium_media_crypto.dart';

void main() {
  test('native desktop media crypto signs and agrees on a shared secret', () {
    final sodium = SodiumMediaCrypto.tryLoad();
    expect(sodium, isNotNull);

    final first = sodium!.newX25519KeyPair();
    final second = sodium.newX25519KeyPair();
    final firstShared = sodium.sharedSecret(
      privateKey: first.privateKey,
      publicKey: second.publicKey,
    );
    final secondShared = sodium.sharedSecret(
      privateKey: second.privateKey,
      publicKey: first.publicKey,
    );
    expect(firstShared, secondShared);

    final signature = sodium.sign(
      message: const [1, 2, 3, 4],
      seed: List<int>.generate(32, (index) => index),
    );
    expect(signature, hasLength(64));
  });
}
