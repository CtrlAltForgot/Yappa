class LinkPreview {
  final String url;
  final String finalUrl;
  final String hostname;
  final String siteName;
  final String title;
  final String description;
  final String imageUrl;
  final String iconUrl;
  final String mediaUrl;
  final String kind;
  final String contentType;

  const LinkPreview({
    required this.url,
    required this.finalUrl,
    required this.hostname,
    required this.siteName,
    required this.title,
    required this.description,
    required this.imageUrl,
    required this.iconUrl,
    required this.mediaUrl,
    required this.kind,
    required this.contentType,
  });

  bool get hasImage => imageUrl.trim().isNotEmpty;
  bool get hasMedia => mediaUrl.trim().isNotEmpty;
  bool get isVideo => kind == 'video';
  bool get isImage => kind == 'image';

  String get launchUrl {
    final candidate = finalUrl.trim();
    if (candidate.isNotEmpty) {
      return candidate;
    }
    return url;
  }

  factory LinkPreview.fromJson(Map<String, dynamic> json) {
    return LinkPreview(
      url: (json['url'] as String?) ?? '',
      finalUrl: (json['finalUrl'] as String?) ?? '',
      hostname: (json['hostname'] as String?) ?? '',
      siteName: (json['siteName'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      imageUrl: (json['imageUrl'] as String?) ?? '',
      iconUrl: (json['iconUrl'] as String?) ?? '',
      mediaUrl: (json['mediaUrl'] as String?) ?? '',
      kind: (json['kind'] as String?) ?? 'link',
      contentType: (json['contentType'] as String?) ?? '',
    );
  }
}
