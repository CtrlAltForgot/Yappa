import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/channel_model.dart';
import '../models/link_preview_model.dart';
import '../models/member_model.dart';
import '../models/message_model.dart';
import '../models/server_model.dart';
import '../models/server_permissions.dart';

class ApiException implements Exception {
  final String message;

  ApiException(this.message);

  @override
  String toString() => message;
}

class NodeHandshakeResult {
  final ChatServer server;
  final List<ChatChannel> channels;

  NodeHandshakeResult({
    required this.server,
    required this.channels,
  });
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

class AdminChannelCreateResult {
  final ChatChannel channel;
  final List<ChatChannel> channels;

  AdminChannelCreateResult({
    required this.channel,
    required this.channels,
  });
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
          (json['attachmentRetentionDays'] as num?)?.toInt() ?? 30,
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
  static const Object _avatarUnspecified = Object();
  static Object get avatarUnspecified => _avatarUnspecified;

  String normalizeBaseUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw ApiException('Enter a server IP or host.');
    }

    final hasScheme =
        trimmed.startsWith('http://') || trimmed.startsWith('https://');
    final withScheme = hasScheme ? trimmed : 'http://$trimmed';

    late final Uri uri;
    try {
      uri = Uri.parse(withScheme);
    } catch (_) {
      throw ApiException('Enter a valid server IP or host.');
    }

    if (uri.host.isEmpty) {
      throw ApiException('Enter a valid server IP or host.');
    }

    final normalized = Uri(
      scheme: uri.scheme.isEmpty ? 'http' : uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : 4100,
    ).toString();

    return normalized.replaceFirst(RegExp(r'/*$'), '');
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
    final channelsJson = (json['channels'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    return NodeHandshakeResult(
      server: ChatServer.fromJson(serverJson),
      channels: channelsJson.map(ChatChannel.fromJson).toList(),
    );
  }


Future<YuidChallenge> fetchYuidChallenge({
  required String baseUrl,
}) async {
  final normalized = normalizeBaseUrl(baseUrl);
  final json = await _requestJson(
    'GET',
    '$normalized/api/auth/yuid/challenge',
  );

  return YuidChallenge.fromJson(
    Map<String, dynamic>.from(json['challenge'] as Map),
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
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'POST',
      '$normalized/api/auth/session',
      body: {
        'username': username,
        'password': password,
        'yuid': yuid,
        'yuidPublicKey': yuidPublicKey,
        'yuidSignature': yuidSignature,
        'yuidNonce': yuidNonce,
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
      body: {
        'channelId': channelId,
      },
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

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);

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
        throw ApiException(errorMap['message'] as String);
      }
      throw ApiException(
        'Branding upload failed with status ${response.statusCode}.',
      );
    }

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
      body: {
        'name': name,
        'type': type,
      },
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

  Future<List<ChatMessage>> fetchMessages({
    required String baseUrl,
    required String token,
    required String channelId,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final json = await _requestJson(
      'GET',
      '$normalized/api/channels/$channelId/messages',
      token: token,
    );

    final messagesJson = (json['messages'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    return messagesJson
        .map(ChatMessage.fromJson)
        .map((message) => _resolveMessageUrls(message, normalized))
        .toList();
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

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);

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
        throw ApiException(errorMap['message'] as String);
      }
      throw ApiException('Upload failed with status ${response.statusCode}.');
    }

    return _resolveAttachmentUrl(
      ChatAttachment.fromJson(
        Map<String, dynamic>.from(decoded['attachment'] as Map),
      ),
      normalized,
    );
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
      body: {
        'content': content,
        'attachmentIds': attachmentIds,
      },
    );

    return _resolveMessageUrls(
      ChatMessage.fromJson(
        Map<String, dynamic>.from(json['message'] as Map),
      ),
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
      body: {
        'content': content,
      },
    );

    return _resolveMessageUrls(
      ChatMessage.fromJson(
        Map<String, dynamic>.from(json['message'] as Map),
      ),
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
    required String url,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final uri = Uri.parse('$normalized/api/link-preview').replace(
      queryParameters: {
        'url': url,
      },
    );

    final json = await _requestJson(
      'GET',
      uri.toString(),
      token: token,
    );

    final previewJson = json['preview'];
    if (previewJson is! Map) {
      return null;
    }

    return LinkPreview.fromJson(Map<String, dynamic>.from(previewJson));
  }

  Future<void> logout({
    required String baseUrl,
    required String token,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    await _requestJson(
      'POST',
      '$normalized/api/auth/logout',
      token: token,
    );
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String url, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    final headers = <String, String>{
      'Accept': 'application/json',
    };

    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }

    http.Response response;

    switch (method.toUpperCase()) {
      case 'GET':
        response = await http.get(Uri.parse(url), headers: headers);
        break;
      case 'POST':
        headers['Content-Type'] = 'application/json';
        response = await http.post(
          Uri.parse(url),
          headers: headers,
          body: jsonEncode(body ?? const {}),
        );
        break;
      case 'PATCH':
        headers['Content-Type'] = 'application/json';
        response = await http.patch(
          Uri.parse(url),
          headers: headers,
          body: jsonEncode(body ?? const {}),
        );
        break;
      case 'DELETE':
        response = await http.delete(Uri.parse(url), headers: headers);
        break;
      default:
        throw ApiException('Unsupported HTTP method: $method');
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
        throw ApiException(errorMap['message'] as String);
      }
      throw ApiException('Request failed with status ${response.statusCode}.');
    }

    return decoded;
  }
}