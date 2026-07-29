import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import 'mls_delivery_models.dart';
import 'mls_native.dart';
import 'secret_storage.dart';

typedef MlsEventDirectoryProvider = Future<Directory> Function();

class MlsRecoveredSenderAuthorization {
  final bool authorized;
  final bool senderIsOwner;

  const MlsRecoveredSenderAuthorization({
    required this.authorized,
    required this.senderIsOwner,
  });
}

class MlsHistoryRecoveryReceipt {
  final String transferId;
  final String manifestSha256;
  final String sourceDeviceId;
  final String destinationDeviceId;
  final int firstServerSequence;
  final int lastServerSequence;
  final int eventCount;

  const MlsHistoryRecoveryReceipt({
    required this.transferId,
    required this.manifestSha256,
    required this.sourceDeviceId,
    required this.destinationDeviceId,
    required this.firstServerSequence,
    required this.lastServerSequence,
    required this.eventCount,
  });

  void validate() {
    if (!RegExp(r'^recovery_[A-Za-z0-9_-]{22}$').hasMatch(transferId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(manifestSha256) ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(sourceDeviceId) ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(destinationDeviceId) ||
        sourceDeviceId == destinationDeviceId ||
        firstServerSequence < 1 ||
        lastServerSequence < firstServerSequence ||
        eventCount < 1 ||
        eventCount > lastServerSequence - firstServerSequence + 1) {
      throw const FormatException('Invalid history recovery receipt.');
    }
  }
}

class MlsApplicationEvent {
  final int serverSequence;
  final int epoch;
  final String eventId;
  final String channelId;
  final EncryptedApplicationEventKind kind;
  final String? targetEventId;
  final DateTime createdAt;
  final Map<String, dynamic> body;
  final Uint8List senderCredential;
  final Uint8List senderSignaturePublicKey;

  const MlsApplicationEvent({
    required this.serverSequence,
    required this.epoch,
    required this.eventId,
    required this.channelId,
    required this.kind,
    required this.targetEventId,
    required this.createdAt,
    required this.body,
    required this.senderCredential,
    required this.senderSignaturePublicKey,
  });

  static MlsApplicationEvent parse({
    required MlsDeliveryMessage delivery,
    required MlsDecryptedApplication application,
  }) {
    final routing = delivery.event;
    if (routing == null ||
        delivery.messageClass != MlsDeliveryMessageClass.application ||
        application.epoch != delivery.acceptedEpoch ||
        application.plaintext.isEmpty ||
        application.plaintext.length > 256 * 1024) {
      throw const FormatException('Invalid encrypted application event.');
    }
    try {
      final text = utf8.decode(application.plaintext);
      final decoded = jsonDecode(text);
      final json = Map<String, dynamic>.from(decoded as Map);
      const allowed = {
        'protocol',
        'eventId',
        'channelId',
        'kind',
        'targetEventId',
        'createdAt',
        'body',
      };
      if (json.keys.any((key) => !allowed.contains(key)) ||
          json['protocol'] != 'yappa-message-v1' ||
          json['eventId'] != routing.eventId ||
          json['channelId']?.toString() != delivery.channelId ||
          json['kind'] != routing.kind.name ||
          json['targetEventId'] != routing.targetEventId ||
          jsonEncode(json) != text) {
        throw const FormatException();
      }
      final createdAt = DateTime.tryParse(json['createdAt']?.toString() ?? '');
      final body = Map<String, dynamic>.from(json['body'] as Map);
      if (createdAt == null ||
          application.senderCredential.isEmpty ||
          application.senderCredential.length > 1024 ||
          application.senderSignaturePublicKey.length != 32) {
        throw const FormatException();
      }
      _validateBody(routing, body);
      return MlsApplicationEvent(
        serverSequence: delivery.serverSequence,
        epoch: application.epoch,
        eventId: routing.eventId,
        channelId: delivery.channelId,
        kind: routing.kind,
        targetEventId: routing.targetEventId,
        createdAt: createdAt.toUtc(),
        body: body,
        senderCredential: Uint8List.fromList(application.senderCredential),
        senderSignaturePublicKey: Uint8List.fromList(
          application.senderSignaturePublicKey,
        ),
      );
    } catch (_) {
      throw const FormatException('Invalid encrypted application event.');
    }
  }

