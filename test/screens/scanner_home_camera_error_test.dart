import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

class _Picker extends ImagePickerPlatform {
  Object? error;
  var cameraCalls = 0;
  var galleryCalls = 0;

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    cameraCalls++;
    if (error case final failure?) throw failure;
    return null;
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    galleryCalls++;
    return [];
  }
}

void main() {
  late ImagePickerPlatform originalPicker;
  late _Picker picker;

  setUp(() {
    originalPicker = ImagePickerPlatform.instance;
    picker = _Picker();
    ImagePickerPlatform.instance = picker;
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> openCamera(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: ScannerHomePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Capture Image'));
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final code in ['camera_access_denied', 'camera_access_restricted']) {
      testWidgets(
        '$platform $code gives guidance without automatic retry',
        (tester) async {
          picker.error = PlatformException(
            code: code,
            message: 'PRIVATE DETAILS',
          );
          await openCamera(tester);
          expect(find.text('Camera unavailable'), findsOneWidget);
          expect(
            find.textContaining(
              code.endsWith('restricted')
                  ? 'device administrator'
                  : 'device settings',
            ),
            findsOneWidget,
          );
          expect(find.text('Retry'), findsNothing);
          expect(find.textContaining('PRIVATE DETAILS'), findsNothing);
          expect(picker.cameraCalls, 1);
          await tester.tap(find.text('Import images'));
          await tester.pumpAndSettle();
          expect(picker.galleryCalls, 1);
          expect(find.byTooltip('Capture Image'), findsOneWidget);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }

    testWidgets(
      '$platform transient failure can retry successfully',
      (tester) async {
        picker.error = PlatformException(code: 'unknown', details: 'PRIVATE');
        await openCamera(tester);
        expect(find.text('Retry'), findsOneWidget);
        picker.error = null;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(picker.cameraCalls, 2);
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          tester
              .widget<FloatingActionButton>(find.byType(FloatingActionButton))
              .onPressed,
          isNotNull,
        );
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  for (final code in ['camera-unavailable', 'no_available_camera']) {
    testWidgets('$code hides unsupported camera but offers gallery', (
      tester,
    ) async {
      picker.error = PlatformException(code: code);
      await openCamera(tester);
      expect(find.textContaining('No camera is available'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      await tester.tap(find.text('Import images'));
      await tester.pumpAndSettle();
      expect(picker.galleryCalls, 1);
      expect(find.byType(FloatingActionButton), findsNothing);
    });
  }

  testWidgets('camera cancellation does not show an error', (tester) async {
    await openCamera(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(picker.cameraCalls, 1);
  });
}
