import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android's native insets controller also supports current edge-to-edge targets.
class ViewerViewport {
  static const _channel = MethodChannel('remotescreen/native');

  static Future<void> setFullscreen(bool fullscreen,
      {bool landscape = false}) async {
    // Dispatch both before awaiting, so dispose's restore is ordered after enter.
    final bars = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? _channel
            .invokeMethod<void>('setViewerFullscreen', {'enabled': fullscreen})
        : SystemChrome.setEnabledSystemUIMode(fullscreen
            ? SystemUiMode.immersiveSticky
            : SystemUiMode.edgeToEdge);
    final orientation = SystemChrome.setPreferredOrientations(
      fullscreen && landscape
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [],
    );
    await Future.wait([bars, orientation]);
  }
}
