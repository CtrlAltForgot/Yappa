import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

Uint8List _decodeBase64Url(String value, String field) {
  if (value.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw FormatException('Invalid $field encoding.');
  }
  try {
    final normalized = value.padRight(
      value.length + ((4 - value.length % 4) % 4),
      '=',
    );
    return Uint8List.fromList(base64Url.decode(normalized));
  } catch (_) {
    throw FormatException('Invalid $field encoding.');
  }
}

int _nonNegativeInteger(dynamic value, String field) {
  if (value is! num || value.toInt() != value || value < 0) {
    throw FormatException('Invalid $field.');
  }
  return value.toInt();
}

String _requiredString(dynamic value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Invalid $field.');
  }
  return value.trim();
}

enum MlsDeliveryMessageClass {
  proposal,
  commit,
  welcome,
  application;

  static MlsDeliveryMessageClass parse(dynamic value) {
    return switch (value) {
      'proposal' => proposal,
      'commit' => commit,
      'welcome' => welcome,
      'application' => application,
      _ => throw const FormatException('Invalid MLS message class.'),
    };
  }
}

enum EncryptedApplicationEventKind {
  message,
  edit,
  delete,
  reaction,
  attachment;

  static EncryptedApplicationEventKind parse(dynamic value) {
    return switch (value) {
      'message' => message,
      'edit' => edit,
      'delete' => delete,
      'reaction' => reaction,
      'attachment' => attachment,
      _ => throw const FormatException('Invalid encrypted event kind.'),
    };
  }
}

class MlsKeyPackageInventory {
  final String deviceId;
  final int total;
  final int available;

  const MlsKeyPackageInventory({
    required this.deviceId,
    required this.total,
    required this.available,
  });

  factory MlsKeyPackageInventory.fromJson(Map<String, dynamic> json) {
    final deviceId = _requiredString(json['deviceId'], 'device id');
    if (!RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(deviceId)) {
      throw const FormatException('Invalid device id.');
    }
    final total = _nonNegativeInteger(json['total'], 'KeyPackage total');
    final available = _nonNegativeInteger(
      json['available'],
      'KeyPackage available count',
    );
    if (available > total || available > 100 || total > 10000) {
      throw const FormatException('Invalid KeyPackage inventory.');
    }
    return MlsKeyPackageInventory(
      deviceId: deviceId,
      total: total,
      available: available,
    );
  }
}

class MlsKeyPackageRegistration {
  final int ciphersuite;
  final Uint8List signaturePublicKey;
  final Uint8List identityBindingSignature;
  final Uint8List keyPackage;
  final DateTime expiresAt;

  const MlsKeyPackageRegistration({
    required this.ciphersuite,
    required this.signaturePublicKey,
    required this.identityBindingSignature,
    required this.keyPackage,
    required this.expiresAt,
  });

  Map<String, dynamic> toJson() {
    if (ciphersuite != 1 ||
        signaturePublicKey.length != 32 ||
        identityBindingSignature.length != 64 ||
        keyPackage.length < 64 ||
        keyPackage.length > 65536) {
      throw const FormatException('Invalid MLS KeyPackage registration.');
    }
    String encode(List<int> value) =>
        base64Url.encode(value).replaceAll('=', '');
    return {
      'ciphersuite': ciphersuite,
      'signaturePublicKey': encode(signaturePublicKey),
      'identityBindingSignature': encode(identityBindingSignature),
      'keyPackage': encode(keyPackage),
      'expiresAt': expiresAt.toUtc().toIso8601String(),
    };
  }
}

class ClaimedMlsKeyPackage {
  final String id;
  final String deviceId;
  final int ciphersuite;
  final Uint8List signaturePublicKey;
  final Uint8List identityBindingSignature;
  final String username;
  final String yuid;
  final Uint8List yuidPublicKey;
  final Uint8List keyPackage;
  final String keyPackageHash;
  final DateTime expiresAt;

  const ClaimedMlsKeyPackage({
    required this.id,
    required this.deviceId,
    required this.ciphersuite,
    required this.signaturePublicKey,
    required this.identityBindingSignature,
    required this.username,
    required this.yuid,
    required this.yuidPublicKey,
    required this.keyPackage,
    required this.keyPackageHash,
    required this.expiresAt,
  });

