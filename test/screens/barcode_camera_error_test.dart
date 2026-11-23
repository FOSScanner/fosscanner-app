import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/screens/barcode_scan_screen.dart';
import '../support/camera_platform.dart';

void main() {
  late CameraPlatform originalCamera;
  late FixtureCameraPlatform camera;

  setUp(() {
    originalCamera = CameraPlatform.instance;
    CameraPlatform.instance = camera = FixtureCameraPlatform();
  });

  tearDown(() async {
    CameraPlatform.instance = originalCamera;
    await camera.errors.close();
  });

  for (final code in [
    'CameraAccessDenied',
    'CameraAccessDeniedWithoutPrompt',
  ]) {
    testWidgets('$code explains permission settings and retries successfully', (
      tester,
    ) async {
      camera.failureCode = code;
      await tester.pumpWidget(const MaterialApp(home: BarcodeScanScreen()));
      expect(find.text('Camera unavailable'), findsNothing);
      await finishCameraAttempt(tester, camera);

      expect(camera.attempts, 1);
      expect(find.text('Camera unavailable'), findsOneWidget);
      expect(find.textContaining('device settings'), findsOneWidget);
      expect(find.textContaining('private native details'), findsNothing);

      camera.failureCode = null;
      camera.enumerated = Completer<void>();
      await tester.tap(find.text('Retry'));
      await finishCameraAttempt(tester, camera);

      expect(camera.attempts, 2);
      expect(find.text('Camera unavailable'), findsNothing);
      expect(find.byKey(const Key('camera-preview')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('unrecognized camera errors hide native details', (tester) async {
    camera.failureCode = 'unknownNativeFailure';
    await tester.pumpWidget(const MaterialApp(home: BarcodeScanScreen()));
    await finishCameraAttempt(tester, camera);

    expect(find.text('Camera unavailable'), findsOneWidget);
    expect(find.textContaining('private native details'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });
}
