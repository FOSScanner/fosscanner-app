import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/screen_privacy.dart' as screen_privacy;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fosscanner.app/screen_privacy');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('sends the secure-screen choice to Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    await screen_privacy.setSecureScreen(true);
    await screen_privacy.setSecureScreen(false);

    expect(calls.map((call) => call.method), [
      'setSecureScreen',
      'setSecureScreen',
    ]);
    expect(calls.map((call) => call.arguments), [
      {'enabled': true},
      {'enabled': false},
    ]);
  });

  test('is a no-op on platforms without the native channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    expect(screen_privacy.isSecureScreenSupported, isFalse);
    await screen_privacy.setSecureScreen(true);

    expect(calls, isEmpty);
  });
}
