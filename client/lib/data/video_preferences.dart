import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

enum YappaLinuxScreenShareBackend {
  auto,
  nativePortal,
  x11Only,
  disableOnWayland,
}

class YappaVideoPreferences {
  static const _linuxScreenShareBackendKey =
      'yappa_linux_screen_share_backend';

  static YappaLinuxScreenShareBackend linuxScreenShareBackend =
      YappaLinuxScreenShareBackend.auto;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedBackend = prefs.getString(_linuxScreenShareBackendKey);

    linuxScreenShareBackend = YappaLinuxScreenShareBackend.values.firstWhere(
      (value) => value.name == savedBackend,
      orElse: () => YappaLinuxScreenShareBackend.auto,
    );
  }

  static Future<void> setLinuxScreenShareBackend(
    YappaLinuxScreenShareBackend value,
  ) async {
    linuxScreenShareBackend = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_linuxScreenShareBackendKey, value.name);
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
        return isWaylandSession
            ? 'Auto → Native portal capture'
            : isX11Session
                ? 'Auto → Native portal capture (X11 fallback ready)'
                : 'Auto → Native Linux capture';
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
