import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/data/voice_transport_service.dart';

void main() {
  test('media publication requires a ready non-failed frame cryptor', () {
    expect(
      mediaPublicationAllowed(localE2eeReady: false, e2eeFailed: false),
      false,
    );
    expect(
      mediaPublicationAllowed(localE2eeReady: true, e2eeFailed: true),
      false,
    );
    expect(
      mediaPublicationAllowed(localE2eeReady: false, e2eeFailed: true),
      false,
    );
    expect(
      mediaPublicationAllowed(localE2eeReady: true, e2eeFailed: false),
      true,
    );
  });
}
