class LocalAccount {
  final String serverId;
  final String username;
  final String passwordDigest;

  const LocalAccount({
    required this.serverId,
    required this.username,
    required this.passwordDigest,
  });

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'username': username,
        'passwordDigest': passwordDigest,
      };

  factory LocalAccount.fromJson(Map<String, dynamic> json) {
    return LocalAccount(
      serverId: json['serverId'] as String,
      username: json['username'] as String,
      passwordDigest: json['passwordDigest'] as String,
    );
  }
}
