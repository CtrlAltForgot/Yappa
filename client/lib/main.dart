import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app.dart';

bool _isIgnorableWebRtcStreamCancelError(Object exception) {
  return exception is PlatformException &&
      exception.code == 'error' &&
      exception.message == 'No active stream to cancel';
}

void main() {
  final previousOnError = FlutterError.onError;

  FlutterError.onError = (FlutterErrorDetails details) {
    if (_isIgnorableWebRtcStreamCancelError(details.exception)) {
      if (kDebugMode) {
        debugPrint(
          '[Yappa] Ignored known FlutterWebRTC teardown warning: '
          '${details.exception}',
        );
      }
      return;
    }

    if (previousOnError != null) {
      previousOnError(details);
      return;
    }

    FlutterError.presentError(details);
  };

  runApp(const YappaApp());
}