  factory ClaimedMlsKeyPackage.fromJson(Map<String, dynamic> json) {
    final id = _requiredString(json['id'], 'KeyPackage id');
    final deviceId = _requiredString(json['deviceId'], 'device id');
    final ciphersuite = _nonNegativeInteger(json['ciphersuite'], 'ciphersuite');
    final signaturePublicKey = _decodeBase64Url(
      _requiredString(json['signaturePublicKey'], 'signature public key'),
      'signature public key',
    );
    final identityBindingSignature = _decodeBase64Url(
      _requiredString(
        json['identityBindingSignature'],
        'identity binding signature',
      ),
      'identity binding signature',
    );
    final yuidPublicKey = _decodeBase64Url(
      _requiredString(json['yuidPublicKey'], 'YUID public key'),
      'YUID public key',
    );
    final keyPackage = _decodeBase64Url(
      _requiredString(json['keyPackage'], 'KeyPackage'),
      'KeyPackage',
    );
    final keyPackageHash = _requiredString(
      json['keyPackageHash'],
      'KeyPackage hash',
    ).toLowerCase();
    final expiresAt = DateTime.tryParse(
      _requiredString(json['expiresAt'], 'KeyPackage expiry'),
    );
    if (!RegExp(r'^kp_[A-Za-z0-9_-]{22}$').hasMatch(id) ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(deviceId) ||
        ciphersuite != 1 ||
        signaturePublicKey.length != 32 ||
        identityBindingSignature.length != 64 ||
        yuidPublicKey.length != 32 ||
        keyPackage.length < 64 ||
        keyPackage.length > 65536 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(keyPackageHash) ||
        sha256.convert(keyPackage).toString() != keyPackageHash ||
        expiresAt == null) {
      throw const FormatException('Invalid claimed MLS KeyPackage.');
    }
    return ClaimedMlsKeyPackage(
      id: id,
      deviceId: deviceId,
      ciphersuite: ciphersuite,
      signaturePublicKey: signaturePublicKey,
      identityBindingSignature: identityBindingSignature,
      username: _requiredString(json['username'], 'username'),
      yuid: _requiredString(json['yuid'], 'YUID'),
      yuidPublicKey: yuidPublicKey,
      keyPackage: keyPackage,
      keyPackageHash: keyPackageHash,
      expiresAt: expiresAt.toUtc(),
    );
  }
}

class MlsDeviceCredential {
  final String deviceId;
  final String userId;
  final String username;
  final String yuid;
  final Uint8List yuidPublicKey;
  final Uint8List signaturePublicKey;
  final Uint8List identityBindingSignature;
  final bool isServerOwner;
  final bool isActive;
  final DateTime createdAt;

  const MlsDeviceCredential({
    required this.deviceId,
    required this.userId,
    required this.username,
    required this.yuid,
    required this.yuidPublicKey,
    required this.signaturePublicKey,
    required this.identityBindingSignature,
    required this.isServerOwner,
    required this.isActive,
    required this.createdAt,
  });

  factory MlsDeviceCredential.fromJson(Map<String, dynamic> json) {
    final deviceId = _requiredString(json['deviceId'], 'device id');
    final userId = _requiredString(json['userId'], 'user id');
    final signaturePublicKey = _decodeBase64Url(
      _requiredString(json['signaturePublicKey'], 'signature public key'),
      'signature public key',
    );
    final identityBindingSignature = _decodeBase64Url(
      _requiredString(
        json['identityBindingSignature'],
        'identity binding signature',
      ),
      'identity binding signature',
    );
    final yuidPublicKey = _decodeBase64Url(
      _requiredString(json['yuidPublicKey'], 'YUID public key'),
      'YUID public key',
    );
    final createdAt = DateTime.tryParse(
      _requiredString(json['createdAt'], 'credential timestamp'),
    );
    final isServerOwner = json['isServerOwner'];
    final isActive = json['isActive'];
    if (!RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(deviceId) ||
        !RegExp(r'^[1-9][0-9]*$').hasMatch(userId) ||
        signaturePublicKey.length != 32 ||
        identityBindingSignature.length != 64 ||
        yuidPublicKey.length != 32 ||
        isServerOwner is! bool ||
        isActive is! bool ||
        createdAt == null) {
      throw const FormatException('Invalid MLS device credential.');
    }
    return MlsDeviceCredential(
      deviceId: deviceId,
      userId: userId,
      username: _requiredString(json['username'], 'username'),
      yuid: _requiredString(json['yuid'], 'YUID'),
      yuidPublicKey: yuidPublicKey,
      signaturePublicKey: signaturePublicKey,
      identityBindingSignature: identityBindingSignature,
      isServerOwner: isServerOwner,
      isActive: isActive,
      createdAt: createdAt.toUtc(),
    );
  }
}

class MlsChannelGroup {
  final String groupId;
  final int currentEpoch;
  final int nextSequence;
  final String? initializedByDeviceId;
  final DateTime? initializedAt;

  const MlsChannelGroup({
    required this.groupId,
    required this.currentEpoch,
    required this.nextSequence,
    this.initializedByDeviceId,
    this.initializedAt,
  });

