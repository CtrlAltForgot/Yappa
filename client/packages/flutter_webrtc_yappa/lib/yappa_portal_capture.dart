import 'package:flutter/services.dart';

/// Yappa's Linux-only single-session xdg-desktop-portal capture controls.
class YappaPortalCapture {
  static const MethodChannel _channel = MethodChannel('FlutterWebRTC.Method');

  static Future<void> stop() =>
      _channel.invokeMethod<void>('stopYappaPortalCapture');
}
