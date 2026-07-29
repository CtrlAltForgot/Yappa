import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'attachment_secretstream.dart';
import 'mls_delivery_models.dart';
import '../models/channel_model.dart';
import '../models/link_preview_model.dart';
import '../models/member_model.dart';
import '../models/message_model.dart';
import '../models/server_model.dart';
import '../models/server_permissions.dart';

bool _constantTimeBytesEqual(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  var difference = 0;
  for (var index = 0; index < first.length; index++) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}

bool _sameStrings(List<String> first, List<String> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

class _ApiDigestSink implements Sink<hashes.Digest> {
  hashes.Digest? value;

  @override
  void add(hashes.Digest data) {
    if (value != null) throw StateError('Digest emitted more than once.');
    value = data;
  }

  @override
  void close() {}
}

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? code;

  ApiException(this.message, {this.statusCode, this.code});

  @override
  String toString() => message;
}

class NodeHandshakeResult {
  final ChatServer server;
  final List<ChatChannel> channels;

  NodeHandshakeResult({required this.server, required this.channels});
}

class VerifiedServerIdentity {
  final String serverId;
  final String publicKey;

  const VerifiedServerIdentity({
    required this.serverId,
    required this.publicKey,
  });
}

class LanServerRoute {
  final String host;
  final int tlsPort;
  final String serverId;
  final String publicKey;
  final String advertisedAddress;

  const LanServerRoute({
    required this.host,
    required this.tlsPort,
    required this.serverId,
    required this.publicKey,
    required this.advertisedAddress,
  });
}

class _LanDialTarget {
  final String host;
  final int port;

  const _LanDialTarget(this.host, this.port);
}

class YuidChallenge {
  final String serverId;
  final String nonce;
  final DateTime? issuedAt;
  final DateTime? expiresAt;

  const YuidChallenge({
    required this.serverId,
    required this.nonce,
    required this.issuedAt,
    required this.expiresAt,
  });

  factory YuidChallenge.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      return DateTime.tryParse(value.toString());
    }

    return YuidChallenge(
      serverId: (json['serverId'] ?? '').toString(),
      nonce: (json['nonce'] ?? '').toString(),
      issuedAt: parseDate(json['issuedAt']),
      expiresAt: parseDate(json['expiresAt']),
    );
  }
}

class HistoryRecoveryDeviceKey {
  final String deviceId;
  final String publicKey;
  final String yuidAuthorizationSignature;
  final DateTime createdAt;
  final DateTime updatedAt;

  const HistoryRecoveryDeviceKey({
    required this.deviceId,
    required this.publicKey,
    required this.yuidAuthorizationSignature,
    required this.createdAt,
    required this.updatedAt,
  });

