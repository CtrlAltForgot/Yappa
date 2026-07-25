import 'dart:async';

import 'package:path_provider/path_provider.dart';

import 'api_client.dart';
import 'media_device_identity_service.dart';
import 'mls_add_coordinator.dart';
import 'mls_attachment_coordinator.dart';
import 'mls_event_store.dart';
import 'mls_key_package_service.dart';
import 'mls_local_state.dart';
import 'mls_membership_coordinator.dart';
import 'mls_message_projection.dart';
import 'mls_native.dart';
import 'mls_outbox.dart';
import 'mls_receive_coordinator.dart';
import 'mls_send_coordinator.dart';
import 'secret_storage.dart';
import 'yuid_identity_service.dart';
import '../models/message_model.dart';

enum MlsChannelReadiness { waitingForWelcome, waitingForMembership, ready }

class MlsChannelStartup {
  final MlsChannelReadiness readiness;
  final List<String> waitingDeviceIds;

  const MlsChannelStartup({
    required this.readiness,
    this.waitingDeviceIds = const [],
  });
}

class MlsServerRuntime {
  final ApiClient api;
  final String baseUrl;
  final String token;
  final String serverId;
  final MlsLocalDevice localDevice;
  final MlsKeyPackageService keyPackages;
  final MlsOutbox outbox;
  Future<void> _tail = Future<void>.value();
  final Map<String, MlsChannelRuntime> _channels = {};
  bool _closed = false;

  MlsServerRuntime._({
    required this.api,
    required this.baseUrl,
    required this.token,
    required this.serverId,
    required this.localDevice,
    required this.keyPackages,
    required this.outbox,
  });

  static Future<MlsServerRuntime> open({
    required ApiClient api,
    required String baseUrl,
    required String token,
    required String serverId,
    SecretStorage secretStorage = const OsSecretStorage(),
    MediaDeviceIdentityService? mediaDeviceIdentity,
    YuidIdentityService? yuidIdentity,
    MlsSupportDirectoryProvider? supportDirectory,
  }) async {
    final media =
        mediaDeviceIdentity ??
        MediaDeviceIdentityService(secretStorage: secretStorage);
    final yuid =
        yuidIdentity ?? YuidIdentityService(secretStorage: secretStorage);
    final local = await MlsLocalDevice.open(
      serverId: serverId,
      secretStorage: secretStorage,
      mediaDeviceIdentity: media,
      yuidIdentity: yuid,
      supportDirectory: supportDirectory ?? getApplicationSupportDirectory,
    );
    try {
      final outbox = await MlsOutbox.open(
        serverId: serverId,
        deviceId: local.deviceId,
        secretStorage: secretStorage,
        supportDirectory: supportDirectory ?? getApplicationSupportDirectory,
      );
      return MlsServerRuntime._(
        api: api,
        baseUrl: baseUrl,
        token: token,
        serverId: serverId,
        localDevice: local,
        keyPackages: MlsKeyPackageService(
          api: api,
          localDevice: local,
          yuidIdentity: yuid,
          baseUrl: baseUrl,
          token: token,
        ),
        outbox: outbox,
      );
    } catch (_) {
      await local.close();
      rethrow;
    }
  }

  Future<MlsChannelRuntime> openChannel({
    required String channelId,
    required bool currentUserIsOwner,
    SecretStorage secretStorage = const OsSecretStorage(),
    MlsEventDirectoryProvider? eventDirectory,
  }) => _exclusive(() async {
    _ensureOpen();
    final existing = _channels[channelId];
    if (existing != null) return existing;
    final events = await MlsEventStore.open(
      serverId: serverId,
      deviceId: localDevice.deviceId,
      channelId: channelId,
      secretStorage: secretStorage,
      supportDirectory: eventDirectory ?? getApplicationSupportDirectory,
    );
    final add = MlsAddCoordinator(
      localDevice: localDevice,
      outbox: outbox,
      submit: apiMlsDeliverySubmitter(api: api, baseUrl: baseUrl, token: token),
    );
    final sender = MlsSendCoordinator(
      api: api,
      localDevice: localDevice,
      eventStore: events,
      baseUrl: baseUrl,
      token: token,
      serverId: serverId,
      channelId: channelId,
      senderIsOwner: currentUserIsOwner,
    );
    final runtime = MlsChannelRuntime._(
      server: this,
      channelId: channelId,
      currentUserIsOwner: currentUserIsOwner,
      eventStore: events,
      receive: MlsReceiveCoordinator(
        api: api,
        localDevice: localDevice,
        keyPackages: keyPackages,
        cursorStore: MlsReceiveCursorStore(
          serverId: serverId,
          deviceId: localDevice.deviceId,
          channelId: channelId,
          secretStorage: secretStorage,
        ),
        eventStore: events,
        baseUrl: baseUrl,
        token: token,
        serverId: serverId,
        channelId: channelId,
      ),
      membership: MlsMembershipCoordinator.withKeyPackageService(
        localDevice: localDevice,
        addCoordinator: add,
        keyPackages: keyPackages,
        serverId: serverId,
        channelId: channelId,
      ),
      sender: sender,
      attachments: MlsAttachmentCoordinator(
        api: api,
        sender: sender,
        baseUrl: baseUrl,
        token: token,
        serverId: serverId,
        channelId: channelId,
      ),
    );
    _channels[channelId] = runtime;
    return runtime;
  });

