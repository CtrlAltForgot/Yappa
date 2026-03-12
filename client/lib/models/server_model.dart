class ChatServer {
  final String id;
  final String name;
  final String shortName;
  final String tagline;
  final String description;
  final String address;
  final String accentColor;
  final String? iconUrl;
  final String? bannerUrl;

  const ChatServer({
    required this.id,
    required this.name,
    required this.shortName,
    required this.tagline,
    required this.description,
    required this.address,
    this.accentColor = '#8b0c14',
    this.iconUrl,
    this.bannerUrl,
  });

  ChatServer copyWith({
    String? id,
    String? name,
    String? shortName,
    String? tagline,
    String? description,
    String? address,
    String? accentColor,
    String? iconUrl,
    String? bannerUrl,
  }) {
    return ChatServer(
      id: id ?? this.id,
      name: name ?? this.name,
      shortName: shortName ?? this.shortName,
      tagline: tagline ?? this.tagline,
      description: description ?? this.description,
      address: address ?? this.address,
      accentColor: accentColor ?? this.accentColor,
      iconUrl: iconUrl ?? this.iconUrl,
      bannerUrl: bannerUrl ?? this.bannerUrl,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'shortName': shortName,
        'tagline': tagline,
        'description': description,
        'address': address,
        'accentColor': accentColor,
        'iconUrl': iconUrl,
        'bannerUrl': bannerUrl,
      };

  factory ChatServer.fromJson(Map<String, dynamic> json) {
    final branding = json['branding'];
    String accentColor = '#8b0c14';
    String? iconUrl;
    String? bannerUrl;

    if (branding is Map && branding['accentColor'] is String) {
      accentColor = branding['accentColor'] as String;
    } else if (json['accentColor'] is String) {
      accentColor = json['accentColor'] as String;
    }

    if (branding is Map && branding['iconUrl'] is String) {
      iconUrl = branding['iconUrl'] as String;
    } else if (json['iconUrl'] is String) {
      iconUrl = json['iconUrl'] as String;
    }

    if (branding is Map && branding['bannerUrl'] is String) {
      bannerUrl = branding['bannerUrl'] as String;
    } else if (json['bannerUrl'] is String) {
      bannerUrl = json['bannerUrl'] as String;
    }

    final description =
        (json['description'] as String?) ?? (json['tagline'] as String?) ?? '';

    return ChatServer(
      id: json['id'] as String,
      name: json['name'] as String,
      shortName: (json['shortName'] as String?) ?? 'NC',
      tagline: (json['tagline'] as String?) ?? description,
      description: description,
      address: (json['address'] as String?) ?? '',
      accentColor: accentColor,
      iconUrl: iconUrl,
      bannerUrl: bannerUrl,
    );
  }
}