  static EncryptedApplicationEventRouting routingFromPlaintext({
    required Uint8List plaintext,
    required String channelId,
  }) {
    if (plaintext.isEmpty || plaintext.length > 256 * 1024) {
      throw const FormatException('Invalid encrypted application event.');
    }
    try {
      final text = utf8.decode(plaintext);
      final json = Map<String, dynamic>.from(jsonDecode(text) as Map);
      final eventId = json['eventId']?.toString() ?? '';
      final target = json['targetEventId']?.toString();
      final kind = EncryptedApplicationEventKind.parse(json['kind']);
      final body = Map<String, dynamic>.from(json['body'] as Map);
      final attachments = kind == EncryptedApplicationEventKind.attachment
          ? (body['attachments'] as List)
                .map(
                  (item) =>
                      Map<String, dynamic>.from(item as Map)['id'].toString(),
                )
                .toList(growable: false)
          : const <String>[];
      final routing = EncryptedApplicationEventRouting.fromJson({
        'eventId': eventId,
        'kind': kind.name,
        'targetEventId': target,
        'encryptedAttachmentIds': attachments,
      });
      final synthetic = MlsDeliveryMessage(
        id: 'mls_${'a' * 22}',
        clientOperationId: 'mlsop_${'b' * 22}',
        channelId: channelId,
        serverSequence: 1,
        messageClass: MlsDeliveryMessageClass.application,
        acceptedEpoch: 0,
        parentEpoch: null,
        uploaderUserId: '1',
        uploaderDeviceId: 'device_${'c' * 24}',
        recipientDeviceId: null,
        wireMessage: Uint8List.fromList([1]),
        createdAt: DateTime.utc(2026),
        event: routing,
      );
      parse(
        delivery: synthetic,
        application: MlsDecryptedApplication(
          epoch: 0,
          senderCredential: Uint8List.fromList([1]),
          senderSignaturePublicKey: Uint8List.fromList(List<int>.filled(32, 1)),
          plaintext: plaintext,
        ),
      );
      return routing;
    } catch (_) {
      throw const FormatException('Invalid encrypted application event.');
    }
  }