  Future<void> close() => _exclusive(() async {
    if (_closed) return;
    _closed = true;
    for (final channel in _channels.values) {
      await channel._close();
    }
    _channels.clear();
    await outbox.close();
    await localDevice.close();
  });

  void _ensureOpen() {
    if (_closed) throw StateError('The MLS server runtime is closed.');
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.catchError((_) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

class MlsChannelRuntime {
  final MlsServerRuntime server;
  final String channelId;
  final bool currentUserIsOwner;
  final MlsEventStore eventStore;
  final MlsReceiveCoordinator receive;
  final MlsMembershipCoordinator membership;
  final MlsSendCoordinator sender;
  final MlsAttachmentCoordinator attachments;
  bool _closed = false;

  MlsChannelRuntime._({
    required this.server,
    required this.channelId,
    required this.currentUserIsOwner,
    required this.eventStore,
    required this.receive,
    required this.membership,
    required this.sender,
    required this.attachments,
  });

  List<MlsApplicationEvent> get events => eventStore.events;

  Future<List<ChatMessage>> projectedMessages() => server._exclusive(() async {
    _ensureOpen();
    final activeDirectory = await server.keyPackages.fetchVerifiedDirectory();
    await server.localDevice.read(
      (native) => MlsKeyPackageService.authenticateMembers(
        native.groupMembers(membership.groupId),
        activeDirectory,
      ),
    );
    final historicalDirectory = await server.keyPackages
        .fetchVerifiedHistoricalDirectory();
    return MlsMessageProjection.project(
      serverId: server.serverId,
      events: eventStore.events,
      directory: historicalDirectory,
    );
  });

  Future<MlsChannelStartup> synchronize() => server._exclusive(() async {
    _ensureOpen();
    await server.keyPackages.replenish();
    var hasGroup = await _hasGroup();
    if (!hasGroup) {
      await receive.synchronize();
      hasGroup = await _hasGroup();
    }
    if (!hasGroup) {
      if (!currentUserIsOwner) {
        return const MlsChannelStartup(
          readiness: MlsChannelReadiness.waitingForWelcome,
        );
      }
      final initialization = await server.api.initializeMlsChannel(
        baseUrl: server.baseUrl,
        token: server.token,
        serverId: server.serverId,
        channelId: channelId,
      );
      if (!initialization.created) {
        return const MlsChannelStartup(
          readiness: MlsChannelReadiness.waitingForWelcome,
        );
      }
      if (initialization.group.initializedByDeviceId !=
              server.localDevice.deviceId ||
          initialization.group.currentEpoch != 0) {
        throw const FormatException(
          'The new MLS channel state has an invalid initializer.',
        );
      }
      await server.localDevice.mutate(
        (native) => native.createGroup(membership.groupId),
      );
      await receive.markLocalFounder();
    }

    await receive.synchronize();
    final result = await membership.reconcile();
    if (!result.complete) {
      return MlsChannelStartup(
        readiness: MlsChannelReadiness.waitingForMembership,
        waitingDeviceIds: result.waitingDeviceIds,
      );
    }
    return const MlsChannelStartup(readiness: MlsChannelReadiness.ready);
  });

  Future<bool> _hasGroup() async {
    try {
      await server.localDevice.read(
        (native) => native.epoch(membership.groupId),
      );
      return true;
    } on MlsNativeException {
      return false;
    }
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await eventStore.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('The MLS channel runtime is closed.');
  }
}
