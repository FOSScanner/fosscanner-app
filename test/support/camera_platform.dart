import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FixtureCameraPlatform extends CameraPlatform {
  String? failureCode = 'CameraAccessDenied';
  int attempts = 0;
  Completer<void> enumerated = Completer<void>();
  final errors = StreamController<CameraErrorEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async {
    enumerated.complete();
    return const [
      CameraDescription(
        name: 'back',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
      ),
    ];
  }

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  Future<int> createCamera(
    CameraDescription cameraDescription,
    ResolutionPreset? resolutionPreset, {
    bool enableAudio = false,
  }) async {
    attempts++;
    if (failureCode case final code?) {
      throw PlatformException(code: code, message: 'private native details');
    }
    return attempts;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          640,
          480,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => errors.stream;

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}

  @override
  bool supportsImageStreaming() => true;

  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) => const Stream.empty();

  @override
  Future<double> getMaxZoomLevel(int cameraId) async => 1;

  @override
  Future<double> getMinZoomLevel(int cameraId) async => 1;

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {}

  @override
  Widget buildPreview(int cameraId) =>
      const SizedBox(key: Key('camera-preview'));

  @override
  Future<void> dispose(int cameraId) async {
    errors.add(CameraErrorEvent(cameraId, 'disposed'));
  }
}

Future<void> finishCameraAttempt(
  WidgetTester tester,
  FixtureCameraPlatform camera,
) async {
  // ReaderWidget starts a real isolate before enumerating cameras. Advance
  // both the test clock and that isolate's event loop until it is ready.
  for (var i = 0; i < 500 && !camera.enumerated.isCompleted; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(camera.enumerated.isCompleted, isTrue);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}