  static void _validateBody(
    EncryptedApplicationEventRouting routing,
    Map<String, dynamic> body,
  ) {
    bool exact(Set<String> keys) =>
        body.length == keys.length && body.keys.toSet().containsAll(keys);
    switch (routing.kind) {
      case EncryptedApplicationEventKind.message:
      case EncryptedApplicationEventKind.edit:
        if (!exact({'content'}) ||
            body['content'] is! String ||
            (body['content'] as String).trim().isEmpty ||
            (body['content'] as String).length > 4000) {
          throw const FormatException();
        }
      case EncryptedApplicationEventKind.delete:
        if (body.isNotEmpty) throw const FormatException();
      case EncryptedApplicationEventKind.reaction:
        if (!exact({'emoji', 'remove'}) ||
            body['emoji'] is! String ||
            (body['emoji'] as String).isEmpty ||
            (body['emoji'] as String).length > 64 ||
            body['remove'] is! bool) {
          throw const FormatException();
        }
      case EncryptedApplicationEventKind.attachment:
        final keys = body.keys.toSet();
        if (!(keys.length == 1 && keys.contains('attachments')) &&
            !(keys.length == 2 &&
                keys.containsAll({'content', 'attachments'}))) {
          throw const FormatException();
        }
        if (body['attachments'] is! List ||
            (body.containsKey('content') &&
                (body['content'] is! String ||
                    (body['content'] as String).length > 4000))) {
          throw const FormatException();
        }
        final attachments = (body['attachments'] as List)
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList(growable: false);
        if (attachments.isEmpty ||
            attachments.length > 10 ||
            attachments.length != routing.encryptedAttachmentIds.length) {
          throw const FormatException();
        }
        final ids = <String>[];
        for (final item in attachments) {
          const keys = {
            'id',
            'name',
            'mimeType',
            'sizeBytes',
            'key',
            'secretstreamHeader',
            'ciphertextSha256',
            'chunkCount',
          };
          final id = item['id']?.toString() ?? '';
          final name = item['name']?.toString() ?? '';
          final mime = item['mimeType']?.toString() ?? '';
          final size = item['sizeBytes'];
          final chunks = item['chunkCount'];
          if (item.length != keys.length ||
              !item.keys.toSet().containsAll(keys) ||
              !RegExp(r'^eatt_[A-Za-z0-9_-]{22}$').hasMatch(id) ||
              name.isEmpty ||
              name.length > 255 ||
              name.contains('/') ||
              name.contains(r'\') ||
              mime.isEmpty ||
              mime.length > 128 ||
              size is! int ||
              size < 0 ||
              size > 262144000 ||
              chunks is! int ||
              chunks < 1 ||
              !_base64UrlLength(item['key'], 32) ||
              !_base64UrlLength(item['secretstreamHeader'], 24) ||
              !RegExp(
                r'^[a-f0-9]{64}$',
              ).hasMatch(item['ciphertextSha256']?.toString() ?? '')) {
            throw const FormatException();
          }
          ids.add(id);
        }
        if (!_sameStrings(ids, routing.encryptedAttachmentIds)) {
          throw const FormatException();
        }
    }
  }

  static bool _base64UrlLength(dynamic value, int length) {
    if (value is! String || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      return false;
    }
    try {
      final normalized = value.padRight(
        value.length + ((4 - value.length % 4) % 4),
        '=',
      );
      return base64Url.decode(normalized).length == length;
    } catch (_) {
      return false;
    }
  }
}

class MlsEventStore {
  static const _keyPrefix = 'yappa.mls_event_store_key.v1.';
  static const _maxFileBytes = 64 * 1024 * 1024;
  static const _maxEvents = 50000;
  static final AesGcm _cipher = AesGcm.with256bits();

  final Uint8List _key;
  final Uint8List _aad;
  final String _deviceId;
  final String _channelId;
  final File _file;
  final File _pending;
  List<MlsApplicationEvent> _events;
  Map<String, MlsHistoryRecoveryReceipt> _recoveries;

  MlsEventStore._({
    required Uint8List key,
    required Uint8List aad,
    required String deviceId,
    required String channelId,
    required File file,
    required List<MlsApplicationEvent> events,
    required Map<String, MlsHistoryRecoveryReceipt> recoveries,
  }) : _key = key,
       _aad = aad,
       _deviceId = deviceId,
       _channelId = channelId,
       _file = file,
       _pending = File('${file.path}.pending'),
       _events = events,
       _recoveries = recoveries;

