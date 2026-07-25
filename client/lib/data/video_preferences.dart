import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

enum YappaLinuxScreenShareBackend {
  auto,
  nativePortal,
  x11Only,
  disableOnWayland,
}

enum YappaScreenShareQuality {
  efficient720p30,
  balanced1080p30,
  smooth1080p60,
  high1440p60,
}

extension YappaScreenShareQualityDetails on YappaScreenShareQuality {
  String get label => switch (this) {
    YappaScreenShareQuality.efficient720p30 => '720p · 30 FPS',
    YappaScreenShareQuality.balanced1080p30 => '1080p · 30 FPS',
    YappaScreenShareQuality.smooth1080p60 => '1080p · 60 FPS',
    YappaScreenShareQuality.high1440p60 => '1440p · 60 FPS',
  };

  String get description => switch (this) {
    YappaScreenShareQuality.efficient720p30 =>
      'Lower CPU and network use for slower systems or connections.',
    YappaScreenShareQuality.balanced1080p30 =>
      'Sharp text and video with moderate resource use.',
    YappaScreenShareQuality.smooth1080p60 =>
      'Recommended for games and smooth motion on capable connections.',
    YappaScreenShareQuality.high1440p60 =>
      'A demanding ceiling for powerful systems and fast upload speeds.',
  };

  int get width => switch (this) {
    YappaScreenShareQuality.efficient720p30 => 1280,
    YappaScreenShareQuality.balanced1080p30 ||
    YappaScreenShareQuality.smooth1080p60 => 1920,
    YappaScreenShareQuality.high1440p60 => 2560,
  };

  int get height => switch (this) {
    YappaScreenShareQuality.efficient720p30 => 720,
    YappaScreenShareQuality.balanced1080p30 ||
    YappaScreenShareQuality.smooth1080p60 => 1080,
    YappaScreenShareQuality.high1440p60 => 1440,
  };

  int get framesPerSecond => switch (this) {
    YappaScreenShareQuality.efficient720p30 ||
    YappaScreenShareQuality.balanced1080p30 => 30,
    YappaScreenShareQuality.smooth1080p60 ||
    YappaScreenShareQuality.high1440p60 => 60,
  };

  int get maxBitrate => switch (this) {
    YappaScreenShareQuality.efficient720p30 => 3_000_000,
    YappaScreenShareQuality.balanced1080p30 => 5_000_000,
    YappaScreenShareQuality.smooth1080p60 => 8_000_000,
    YappaScreenShareQuality.high1440p60 => 14_000_000,
  };
}

class YappaVideoPreferences {
  static const _linuxScreenShareBackendKey = 'yappa_linux_screen_share_backend';
  static const _screenShareQualityKey = 'yappa_screen_share_quality';

  static YappaLinuxScreenShareBackend linuxScreenShareBackend =
      YappaLinuxScreenShareBackend.nativePortal;
  static YappaScreenShareQuality screenShareQuality =
      YappaScreenShareQuality.smooth1080p60;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedBackend = prefs.getString(_linuxScreenShareBackendKey);
    final savedQuality = prefs.getString(_screenShareQualityKey);

    linuxScreenShareBackend = YappaLinuxScreenShareBackend.values.firstWhere(
      (value) => value.name == savedBackend,
      orElse: () => YappaLinuxScreenShareBackend.nativePortal,
    );
    screenShareQuality = YappaScreenShareQuality.values.firstWhere(
      (value) => value.name == savedQuality,
      orElse: () => YappaScreenShareQuality.smooth1080p60,
    );
  }

  static Future<void> setLinuxScreenShareBackend(
    YappaLinuxScreenShareBackend value,
  ) async {
    linuxScreenShareBackend = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_linuxScreenShareBackendKey, value.name);
  }

  static Future<void> setScreenShareQuality(
    YappaScreenShareQuality value,
  ) async {
    screenShareQuality = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_screenShareQualityKey, value.name);
  }

  static bool get isLinuxBuild => Platform.isLinux;

  static String get detectedLinuxSessionType {
    if (!Platform.isLinux) {
      return 'Not Linux';
    }

    final env = Platform.environment;
    final explicit = env['XDG_SESSION_TYPE']?.trim().toLowerCase();

    if (explicit == 'wayland') {
      return 'Wayland';
    }
    if (explicit == 'x11' || explicit == 'xorg') {
      return 'X11';
    }
    if ((env['WAYLAND_DISPLAY'] ?? '').trim().isNotEmpty) {
      return 'Wayland';
    }
    if ((env['DISPLAY'] ?? '').trim().isNotEmpty) {
      return 'X11';
    }

    return 'Unknown';
  }

  static bool get isWaylandSession => detectedLinuxSessionType == 'Wayland';
  static bool get isX11Session => detectedLinuxSessionType == 'X11';

  static String get effectiveLinuxScreenSharePath {
    if (!Platform.isLinux) {
      return 'Standard desktop capture';
    }

    switch (linuxScreenShareBackend) {
      case YappaLinuxScreenShareBackend.auto:
        return 'Auto → Native Linux capture first';
      case YappaLinuxScreenShareBackend.nativePortal:
        return 'Native Linux portal capture';
      case YappaLinuxScreenShareBackend.x11Only:
        return isX11Session
            ? 'X11-only mode active'
            : 'X11-only mode selected, but current session is not X11';
      case YappaLinuxScreenShareBackend.disableOnWayland:
        return isWaylandSession
            ? 'Wayland screen share is blocked'
            : 'Wayland blocking enabled, current session is not Wayland';
    }
  }

  static String? linuxScreenShareBlockMessage() {
    if (!Platform.isLinux) {
      return null;
    }

    switch (linuxScreenShareBackend) {
      case YappaLinuxScreenShareBackend.auto:
      case YappaLinuxScreenShareBackend.nativePortal:
        return null;
      case YappaLinuxScreenShareBackend.x11Only:
        if (!isX11Session) {
          return 'Screen sharing is set to X11-only mode. Log into a Plasma X11 session or switch the backend to Auto / Native Linux capture in Video settings.';
        }
        return null;
      case YappaLinuxScreenShareBackend.disableOnWayland:
        if (isWaylandSession) {
          return 'Screen sharing is disabled on Wayland in Video settings. Use a Plasma X11 session or change the Linux screen share backend.';
        }
        return null;
    }
  }
}