  factory HistoryRecoveryDeviceKey.fromJson(Map<String, dynamic> json) {
    final deviceId = json['deviceId']?.toString() ?? '';
    final publicKey = json['publicKey']?.toString() ?? '';
    final signature = json['yuidAuthorizationSignature']?.toString() ?? '';
    final createdAt = DateTime.tryParse(json['createdAt']?.toString() ?? '');
    final updatedAt = DateTime.tryParse(json['updatedAt']?.toString() ?? '');
    if (!RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(deviceId) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(publicKey) ||
        !RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(signature) ||
        createdAt == null ||
        updatedAt == null) {
      throw const FormatException('Invalid history recovery device key.');
    }
    return HistoryRecoveryDeviceKey(
      deviceId: deviceId,
      publicKey: publicKey,
      yuidAuthorizationSignature: signature,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

class HistoryRecoveryKeyDirectory {
  final String accountYuid;
  final List<HistoryRecoveryDeviceKey> keys;

  const HistoryRecoveryKeyDirectory({
    required this.accountYuid,
    required this.keys,
  });
}

enum HistoryRecoveryTransferState {
  uploading,
  ready,
  consumed,
  canceled,
  expired;

  static HistoryRecoveryTransferState parse(dynamic value) {
    return values.firstWhere(
      (state) => state.name == value,
      orElse: () =>
          throw const FormatException('Invalid history recovery state.'),
    );
  }
}

class HistoryRecoveryTransfer {
  final String id;
  final String channelId;
  final String sourceDeviceId;
  final String destinationDeviceId;
  final int firstServerSequence;
  final int lastServerSequence;
  final int eventCount;
  final int chunkCount;
  final int totalBytes;
  final Uint8List? manifest;
  final String manifestSha256;
  final String yuidSignature;
  final HistoryRecoveryTransferState state;
  final int uploadedChunks;
  final int uploadedBytes;
  final DateTime createdAt;
  final DateTime? readyAt;
  final DateTime? consumedAt;
  final DateTime? canceledAt;
  final DateTime expiresAt;

  const HistoryRecoveryTransfer({
    required this.id,
    required this.channelId,
    required this.sourceDeviceId,
    required this.destinationDeviceId,
    required this.firstServerSequence,
    required this.lastServerSequence,
    required this.eventCount,
    required this.chunkCount,
    required this.totalBytes,
    required this.manifest,
    required this.manifestSha256,
    required this.yuidSignature,
    required this.state,
    required this.uploadedChunks,
    required this.uploadedBytes,
    required this.createdAt,
    required this.readyAt,
    required this.consumedAt,
    required this.canceledAt,
    required this.expiresAt,
  });

  factory HistoryRecoveryTransfer.fromJson(
    Map<String, dynamic> json, {
    bool requireManifest = true,
  }) {
    DateTime? date(dynamic value) =>
        value == null ? null : DateTime.tryParse(value.toString())?.toUtc();
    Uint8List? manifest;
    final encodedManifest = json['manifest'];
    if (encodedManifest != null) {
      final text = encodedManifest.toString();
      manifest = Uint8List.fromList(
        base64Url.decode(
          text.padRight(text.length + ((4 - text.length % 4) % 4), '='),
        ),
      );
    }
    final id = json['id']?.toString() ?? '';
    final channelId = json['channelId']?.toString() ?? '';
    final sourceDeviceId = json['sourceDeviceId']?.toString() ?? '';
    final destinationDeviceId = json['destinationDeviceId']?.toString() ?? '';
    final first = json['firstServerSequence'];
    final last = json['lastServerSequence'];
    final eventCount = json['eventCount'];
    final chunkCount = json['chunkCount'];
    final totalBytes = json['totalBytes'];
    final uploadedChunks = json['uploadedChunks'];
    final uploadedBytes = json['uploadedBytes'];
    final manifestSha256 = json['manifestSha256']?.toString() ?? '';
    final signature = json['yuidSignature']?.toString() ?? '';
    final createdAt = date(json['createdAt']);
    final readyAt = date(json['readyAt']);
    final consumedAt = date(json['consumedAt']);
    final canceledAt = date(json['canceledAt']);
    final expiresAt = date(json['expiresAt']);
    if (!RegExp(r'^recovery_[A-Za-z0-9_-]{22}$').hasMatch(id) ||
        (int.tryParse(channelId) ?? 0) < 1 ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(sourceDeviceId) ||
        !RegExp(r'^device_[A-Za-z0-9_-]{24}$').hasMatch(destinationDeviceId) ||
        sourceDeviceId == destinationDeviceId ||
        first is! int ||
        first < 1 ||
        last is! int ||
        last < first ||
        eventCount is! int ||
        eventCount < 1 ||
        eventCount > last - first + 1 ||
        chunkCount is! int ||
        chunkCount < 1 ||
        chunkCount > 1024 ||
        totalBytes is! int ||
        totalBytes < chunkCount ||
        totalBytes > 256 * 1024 * 1024 ||
        uploadedChunks is! int ||
        uploadedChunks < 0 ||
        uploadedChunks > chunkCount ||
        uploadedBytes is! int ||
        uploadedBytes < 0 ||
        uploadedBytes > totalBytes ||
        (requireManifest && (manifest == null || manifest.isEmpty)) ||
        (manifest?.length ?? 0) > 64 * 1024 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(manifestSha256) ||
        !RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(signature) ||
        createdAt == null ||
        expiresAt == null) {
      throw const FormatException('Invalid history recovery transfer.');
    }
    final state = HistoryRecoveryTransferState.parse(json['state']);
    if ((state == HistoryRecoveryTransferState.ready && readyAt == null) ||
        (state == HistoryRecoveryTransferState.consumed &&
            consumedAt == null) ||
        (state == HistoryRecoveryTransferState.canceled &&
            canceledAt == null)) {
      throw const FormatException('Invalid history recovery lifecycle.');
    }
    return HistoryRecoveryTransfer(
      id: id,
      channelId: channelId,
      sourceDeviceId: sourceDeviceId,
      destinationDeviceId: destinationDeviceId,
      firstServerSequence: first,
      lastServerSequence: last,
      eventCount: eventCount,
      chunkCount: chunkCount,
      totalBytes: totalBytes,
      manifest: manifest,
      manifestSha256: manifestSha256,
      yuidSignature: signature,
      state: state,
      uploadedChunks: uploadedChunks,
      uploadedBytes: uploadedBytes,
      createdAt: createdAt,
      readyAt: readyAt,
      consumedAt: consumedAt,
      canceledAt: canceledAt,
      expiresAt: expiresAt,
    );
  }
}

class HistoryRecoveryTransferResult {
  final bool changed;
  final HistoryRecoveryTransfer transfer;

  const HistoryRecoveryTransferResult({
    required this.changed,
    required this.transfer,
  });
}

class HistoryRecoveryChunk {
  final String transferId;
  final int chunkIndex;
  final Uint8List ciphertext;
  final String ciphertextSha256;

  const HistoryRecoveryChunk({
    required this.transferId,
    required this.chunkIndex,
    required this.ciphertext,
    required this.ciphertextSha256,
  });
}

class SessionBundle {
  final ChatServer server;
  final List<ChatChannel> channels;
  final Member user;
  final ServerPermissions permissions;

  SessionBundle({
    required this.server,
    required this.channels,
    required this.user,
    required this.permissions,
  });
}

class AuthSessionResult extends SessionBundle {
  final String token;
  final bool created;
  final bool becameOwner;

  AuthSessionResult({
    required this.token,
    required this.created,
    required this.becameOwner,
    required super.server,
    required super.channels,
    required super.user,
    required super.permissions,
  });
}

class DeviceSession {
  final String id;
  final String deviceName;
  final DateTime? createdAt;
  final DateTime? lastSeenAt;
  final DateTime? expiresAt;
  final DateTime? idleExpiresAt;
  final bool current;

  const DeviceSession({
    required this.id,
    required this.deviceName,
    required this.createdAt,
    required this.lastSeenAt,
    required this.expiresAt,
    required this.idleExpiresAt,
    required this.current,
  });

  factory DeviceSession.fromJson(Map<String, dynamic> json) {
    DateTime? date(dynamic value) =>
        value == null ? null : DateTime.tryParse(value.toString());

    return DeviceSession(
      id: (json['id'] ?? '').toString(),
      deviceName: (json['deviceName'] ?? 'Yappa client').toString(),
      createdAt: date(json['createdAt']),
      lastSeenAt: date(json['lastSeenAt']),
      expiresAt: date(json['expiresAt']),
      idleExpiresAt: date(json['idleExpiresAt']),
      current: json['current'] == true,
    );
  }
}

class AdminChannelCreateResult {
  final ChatChannel channel;
  final List<ChatChannel> channels;

  AdminChannelCreateResult({required this.channel, required this.channels});
}

class BrandingUploadResult {
  final String slot;
  final String assetUrl;
  final ChatServer server;

  BrandingUploadResult({
    required this.slot,
    required this.assetUrl,
    required this.server,
  });
}

class EncryptedAttachmentUploadReceipt {
  final String id;
  final String channelId;
  final Uint8List secretstreamHeader;
  final int ciphertextSizeBytes;
  final String ciphertextSha256;
  final int chunkCount;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  const EncryptedAttachmentUploadReceipt({
    required this.id,
    required this.channelId,
    required this.secretstreamHeader,
    required this.ciphertextSizeBytes,
    required this.ciphertextSha256,
    required this.chunkCount,
    required this.createdAt,
    required this.expiresAt,
  });
}

class ServerSettings {
  final int attachmentRetentionDays;
  final int attachmentMaxBytes;
  final List<String> attachmentAllowedTypes;
  final bool fileStorageEnabled;
  final int fileStorageMaxTotalBytes;
  final int fileStorageMaxFileBytes;
  final List<String> fileStorageAllowedTypes;
  final bool inlineMediaPreviewsEnabled;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const ServerSettings({
    required this.attachmentRetentionDays,
    required this.attachmentMaxBytes,
    required this.attachmentAllowedTypes,
    required this.fileStorageEnabled,
    required this.fileStorageMaxTotalBytes,
    required this.fileStorageMaxFileBytes,
    required this.fileStorageAllowedTypes,
    required this.inlineMediaPreviewsEnabled,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ServerSettings.fromJson(Map<String, dynamic> json) {
    DateTime? parseOptionalDate(dynamic value) {
      if (value == null) return null;
      final text = value.toString().trim();
      if (text.isEmpty) return null;
      return DateTime.tryParse(text);
    }

    return ServerSettings(
      attachmentRetentionDays:
          (json['attachmentRetentionDays'] as num?)?.toInt() ?? 0,
      attachmentMaxBytes:
          (json['attachmentMaxBytes'] as num?)?.toInt() ?? 26214400,
      attachmentAllowedTypes:
          (json['attachmentAllowedTypes'] as List? ?? const [])
              .map((item) => item.toString())
              .toList(),
      fileStorageEnabled: json['fileStorageEnabled'] as bool? ?? true,
      fileStorageMaxTotalBytes:
          (json['fileStorageMaxTotalBytes'] as num?)?.toInt() ?? 2147483648,
      fileStorageMaxFileBytes:
          (json['fileStorageMaxFileBytes'] as num?)?.toInt() ?? 262144000,
      fileStorageAllowedTypes:
          (json['fileStorageAllowedTypes'] as List? ?? const ['*'])
              .map((item) => item.toString())
              .toList(),
      inlineMediaPreviewsEnabled:
          json['inlineMediaPreviewsEnabled'] as bool? ?? true,
      createdAt: parseOptionalDate(json['createdAt']),
      updatedAt: parseOptionalDate(json['updatedAt']),
    );
  }
}

class ServerStorageStatus {
  final String status;
  final bool acceptsDurableWrites;
  final int availableBytes;
  final int totalBytes;
  final int warningFreeBytes;
  final int criticalFreeBytes;
  final int databaseBytes;
  final int ordinaryAttachmentBytes;
  final int encryptedAttachmentBytes;
  final int? backupBytes;
  final bool backupMonitoringEnabled;

  const ServerStorageStatus({
    required this.status,
    required this.acceptsDurableWrites,
    required this.availableBytes,
    required this.totalBytes,
    required this.warningFreeBytes,
    required this.criticalFreeBytes,
    required this.databaseBytes,
    required this.ordinaryAttachmentBytes,
    required this.encryptedAttachmentBytes,
    required this.backupBytes,
    required this.backupMonitoringEnabled,
  });

  factory ServerStorageStatus.fromJson(Map<String, dynamic> json) {
    final filesystem = Map<String, dynamic>.from(json['filesystem'] as Map);
    final thresholds = Map<String, dynamic>.from(json['thresholds'] as Map);
    final usage = Map<String, dynamic>.from(json['usage'] as Map);
    return ServerStorageStatus(
      status: json['status']?.toString() ?? 'unavailable',
      acceptsDurableWrites: json['acceptsDurableWrites'] as bool? ?? false,
      availableBytes: (filesystem['availableBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (filesystem['totalBytes'] as num?)?.toInt() ?? 0,
      warningFreeBytes: (thresholds['warningFreeBytes'] as num?)?.toInt() ?? 0,
      criticalFreeBytes:
          (thresholds['criticalFreeBytes'] as num?)?.toInt() ?? 0,
      databaseBytes: (usage['databaseBytes'] as num?)?.toInt() ?? 0,
      ordinaryAttachmentBytes:
          (usage['ordinaryAttachmentBytes'] as num?)?.toInt() ?? 0,
      encryptedAttachmentBytes:
          (usage['encryptedAttachmentBytes'] as num?)?.toInt() ?? 0,
      backupBytes: (usage['backupBytes'] as num?)?.toInt(),
      backupMonitoringEnabled:
          usage['backupMonitoringEnabled'] as bool? ?? false,
    );
  }
}

class VoiceConnectionCredentials {
  final String serverUrl;
  final String participantToken;
  final String roomName;

  const VoiceConnectionCredentials({
    required this.serverUrl,
    required this.participantToken,
    required this.roomName,
  });
}

class ApiClient {
  final Map<String, _LanDialTarget> _lanRoutes = {};
  final http.Client Function(Uri uri)? _clientFactory;

  static const Object _avatarUnspecified = Object();
  static Object get avatarUnspecified => _avatarUnspecified;

  ApiClient({http.Client Function(Uri uri)? clientFactory})
    : _clientFactory = clientFactory;

  String normalizeBaseUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw ApiException('Enter a server IP or host.');
    }

    final explicitScheme = RegExp(
      r'^([a-z][a-z0-9+.-]*)://',
      caseSensitive: false,
    ).firstMatch(trimmed);
    final suppliedScheme = explicitScheme?.group(1)?.toLowerCase();
    if (suppliedScheme != null &&
        suppliedScheme != 'http' &&
        suppliedScheme != 'https') {
      throw ApiException('Server addresses must use http:// or https://.');
    }
    final withScheme = suppliedScheme == null ? 'http://$trimmed' : trimmed;

    late final Uri uri;
    try {
      uri = Uri.parse(withScheme);
    } catch (_) {
      throw ApiException('Enter a valid server IP or host.');
    }

    if (uri.host.isEmpty) {
      throw ApiException('Enter a valid server IP or host.');
    }

    if ((uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      throw ApiException('Enter only the server host and optional port.');
    }

    final allowsInsecureTransport = _isPrivateOrDevelopmentHost(uri.host);
    final scheme =
        suppliedScheme ?? (allowsInsecureTransport ? 'http' : 'https');
    if (scheme == 'http' && !allowsInsecureTransport) {
      throw ApiException(
        'Public Yappa servers must use HTTPS. Use an https:// address.',
        code: 'insecure_transport',
      );
    }

    final normalized = Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : (scheme == 'http' ? 4100 : null),
    ).toString();

    return normalized.replaceFirst(RegExp(r'/*$'), '');
  }

  String addressHost(String input) {
    final trimmed = input.trim();
    final withScheme =
        RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(trimmed)
        ? trimmed
        : 'http://$trimmed';
    return Uri.tryParse(withScheme)?.host.trim().toLowerCase() ?? '';
  }

  String advertisedHostForAddress(String input) {
    return addressHost(input);
  }

  bool isPrivateOrDevelopmentAddress(String input) =>
      _isPrivateOrDevelopmentHost(addressHost(input));

  String secureBaseUrlForDiscoveredRoute({
    required String savedBaseUrl,
    required String advertisedAddress,
  }) {
    final saved = normalizeBaseUrl(savedBaseUrl);
    final savedUri = Uri.parse(saved);
    if (savedUri.scheme == 'https') return saved;

    final advertised = normalizeBaseUrl(advertisedAddress);
    if (Uri.parse(advertised).scheme != 'https') {
      throw ApiException(
        'The discovered server did not advertise a secure public route.',
        code: 'invalid_lan_route',
      );
    }
    return advertised;
  }

  void setLanRoute({
    required String publicBaseUrl,
    required String lanHost,
    required int lanTlsPort,
  }) {
    final publicUri = Uri.parse(normalizeBaseUrl(publicBaseUrl));
    if (publicUri.scheme != 'https' ||
        !_isPrivateOrDevelopmentHost(lanHost) ||
        lanTlsPort < 1 ||
        lanTlsPort > 65535) {
      throw ApiException(
        'The discovered LAN route is not a valid secure fallback.',
        code: 'invalid_lan_route',
      );
    }
    _lanRoutes[publicUri.origin] = _LanDialTarget(lanHost, lanTlsPort);
  }

  void clearLanRoute(String publicBaseUrl) {
    final publicUri = Uri.parse(normalizeBaseUrl(publicBaseUrl));
    _lanRoutes.remove(publicUri.origin);
  }

  bool hasLanRoute(String publicBaseUrl) {
    final publicUri = Uri.parse(normalizeBaseUrl(publicBaseUrl));
    return _lanRoutes.containsKey(publicUri.origin);
  }

  bool _isPrivateOrDevelopmentHost(String input) {
    final host = input.trim().toLowerCase();
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        !host.contains('.')) {
      return true;
    }

    final address = InternetAddress.tryParse(host);
    if (address == null) {
      return false;
    }

    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return bytes[0] == 10 ||
          bytes[0] == 127 ||
          (bytes[0] == 169 && bytes[1] == 254) ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168);
    }

    final isLoopback =
        bytes.take(15).every((value) => value == 0) && bytes[15] == 1;
    final isUniqueLocal = (bytes[0] & 0xFE) == 0xFC;
    final isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80;
    return isLoopback || isUniqueLocal || isLinkLocal;
  }

  ChatMessage _resolveMessageUrls(ChatMessage message, String baseUrl) {
    return message.resolvedAgainst(baseUrl);
  }

  ChatAttachment _resolveAttachmentUrl(
    ChatAttachment attachment,
    String baseUrl,
  ) {
    return attachment.resolvedAgainst(baseUrl);
  }

  Future<NodeHandshakeResult> handshake(String rawAddress) async {
    final baseUrl = normalizeBaseUrl(rawAddress);
    final json = await _requestJson('GET', '$baseUrl/api/server');

    final serverJson = Map<String, dynamic>.from(json['server'] as Map)
      ..['address'] = baseUrl;
    final identity = await verifyServerIdentity(
      baseUrl: baseUrl,
      expectedServerId: serverJson['id']?.toString() ?? '',
    );
    serverJson['identityPublicKey'] = identity.publicKey;
    final channelsJson = (json['channels'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    return NodeHandshakeResult(
      server: ChatServer.fromJson(serverJson),
      channels: channelsJson.map(ChatChannel.fromJson).toList(),
    );
  }

  Future<VerifiedServerIdentity> verifyServerIdentity({
    required String baseUrl,
    required String expectedServerId,
    String expectedPublicKey = '',
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final random = Random.secure();
    final nonce = base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final json = await _requestJson(
      'GET',
      '$normalized/api/server/identity?nonce=${Uri.encodeQueryComponent(nonce)}',
    );
    final identity = Map<String, dynamic>.from(
      json['identity'] as Map? ?? const {},
    );
    final serverId = identity['serverId']?.toString() ?? '';
    final algorithm = identity['algorithm']?.toString() ?? '';
    final publicKey = identity['publicKey']?.toString() ?? '';
    final returnedNonce = identity['nonce']?.toString() ?? '';
    final encodedSignature = identity['signature']?.toString() ?? '';

    if (serverId != expectedServerId ||
        returnedNonce != nonce ||
        algorithm != 'Ed25519' ||
        publicKey.isEmpty ||
        encodedSignature.isEmpty) {
      throw ApiException(
        'The server could not prove its expected identity.',
        code: 'server_identity_invalid',
      );
    }
    if (expectedPublicKey.isNotEmpty && publicKey != expectedPublicKey) {
      throw ApiException(
        'This address now belongs to a different Yappa server. Your saved '
        'session was not sent.',
        code: 'server_identity_changed',
      );
    }

    try {
      final signature = Signature(
        _decodeBase64Url(encodedSignature),
        publicKey: SimplePublicKey(
          _decodeBase64Url(publicKey),
          type: KeyPairType.ed25519,
        ),
      );
      final verified = await Ed25519().verify(
        utf8.encode('yappa-server-proof-v1|$serverId|$nonce'),
        signature: signature,
      );
      if (!verified) {
        throw const FormatException('Invalid identity signature.');
      }
    } catch (_) {
      throw ApiException(
        'The server identity signature was invalid.',
        code: 'server_identity_invalid',
      );
    }

    return VerifiedServerIdentity(serverId: serverId, publicKey: publicKey);
  }

  Future<LanServerRoute?> discoverLanServer({
    String expectedServerId = '',
    String expectedPublicKey = '',
    String expectedAdvertisedAddress = '',
    Duration timeout = const Duration(milliseconds: 1400),
    InternetAddress? discoveryAddress,
  }) async {
    const discoveryPort = 41200;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    final random = Random.secure();
    final nonce = base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final request = utf8.encode(
      jsonEncode({'protocol': 'yappa-lan-discovery-v1', 'nonce': nonce}),
    );
    final result = Completer<LanServerRoute?>();
    late final StreamSubscription<RawSocketEvent> subscription;

    Future<void> consider(Datagram datagram) async {
      if (datagram.data.length > 2048 ||
          !_isPrivateOrDevelopmentHost(datagram.address.address)) {
        return;
      }
      try {
        final decoded = jsonDecode(utf8.decode(datagram.data));
        if (decoded is! Map) return;
        final response = Map<String, dynamic>.from(decoded);
        final serverId = response['serverId']?.toString() ?? '';
        final publicKey = response['publicKey']?.toString() ?? '';
        final algorithm = response['algorithm']?.toString() ?? '';
        final returnedNonce = response['nonce']?.toString() ?? '';
        final advertisedAddress =
            response['advertisedAddress']?.toString().trim().toLowerCase() ??
            '';
        final signatureText = response['signature']?.toString() ?? '';
        final tlsPort = (response['tlsPort'] as num?)?.toInt() ?? 0;
        if (response['protocol'] != 'yappa-lan-discovery-v1' ||
            algorithm != 'Ed25519' ||
            serverId.isEmpty ||
            publicKey.isEmpty ||
            returnedNonce != nonce ||
            tlsPort < 1 ||
            tlsPort > 65535 ||
            (expectedServerId.isNotEmpty && serverId != expectedServerId) ||
            (expectedPublicKey.isNotEmpty && publicKey != expectedPublicKey) ||
            (expectedAdvertisedAddress.isNotEmpty &&
                advertisedAddress !=
                    expectedAdvertisedAddress.trim().toLowerCase())) {
          return;
        }

        final proof =
            'yappa-lan-discovery-v1|$serverId|$nonce|'
            '$tlsPort|$advertisedAddress';
        final signature = Signature(
          _decodeBase64Url(signatureText),
          publicKey: SimplePublicKey(
            _decodeBase64Url(publicKey),
            type: KeyPairType.ed25519,
          ),
        );
        if (!await Ed25519().verify(utf8.encode(proof), signature: signature)) {
          return;
        }

        if (!result.isCompleted) {
          result.complete(
            LanServerRoute(
              host: datagram.address.address,
              tlsPort: tlsPort,
              serverId: serverId,
              publicKey: publicKey,
              advertisedAddress: advertisedAddress,
            ),
          );
        }
      } catch (_) {
        // Ignore malformed, untrusted, or unreachable discovery responses.
      }
    }

    subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        consider(datagram!);
      }
    });
    try {
      socket.send(
        request,
        discoveryAddress ?? InternetAddress('255.255.255.255'),
        discoveryPort,
      );
    } on SocketException {
      result.complete(null);
    }
    Timer(timeout, () {
      if (!result.isCompleted) result.complete(null);
    });

    try {
      return await result.future;
    } finally {
      await subscription.cancel();
      socket.close();
    }
  }

  List<int> _decodeBase64Url(String value) {
    final normalized = value.padRight(
      value.length + ((4 - value.length % 4) % 4),
      '=',
    );
    return base64Url.decode(normalized);
  }

  Future<YuidChallenge> fetchYuidChallenge({required String baseUrl}) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'GET',
      '$normalized/api/auth/yuid/challenge',
    );

    return YuidChallenge.fromJson(
      Map<String, dynamic>.from(json['challenge'] as Map),
    );
  }

