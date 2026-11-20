import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;

/// Opens the system settings page of this app, where camera access can be
/// turned back on after it was denied for good. Returns false when the page
/// could not be opened.
typedef AppSettingsOpener = Future<bool> Function();

/// Shown wherever the camera is blocked because access was denied.
const cameraAccessOffMessage =
    'Camera access was denied. Allow camera access for FOSScanner in your '
    'device settings before trying again.';

/// Shown wherever the camera is blocked by a device policy.
const cameraAccessRestrictedMessage =
    'Camera access is restricted on this device. Check device restrictions '
    'with your device administrator.';

// Keep the contract in sync with MainActivity.configureFlutterEngine.
const _channel = MethodChannel('com.fosscanner.app/app_settings');

/// Whether this platform can open the app's settings page.
bool get canOpenAppSettings =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Opens Android's app details settings (ACTION_APPLICATION_DETAILS_SETTINGS).
Future<bool> openAppSettings() async {
  if (!canOpenAppSettings) return false;
  try {
    return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
  } catch (_) {
    return false;
  }
}