  static Future<MlsEventStore> open({
    required String serverId,
    required String deviceId,
    required String channelId,
    SecretStorage secretStorage = const OsSecretStorage(),
    MlsEventDirectoryProvider supportDirectory = getApplicationSupportDirectory,
  }) async {
    if (serverId.trim().isEmpty ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(deviceId) ||
        (int.tryParse(channelId) ?? 0) < 1) {
      throw const FormatException('Invalid MLS event-store identity.');
    }
    final scope = sha256
        .convert(utf8.encode('$serverId|$deviceId|$channelId'))
        .toString();
    final directory = Directory(
      '${(await supportDirectory()).path}${Platform.pathSeparator}'
      'mls${Platform.pathSeparator}$scope',
    );
    await directory.create(recursive: true);
    await _restrictDirectory(directory);
    final file = File(
      '${directory.path}${Platform.pathSeparator}events.v1.bin',
    );
    final pending = File('${file.path}.pending');
    final keyName = '$_keyPrefix$scope';
    var encodedKey = await secretStorage.read(keyName);
    final hasFile = await file.exists() || await pending.exists();
    if (encodedKey == null && hasFile) {
      throw const FormatException(
        'Encrypted MLS history exists but its OS-protected key is missing.',
      );
    }
    if (encodedKey != null && !hasFile) {
      await secretStorage.delete(keyName);
      encodedKey = null;
    }
    final key = encodedKey == null
        ? Uint8List.fromList(
            await SecretKeyData.random(length: 32).extractBytes(),
          )
        : _decodeKey(encodedKey);
    if (encodedKey == null) {
      await secretStorage.write(
        keyName,
        base64Url.encode(key).replaceAll('=', ''),
      );
    }
    final store = MlsEventStore._(
      key: key,
      aad: Uint8List.fromList(
        utf8.encode('yappa-mls-event-store-v1|$serverId|$deviceId|$channelId'),
      ),
      deviceId: deviceId,
      channelId: channelId,
      file: file,
      events: [],
      recoveries: {},
    );
    if (await pending.exists()) {
      final snapshot = await store._decode(await pending.readAsBytes());
      store._events = snapshot.events;
      store._recoveries = snapshot.recoveries;
      if (await file.exists()) await file.delete();
      await pending.rename(file.path);
      await _restrictFile(file);
    } else if (await file.exists()) {
      final snapshot = await store._decode(await file.readAsBytes());
      store._events = snapshot.events;
      store._recoveries = snapshot.recoveries;
    }
    return store;
  }

  List<MlsApplicationEvent> get events => List.unmodifiable(_events);

  List<MlsHistoryRecoveryReceipt> get recoveryReceipts =>
      List.unmodifiable(_recoveries.values);

  bool containsSequence(int sequence) =>
      _events.any((event) => event.serverSequence == sequence);

  Uint8List exportRecoveryRecords({
    required int firstServerSequence,
    required int lastServerSequence,
  }) {
    if (firstServerSequence < 1 || lastServerSequence < firstServerSequence) {
      throw const FormatException('Invalid encrypted-history export range.');
    }
    final selected = _events
        .where(
          (event) =>
              event.serverSequence >= firstServerSequence &&
              event.serverSequence <= lastServerSequence,
        )
        .toList(growable: false);
    if (selected.isEmpty ||
        selected.first.serverSequence != firstServerSequence ||
        selected.last.serverSequence != lastServerSequence) {
      throw const FormatException(
        'Encrypted history is incomplete for that export range.',
      );
    }
    var previous = firstServerSequence - 1;
    for (final event in selected) {
      if (event.serverSequence <= previous || event.channelId != _channelId) {
        throw const FormatException(
          'Encrypted history is incomplete for that export range.',
        );
      }
      previous = event.serverSequence;
    }
    return Uint8List.fromList(
      utf8.encode(
        _canonicalJson({
          'events': selected.map(_encodeEvent).toList(growable: false),
          'protocol': 'yappa-history-records-v1',
        }),
      ),
    );
  }

