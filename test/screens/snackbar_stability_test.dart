import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';

import '../support/layout_stability.dart';

/// Every gallery request fails, so each import ends in a message.
class _FailingPicker extends ImagePickerPlatform {
  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) => throw PlatformException(code: 'unexpected');
}

/// The default and the maximum supported text scale on every viewport.
final _cases = [
  for (final layoutCase in layoutMatrix)
    if (layoutCase.textScale != 1.3) layoutCase,
];

void main() {
  late ImagePickerPlatform originalPicker;
  late Uint8List imageBytes;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _FailingPicker();
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  });

  tearDown(() => ImagePickerPlatform.instance = originalPicker);

  Future<void> pumpHome(
    WidgetTester tester,
    LayoutCase layoutCase, {
    required int pages,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: withTextScale(layoutCase.textScale),
        home: ScannerHomePage(
          searchablePdfEnabled: false,
          appSettingsOpener: () async => true,
          cameraPromptCheck: () async => false,
          initialPages: [
            for (var i = 0; i < pages; i++)
              ScannedPage(
                originalBytes: imageBytes,
                processedBytes: imageBytes,
                corners: const [],
              ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final camera = find.byType(FloatingActionButton);
  final anchors = {'camera button': camera};

  void pressIconButton(WidgetTester tester, String tooltip) => tester
      .widget<IconButton>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(IconButton),
        ),
      )
      .onPressed!();

  /// Shows a message with [show], then lets it time out; the camera button
  /// must keep its place while the message appears, is shown and leaves.
  Future<void> expectMessageKeepsCamera(
    WidgetTester tester,
    String message,
    VoidCallback show,
  ) async {
    late SnackBar snackBar;
    await expectStableRects(tester, anchors, () async {
      await expectStableRects(tester, anchors, () async {
        show();
        await tester.pumpAndSettle();
        expect(find.text(message), findsOneWidget);
        snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
        expect(snackBar.behavior, SnackBarBehavior.floating);
        // It floats above the button instead of covering it.
        expect(
          tester.getRect(find.byType(SnackBar)).bottom,
          lessThanOrEqualTo(tester.getRect(camera).top + 0.5),
        );
      }, reason: 'appears');
      if (snackBar.action == null) {
        await tester.pump(const Duration(seconds: 5));
      } else {
        // Messages with an action stay until used or closed.
        tester
            .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
            .hideCurrentSnackBar();
      }
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    }, reason: 'appears and leaves');
  }

  for (final pages in [0, 3]) {
    testLayoutMatrix(
      'an ordinary message does not move the camera button ($pages pages)',
      (tester, layoutCase) async {
        await pumpHome(tester, layoutCase, pages: pages);
        await expectMessageKeepsCamera(
          tester,
          'Could not open the gallery.',
          () => pressIconButton(tester, 'Import from gallery'),
        );
        expect(tester.takeException(), isNull);
      },
      cases: _cases,
    );
  }
}
