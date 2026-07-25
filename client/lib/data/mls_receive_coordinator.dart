import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'api_client.dart';
import 'mls_delivery_models.dart';
import 'mls_event_store.dart';
import 'mls_key_package_service.dart';
import 'mls_local_state.dart';
import 'mls_native.dart';
import 'secret_storage.dart';

class MlsReceiveCursor {
  final int sequence;
  final int epoch;
  final bool joined;

  const MlsReceiveCursor({
    required this.sequence,
    required this.epoch,
    required this.joined,
  });
}

class MlsReceiveCursorStore {
  static const _prefix = 'yappa.mls_receive_cursor.v1.';

  final SecretStorage secretStorage;
  final String _key;

  MlsReceiveCursorStore({
    required String serverId,
    required String deviceId,
    required String channelId,
    this.secretStorage = const OsSecretStorage(),
  }) : _key =
           '$_prefix${sha256.convert(utf8.encode('$serverId|$deviceId|$channelId'))}';

  Future<MlsReceiveCursor> read() async {
    final encoded = await secretStorage.read(_key);
    if (encoded == null) {
      return const MlsReceiveCursor(sequence: 0, epoch: 0, joined: false);
    }
    try {
      final json = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
      final sequence = json['sequence'];
      final epoch = json['epoch'];
      final joined = json['joined'];
      if (json['version'] != 1 ||
          sequence is! int ||
          sequence < 0 ||
          epoch is! int ||
          epoch < 0 ||
          joined is! bool ||
          !joined && (sequence != 0 || epoch != 0)) {
        throw const FormatException();
      }
      return MlsReceiveCursor(sequence: sequence, epoch: epoch, joined: joined);
    } catch (_) {
      throw const FormatException('Invalid protected MLS receive cursor.');
    }
  }

  Future<void> write(MlsReceiveCursor cursor) {
    if (cursor.sequence < 0 ||
        cursor.epoch < 0 ||
        !cursor.joined && (cursor.sequence != 0 || cursor.epoch != 0)) {
      throw const FormatException('Invalid MLS receive cursor.');
    }
    return secretStorage.write(
      _key,
      jsonEncode({
        'version': 1,
        'sequence': cursor.sequence,
        'epoch': cursor.epoch,
        'joined': cursor.joined,
      }),
    );
  }
}

class MlsReceiveCoordinator {
  final ApiClient api;
  final MlsLocalDevice localDevice;
  final MlsKeyPackageService keyPackages;
  final MlsReceiveCursorStore cursorStore;
  final MlsEventStore eventStore;
  final String baseUrl;
  final String token;
  final String serverId;
  final String channelId;

  MlsReceiveCoordinator({
    required this.api,
    required this.localDevice,
    required this.keyPackages,
    required this.cursorStore,
    required this.eventStore,
    required this.baseUrl,
    required this.token,
    required this.serverId,
    required this.channelId,
  });

  Uint8List get groupId =>
      Uint8List.fromList(utf8.encode('yappa-text-v1|$serverId|$channelId'));

  Future<void> markLocalFounder() async {
    final cursor = await cursorStore.read();
    if (cursor.joined || cursor.sequence != 0 || cursor.epoch != 0) {
      throw const FormatException('The MLS founder cursor already exists.');
    }
    final localEpoch = await localDevice.read(
      (native) => native.epoch(groupId),
    );
    if (localEpoch != 0) {
      throw const FormatException('The MLS founder must begin at epoch zero.');
    }
    await cursorStore.write(
      const MlsReceiveCursor(sequence: 0, epoch: 0, joined: true),
    );
  }

