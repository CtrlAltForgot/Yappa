class ServerPermissions {
  final bool isOwner;
  final bool canManageServer;
  final bool canManageChannels;
  final bool canManageInvites;
  final bool canManageBranding;
  final bool canManageMedia;

  const ServerPermissions({
    this.isOwner = false,
    this.canManageServer = false,
    this.canManageChannels = false,
    this.canManageInvites = false,
    this.canManageBranding = false,
    this.canManageMedia = false,
  });

  bool get canOpenAdminPanel =>
      isOwner ||
      canManageServer ||
      canManageChannels ||
      canManageBranding ||
      canManageMedia;

  Map<String, dynamic> toJson() => {
        'isOwner': isOwner,
        'canManageServer': canManageServer,
        'canManageChannels': canManageChannels,
        'canManageInvites': canManageInvites,
        'canManageBranding': canManageBranding,
        'canManageMedia': canManageMedia,
      };

  factory ServerPermissions.fromJson(Map<String, dynamic> json) {
    return ServerPermissions(
      isOwner: json['isOwner'] as bool? ?? false,
      canManageServer: json['canManageServer'] as bool? ?? false,
      canManageChannels: json['canManageChannels'] as bool? ?? false,
      canManageInvites: json['canManageInvites'] as bool? ?? false,
      canManageBranding: json['canManageBranding'] as bool? ?? false,
      canManageMedia: json['canManageMedia'] as bool? ?? false,
    );
  }
}