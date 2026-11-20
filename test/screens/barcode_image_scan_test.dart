import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/screens/barcode_scan_screen.dart';
import 'package:fosscanner/services/app_settings.dart';

void main() {
  Widget buildScreen(BarcodeImageScanner scanner) => MaterialApp(
    home: BarcodeScanScreen(
      scanViewBuilder: (context, onScan) =>
          const SizedBox.expand(child: ColoredBox(color: Colors.black)),
      clipboardWriter: (_) async {},
      uriLauncher: (_) async => true,
      imageScanner: scanner,
    ),
  );

  Future<void> scanImage(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Scan an image'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('an image without a code says so', (tester) async {
    await tester.pumpWidget(
      buildScreen(
        () async => const BarcodeScanResult(isValid: false, text: null),
      ),
    );
    await scanImage(tester);
    expect(find.text('No code found in this image.'), findsOneWidget);
    expect(find.text('Scanned result'), findsNothing);
  });

  testWidgets('a code in an image is shown like a live scan', (tester) async {
    await tester.pumpWidget(
      buildScreen(
        () async => const BarcodeScanResult(isValid: true, text: 'hello'),
      ),
    );
    await scanImage(tester);
    expect(find.text('Scanned result'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
    // Scanning another image is offered only while scanning.
    expect(find.byTooltip('Scan an image'), findsNothing);
  });

  testWidgets('cancelling the picker says nothing', (tester) async {
    await tester.pumpWidget(buildScreen(() async => null));
    await scanImage(tester);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('an unreadable image shows a generic message', (tester) async {
    await tester.pumpWidget(
      buildScreen(() async => throw PlatformException(code: 'x', message: 'p')),
    );
    await scanImage(tester);
    expect(find.text('Could not read this image.'), findsOneWidget);
  });

  test('the settings channel contract reaches MainActivity', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('com.fosscanner.app/app_settings');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    Object? reply = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (reply case final Exception error) throw error;
      return reply;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    expect(await openAppSettings(), isTrue);
    expect(calls.single.method, 'openAppSettings');
    expect(calls.single.arguments, isNull);
    reply = false;
    expect(await openAppSettings(), isFalse);
    reply = PlatformException(code: 'settings_unavailable');
    expect(await openAppSettings(), isFalse);

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    expect(await openAppSettings(), isFalse);
    expect(calls, isEmpty);
  });
}
