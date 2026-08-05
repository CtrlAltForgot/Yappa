import 'package:flutter_test/flutter_test.dart';
import 'package:yappa/models/member_model.dart';
import 'package:yappa/models/voice_models.dart';

void main() {
  test('member copy can explicitly remove a profile picture', () {
    const member = Member(
      id: '7',
      username: 'mishka',
      name: 'Mishka',
      avatarUrl: 'data:image/png;base64,old',
      role: 'owner',
      isOnline: true,
      status: 'online',
      voiceChannelId: null,
      voiceJoinedAt: null,
      voiceState: VoicePresenceState.defaults(),
      createdAt: null,
      lastLoginAt: null,
    );

    final updated = member.copyWith(clearAvatarUrl: true);

    expect(updated.avatarUrl, isNull);
    expect(updated.id, member.id);
    expect(updated.isOnline, isTrue);
  });
}
