import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/image_metadata.dart';

const _corners = [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)];

/// Returns the next queued camera result per launch; null once exhausted,
/// which is what image_picker reports when the user cancels the camera.
class _Picker extends ImagePickerPlatform {
  final cameraResults = <XFile? Function()>[];
  List<XFile> galleryPhotos = [];
  List<XFile> recoveredPhotos = [];
  var cameraCalls = 0;

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    cameraCalls++;
    if (cameraResults.isEmpty) return null;
    return cameraResults.removeAt(0)();
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => galleryPhotos;

  @override
  Future<LostDataResponse> getLostData() async => recoveredPhotos.isEmpty
      ? LostDataResponse.empty()
      : LostDataResponse(files: recoveredPhotos);
}

class _Operations implements CornerAdjustOperations {
  var exports = 0;

  @override
  Future<Size> decodeSize(Uint8List bytes) async => const Size(100, 100);

  @override
  Future<List<Offset>?> detectCorners(Uint8List bytes) async => _corners;

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List bytes,
    List<Offset> corners,
  ) async => {for (final filter in PageFilter.values) filter: bytes};

  @override
  Future<Uint8List> buildFinalPreview(
    Uint8List bytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async => bytes;

  @override
  Future<Uint8List> processForExport(
    Uint8List bytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async {
    exports++;
    return bytes;
  }
}

void main() {
  late ImagePickerPlatform originalPicker;
  late _Picker picker;
  late _Operations operations;
  late Directory directory;
  late Uint8List bytes;
  var photoCount = 0;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    picker = _Picker();
    ImagePickerPlatform.instance = picker;
    operations = _Operations();
    directory = Directory.systemTemp.createTempSync('camera-capture-loop-');
    final data = await rootBundle.load('assets/icon/icon.png');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    directory.deleteSync(recursive: true);
  });

  /// Each launch writes a fresh app-owned file, like the system camera.
  File queueCapture() {
    final file = File('${directory.path}/capture-${photoCount++}.png');
    picker.cameraResults.add(() {
      file.writeAsBytesSync(bytes);
      return XFile(file.path);
    });
    return file;
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    List<ScannedPage> pages = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: pages,
          searchablePdfEnabled: false,
          cornerAdjustOperations: operations,
          sourceImageSizeReader: (_) async => const Size(100, 100),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<CornerAdjustScreen> waitForEditor(
    WidgetTester tester, {
    CornerAdjustScreen? previous,
  }) async {
    // File IO and image metadata decoding require real event-loop turns.
    for (var i = 0; i < 100; i++) {
      final editors = find.byType(CornerAdjustScreen);
      if (editors.evaluate().length == 1 &&
          !identical(tester.widget<CornerAdjustScreen>(editors), previous) &&
          find.text('Preview page').evaluate().isNotEmpty) {
        await tester.pumpAndSettle();
        return tester.widget<CornerAdjustScreen>(editors);
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    fail('Expected a camera review route');
  }

  /// Lets a picker launch that is not followed by a review settle.
  Future<void> settleIntake(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<void> preview(WidgetTester tester) async {
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
  }

  ScannedPage savedPage() => ScannedPage(
    originalBytes: bytes,
    corners: _corners,
    processedBytes: bytes,
  );

  testWidgets(
    'Add & scan next relaunches the camera until Add page ends the loop',
    (tester) async {
      final first = queueCapture();
      final second = queueCapture();
      final third = queueCapture();
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Capture Image'));
      var editor = await waitForEditor(tester);
      expect(editor.source, PageReviewSource.camera);
      await preview(tester);
      expect(find.text('Add & scan next'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Add page'), findsOneWidget);

      // A stale second tap must not add the page twice or open two cameras.
      final scanNext = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Add & scan next'),
          )
          .onPressed!;
      scanNext();
      scanNext();
      editor = await waitForEditor(tester, previous: editor);
      expect(picker.cameraCalls, 2);
      expect(operations.exports, 1);

      await preview(tester);
      await tester.tap(find.text('Add & scan next'));
      await waitForEditor(tester, previous: editor);
      expect(picker.cameraCalls, 3);

      await preview(tester);
      await tester.tap(find.text('Add page'));
      await settleIntake(tester);

      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(picker.cameraCalls, 3);
      expect(find.text('Export PDF (3 pages)'), findsOneWidget);
      expect(
        [first, second, third].every((file) => !file.existsSync()),
        isTrue,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Retake discards the shot and relaunches the camera; Back leaves the loop',
    (tester) async {
      final first = queueCapture();
      final second = queueCapture();
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Capture Image'));
      final editor = await waitForEditor(tester);
      expect(find.text('Retake'), findsOneWidget);
      expect(find.text('Cancel'), findsNothing);

      await tester.tap(find.text('Retake'));
      await waitForEditor(tester, previous: editor);
      expect(picker.cameraCalls, 2);
      expect(first.existsSync(), isFalse);
      expect(find.byType(Card), findsNothing);

      // Back from the crop step exits without adding and without a relaunch.
      await tester.pageBack();
      await settleIntake(tester);
      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(picker.cameraCalls, 2);
      expect(find.byType(Card), findsNothing);
      expect(operations.exports, 0);
      expect(second.existsSync(), isFalse);

      // The picker lock is released.
      await tester.tap(find.byTooltip('Capture Image'));
      await settleIntake(tester);
      expect(picker.cameraCalls, 3);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'canceling the system camera mid-loop keeps the accepted pages',
    (tester) async {
      queueCapture();
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Capture Image'));
      await waitForEditor(tester);
      await preview(tester);
      await tester.tap(find.text('Add & scan next'));
      // The second launch is canceled: the fake returns null.
      await settleIntake(tester);

      expect(picker.cameraCalls, 2);
      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(find.text('Export PDF (1 page)'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.byTooltip('Capture Image'));
      await settleIntake(tester);
      expect(picker.cameraCalls, 3);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'reaching the page limit mid-loop ends it and reports the limit once',
    (tester) async {
      queueCapture();
      queueCapture();
      await pumpHome(
        tester,
        pages: List.generate(maxDocumentPages - 1, (_) => savedPage()),
      );
      await tester.tap(find.byTooltip('Capture Image'));
      await waitForEditor(tester);
      await preview(tester);
      await tester.tap(find.text('Add & scan next'));
      await settleIntake(tester);

      expect(picker.cameraCalls, 1);
      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(find.text('Export PDF ($maxDocumentPages pages)'), findsOneWidget);
      expect(
        find.textContaining('reached the $maxDocumentPages-page limit'),
        findsOneWidget,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'gallery, recovered and existing-page reviews keep their actions',
    (tester) async {
      final gallery = File('${directory.path}/gallery.png')
        ..writeAsBytesSync(bytes);
      picker.galleryPhotos = [XFile(gallery.path)];
      await pumpHome(tester, pages: [savedPage()]);

      await tester.tap(find.byTooltip('Import from gallery'));
      await waitForEditor(tester);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Retake'), findsNothing);
      await preview(tester);
      expect(find.text('Add & scan next'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Add page'), findsOneWidget);
      await tester.tap(find.text('Add page'));
      await settleIntake(tester);
      expect(find.text('Export PDF (2 pages)'), findsOneWidget);
      expect(picker.cameraCalls, 0);

      await tester.tap(find.byType(Card).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit page'));
      await tester.pumpAndSettle();
      expect(find.text('Save changes'), findsOneWidget);
      expect(find.text('Add & scan next'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Retake'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'recovered camera results are reviewed once without the capture loop',
    (tester) async {
      final recovered = File('${directory.path}/recovered.png')
        ..writeAsBytesSync(bytes);
      picker.recoveredPhotos = [XFile(recovered.path)];
      await pumpHome(tester);
      await waitForEditor(tester);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Retake'), findsNothing);
      await preview(tester);
      expect(find.text('Add & scan next'), findsNothing);
      await tester.tap(find.text('Add page'));
      await settleIntake(tester);
      expect(find.text('Export PDF (1 page)'), findsOneWidget);
      expect(picker.cameraCalls, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'camera reviews without loop callbacks keep Cancel and a single Add page',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CornerAdjustScreen(
            originalBytes: bytes,
            source: PageReviewSource.camera,
            operations: operations,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Retake'), findsNothing);
      await preview(tester);
      expect(find.text('Add & scan next'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Add page'), findsOneWidget);
    },
  );

  for (final size in [const Size(320, 568), const Size(568, 320)]) {
    testWidgets('camera actions fit $size at 200% text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: CornerAdjustScreen(
            originalBytes: bytes,
            source: PageReviewSource.camera,
            onScanNext: () {},
            onRetake: () {},
            operations: operations,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Retake'));
      await tester.pumpAndSettle();
      expect(find.text('Retake').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.text('Preview page'));
      await tester.tap(find.text('Preview page'));
      await tester.pumpAndSettle();
      final widths = <double>[];
      for (final label in ['Add & scan next', 'Add page']) {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        expect(find.text(label).hitTestable(), findsOneWidget);
        widths.add(
          tester
              .getSize(
                find.ancestor(
                  of: find.text(label),
                  matching: find.byWidgetPredicate(
                    (w) => w is ButtonStyleButton,
                  ),
                ),
              )
              .width,
        );
      }
      // Both buttons share the full row width, so neither jumps in size.
      expect(widths.first, widths.last);
      expect(tester.takeException(), isNull);
    });
  }
}