  Future<MlsReceiveCursor> synchronize({int limit = 100}) async {
    final cursor = await cursorStore.read();
    final batch = await api.fetchMlsDeliveryMessages(
      baseUrl: baseUrl,
      token: token,
      serverId: serverId,
      channelId: channelId,
      after: cursor.sequence,
      limit: limit,
    );
    if (batch.messages.isEmpty) {
      if (cursor.joined) {
        await api.acknowledgeMlsDelivery(
          baseUrl: baseUrl,
          token: token,
          channelId: channelId,
          acknowledgedSequence: cursor.sequence,
          acknowledgedEpoch: cursor.epoch,
        );
      }
      return cursor;
    }

    var joined = cursor.joined;
    var epoch = cursor.epoch;
    var processedSequence = cursor.sequence;
    final directory = await keyPackages.fetchVerifiedDirectory();

    for (final message in batch.messages) {
      if (!joined) {
        if (message.messageClass != MlsDeliveryMessageClass.welcome) {
          continue;
        }
        epoch = await localDevice.mutate((native) {
          int joinedEpoch;
          try {
            joinedEpoch = native.epoch(groupId);
          } on MlsNativeException {
            joinedEpoch = native.joinWelcome(groupId, message.wireMessage);
          }
          if (joinedEpoch != message.acceptedEpoch) {
            throw const FormatException(
              'The MLS Welcome epoch does not match delivery metadata.',
            );
          }
          MlsKeyPackageService.matchAuthorizedMembers(
            native.groupMembers(groupId),
            directory,
          );
          return joinedEpoch;
        });
        joined = true;
      } else {
        switch (message.messageClass) {
          case MlsDeliveryMessageClass.commit:
            epoch = await localDevice.mutate((native) {
              final localEpoch = native.epoch(groupId);
              final next = localEpoch == message.acceptedEpoch
                  ? localEpoch
                  : localEpoch == message.parentEpoch
                  ? native.processCommit(groupId, message.wireMessage)
                  : throw const FormatException(
                      'The local MLS epoch cannot replay this commit.',
                    );
              if (next != message.acceptedEpoch ||
                  message.parentEpoch != epoch) {
                throw const FormatException(
                  'The MLS commit does not match canonical delivery order.',
                );
              }
              MlsKeyPackageService.matchAuthorizedMembers(
                native.groupMembers(groupId),
                directory,
              );
              return next;
            });
          case MlsDeliveryMessageClass.welcome:
            throw const FormatException(
              'An initialized MLS device received an unexpected Welcome.',
            );
          case MlsDeliveryMessageClass.proposal:
            throw const FormatException(
              'Standalone MLS proposals are not supported by this client.',
            );
          case MlsDeliveryMessageClass.application:
            if (message.acceptedEpoch != epoch) {
              throw const FormatException(
                'The MLS application epoch does not match local state.',
              );
            }
            await localDevice.read(
              (native) => MlsKeyPackageService.authenticateMembers(
                native.groupMembers(groupId),
                directory,
              ),
            );
            if (eventStore.containsSequence(message.serverSequence)) {
              await localDevice.mutate(
                (native) => native.clearStagedApplication(
                  groupId,
                  message.serverSequence,
                ),
              );
              processedSequence = message.serverSequence;
              continue;
            }
            late VerifiedMlsDeviceBinding sender;
            final event = await localDevice.mutate((native) {
              final application = native.stageApplication(
                groupId,
                message.serverSequence,
                message.wireMessage,
              );
              sender = directory.firstWhere(
                (binding) => binding.authenticates(application),
                orElse: () => throw const FormatException(
                  'The MLS application sender is not an authorized device.',
                ),
              );
              return MlsApplicationEvent.parse(
                delivery: message,
                application: application,
              );
            });
            await eventStore.apply(event, senderIsOwner: sender.isServerOwner);
            await localDevice.mutate(
              (native) => native.clearStagedApplication(
                groupId,
                message.serverSequence,
              ),
            );
        }
      }
      processedSequence = message.serverSequence;
    }

    if (!joined) {
      // Do not acknowledge commits that preceded this device's Welcome.
      return cursor;
    }
    final nextCursor = MlsReceiveCursor(
      sequence: processedSequence,
      epoch: epoch,
      joined: true,
    );
    await cursorStore.write(nextCursor);
    await api.acknowledgeMlsDelivery(
      baseUrl: baseUrl,
      token: token,
      channelId: channelId,
      acknowledgedSequence: nextCursor.sequence,
      acknowledgedEpoch: nextCursor.epoch,
    );
    return nextCursor;
  }
}
