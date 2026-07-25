class ChatServer {
  final String id;
  final String name;
  final String shortName;
  final String tagline;
  final String description;
  final String address;
  final String publicAddress;
  final String lanAddress;
  final int? lanTlsPort;
  final String identityPublicKey;
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
    this.publicAddress = '',
    this.lanAddress = '',
    this.lanTlsPort,
    this.identityPublicKey = '',
    this.accentColor = '#8b0c14',
    this.iconUrl,
    this.bannerUrl,
  });

  String get joinAddress {
    return publicAddress.trim().isNotEmpty ? publicAddress : address;
  }

  ChatServer copyWith({
    String? id,
    String? name,
    String? shortName,
    String? tagline,
    String? description,
    String? address,
    String? publicAddress,
    String? lanAddress,
    int? lanTlsPort,
    String? identityPublicKey,
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
      publicAddress: publicAddress ?? this.publicAddress,
      lanAddress: lanAddress ?? this.lanAddress,
      lanTlsPort: lanTlsPort ?? this.lanTlsPort,
      identityPublicKey: identityPublicKey ?? this.identityPublicKey,
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
    'publicAddress': publicAddress,
    'lanAddress': lanAddress,
    'lanTlsPort': lanTlsPort,
    'identityPublicKey': identityPublicKey,
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
      publicAddress: (json['publicAddress'] as String?) ?? '',
      lanAddress: (json['lanAddress'] as String?) ?? '',
      lanTlsPort: (json['lanTlsPort'] as num?)?.toInt(),
      identityPublicKey: (json['identityPublicKey'] as String?) ?? '',
      accentColor: accentColor,
      iconUrl: iconUrl,
      bannerUrl: bannerUrl,
    );
  }
}
