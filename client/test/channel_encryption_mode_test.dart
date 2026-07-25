import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/models/channel_model.dart';

Map<String, dynamic> _channelJson({
  Object? encryptionMode,
  Object? encryptionVersion,
  bool includeEncryptionFields = true,
}) {
  final value = <String, dynamic>{
    'id': '1',
    'serverId': 'node_test',
    'name': 'general',
    'type': 'text',
    'position': 1,
  };
  if (includeEncryptionFields) {
    value['encryptionMode'] = encryptionMode;
    value['encryptionVersion'] = encryptionVersion;
  }
  return value;
}

void main() {
  test('cached pre-migration channels remain explicitly legacy', () {
    final channel = ChatChannel.fromJson(
      _channelJson(includeEncryptionFields: false),
    );
    expect(channel.encryptionMode, ChannelEncryptionMode.legacy);
    expect(channel.encryptionVersion, 0);
    expect(channel.allowsPlaintextMessaging, true);
  });

  test('E2EE and unknown modes never permit plaintext fallback', () {
    final encrypted = ChatChannel.fromJson(
      _channelJson(encryptionMode: 'e2ee', encryptionVersion: 1),
    );
    expect(encrypted.encryptionMode, ChannelEncryptionMode.e2ee);
    expect(encrypted.allowsPlaintextMessaging, false);

    final unknown = ChatChannel.fromJson(
      _channelJson(encryptionMode: 'future-mode', encryptionVersion: 9),
    );
    expect(unknown.encryptionMode, ChannelEncryptionMode.unsupported);
    expect(unknown.allowsPlaintextMessaging, false);

    final malformedLegacy = ChatChannel.fromJson(
      _channelJson(encryptionMode: 'legacy', encryptionVersion: 1),
    );
    expect(malformedLegacy.allowsPlaintextMessaging, false);
  });
}