  factory MlsChannelGroup.fromJson(Map<String, dynamic> json) {
    final groupId = _requiredString(json['groupId'], 'MLS group id');
    final currentEpoch = _nonNegativeInteger(
      json['currentEpoch'],
      'current epoch',
    );
    final nextSequence = _nonNegativeInteger(
      json['nextSequence'],
      'next sequence',
    );
    if (!groupId.startsWith('yappa-text-v1|') || nextSequence < 1) {
      throw const FormatException('Invalid MLS group state.');
    }
    final initializedBy = json['initializedByDeviceId']?.toString();
    final initializedAt = json['initializedAt'] == null
        ? null
        : DateTime.tryParse(json['initializedAt'].toString())?.toUtc();
    if (initializedBy != null &&
            !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(initializedBy) ||
        json['initializedAt'] != null && initializedAt == null) {
      throw const FormatException('Invalid MLS initializer device.');
    }
    return MlsChannelGroup(
      groupId: groupId,
      currentEpoch: currentEpoch,
      nextSequence: nextSequence,
      initializedByDeviceId: initializedBy,
      initializedAt: initializedAt,
    );
  }
}

class MlsChannelInitialization {
  final MlsChannelGroup group;
  final bool created;

  const MlsChannelInitialization({required this.group, required this.created});
}

class EncryptedApplicationEventRouting {
  final String eventId;
  final EncryptedApplicationEventKind kind;
  final String? targetEventId;
  final List<String> encryptedAttachmentIds;

  const EncryptedApplicationEventRouting({
    required this.eventId,
    required this.kind,
    this.targetEventId,
    this.encryptedAttachmentIds = const [],
  });

  factory EncryptedApplicationEventRouting.fromJson(Map<String, dynamic> json) {
    final eventId = _requiredString(json['eventId'], 'event id');
    final target = json['targetEventId']?.toString();
    final attachments = (json['encryptedAttachmentIds'] as List? ?? const [])
        .map((value) => value.toString())
        .toList(growable: false);
    if (!RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(eventId) ||
        target != null && !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(target) ||
        attachments.length > 10 ||
        attachments.toSet().length != attachments.length ||
        attachments.any(
          (id) => !RegExp(r'^eatt_[A-Za-z0-9_-]{22}$').hasMatch(id),
        )) {
      throw const FormatException('Invalid encrypted event routing.');
    }
    final kind = EncryptedApplicationEventKind.parse(json['kind']);
    if ({
          EncryptedApplicationEventKind.edit,
          EncryptedApplicationEventKind.delete,
          EncryptedApplicationEventKind.reaction,
        }.contains(kind) &&
        target == null) {
      throw const FormatException('Encrypted event target is required.');
    }
    if (kind == EncryptedApplicationEventKind.attachment
        ? attachments.isEmpty
        : attachments.isNotEmpty) {
      throw const FormatException('Invalid encrypted attachment routing.');
    }
    return EncryptedApplicationEventRouting(
      eventId: eventId,
      kind: kind,
      targetEventId: target,
      encryptedAttachmentIds: attachments,
    );
  }

  Map<String, dynamic> toJson() => {
    'eventId': eventId,
    'kind': kind.name,
    if (targetEventId != null) 'targetEventId': targetEventId,
    if (encryptedAttachmentIds.isNotEmpty)
      'encryptedAttachmentIds': encryptedAttachmentIds,
  };
}

class MlsDeliveryMessage {
  final String id;
  final String clientOperationId;
  final String channelId;
  final int serverSequence;
  final MlsDeliveryMessageClass messageClass;
  final int acceptedEpoch;
  final int? parentEpoch;
  final String uploaderUserId;
  final String uploaderDeviceId;
  final String? recipientDeviceId;
  final Uint8List wireMessage;
  final DateTime createdAt;
  final EncryptedApplicationEventRouting? event;

  const MlsDeliveryMessage({
    required this.id,
    required this.clientOperationId,
    required this.channelId,
    required this.serverSequence,
    required this.messageClass,
    required this.acceptedEpoch,
    required this.parentEpoch,
    required this.uploaderUserId,
    required this.uploaderDeviceId,
    required this.recipientDeviceId,
    required this.wireMessage,
    required this.createdAt,
    required this.event,
  });