  Future<bool> mergeRecoveryRecords({
    required Uint8List canonicalRecords,
    required MlsHistoryRecoveryReceipt receipt,
    required Future<MlsRecoveredSenderAuthorization> Function(
      MlsApplicationEvent event,
    )
    authorizeSender,
  }) async {
    receipt.validate();
    if (receipt.destinationDeviceId != _deviceId) {
      throw const FormatException(
        'Encrypted-history receipt targets another device.',
      );
    }
    final priorReceipt = _recoveries[receipt.transferId];
    if (priorReceipt != null) {
      if (_canonicalJson(_encodeReceipt(priorReceipt)) ==
          _canonicalJson(_encodeReceipt(receipt))) {
        return false;
      }
      throw const FormatException(
        'Encrypted-history transfer replay conflicts with its receipt.',
      );
    }
    if (canonicalRecords.isEmpty || canonicalRecords.length > _maxFileBytes) {
      throw const FormatException('Invalid encrypted-history records.');
    }
    final recovered = _decodeRecoveryRecords(
      canonicalRecords,
      firstServerSequence: receipt.firstServerSequence,
      lastServerSequence: receipt.lastServerSequence,
      eventCount: receipt.eventCount,
    );
    final authorization = <int, MlsRecoveredSenderAuthorization>{};
    for (final event in recovered) {
      final result = await authorizeSender(event);
      if (!result.authorized) {
        throw const FormatException(
          'A recovered encrypted-history sender is not authorized.',
        );
      }
      authorization[event.serverSequence] = result;
    }

    final bySequence = <int, MlsApplicationEvent>{
      for (final event in _events) event.serverSequence: event,
    };
    final ids = <String, MlsApplicationEvent>{
      for (final event in _events) event.eventId: event,
    };
    for (final event in recovered) {
      final existingSequence = bySequence[event.serverSequence];
      final existingId = ids[event.eventId];
      if (existingSequence != null &&
          _canonicalJson(_encodeEvent(existingSequence)) !=
              _canonicalJson(_encodeEvent(event))) {
        throw const FormatException(
          'Recovered encrypted-history sequence conflicts with local data.',
        );
      }
      if (existingId != null &&
          existingId.serverSequence != event.serverSequence) {
        throw const FormatException(
          'Recovered encrypted-history event id conflicts with local data.',
        );
      }
      bySequence[event.serverSequence] = event;
      ids[event.eventId] = event;
    }
    final merged = bySequence.values.toList()
      ..sort(
        (first, second) =>
            first.serverSequence.compareTo(second.serverSequence),
      );
    final priorEvents = <String, MlsApplicationEvent>{};
    final recoveredSequences = recovered
        .map((event) => event.serverSequence)
        .toSet();
    for (final event in merged) {
      final target = event.targetEventId == null
          ? null
          : priorEvents[event.targetEventId];
      if (event.targetEventId != null && target == null) {
        throw const FormatException(
          'Recovered encrypted-history mutation target is missing.',
        );
      }
      if (recoveredSequences.contains(event.serverSequence)) {
        _validateMutationAuthorization(
          event,
          target: target,
          senderIsOwner: authorization[event.serverSequence]!.senderIsOwner,
        );
      }
      priorEvents[event.eventId] = event;
    }
    if (merged.length > _maxEvents) {
      throw const FormatException('Encrypted MLS history is full.');
    }
    final recoveries = {..._recoveries, receipt.transferId: receipt};
    await _persist(merged, recoveries: recoveries);
    _events = merged;
    _recoveries = recoveries;
    return true;
  }

  Future<void> apply(
    MlsApplicationEvent event, {
    required bool senderIsOwner,
  }) async {
    _decodeEvent(_encodeEvent(event));
    final existing = _events
        .where((item) => item.serverSequence == event.serverSequence)
        .firstOrNull;
    if (existing != null) {
      if (_canonicalJson(_encodeEvent(existing)) !=
          _canonicalJson(_encodeEvent(event))) {
        throw const FormatException('Conflicting encrypted event sequence.');
      }
      return;
    }
    if (event.channelId != _channelId ||
        _events.length >= _maxEvents ||
        _events.any((item) => item.eventId == event.eventId) ||
        (_events.isNotEmpty &&
            event.serverSequence <= _events.last.serverSequence)) {
      throw const FormatException('Invalid encrypted event ordering.');
    }
    final target = event.targetEventId == null
        ? null
        : _events
              .where((item) => item.eventId == event.targetEventId)
              .firstOrNull;
    _validateMutationAuthorization(
      event,
      target: target,
      senderIsOwner: senderIsOwner,
    );
    final next = [..._events, event];
    await _persist(next);
    _events = next;
  }

  Future<void> close() async {
    _key.fillRange(0, _key.length, 0);
  }

