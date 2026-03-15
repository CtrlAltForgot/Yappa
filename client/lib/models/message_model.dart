class ChatAttachment {
  final String id;
  final String serverId;
  final String channelId;
  final String? messageId;
  final String kind;
  final String name;
  final String originalName;
  final String storedName;
  final String mimeType;
  final int sizeBytes;
  final String url;
  final String relativePath;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? deletedAt;

  const ChatAttachment({
    required this.id,
    required this.serverId,
    required this.channelId,
    required this.messageId,
    required this.kind,
    required this.name,
    required this.originalName,
    required this.storedName,
    required this.mimeType,
    required this.sizeBytes,
    required this.url,
    required this.relativePath,
    required this.createdAt,
    required this.expiresAt,
    required this.deletedAt,
  });

  bool get isImage => kind == 'image' || mimeType.startsWith('image/');
  bool get isVideo => kind == 'video' || mimeType.startsWith('video/');
  bool get isAudio => kind == 'audio' || mimeType.startsWith('audio/');

  ChatAttachment copyWith({
    String? id,
    String? serverId,
    String? channelId,
    String? messageId,
    String? kind,
    String? name,
    String? originalName,
    String? storedName,
    String? mimeType,
    int? sizeBytes,
    String? url,
    String? relativePath,
    DateTime? createdAt,
    DateTime? expiresAt,
    DateTime? deletedAt,
  }) {
    return ChatAttachment(
      id: id ?? this.id,
      serverId: serverId ?? this.serverId,
      channelId: channelId ?? this.channelId,
      messageId: messageId ?? this.messageId,
      kind: kind ?? this.kind,
      name: name ?? this.name,
      originalName: originalName ?? this.originalName,
      storedName: storedName ?? this.storedName,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      url: url ?? this.url,
      relativePath: relativePath ?? this.relativePath,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  ChatAttachment resolvedAgainst(String baseUrl) {
    final raw = url.trim();
    if (raw.isEmpty) {
      return this;
    }

    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return this;
    }

    final normalizedBase = baseUrl.replaceFirst(RegExp(r'/*$'), '');
    final normalizedPath = raw.startsWith('/') ? raw : '/$raw';

    return copyWith(url: '$normalizedBase$normalizedPath');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverId': serverId,
        'channelId': channelId,
        'messageId': messageId,
        'kind': kind,
        'name': name,
        'originalName': originalName,
        'storedName': storedName,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'url': url,
        'relativePath': relativePath,
        'createdAt': createdAt.toIso8601String(),
        'expiresAt': expiresAt?.toIso8601String(),
        'deletedAt': deletedAt?.toIso8601String(),
      };

  factory ChatAttachment.fromJson(Map<String, dynamic> json) {
    DateTime? parseOptionalDate(dynamic value) {
      if (value == null) return null;
      final text = value.toString().trim();
      if (text.isEmpty) return null;
      return DateTime.tryParse(text);
    }

    return ChatAttachment(
      id: json['id']?.toString() ?? '',
      serverId: json['serverId']?.toString() ?? '',
      channelId: json['channelId']?.toString() ?? '',
      messageId: json['messageId']?.toString(),
      kind: (json['kind'] as String?) ?? 'file',
      name: (json['name'] as String?) ??
          (json['originalName'] as String?) ??
          'file',
      originalName: (json['originalName'] as String?) ??
          (json['name'] as String?) ??
          'file',
      storedName: (json['storedName'] as String?) ?? '',
      mimeType: (json['mimeType'] as String?) ?? 'application/octet-stream',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      url: (json['url'] as String?) ?? '',
      relativePath: (json['relativePath'] as String?) ?? '',
      createdAt: DateTime.tryParse((json['createdAt'] as String?) ?? '') ??
          DateTime.now(),
      expiresAt: parseOptionalDate(json['expiresAt']),
      deletedAt: parseOptionalDate(json['deletedAt']),
    );
  }
}

class ChatMessage {
  final String id;
  final String channelId;
  final String author;
  final String authorId;
  final String authorRole;
  final String content;
  final DateTime sentAt;
  final List<ChatAttachment> attachments;

  const ChatMessage({
    required this.id,
    required this.channelId,
    required this.author,
    required this.authorId,
    required this.authorRole,
    required this.content,
    required this.sentAt,
    this.attachments = const [],
  });

  bool get hasAttachments => attachments.isNotEmpty;

  ChatMessage copyWith({
    String? id,
    String? channelId,
    String? author,
    String? authorId,
    String? authorRole,
    String? content,
    DateTime? sentAt,
    List<ChatAttachment>? attachments,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      channelId: channelId ?? this.channelId,
      author: author ?? this.author,
      authorId: authorId ?? this.authorId,
      authorRole: authorRole ?? this.authorRole,
      content: content ?? this.content,
      sentAt: sentAt ?? this.sentAt,
      attachments: attachments ?? this.attachments,
    );
  }

  ChatMessage resolvedAgainst(String baseUrl) {
    return copyWith(
      attachments: attachments
          .map((attachment) => attachment.resolvedAgainst(baseUrl))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'channelId': channelId,
        'author': author,
        'authorId': authorId,
        'authorRole': authorRole,
        'content': content,
        'sentAt': sentAt.toIso8601String(),
        'attachments': attachments.map((item) => item.toJson()).toList(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    String author = 'Unknown';
    String authorId = '';
    String authorRole = 'member';

    final authorJson = json['author'];
    if (authorJson is Map<String, dynamic>) {
      author = (authorJson['name'] as String?) ??
          (authorJson['username'] as String?) ??
          'Unknown';
      authorId = authorJson['id']?.toString() ?? '';
      authorRole = (authorJson['role'] as String?) ?? 'member';
    } else {
      author = (json['author'] as String?) ?? 'Unknown';
      authorId = json['authorId']?.toString() ?? '';
      authorRole = (json['authorRole'] as String?) ?? 'member';
    }

    final rawTime =
        (json['createdAt'] as String?) ?? (json['sentAt'] as String?);
    final sentAt = rawTime == null
        ? DateTime.now()
        : (DateTime.tryParse(rawTime) ?? DateTime.now());

    final attachmentsJson = (json['attachments'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => ChatAttachment.fromJson(Map<String, dynamic>.from(item)))
        .toList();

    return ChatMessage(
      id: json['id']?.toString() ?? '',
      channelId: json['channelId']?.toString() ?? '',
      author: author,
      authorId: authorId,
      authorRole: authorRole,
      content: (json['content'] as String?) ?? '',
      sentAt: sentAt,
      attachments: attachmentsJson,
    );
  }
}