  factory MlsDeliveryMessage.fromJson(Map<String, dynamic> json) {
    final id = _requiredString(json['id'], 'delivery id');
    final clientOperationId = _requiredString(
      json['clientOperationId'],
      'client operation id',
    );
    final channelId = _requiredString(json['channelId'], 'channel id');
    final sequence = _nonNegativeInteger(
      json['serverSequence'],
      'server sequence',
    );
    final messageClass = MlsDeliveryMessageClass.parse(json['messageClass']);
    final acceptedEpoch = _nonNegativeInteger(
      json['acceptedEpoch'],
      'accepted epoch',
    );
    final parentEpoch = json['parentEpoch'] == null
        ? null
        : _nonNegativeInteger(json['parentEpoch'], 'parent epoch');
    final uploaderUserId = _requiredString(
      json['uploaderUserId'],
      'uploader user id',
    );
    final uploaderDeviceId = _requiredString(
      json['uploaderDeviceId'],
      'uploader device id',
    );
    final recipient = json['recipientDeviceId']?.toString();
    final wireMessage = _decodeBase64Url(
      _requiredString(json['wireMessage'], 'MLS wire message'),
      'MLS wire message',
    );
    final createdAt = DateTime.tryParse(
      _requiredString(json['createdAt'], 'delivery timestamp'),
    );
    final rawEvent = json['event'];
    final event = rawEvent == null
        ? null
        : rawEvent is Map
        ? EncryptedApplicationEventRouting.fromJson(
            Map<String, dynamic>.from(rawEvent),
          )
        : throw const FormatException('Invalid encrypted event.');
    if (!RegExp(r'^mls_[A-Za-z0-9_-]{22}$').hasMatch(id) ||
        !RegExp(r'^mlsop_[A-Za-z0-9_-]{22}$').hasMatch(clientOperationId) ||
        (int.tryParse(channelId) ?? 0) < 1 ||
        sequence < 1 ||
        (int.tryParse(uploaderUserId) ?? 0) < 1 ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(uploaderDeviceId) ||
        recipient != null &&
            !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(recipient) ||
        wireMessage.isEmpty ||
        wireMessage.length > 131072 ||
        createdAt == null ||
        (messageClass == MlsDeliveryMessageClass.welcome) !=
            (recipient != null) ||
        (messageClass == MlsDeliveryMessageClass.application) !=
            (event != null) ||
        switch (messageClass) {
          MlsDeliveryMessageClass.commit =>
            parentEpoch == null || acceptedEpoch != parentEpoch + 1,
          MlsDeliveryMessageClass.proposal =>
            parentEpoch == null || acceptedEpoch != parentEpoch,
          MlsDeliveryMessageClass.welcome ||
          MlsDeliveryMessageClass.application => parentEpoch != null,
        }) {
      throw const FormatException('Invalid MLS delivery message.');
    }
    return MlsDeliveryMessage(
      id: id,
      clientOperationId: clientOperationId,
      channelId: channelId,
      serverSequence: sequence,
      messageClass: messageClass,
      acceptedEpoch: acceptedEpoch,
      parentEpoch: parentEpoch,
      uploaderUserId: uploaderUserId,
      uploaderDeviceId: uploaderDeviceId,
      recipientDeviceId: recipient,
      wireMessage: wireMessage,
      createdAt: createdAt.toUtc(),
      event: event,
    );
  }
}

class MlsDeliveryBatch {
  final MlsChannelGroup group;
  final List<MlsDeliveryMessage> messages;
  final int deliveredSequence;

  const MlsDeliveryBatch({
    required this.group,
    required this.messages,
    required this.deliveredSequence,
  });

  factory MlsDeliveryBatch.fromJson(
    Map<String, dynamic> json, {
    required int after,
  }) {
    final group = MlsChannelGroup.fromJson(
      Map<String, dynamic>.from(json['group'] as Map),
    );
    final messages = (json['messages'] as List? ?? const [])
        .map(
          (item) => MlsDeliveryMessage.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);
    final delivered = _nonNegativeInteger(
      json['deliveredSequence'],
      'delivered sequence',
    );
    var previous = after;
    for (final message in messages) {
      if (message.serverSequence <= previous) {
        throw const FormatException('MLS delivery order is not increasing.');
      }
      previous = message.serverSequence;
    }
    if (delivered != (messages.isEmpty ? after : previous)) {
      throw const FormatException('Invalid MLS delivered cursor.');
    }
    return MlsDeliveryBatch(
      group: group,
      messages: messages,
      deliveredSequence: delivered,
    );
  }
}

class MlsDeliveryAcknowledgement {
  final int deliveredSequence;
  final int acknowledgedSequence;
  final int acknowledgedEpoch;

  const MlsDeliveryAcknowledgement({
    required this.deliveredSequence,
    required this.acknowledgedSequence,
    required this.acknowledgedEpoch,
  });

  factory MlsDeliveryAcknowledgement.fromJson(Map<String, dynamic> json) {
    final delivered = _nonNegativeInteger(
      json['deliveredSequence'],
      'delivered sequence',
    );
    final acknowledged = _nonNegativeInteger(
      json['acknowledgedSequence'],
      'acknowledged sequence',
    );
    final epoch = _nonNegativeInteger(
      json['acknowledgedEpoch'],
      'acknowledged epoch',
    );
    if (acknowledged > delivered) {
      throw const FormatException('Invalid MLS acknowledgement.');
    }
    return MlsDeliveryAcknowledgement(
      deliveredSequence: delivered,
      acknowledgedSequence: acknowledged,
      acknowledgedEpoch: epoch,
    );
  }
}