  Future<void> registerMediaDevice({
    required String baseUrl,
    required String token,
    required String yuidPublicKey,
    required String yuidSignature,
    required String yuidNonce,
    required String mediaDeviceId,
    required String mediaPublicKey,
    required String mediaDeviceSignature,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    await _requestJson(
      'POST',
      '$normalized/api/media/devices/register',
      token: token,
      body: {
        'yuidPublicKey': yuidPublicKey,
        'yuidSignature': yuidSignature,
        'yuidNonce': yuidNonce,
        'mediaDeviceId': mediaDeviceId,
        'mediaPublicKey': mediaPublicKey,
        'mediaDeviceSignature': mediaDeviceSignature,
      },
    );
  }

  Future<AuthSessionResult> authenticate({
    required String baseUrl,
    required String username,
    required String password,
    required String yuid,
    required String yuidPublicKey,
    required String yuidSignature,
    required String yuidNonce,
    required String mediaDeviceId,
    required String mediaPublicKey,
    required String mediaDeviceSignature,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/auth/session',
      body: {
        'username': username,
        'password': password,
        'deviceName': 'Yappa on ${_devicePlatformName()}',
        'yuid': yuid,
        'yuidPublicKey': yuidPublicKey,
        'yuidSignature': yuidSignature,
        'yuidNonce': yuidNonce,
        'mediaDeviceId': mediaDeviceId,
        'mediaPublicKey': mediaPublicKey,
        'mediaDeviceSignature': mediaDeviceSignature,
      },
    );

    final serverJson = Map<String, dynamic>.from(json['server'] as Map)
      ..['address'] = normalized;
    final channelsJson = (json['channels'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final userJson = Map<String, dynamic>.from(json['user'] as Map);

    return AuthSessionResult(
      token: json['token'] as String,
      created: json['created'] as bool? ?? false,
      becameOwner: json['becameOwner'] as bool? ?? false,
      server: ChatServer.fromJson(serverJson),
      channels: channelsJson.map(ChatChannel.fromJson).toList(),
      user: Member.fromJson(userJson),
      permissions: ServerPermissions.fromJson(
        Map<String, dynamic>.from(json['permissions'] as Map? ?? const {}),
      ),
    );
  }

  Future<SessionBundle> fetchMe({
    required String baseUrl,
    required String token,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'GET',
      '$normalized/api/auth/me',
      token: token,
    );

    final serverJson = Map<String, dynamic>.from(json['server'] as Map)
      ..['address'] = normalized;
    final channelsJson = (json['channels'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final userJson = Map<String, dynamic>.from(json['user'] as Map);

    return SessionBundle(
      server: ChatServer.fromJson(serverJson),
      channels: channelsJson.map(ChatChannel.fromJson).toList(),
      user: Member.fromJson(userJson),
      permissions: ServerPermissions.fromJson(
        Map<String, dynamic>.from(json['permissions'] as Map? ?? const {}),
      ),
    );
  }

  Future<Member> updateCurrentUserSettings({
    required String baseUrl,
    required String token,
    String? displayName,
    Object? avatarUrl = _avatarUnspecified,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final body = <String, dynamic>{};

    if (displayName != null) {
      body['displayName'] = displayName;
    }
    if (!identical(avatarUrl, _avatarUnspecified)) {
      body['avatarUrl'] = avatarUrl;
    }

    final json = await _requestJson(
      'PATCH',
      '$normalized/api/users/me',
      token: token,
      body: body,
    );

    return Member.fromJson(Map<String, dynamic>.from(json['user'] as Map));
  }

  Future<VoiceConnectionCredentials> fetchVoiceConnection({
    required String baseUrl,
    required String token,
    required String channelId,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/voice/token',
      token: token,
      body: {'channelId': channelId},
    );

    return VoiceConnectionCredentials(
      serverUrl: (json['url'] as String? ?? '').trim(),
      participantToken: (json['token'] as String? ?? '').trim(),
      roomName: (json['roomName'] as String? ?? '').trim(),
    );
  }

  Future<ServerSettings> fetchServerSettings({
    required String baseUrl,
    required String token,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'GET',
      '$normalized/api/server/settings',
      token: token,
    );

    return ServerSettings.fromJson(
      Map<String, dynamic>.from(json['settings'] as Map),
    );
  }

  Future<ServerStorageStatus> fetchServerStorage({
    required String baseUrl,
    required String token,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'GET',
      '$normalized/api/server/storage',
      token: token,
    );
    return ServerStorageStatus.fromJson(
      Map<String, dynamic>.from(json['storage'] as Map),
    );
  }

  Future<ServerSettings> updateServerSettings({
    required String baseUrl,
    required String token,
    required Map<String, dynamic> patch,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'PATCH',
      '$normalized/api/server/settings',
      token: token,
      body: patch,
    );

    return ServerSettings.fromJson(
      Map<String, dynamic>.from(json['settings'] as Map),
    );
  }

  Future<ChatServer> updateServerProfile({
    required String baseUrl,
    required String token,
    required Map<String, dynamic> patch,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'PATCH',
      '$normalized/api/admin/server',
      token: token,
      body: patch,
    );

    final serverJson = Map<String, dynamic>.from(json['server'] as Map)
      ..['address'] = normalized;
    return ChatServer.fromJson(serverJson);
  }

  Future<BrandingUploadResult> uploadServerBrandingAsset({
    required String baseUrl,
    required String token,
    required String slot,
    required File file,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final normalizedSlot = slot.trim().toLowerCase();

    if (normalizedSlot != 'icon' && normalizedSlot != 'banner') {
      throw ApiException('Branding slot must be icon or banner.');
    }

    final uri = Uri.parse('$normalized/api/admin/server/$normalizedSlot');
    final request = http.MultipartRequest('POST', uri)
      ..headers['Accept'] = 'application/json'
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(
        await http.MultipartFile.fromPath(
          'file',
          file.path,
          filename: file.uri.pathSegments.isNotEmpty
              ? file.uri.pathSegments.last
              : 'branding_image.bin',
        ),
      );

    final decoded = await _sendMultipartJson(
      request,
      failureLabel: 'Branding upload',
    );

    final serverJson = Map<String, dynamic>.from(decoded['server'] as Map)
      ..['address'] = normalized;

    return BrandingUploadResult(
      slot: decoded['slot']?.toString() ?? normalizedSlot,
      assetUrl: decoded['assetUrl']?.toString() ?? '',
      server: ChatServer.fromJson(serverJson),
    );
  }

  Future<AdminChannelCreateResult> createChannel({
    required String baseUrl,
    required String token,
    required String name,
    required String type,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/admin/channels',
      token: token,
      body: {'name': name, 'type': type},
    );

    final channelJson = Map<String, dynamic>.from(json['channel'] as Map);
    final channelsJson = (json['channels'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    return AdminChannelCreateResult(
      channel: ChatChannel.fromJson(channelJson),
      channels: channelsJson.map(ChatChannel.fromJson).toList(),
    );
  }

  Future<AdminChannelCreateResult> updateChannel({
    required String baseUrl,
    required String token,
    required String channelId,
    required String name,
    String? glyph,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'PATCH',
      '$normalized/api/admin/channels/$channelId',
      token: token,
      body: {'name': name, 'glyph': glyph},
    );

    final channelJson = Map<String, dynamic>.from(json['channel'] as Map);
    final channelsJson = (json['channels'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    return AdminChannelCreateResult(
      channel: ChatChannel.fromJson(channelJson),
      channels: channelsJson.map(ChatChannel.fromJson).toList(),
    );
  }

  Future<List<ChatChannel>> deleteChannel({
    required String baseUrl,
    required String token,
    required String channelId,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'DELETE',
      '$normalized/api/admin/channels/$channelId',
      token: token,
    );

    final channelsJson = (json['channels'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    return channelsJson.map(ChatChannel.fromJson).toList();
  }

  Future<List<Member>> fetchMembers({
    required String baseUrl,
    required String token,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'GET',
      '$normalized/api/members',
      token: token,
    );

    final membersJson = (json['members'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    return membersJson.map(Member.fromJson).toList();
  }

  Future<HistoryRecoveryDeviceKey> registerHistoryRecoveryDeviceKey({
    required String baseUrl,
    required String token,
    required String expectedDeviceId,
    required String publicKey,
    required String yuidAuthorizationSignature,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/mls/history-recovery/keys',
      token: token,
      body: {
        'publicKey': publicKey,
        'yuidAuthorizationSignature': yuidAuthorizationSignature,
      },
    );
    try {
      final key = HistoryRecoveryDeviceKey.fromJson(
        Map<String, dynamic>.from(json['key'] as Map),
      );
      if (key.deviceId != expectedDeviceId ||
          key.publicKey != publicKey ||
          key.yuidAuthorizationSignature != yuidAuthorizationSignature) {
        throw const FormatException(
          'History recovery key registration was substituted.',
        );
      }
      return key;
    } catch (_) {
      throw ApiException(
        'The server returned invalid encrypted-history recovery key metadata.',
        code: 'invalid_history_recovery_response',
      );
    }
  }

  Future<HistoryRecoveryKeyDirectory> fetchHistoryRecoveryDeviceKeys({
    required String baseUrl,
    required String token,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'GET',
      '$normalized/api/mls/history-recovery/keys',
      token: token,
    );
    try {
      final accountYuid = json['accountYuid']?.toString() ?? '';
      if (!RegExp(r'^[A-Za-z0-9_-]{20}$').hasMatch(accountYuid)) {
        throw const FormatException('Invalid recovery account.');
      }
      final rawKeys = json['keys'];
      if (rawKeys is! List || rawKeys.length > 100) {
        throw const FormatException('Invalid recovery key directory.');
      }
      return HistoryRecoveryKeyDirectory(
        accountYuid: accountYuid,
        keys: rawKeys
            .map(
              (item) => HistoryRecoveryDeviceKey.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(growable: false),
      );
    } catch (_) {
      throw ApiException(
        'The server returned an invalid encrypted-history recovery directory.',
        code: 'invalid_history_recovery_response',
      );
    }
  }

  Future<HistoryRecoveryTransferResult> createHistoryRecoveryTransfer({
    required String baseUrl,
    required String token,
    required String channelId,
    required String transferId,
    required String sourceDeviceId,
    required String destinationDeviceId,
    required int firstServerSequence,
    required int lastServerSequence,
    required int eventCount,
    required int chunkCount,
    required int totalBytes,
    required Uint8List manifest,
    required String manifestSha256,
    required String yuidSignature,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/channels/$channelId/mls/history-recovery/transfers',
      token: token,
      body: {
        'id': transferId,
        'destinationDeviceId': destinationDeviceId,
        'firstServerSequence': firstServerSequence,
        'lastServerSequence': lastServerSequence,
        'eventCount': eventCount,
        'chunkCount': chunkCount,
        'totalBytes': totalBytes,
        'manifest': base64Url.encode(manifest).replaceAll('=', ''),
        'manifestSha256': manifestSha256,
        'yuidSignature': yuidSignature,
      },
    );
    try {
      final transfer = HistoryRecoveryTransfer.fromJson(
        Map<String, dynamic>.from(json['transfer'] as Map),
      );
      if (transfer.id != transferId ||
          transfer.channelId != channelId ||
          transfer.sourceDeviceId != sourceDeviceId ||
          transfer.destinationDeviceId != destinationDeviceId ||
          transfer.firstServerSequence != firstServerSequence ||
          transfer.lastServerSequence != lastServerSequence ||
          transfer.eventCount != eventCount ||
          transfer.chunkCount != chunkCount ||
          transfer.totalBytes != totalBytes ||
          transfer.manifestSha256 != manifestSha256 ||
          transfer.yuidSignature != yuidSignature ||
          !_constantTimeBytesEqual(transfer.manifest!, manifest)) {
        throw const FormatException('History recovery transfer substituted.');
      }
      return HistoryRecoveryTransferResult(
        changed: json['created'] == true,
        transfer: transfer,
      );
    } catch (_) {
      throw ApiException(
        'The server returned invalid encrypted-history transfer metadata.',
        code: 'invalid_history_recovery_response',
      );
    }
  }

  Future<bool> uploadHistoryRecoveryChunk({
    required String baseUrl,
    required String token,
    required String transferId,
    required int chunkIndex,
    required Uint8List ciphertext,
    required String ciphertextSha256,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestBinaryJson(
      'PUT',
      '$normalized/api/mls/history-recovery/transfers/$transferId/chunks/'
          '$chunkIndex',
      token: token,
      body: ciphertext,
      headers: {'X-Yappa-Content-Sha256': ciphertextSha256},
    );
    if (json['transferId'] != transferId ||
        json['chunkIndex'] != chunkIndex ||
        json['sizeBytes'] != ciphertext.length ||
        json['ciphertextSha256'] != ciphertextSha256 ||
        json['created'] is! bool) {
      throw ApiException(
        'The server returned invalid encrypted-history chunk metadata.',
        code: 'invalid_history_recovery_response',
      );
    }
    return json['created'] as bool;
  }

  Future<HistoryRecoveryTransferResult> finalizeHistoryRecoveryTransfer({
    required String baseUrl,
    required String token,
    required String transferId,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/mls/history-recovery/transfers/$transferId/finalize',
      token: token,
    );
    return _parseHistoryRecoveryMutation(
      json,
      transferId: transferId,
      changedField: 'finalized',
      expectedState: HistoryRecoveryTransferState.ready,
    );
  }

  Future<List<HistoryRecoveryTransfer>> fetchHistoryRecoveryTransfers({
    required String baseUrl,
    required String token,
    required String channelId,
    required String destinationDeviceId,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'GET',
      '$normalized/api/channels/$channelId/mls/history-recovery/transfers',
      token: token,
    );
    try {
      final raw = json['transfers'];
      if (raw is! List || raw.length > 20) throw const FormatException();
      final transfers = raw
          .map(
            (item) => HistoryRecoveryTransfer.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(growable: false);
      final ids = <String>{};
      for (final transfer in transfers) {
        if (transfer.channelId != channelId ||
            transfer.destinationDeviceId != destinationDeviceId ||
            transfer.state != HistoryRecoveryTransferState.ready ||
            !ids.add(transfer.id)) {
          throw const FormatException();
        }
      }
      return transfers;
    } catch (_) {
      throw ApiException(
        'The server returned an invalid encrypted-history transfer list.',
        code: 'invalid_history_recovery_response',
      );
    }
  }

  Future<HistoryRecoveryChunk> downloadHistoryRecoveryChunk({
    required String baseUrl,
    required String token,
    required String transferId,
    required int chunkIndex,
    required String expectedSha256,
    required int expectedSizeBytes,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'GET',
      '$normalized/api/mls/history-recovery/transfers/$transferId/chunks/'
          '$chunkIndex',
      token: token,
    );
    try {
      final encoded = json['ciphertext'] as String;
      final ciphertext = Uint8List.fromList(_decodeBase64Url(encoded));
      final digest = hashes.sha256.convert(ciphertext).toString();
      if (json['transferId'] != transferId ||
          json['chunkIndex'] != chunkIndex ||
          json['sizeBytes'] != ciphertext.length ||
          ciphertext.length != expectedSizeBytes ||
          json['ciphertextSha256'] != expectedSha256 ||
          digest != expectedSha256 ||
          ciphertext.isEmpty ||
          ciphertext.length > 256 * 1024) {
        throw const FormatException();
      }
      return HistoryRecoveryChunk(
        transferId: transferId,
        chunkIndex: chunkIndex,
        ciphertext: ciphertext,
        ciphertextSha256: digest,
      );
    } catch (_) {
      throw ApiException(
        'The server returned an invalid encrypted-history chunk.',
        code: 'invalid_history_recovery_response',
      );
    }
  }

  Future<HistoryRecoveryTransferResult> consumeHistoryRecoveryTransfer({
    required String baseUrl,
    required String token,
    required String transferId,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/mls/history-recovery/transfers/$transferId/consume',
      token: token,
    );
    return _parseHistoryRecoveryMutation(
      json,
      transferId: transferId,
      changedField: 'consumed',
      expectedState: HistoryRecoveryTransferState.consumed,
      requireManifest: false,
    );
  }

  Future<bool> cancelHistoryRecoveryTransfer({
    required String baseUrl,
    required String token,
    required String transferId,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'DELETE',
      '$normalized/api/mls/history-recovery/transfers/$transferId',
      token: token,
    );
    if (json['transferId'] != transferId || json['canceled'] is! bool) {
      throw ApiException(
        'The server returned invalid encrypted-history cancellation metadata.',
        code: 'invalid_history_recovery_response',
      );
    }
    return json['canceled'] as bool;
  }

  HistoryRecoveryTransferResult _parseHistoryRecoveryMutation(
    Map<String, dynamic> json, {
    required String transferId,
    required String changedField,
    required HistoryRecoveryTransferState expectedState,
    bool requireManifest = true,
  }) {
    try {
      final changed = json[changedField];
      final transfer = HistoryRecoveryTransfer.fromJson(
        Map<String, dynamic>.from(json['transfer'] as Map),
        requireManifest: requireManifest,
      );
      if (changed is! bool ||
          transfer.id != transferId ||
          transfer.state != expectedState) {
        throw const FormatException();
      }
      return HistoryRecoveryTransferResult(
        changed: changed,
        transfer: transfer,
      );
    } catch (_) {
      throw ApiException(
        'The server returned invalid encrypted-history lifecycle metadata.',
        code: 'invalid_history_recovery_response',
      );
    }
  }

  Future<MlsKeyPackageInventory> fetchMlsKeyPackageInventory({
    required String baseUrl,
    required String token,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'GET',
      '$normalized/api/mls/key-packages',
      token: token,
    );
    return _parseMlsResponse(() => MlsKeyPackageInventory.fromJson(json));
  }

  Future<void> registerMlsKeyPackages({
    required String baseUrl,
    required String token,
    required String expectedDeviceId,
    required List<MlsKeyPackageRegistration> packages,
  }) async {
    if (packages.isEmpty || packages.length > 2) {
      throw ApiException(
        'Register one or two MLS KeyPackages at a time.',
        code: 'invalid_mls_key_packages',
      );
    }
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/mls/key-packages',
      token: token,
      body: {'packages': packages.map((item) => item.toJson()).toList()},
    );
    final returnedDeviceId = json['deviceId']?.toString();
    final registered = (json['registered'] as num?)?.toInt();
    if (returnedDeviceId != expectedDeviceId || registered != packages.length) {
      throw ApiException(
        'The server returned mismatched MLS KeyPackage registration metadata.',
        code: 'invalid_mls_response',
      );
    }
  }

  Future<ClaimedMlsKeyPackage> claimMlsKeyPackage({
    required String baseUrl,
    required String token,
    required String targetDeviceId,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/mls/key-packages/claim',
      token: token,
      body: {'deviceId': targetDeviceId},
    );
    final raw = json['keyPackage'];
    final claimed = _parseMlsResponse(
      () =>
          ClaimedMlsKeyPackage.fromJson(Map<String, dynamic>.from(raw as Map)),
    );
    if (claimed.deviceId != targetDeviceId) {
      throw ApiException(
        'The server returned a KeyPackage for a different device.',
        code: 'invalid_mls_response',
      );
    }
    return claimed;
  }

  Future<List<MlsDeviceCredential>> fetchMlsDeviceCredentials({
    required String baseUrl,
    required String token,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'GET',
      '$normalized/api/mls/device-credentials',
      token: token,
    );
    final raw = json['credentials'];
    return _parseMlsResponse(
      () => (raw as List)
          .map(
            (item) => MlsDeviceCredential.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(growable: false),
    );
  }

  Future<MlsChannelInitialization> initializeMlsChannel({
    required String baseUrl,
    required String token,
    required String serverId,
    required String channelId,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/channels/$channelId/mls/initialize',
      token: token,
      body: const {},
    );
    final raw = json['group'];
    final created = json['created'];
    final group = _parseMlsResponse(
      () => MlsChannelGroup.fromJson(Map<String, dynamic>.from(raw as Map)),
    );
    if (created is! bool ||
        group.groupId != 'yappa-text-v1|$serverId|$channelId') {
      throw ApiException(
        'The server returned the wrong MLS group identity.',
        code: 'invalid_mls_response',
      );
    }
    return MlsChannelInitialization(group: group, created: created);
  }

  Future<MlsDeliveryMessage> submitMlsDeliveryMessage({
    required String baseUrl,
    required String token,
    required String channelId,
    required String clientOperationId,
    required MlsDeliveryMessageClass messageClass,
    required int acceptedEpoch,
    required Uint8List wireMessage,
    int? parentEpoch,
    String? recipientDeviceId,
    EncryptedApplicationEventRouting? event,
  }) async {
    if (!RegExp(r'^mlsop_[A-Za-z0-9_-]{22}$').hasMatch(clientOperationId) ||
        acceptedEpoch < 0 ||
        wireMessage.isEmpty ||
        wireMessage.length > 131072 ||
        switch (messageClass) {
          MlsDeliveryMessageClass.commit =>
            parentEpoch == null ||
                acceptedEpoch != parentEpoch + 1 ||
                recipientDeviceId != null ||
                event != null,
          MlsDeliveryMessageClass.proposal =>
            parentEpoch == null ||
                acceptedEpoch != parentEpoch ||
                recipientDeviceId != null ||
                event != null,
          MlsDeliveryMessageClass.welcome =>
            parentEpoch != null || recipientDeviceId == null || event != null,
          MlsDeliveryMessageClass.application =>
            parentEpoch != null || recipientDeviceId != null || event == null,
        }) {
      throw ApiException(
        'Invalid MLS delivery message.',
        code: 'invalid_mls_delivery_message',
      );
    }
    if (event != null) {
      _parseMlsResponse(
        () => EncryptedApplicationEventRouting.fromJson(event.toJson()),
      );
    }
    final normalized = normalizeBaseUrl(baseUrl);
    final wireText = base64Url.encode(wireMessage).replaceAll('=', '');
    final json = await _requestJson(
      'POST',
      '$normalized/api/channels/$channelId/mls/messages',
      token: token,
      body: {
        'clientOperationId': clientOperationId,
        'messageClass': messageClass.name,
        'acceptedEpoch': acceptedEpoch,
        'parentEpoch': ?parentEpoch,
        'recipientDeviceId': ?recipientDeviceId,
        'wireMessage': wireText,
        if (event != null) 'event': event.toJson(),
      },
    );
    final raw = json['message'];
    final delivery = _parseMlsResponse(
      () => MlsDeliveryMessage.fromJson(Map<String, dynamic>.from(raw as Map)),
    );
    if (delivery.channelId != channelId ||
        delivery.clientOperationId != clientOperationId ||
        delivery.messageClass != messageClass ||
        delivery.acceptedEpoch != acceptedEpoch ||
        delivery.parentEpoch != parentEpoch ||
        delivery.recipientDeviceId != recipientDeviceId ||
        !_constantTimeBytesEqual(delivery.wireMessage, wireMessage) ||
        delivery.event?.eventId != event?.eventId ||
        delivery.event?.kind != event?.kind ||
        delivery.event?.targetEventId != event?.targetEventId ||
        !_sameStrings(
          delivery.event?.encryptedAttachmentIds ?? const [],
          event?.encryptedAttachmentIds ?? const [],
        )) {
      throw ApiException(
        'The server substituted MLS delivery metadata.',
        code: 'invalid_mls_response',
      );
    }
    return delivery;
  }

  Future<MlsDeliveryBatch> fetchMlsDeliveryMessages({
    required String baseUrl,
    required String token,
    required String serverId,
    required String channelId,
    required int after,
    int limit = 100,
  }) async {
    if (after < 0 || limit < 1 || limit > 200) {
      throw ApiException(
        'Invalid MLS delivery cursor.',
        code: 'invalid_mls_delivery_cursor',
      );
    }
    final normalized = normalizeBaseUrl(baseUrl);
    final uri = Uri.parse('$normalized/api/channels/$channelId/mls/messages')
        .replace(
          queryParameters: {
            'after': after.toString(),
            'limit': limit.toString(),
          },
        );
    final json = await _requestJson('GET', uri.toString(), token: token);
    final batch = _parseMlsResponse(
      () => MlsDeliveryBatch.fromJson(json, after: after),
    );
    if (batch.group.groupId != 'yappa-text-v1|$serverId|$channelId' ||
        batch.messages.any((message) => message.channelId != channelId)) {
      throw ApiException(
        'The server returned messages for the wrong MLS group.',
        code: 'invalid_mls_response',
      );
    }
    return batch;
  }

  Future<MlsDeliveryAcknowledgement> acknowledgeMlsDelivery({
    required String baseUrl,
    required String token,
    required String channelId,
    required int acknowledgedSequence,
    required int acknowledgedEpoch,
  }) async {
    if (acknowledgedSequence < 0 || acknowledgedEpoch < 0) {
      throw ApiException(
        'Invalid MLS acknowledgement.',
        code: 'invalid_mls_acknowledgement',
      );
    }
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/channels/$channelId/mls/ack',
      token: token,
      body: {
        'acknowledgedSequence': acknowledgedSequence,
        'acknowledgedEpoch': acknowledgedEpoch,
      },
    );
    final raw = json['cursor'];
    final cursor = _parseMlsResponse(
      () => MlsDeliveryAcknowledgement.fromJson(
        Map<String, dynamic>.from(raw as Map),
      ),
    );
    if (cursor.acknowledgedSequence != acknowledgedSequence ||
        cursor.acknowledgedEpoch != acknowledgedEpoch) {
      throw ApiException(
        'The server returned a mismatched MLS acknowledgement.',
        code: 'invalid_mls_response',
      );
    }
    return cursor;
  }

  Future<MessageHistoryPage> fetchMessages({
    required String baseUrl,
    required String token,
    required String channelId,
    String? cursor,
    int limit = 50,
  }) async {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'must be from 1 to 100');
    }
    final normalized = normalizeBaseUrl(baseUrl);
    final query = <String, String>{'limit': limit.toString()};
    if (cursor != null && cursor.isNotEmpty) {
      query['cursor'] = cursor;
    }
    final uri = Uri.parse(
      '$normalized/api/channels/$channelId/messages',
    ).replace(queryParameters: query);
    final json = await _requestJson('GET', uri.toString(), token: token);

    final messagesJson = (json['messages'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    final messages = messagesJson
        .map(ChatMessage.fromJson)
        .map((message) => _resolveMessageUrls(message, normalized))
        .toList();
    final pageJson = json['page'];
    if (pageJson is! Map) {
      throw ApiException(
        'The server returned an invalid message history page.',
        code: 'invalid_history_response',
      );
    }
    final page = Map<String, dynamic>.from(pageJson);
    final direction = page['direction'];
    final hasMore = page['hasMore'];
    final nextCursor = page['nextCursor'];
    final forwardCursor = page['forwardCursor'];
    final backwardCursor = page['backwardCursor'];
    if ((direction != 'before' && direction != 'after') ||
        hasMore is! bool ||
        (nextCursor != null && nextCursor is! String) ||
        (forwardCursor != null && forwardCursor is! String) ||
        (backwardCursor != null && backwardCursor is! String) ||
        (hasMore && (nextCursor is! String || nextCursor.isEmpty)) ||
        (!hasMore && nextCursor != null) ||
        (messages.isNotEmpty &&
            (forwardCursor is! String ||
                forwardCursor.isEmpty ||
                backwardCursor is! String ||
                backwardCursor.isEmpty))) {
      throw ApiException(
        'The server returned an invalid message history cursor.',
        code: 'invalid_history_response',
      );
    }
    return MessageHistoryPage(
      messages: messages,
      direction: direction as String,
      hasMore: hasMore,
      nextCursor: nextCursor as String?,
      forwardCursor: forwardCursor as String?,
      backwardCursor: backwardCursor as String?,
    );
  }

  Future<String> createMessageHistoryCursor({
    required String baseUrl,
    required String token,
    required String channelId,
    required String messageId,
    required String direction,
  }) async {
    if (direction != 'before' && direction != 'after') {
      throw ArgumentError.value(direction, 'direction');
    }
    final normalized = normalizeBaseUrl(baseUrl);
    final uri = Uri.parse('$normalized/api/channels/$channelId/messages/cursor')
        .replace(
          queryParameters: {'messageId': messageId, 'direction': direction},
        );
    final json = await _requestJson('GET', uri.toString(), token: token);
    final cursor = json['cursor'];
    if (json['direction'] != direction ||
        json['messageId']?.toString() != messageId ||
        cursor is! String ||
        cursor.isEmpty) {
      throw ApiException(
        'The server returned an invalid message history boundary.',
        code: 'invalid_history_response',
      );
    }
    return cursor;
  }

  Future<ChatAttachment> uploadAttachment({
    required String baseUrl,
    required String token,
    required String channelId,
    required File file,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final uri = Uri.parse('$normalized/api/uploads/attachments');

    final request = http.MultipartRequest('POST', uri)
      ..headers['Accept'] = 'application/json'
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['channelId'] = channelId
      ..files.add(
        await http.MultipartFile.fromPath(
          'file',
          file.path,
          filename: file.uri.pathSegments.isNotEmpty
              ? file.uri.pathSegments.last
              : 'upload.bin',
        ),
      );

    final decoded = await _sendMultipartJson(request, failureLabel: 'Upload');

    return _resolveAttachmentUrl(
      ChatAttachment.fromJson(
        Map<String, dynamic>.from(decoded['attachment'] as Map),
      ),
      normalized,
    );
  }

  Future<EncryptedAttachmentUploadReceipt> uploadEncryptedAttachment({
    required String baseUrl,
    required String token,
    required String channelId,
    required String attachmentId,
    required EncryptedAttachmentObject encrypted,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final uri = Uri.parse(
      '$normalized/api/channels/$channelId/encrypted-attachments',
    );
    final headerText = base64Url.encode(encrypted.header).replaceAll('=', '');
    final request = http.MultipartRequest('POST', uri)
      ..headers['Accept'] = 'application/json'
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['attachmentId'] = attachmentId
      ..fields['secretstreamHeader'] = headerText
      ..fields['ciphertextSha256'] = encrypted.ciphertextSha256
      ..fields['chunkCount'] = encrypted.chunkCount.toString()
      ..files.add(
        await http.MultipartFile.fromPath(
          'ciphertext',
          encrypted.ciphertextPath,
          filename: 'ciphertext.bin',
        ),
      );
    final decoded = await _sendMultipartJson(
      request,
      failureLabel: 'Encrypted attachment upload',
    );
    final rawAttachment = decoded['attachment'];
    if (rawAttachment is! Map) {
      throw ApiException(
        'The server returned invalid encrypted attachment metadata.',
        code: 'invalid_encrypted_attachment_response',
      );
    }
    final attachment = Map<String, dynamic>.from(rawAttachment);
    Uint8List returnedHeader;
    try {
      returnedHeader = Uint8List.fromList(
        _decodeBase64Url((attachment['secretstreamHeader'] ?? '').toString()),
      );
    } catch (_) {
      throw ApiException(
        'The server returned an invalid secretstream header.',
        code: 'invalid_encrypted_attachment_response',
      );
    }
    final receipt = EncryptedAttachmentUploadReceipt(
      id: (attachment['id'] ?? '').toString(),
      channelId: (attachment['channelId'] ?? '').toString(),
      secretstreamHeader: returnedHeader,
      ciphertextSizeBytes:
          (attachment['ciphertextSizeBytes'] as num?)?.toInt() ?? -1,
      ciphertextSha256: (attachment['ciphertextSha256'] ?? '').toString(),
      chunkCount: (attachment['chunkCount'] as num?)?.toInt() ?? -1,
      createdAt: DateTime.tryParse((attachment['createdAt'] ?? '').toString()),
      expiresAt: attachment['expiresAt'] == null
          ? null
          : DateTime.tryParse(attachment['expiresAt'].toString()),
    );
    if (receipt.id != attachmentId ||
        receipt.channelId != channelId ||
        receipt.ciphertextSizeBytes != encrypted.ciphertextSizeBytes ||
        receipt.ciphertextSha256 != encrypted.ciphertextSha256 ||
        receipt.chunkCount != encrypted.chunkCount ||
        !_constantTimeBytesEqual(
          receipt.secretstreamHeader,
          encrypted.header,
        )) {
      throw ApiException(
        'The server returned mismatched encrypted attachment metadata.',
        code: 'encrypted_attachment_metadata_mismatch',
      );
    }
    return receipt;
  }

  Future<void> downloadEncryptedAttachment({
    required String baseUrl,
    required String token,
    required String channelId,
    required String attachmentId,
    required String outputPath,
    required Uint8List expectedSecretstreamHeader,
    required String expectedCiphertextSha256,
    required int expectedCiphertextSizeBytes,
    required int expectedChunkCount,
  }) async {
    final output = File(outputPath);
    final partial = File('$outputPath.partial');
    if (await output.exists() || await partial.exists()) {
      throw ApiException(
        'Refusing to overwrite an existing encrypted attachment file.',
        code: 'encrypted_attachment_output_exists',
      );
    }
    final normalized = normalizeBaseUrl(baseUrl);
    final uri = Uri.parse(
      '$normalized/api/channels/$channelId/encrypted-attachments/$attachmentId',
    );
    final request = http.Request('GET', uri)
      ..headers['Accept'] = 'application/octet-stream'
      ..headers['Authorization'] = 'Bearer $token';
    final client = _clientFor(uri);
    RandomAccessFile? destination;
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(minutes: 2));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errorBody = await response.stream.bytesToString().timeout(
          const Duration(seconds: 10),
        );
        Map<String, dynamic> decoded = const {};
        try {
          final parsed = jsonDecode(errorBody);
          if (parsed is Map<String, dynamic>) decoded = parsed;
        } catch (_) {
          // The structured status below remains safe for a non-JSON response.
        }
        final errorMap = decoded['error'];
        throw ApiException(
          errorMap is Map && errorMap['message'] is String
              ? errorMap['message'] as String
              : 'Encrypted attachment download failed with status '
                    '${response.statusCode}.',
          statusCode: response.statusCode,
          code: errorMap is Map ? errorMap['code']?.toString() : null,
        );
      }
      Uint8List returnedHeader;
      try {
        returnedHeader = Uint8List.fromList(
          _decodeBase64Url(
            response.headers['x-yappa-secretstream-header'] ?? '',
          ),
        );
      } catch (_) {
        throw ApiException(
          'The server returned invalid encrypted attachment metadata.',
          code: 'encrypted_attachment_metadata_mismatch',
        );
      }
      final returnedDigest =
          response.headers['x-yappa-ciphertext-sha256'] ?? '';
      final returnedSize = int.tryParse(
        response.headers['x-yappa-ciphertext-size'] ?? '',
      );
      final returnedChunks = int.tryParse(
        response.headers['x-yappa-chunk-count'] ?? '',
      );
      if (!_constantTimeBytesEqual(
            returnedHeader,
            expectedSecretstreamHeader,
          ) ||
          returnedDigest != expectedCiphertextSha256 ||
          returnedSize != expectedCiphertextSizeBytes ||
          returnedChunks != expectedChunkCount ||
          response.contentLength != null &&
              response.contentLength != expectedCiphertextSizeBytes) {
        throw ApiException(
          'The server returned mismatched encrypted attachment metadata.',
          code: 'encrypted_attachment_metadata_mismatch',
        );
      }

      destination = await partial.open(mode: FileMode.writeOnly);
      final digestSink = _ApiDigestSink();
      final digestInput = hashes.sha256.startChunkedConversion(digestSink);
      var received = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(minutes: 2),
      )) {
        received += chunk.length;
        if (received > expectedCiphertextSizeBytes) {
          throw ApiException(
            'The encrypted attachment exceeded its authenticated size.',
            code: 'encrypted_attachment_size_mismatch',
          );
        }
        digestInput.add(chunk);
        await destination.writeFrom(chunk);
      }
      digestInput.close();
      if (received != expectedCiphertextSizeBytes ||
          digestSink.value?.toString() != expectedCiphertextSha256) {
        throw ApiException(
          'The encrypted attachment failed size or digest verification.',
          code: 'encrypted_attachment_digest_mismatch',
        );
      }
      await destination.close();
      destination = null;
      await partial.rename(outputPath);
    } on TimeoutException {
      throw ApiException(
        'The server did not finish the download in time.',
        code: 'connection_timeout',
      );
    } finally {
      await destination?.close();
      client.close();
      if (await partial.exists()) {
        await partial.delete();
      }
    }
  }

  Future<ChatMessage> sendMessage({
    required String baseUrl,
    required String token,
    required String channelId,
    required String content,
    List<String> attachmentIds = const [],
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/channels/$channelId/messages',
      token: token,
      body: {'content': content, 'attachmentIds': attachmentIds},
    );

    return _resolveMessageUrls(
      ChatMessage.fromJson(Map<String, dynamic>.from(json['message'] as Map)),
      normalized,
    );
  }

  Future<ChatMessage> updateMessage({
    required String baseUrl,
    required String token,
    required String channelId,
    required String messageId,
    required String content,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'PATCH',
      '$normalized/api/channels/$channelId/messages/$messageId',
      token: token,
      body: {'content': content},
    );

    return _resolveMessageUrls(
      ChatMessage.fromJson(Map<String, dynamic>.from(json['message'] as Map)),
      normalized,
    );
  }

  Future<void> deleteMessage({
    required String baseUrl,
    required String token,
    required String channelId,
    required String messageId,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    await _requestJson(
      'DELETE',
      '$normalized/api/channels/$channelId/messages/$messageId',
      token: token,
    );
  }

  Future<LinkPreview?> fetchLinkPreview({
    required String baseUrl,
    required String token,
    required String channelId,
    required String url,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final uri = Uri.parse(
      '$normalized/api/link-preview',
    ).replace(queryParameters: {'channelId': channelId, 'url': url});

    final json = await _requestJson('GET', uri.toString(), token: token);

    final previewJson = json['preview'];
    if (previewJson is! Map) {
      return null;
    }

    return LinkPreview.fromJson(Map<String, dynamic>.from(previewJson));
  }

  Future<void> logout({required String baseUrl, required String token}) async {
    final normalized = normalizeBaseUrl(baseUrl);
    await _requestJson('POST', '$normalized/api/auth/logout', token: token);
  }

  Future<String> rotateSession({
    required String baseUrl,
    required String token,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/auth/session/rotate',
      token: token,
    );
    return (json['token'] ?? '').toString();
  }

  Future<List<DeviceSession>> fetchSessions({
    required String baseUrl,
    required String token,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'GET',
      '$normalized/api/auth/sessions',
      token: token,
    );
    return (json['sessions'] as List? ?? const [])
        .map((item) => DeviceSession.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<bool> revokeSession({
    required String baseUrl,
    required String token,
    required String sessionId,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'DELETE',
      '$normalized/api/auth/sessions/$sessionId',
      token: token,
    );
    return json['revokedCurrent'] == true;
  }

  String _devicePlatformName() {
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    return 'Desktop';
  }

  Future<Map<String, dynamic>> _requestBinaryJson(
    String method,
    String url, {
    required String token,
    required Uint8List body,
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri.parse(url);
    final request = http.Request(method, uri)
      ..headers['Accept'] = 'application/json'
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/octet-stream'
      ..headers.addAll(headers)
      ..bodyBytes = body;
    final client = _clientFor(uri);
    late final http.Response response;
    try {
      final streamed = await client
          .send(request)
          .timeout(const Duration(minutes: 2));
      response = await http.Response.fromStream(
        streamed,
      ).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw ApiException(
        'The server did not finish the encrypted-history upload in time.',
        code: 'connection_timeout',
      );
    } finally {
      client.close();
    }
    return _decodeJsonResponse(response);
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String url, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    final headers = <String, String>{'Accept': 'application/json'};

    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }

    final uri = Uri.parse(url);
    final client = _clientFor(uri);
    late final Future<http.Response> responseFuture;
    switch (method.toUpperCase()) {
      case 'GET':
        responseFuture = client.get(uri, headers: headers);
        break;
      case 'POST':
        headers['Content-Type'] = 'application/json';
        responseFuture = client.post(
          uri,
          headers: headers,
          body: jsonEncode(body ?? const {}),
        );
        break;
      case 'PATCH':
        headers['Content-Type'] = 'application/json';
        responseFuture = client.patch(
          uri,
          headers: headers,
          body: jsonEncode(body ?? const {}),
        );
        break;
      case 'DELETE':
        responseFuture = client.delete(uri, headers: headers);
        break;
      default:
        throw ApiException('Unsupported HTTP method: $method');
    }
    late final http.Response response;
    try {
      response = await responseFuture.timeout(const Duration(seconds: 6));
    } on TimeoutException {
      throw ApiException(
        'The server did not respond in time.',
        code: 'connection_timeout',
      );
    } finally {
      client.close();
    }

    return _decodeJsonResponse(response);
  }

  Map<String, dynamic> _decodeJsonResponse(http.Response response) {
    Map<String, dynamic> decoded = const {};
    try {
      if (response.body.isNotEmpty) {
        final dynamic parsed = jsonDecode(response.body);
        if (parsed is Map<String, dynamic>) decoded = parsed;
      }
    } catch (_) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw ApiException(
          'The server returned an invalid response.',
          code: 'invalid_server_response',
        );
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }
    final errorMap = decoded['error'];
    if (errorMap is Map<String, dynamic> && errorMap['message'] is String) {
      throw ApiException(
        errorMap['message'] as String,
        statusCode: response.statusCode,
        code: errorMap['code']?.toString(),
      );
    }
    throw ApiException(
      'Request failed with status ${response.statusCode}.',
      statusCode: response.statusCode,
    );
  }

  T _parseMlsResponse<T>(T Function() parse) {
    try {
      return parse();
    } on FormatException {
      throw ApiException(
        'The server returned invalid encrypted-messaging data.',
        code: 'invalid_mls_response',
      );
    } on TypeError {
      throw ApiException(
        'The server returned invalid encrypted-messaging data.',
        code: 'invalid_mls_response',
      );
    }
  }

  Future<Map<String, dynamic>> _sendMultipartJson(
    http.MultipartRequest request, {
    required String failureLabel,
  }) async {
    final client = _clientFor(request.url);
    late final http.Response response;
    try {
      final streamed = await client
          .send(request)
          .timeout(const Duration(minutes: 2));
      response = await http.Response.fromStream(
        streamed,
      ).timeout(const Duration(minutes: 2));
    } on TimeoutException {
      throw ApiException(
        'The server did not finish the upload in time.',
        code: 'connection_timeout',
      );
    } finally {
      client.close();
    }

    Map<String, dynamic> decoded = const {};
    if (response.body.isNotEmpty) {
      final dynamic parsed = jsonDecode(response.body);
      if (parsed is Map<String, dynamic>) {
        decoded = parsed;
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorMap = decoded['error'];
      if (errorMap is Map<String, dynamic> && errorMap['message'] is String) {
        throw ApiException(
          errorMap['message'] as String,
          statusCode: response.statusCode,
          code: errorMap['code']?.toString(),
        );
      }
      throw ApiException(
        '$failureLabel failed with status ${response.statusCode}.',
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  http.Client _clientFor(Uri uri) {
    final clientFactory = _clientFactory;
    if (clientFactory != null) return clientFactory(uri);
    final target = _lanRoutes[uri.origin];
    if (target == null) return http.Client();

    final ioClient = HttpClient();
    ioClient.findProxy = (_) => 'DIRECT';
    ioClient.connectionTimeout = const Duration(seconds: 6);
    ioClient.connectionFactory = (requestUri, proxyHost, proxyPort) async {
      if (proxyHost != null ||
          proxyPort != null ||
          requestUri.scheme != 'https' ||
          requestUri.origin != uri.origin) {
        throw const SocketException('Invalid secure LAN route request.');
      }
      final rawTask = await Socket.startConnect(target.host, target.port);
      final secureSocket = rawTask.socket.then(
        (socket) => SecureSocket.secure(socket, host: requestUri.host),
      );
      return ConnectionTask.fromSocket(secureSocket, rawTask.cancel);
    };
    return IOClient(ioClient);
  }
}