  Future<void> _persist(
    List<MlsApplicationEvent> events, {
    Map<String, MlsHistoryRecoveryReceipt>? recoveries,
  }) async {
    final durableRecoveries = recoveries ?? _recoveries;
    final plaintext = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 2,
          'events': events.map(_encodeEvent).toList(growable: false),
          'recoveries': durableRecoveries.values
              .map(_encodeReceipt)
              .toList(growable: false),
        }),
      ),
    );
    final nonce = _cipher.newNonce();
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: SecretKey(_key),
      nonce: nonce,
      aad: _aad,
    );
    plaintext.fillRange(0, plaintext.length, 0);
    final encrypted = Uint8List.fromList([
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    if (encrypted.length > _maxFileBytes) {
      throw const FormatException('Encrypted MLS history is full.');
    }
    await _pending.writeAsBytes(encrypted, flush: true);
    await _restrictFile(_pending);
    await _decode(encrypted);
    if (await _file.exists()) await _file.delete();
    await _pending.rename(_file.path);
    await _restrictFile(_file);
  }

  Future<_MlsEventStoreSnapshot> _decode(List<int> encrypted) async {
    if (encrypted.length < 28 || encrypted.length > _maxFileBytes) {
      throw const FormatException('Invalid encrypted MLS history.');
    }
    try {
      final plaintext = Uint8List.fromList(
        await _cipher.decrypt(
          SecretBox(
            encrypted.sublist(12, encrypted.length - 16),
            nonce: encrypted.sublist(0, 12),
            mac: Mac(encrypted.sublist(encrypted.length - 16)),
          ),
          secretKey: SecretKey(_key),
          aad: _aad,
        ),
      );
      try {
        final json = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(plaintext)) as Map,
        );
        final rawEvents = json['events'] as List;
        final version = json['version'];
        final rawRecoveries = version == 2
            ? json['recoveries'] as List
            : const [];
        if ((version != 1 && version != 2) ||
            rawEvents.length > _maxEvents ||
            rawRecoveries.length > _maxEvents) {
          throw const FormatException();
        }
        final events = rawEvents
            .map((item) => _decodeEvent(Map<String, dynamic>.from(item as Map)))
            .toList(growable: false);
        var previous = 0;
        final ids = <String>{};
        for (final event in events) {
          if (event.serverSequence <= previous ||
              event.channelId != _channelId ||
              !ids.add(event.eventId)) {
            throw const FormatException();
          }
          previous = event.serverSequence;
        }
        final recoveries = <String, MlsHistoryRecoveryReceipt>{};
        for (final item in rawRecoveries) {
          final receipt = _decodeReceipt(
            Map<String, dynamic>.from(item as Map),
          );
          if (recoveries[receipt.transferId] != null) {
            throw const FormatException();
          }
          recoveries[receipt.transferId] = receipt;
        }
        return _MlsEventStoreSnapshot(events: events, recoveries: recoveries);
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
      }
    } catch (_) {
      throw const FormatException(
        'The encrypted MLS history failed authentication.',
      );
    }
  }

  static Map<String, dynamic> _encodeEvent(MlsApplicationEvent event) => {
    'serverSequence': event.serverSequence,
    'epoch': event.epoch,
    'eventId': event.eventId,
    'channelId': event.channelId,
    'kind': event.kind.name,
    'targetEventId': event.targetEventId,
    'createdAt': event.createdAt.toUtc().toIso8601String(),
    'body': event.body,
    'senderCredential': base64Url
        .encode(event.senderCredential)
        .replaceAll('=', ''),
    'senderSignaturePublicKey': base64Url
        .encode(event.senderSignaturePublicKey)
        .replaceAll('=', ''),
  };

  static MlsApplicationEvent _decodeEvent(Map<String, dynamic> json) {
    const keys = {
      'serverSequence',
      'epoch',
      'eventId',
      'channelId',
      'kind',
      'targetEventId',
      'createdAt',
      'body',
      'senderCredential',
      'senderSignaturePublicKey',
    };
    final sequence = json['serverSequence'];
    final epoch = json['epoch'];
    final eventId = json['eventId']?.toString() ?? '';
    final channelId = json['channelId']?.toString() ?? '';
    final target = json['targetEventId']?.toString();
    final createdAt = DateTime.tryParse(json['createdAt']?.toString() ?? '');
    final senderCredential = _decodeBytes(json['senderCredential']);
    final senderKey = _decodeBytes(json['senderSignaturePublicKey']);
    if (json.length != keys.length ||
        !json.keys.toSet().containsAll(keys) ||
        sequence is! int ||
        sequence < 1 ||
        epoch is! int ||
        epoch < 0 ||
        !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(eventId) ||
        (int.tryParse(channelId) ?? 0) < 1 ||
        target != null && !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(target) ||
        createdAt == null ||
        senderCredential.isEmpty ||
        senderCredential.length > 1024 ||
        senderKey.length != 32) {
      throw const FormatException();
    }
    final kind = EncryptedApplicationEventKind.parse(json['kind']);
    final body = Map<String, dynamic>.from(json['body'] as Map);
    final attachmentIds = kind == EncryptedApplicationEventKind.attachment
        ? (body['attachments'] as List)
              .map(
                (item) =>
                    Map<String, dynamic>.from(item as Map)['id'].toString(),
              )
              .toList(growable: false)
        : const <String>[];
    final routing = EncryptedApplicationEventRouting(
      eventId: eventId,
      kind: kind,
      targetEventId: target,
      encryptedAttachmentIds: attachmentIds,
    );
    MlsApplicationEvent._validateBody(routing, body);
    return MlsApplicationEvent(
      serverSequence: sequence,
      epoch: epoch,
      eventId: eventId,
      channelId: channelId,
      kind: kind,
      targetEventId: target,
      createdAt: createdAt.toUtc(),
      body: body,
      senderCredential: senderCredential,
      senderSignaturePublicKey: senderKey,
    );
  }

  List<MlsApplicationEvent> _decodeRecoveryRecords(
    Uint8List canonicalRecords, {
    required int firstServerSequence,
    required int lastServerSequence,
    required int eventCount,
  }) {
    try {
      final text = utf8.decode(canonicalRecords);
      final json = Map<String, dynamic>.from(jsonDecode(text) as Map);
      if (json.length != 2 ||
          json['protocol'] != 'yappa-history-records-v1' ||
          _canonicalJson(json) != text) {
        throw const FormatException();
      }
      final raw = json['events'] as List;
      if (raw.length != eventCount) {
        throw const FormatException();
      }
      final result = raw
          .map((item) => _decodeEvent(Map<String, dynamic>.from(item as Map)))
          .toList(growable: false);
      var previous = firstServerSequence - 1;
      for (var index = 0; index < result.length; index++) {
        final event = result[index];
        if (event.serverSequence <= previous ||
            event.serverSequence < firstServerSequence ||
            event.serverSequence > lastServerSequence ||
            event.channelId != _channelId) {
          throw const FormatException();
        }
        previous = event.serverSequence;
      }
      if (result.first.serverSequence != firstServerSequence ||
          result.last.serverSequence != lastServerSequence) {
        throw const FormatException();
      }
      return result;
    } catch (_) {
      throw const FormatException('Invalid encrypted-history records.');
    }
  }

  static void _validateMutationAuthorization(
    MlsApplicationEvent event, {
    required MlsApplicationEvent? target,
    required bool senderIsOwner,
  }) {
    final requiresTarget = {
      EncryptedApplicationEventKind.edit,
      EncryptedApplicationEventKind.delete,
      EncryptedApplicationEventKind.reaction,
    }.contains(event.kind);
    if (requiresTarget && (event.targetEventId == null || target == null)) {
      throw const FormatException('Missing encrypted event target.');
    }
    if (event.kind == EncryptedApplicationEventKind.edit &&
        target!.kind != EncryptedApplicationEventKind.message) {
      throw const FormatException('Invalid encrypted edit target.');
    }
    if ((event.kind == EncryptedApplicationEventKind.delete ||
            event.kind == EncryptedApplicationEventKind.reaction) &&
        target!.kind != EncryptedApplicationEventKind.message &&
        target.kind != EncryptedApplicationEventKind.attachment) {
      throw const FormatException('Invalid encrypted mutation target.');
    }
    if (event.kind == EncryptedApplicationEventKind.edit &&
        !_sameBytes(event.senderCredential, target!.senderCredential)) {
      throw const FormatException('Unauthorized encrypted edit.');
    }
    if (event.kind == EncryptedApplicationEventKind.delete &&
        !senderIsOwner &&
        !_sameBytes(event.senderCredential, target!.senderCredential)) {
      throw const FormatException('Unauthorized encrypted delete.');
    }
  }

  static Map<String, dynamic> _encodeReceipt(
    MlsHistoryRecoveryReceipt receipt,
  ) => {
    'destinationDeviceId': receipt.destinationDeviceId,
    'eventCount': receipt.eventCount,
    'firstServerSequence': receipt.firstServerSequence,
    'lastServerSequence': receipt.lastServerSequence,
    'manifestSha256': receipt.manifestSha256,
    'sourceDeviceId': receipt.sourceDeviceId,
    'transferId': receipt.transferId,
  };

  static MlsHistoryRecoveryReceipt _decodeReceipt(Map<String, dynamic> json) {
    if (json.length != 7) throw const FormatException();
    final receipt = MlsHistoryRecoveryReceipt(
      transferId: json['transferId']?.toString() ?? '',
      manifestSha256: json['manifestSha256']?.toString() ?? '',
      sourceDeviceId: json['sourceDeviceId']?.toString() ?? '',
      destinationDeviceId: json['destinationDeviceId']?.toString() ?? '',
      firstServerSequence: json['firstServerSequence'] is int
          ? json['firstServerSequence'] as int
          : -1,
      lastServerSequence: json['lastServerSequence'] is int
          ? json['lastServerSequence'] as int
          : -1,
      eventCount: json['eventCount'] is int ? json['eventCount'] as int : -1,
    );
    receipt.validate();
    return receipt;
  }

  static Uint8List _decodeBytes(dynamic value) {
    final text = value as String;
    return Uint8List.fromList(
      base64Url.decode(
        text.padRight(text.length + ((4 - text.length % 4) % 4), '='),
      ),
    );
  }

  static Uint8List _decodeKey(String value) {
    try {
      final key = _decodeBytes(value);
      if (key.length != 32) throw const FormatException();
      return key;
    } catch (_) {
      throw const FormatException('Invalid OS-protected MLS history key.');
    }
  }

  static Future<void> _restrictDirectory(Directory directory) async {
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', ['700', directory.path]);
      if (result.exitCode != 0) throw const FileSystemException();
    }
  }

  static Future<void> _restrictFile(File file) async {
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) throw const FileSystemException();
    }
  }
}

class _MlsEventStoreSnapshot {
  final List<MlsApplicationEvent> events;
  final Map<String, MlsHistoryRecoveryReceipt> recoveries;

  const _MlsEventStoreSnapshot({
    required this.events,
    required this.recoveries,
  });
}

String _canonicalJson(dynamic value) {
  dynamic normalize(dynamic item) {
    if (item is Map) {
      final keys = item.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: normalize(item[key])};
    }
    if (item is List) return item.map(normalize).toList(growable: false);
    if (item == null || item is String || item is bool || item is int) {
      return item;
    }
    throw const FormatException('Invalid canonical JSON value.');
  }

  return jsonEncode(normalize(value));
}

bool _sameStrings(List<String> first, List<String> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index += 1) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  var difference = 0;
  for (var index = 0; index < first.length; index += 1) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}
