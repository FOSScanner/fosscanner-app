import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;

// Keep the channel contract synchronized with MainActivity.kt.
const _channel = MethodChannel('com.fosscanner.app/screen_privacy');

/// Whether the platform can block screenshots and screen recording.
bool get isSecureScreenSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Turns Android's `FLAG_SECURE` on or off for the app window, blocking
/// screenshots, screen recording and the Recents thumbnail while enabled.
///
/// The Recents thumbnail is already hidden on Android 13+ without this flag.
/// The choice is not persisted here: the settings screen that exposes it owns
/// persistence and re-applies the saved value at startup. On other platforms
/// this is a no-op.
Future<void> setSecureScreen(bool enabled) async {
  if (!isSecureScreenSupported) return;
  await _channel.invokeMethod<void>('setSecureScreen', {'enabled': enabled});
}
