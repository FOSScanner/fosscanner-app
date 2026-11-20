import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

const _skipNotice =
    'Skip this image only. Any remaining images will still be reviewed.';
const _corners = [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)];

class _Picker extends ImagePickerPlatform {
  XFile? cameraPhoto;
  List<XFile> galleryPhotos = [];
  List<XFile> recoveredPhotos = [];
  var cameraCalls = 0;
  var galleryCalls = 0;

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    cameraCalls++;
    return cameraPhoto;
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    galleryCalls++;
    return galleryPhotos;
  }

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

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    picker = _Picker();
    ImagePickerPlatform.instance = picker;
    operations = _Operations();
    directory = Directory.systemTemp.createTempSync('page-review-actions-');
    final data = await rootBundle.load('assets/icon/icon.png');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    directory.deleteSync(recursive: true);
  });

  File photo(String name) =>
      File('${directory.path}/$name.png')..writeAsBytesSync(bytes);

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

  Future<void> waitForEditor(
    WidgetTester tester, {
    Uint8List? previousBytes,
  }) async {
    // File IO and image metadata decoding require real event-loop turns.
    for (var i = 0; i < 100; i++) {
      final editors = find.byType(CornerAdjustScreen);
      if (editors.evaluate().length == 1 &&
          !identical(
            tester.widget<CornerAdjustScreen>(editors).originalBytes,
            previousBytes,
          ) &&
          find.text('Preview page').evaluate().isNotEmpty) {
        await tester.pumpAndSettle();
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    fail('Expected the next image review route');
  }

  Future<void> accept(WidgetTester tester) async {
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add page'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'canceling the system camera adds nothing and releases the picker lock',
    (tester) async {
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Capture Image'));
      await tester.pumpAndSettle();
      expect(picker.cameraCalls, 1);
      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(find.byType(Card), findsNothing);
      await tester.tap(find.byTooltip('Capture Image'));
      await tester.pumpAndSettle();
      expect(picker.cameraCalls, 2);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'camera review says Cancel, cleans its temp file, and does not reopen capture',
    (tester) async {
      final file = photo('capture');
      picker.cameraPhoto = XFile(file.path);
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Capture Image'));
      await waitForEditor(tester);
      final editor = tester.widget<CornerAdjustScreen>(
        find.byType(CornerAdjustScreen),
      );
      expect(editor.source, PageReviewSource.camera);
      expect(editor.isBatchImport, isFalse);
      expect(find.text('Retake'), findsNothing);
      expect(find.text('Skip image'), findsNothing);
      expect(file.existsSync(), isFalse);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsNothing);
      expect(operations.exports, 0);
      expect(picker.cameraCalls, 1);
      picker.cameraPhoto = null;
      await tester.tap(find.byTooltip('Capture Image'));
      await tester.pumpAndSettle();
      expect(picker.cameraCalls, 2);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'single gallery review cancels without deleting the original',
    (tester) async {
      final file = photo('gallery');
      picker.galleryPhotos = [XFile(file.path)];
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Import from gallery'));
      await waitForEditor(tester);
      final editor = tester.widget<CornerAdjustScreen>(
        find.byType(CornerAdjustScreen),
      );
      expect(editor.source, PageReviewSource.gallery);
      expect(editor.isBatchImport, isFalse);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Skip image'), findsNothing);
      expect(find.text(_skipNotice), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsNothing);
      expect(file.existsSync(), isTrue);
      expect(picker.galleryCalls, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Skip omits only this image and stale taps cannot dismiss the next review',
    (tester) async {
      final files = [for (var i = 0; i < 3; i++) photo('gallery-$i')];
      picker.galleryPhotos = files.map((file) => XFile(file.path)).toList();
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Import from gallery'));
      await waitForEditor(tester);
      final first = tester.widget<CornerAdjustScreen>(
        find.byType(CornerAdjustScreen),
      );
      expect(first.source, PageReviewSource.gallery);
      expect(first.isBatchImport, isTrue);
      expect(find.text(_skipNotice), findsOneWidget);
      final skip = tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Skip image'),
          )
          .onPressed!;
      final next = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Preview page'),
          )
          .onPressed!;
      skip();
      skip();
      next();
      await waitForEditor(tester, previousBytes: first.originalBytes);
      expect(find.text('Image 2 of 3'), findsOneWidget);
      expect(find.byType(CornerAdjustScreen), findsOneWidget);
      await accept(tester);
      await waitForEditor(tester);
      expect(find.text('Skip image'), findsOneWidget);
      await tester.tap(find.text('Skip image'));
      await tester.pumpAndSettle();
      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(find.byType(Card), findsOneWidget);
      expect(operations.exports, 1);
      expect(picker.galleryCalls, 1);
      expect(files.every((file) => file.existsSync()), isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'skipping every selected image adds no pages and releases intake',
    (tester) async {
      picker.galleryPhotos = [
        XFile(photo('first').path),
        XFile(photo('last').path),
      ];
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Import from gallery'));
      await waitForEditor(tester);
      final first = tester.widget<CornerAdjustScreen>(
        find.byType(CornerAdjustScreen),
      );
      await tester.tap(find.text('Skip image'));
      await waitForEditor(tester, previousBytes: first.originalBytes);
      await tester.tap(find.text('Skip image'));
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsNothing);
      expect(operations.exports, 0);
      picker.galleryPhotos = [];
      await tester.tap(find.byTooltip('Import from gallery'));
      await tester.pumpAndSettle();
      expect(picker.galleryCalls, 2);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'canceling an existing edit preserves the saved page and its settings',
    (tester) async {
      final page = ScannedPage(
        originalBytes: bytes,
        corners: _corners,
        processedBytes: bytes,
        filter: PageFilter.grayscale,
        brightness: 20,
        contrast: 1.2,
        rotationQuarterTurns: 1,
      );
      await pumpHome(tester, pages: [page]);
      await tester.tap(find.byType(Card));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit page'));
      await tester.pumpAndSettle();
      expect(find.text('Adjust appearance'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Edit page'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Skip image'), findsNothing);
      final cancel = tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Cancel'))
          .onPressed!;
      cancel();
      cancel();
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsOneWidget);
      expect(operations.exports, 0);
      await tester.tap(find.byType(Card));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit page'));
      await tester.pumpAndSettle();
      final editor = tester.widget<CornerAdjustScreen>(
        find.byType(CornerAdjustScreen),
      );
      expect(editor.originalBytes, same(page.originalBytes));
      expect(editor.initialFilter, page.filter);
      expect(editor.initialBrightness, page.brightness);
      expect(editor.initialContrast, page.contrast);
      expect(editor.initialRotationQuarterTurns, page.rotationQuarterTurns);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final count in [1, 2]) {
    testWidgets(
      'recovered selection of $count images uses accurate actions and cleans owned files',
      (tester) async {
        final files = [for (var i = 0; i < count; i++) photo('recovered-$i')];
        picker.recoveredPhotos = files.map((file) => XFile(file.path)).toList();
        await pumpHome(tester);
        Uint8List? previousBytes;
        for (var i = 0; i < count; i++) {
          await waitForEditor(tester, previousBytes: previousBytes);
          final editor = tester.widget<CornerAdjustScreen>(
            find.byType(CornerAdjustScreen),
          );
          expect(editor.source, PageReviewSource.recovered);
          previousBytes = editor.originalBytes;
          expect(files[i].existsSync(), isFalse);
          await tester.tap(find.text(count > 1 ? 'Skip image' : 'Cancel'));
        }
        await tester.pumpAndSettle();
        expect(find.byType(CornerAdjustScreen), findsNothing);
        expect(find.byType(Card), findsNothing);
        expect(picker.cameraCalls + picker.galleryCalls, 0);
        expect(files.every((file) => !file.existsSync()), isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  IconButton stopButton(WidgetTester tester) => tester.widget<IconButton>(
    find.widgetWithIcon(IconButton, Icons.stop_circle_outlined),
  );

  testWidgets(
    'batch review shows its position and Stop keeps accepted pages only',
    (tester) async {
      final files = [for (var i = 0; i < 4; i++) photo('stop-$i')];
      picker.galleryPhotos = files.map((file) => XFile(file.path)).toList();
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Import from gallery'));
      await waitForEditor(tester);
      expect(find.text('Image 1 of 4'), findsOneWidget);
      final first = tester.widget<CornerAdjustScreen>(
        find.byType(CornerAdjustScreen),
      );
      await accept(tester);

      await waitForEditor(tester, previousBytes: first.originalBytes);
      expect(find.text('Image 2 of 4'), findsOneWidget);
      final stop = stopButton(tester).onPressed!;
      stop();
      stop();
      await tester.pumpAndSettle();

      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(find.byType(Card), findsOneWidget);
      expect(operations.exports, 1);
      expect(
        find.text(
          'Import stopped. Pages already added were kept; the remaining '
          'images were not added.',
        ),
        findsOneWidget,
      );
      // Gallery originals belong to the user and must never be deleted.
      expect(files.every((file) => file.existsSync()), isTrue);

      picker.galleryPhotos = [];
      await tester.tap(find.byTooltip('Import from gallery'));
      await tester.pumpAndSettle();
      expect(picker.galleryCalls, 2);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Back during batch review stops the import instead of skipping',
    (tester) async {
      final files = [for (var i = 0; i < 3; i++) photo('back-$i')];
      picker.galleryPhotos = files.map((file) => XFile(file.path)).toList();
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Import from gallery'));
      await waitForEditor(tester);
      final first = tester.widget<CornerAdjustScreen>(
        find.byType(CornerAdjustScreen),
      );
      await accept(tester);
      await waitForEditor(tester, previousBytes: first.originalBytes);
      expect(find.text('Image 2 of 3'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(find.byType(Card), findsOneWidget);
      expect(find.textContaining('Import stopped.'), findsOneWidget);
      expect(picker.galleryCalls, 1);
      expect(files.every((file) => file.existsSync()), isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'the last batch image keeps Stop in place but disabled',
    (tester) async {
      picker.galleryPhotos = [
        XFile(photo('only-first').path),
        XFile(photo('only-last').path),
      ];
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Import from gallery'));
      await waitForEditor(tester);
      expect(stopButton(tester).onPressed, isNotNull);
      final stopRect = tester.getRect(find.byTooltip('Stop importing'));
      final canvasRect = tester.getRect(find.byType(CornerOverlay));
      final first = tester.widget<CornerAdjustScreen>(
        find.byType(CornerAdjustScreen),
      );
      await tester.tap(find.text('Skip image'));
      await waitForEditor(tester, previousBytes: first.originalBytes);
      expect(find.text('Image 2 of 2'), findsOneWidget);
      // Disabled rather than removed, so the app bar does not change on the
      // last image; Skip image still ends the batch.
      expect(stopButton(tester).onPressed, isNull);
      expect(tester.getRect(find.byTooltip('Stop importing')), stopRect);
      expect(tester.getRect(find.byType(CornerOverlay)), canvasRect);
      expect(find.text('Skip image'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'stopping a recovered batch deletes the remaining app-owned files',
    (tester) async {
      final files = [for (var i = 0; i < 3; i++) photo('recovered-stop-$i')];
      picker.recoveredPhotos = files.map((file) => XFile(file.path)).toList();
      await pumpHome(tester);
      await waitForEditor(tester);
      expect(find.text('Image 1 of 3'), findsOneWidget);
      await tester.tap(find.byTooltip('Stop importing'));
      // Cleanup is real file IO, which needs real event-loop turns.
      for (var i = 0; i < 50 && files.any((file) => file.existsSync()); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(find.byType(Card), findsNothing);
      expect(files.every((file) => !file.existsSync()), isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'single-image review shows no batch progress or Stop',
    (tester) async {
      picker.galleryPhotos = [XFile(photo('single').path)];
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Import from gallery'));
      await waitForEditor(tester);
      expect(find.byKey(const Key('batch_progress')), findsNothing);
      expect(find.byTooltip('Stop importing'), findsNothing);
      expect(find.text('Adjust corners'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  Future<void> acceptWithFilter(WidgetTester tester, PageFilter filter) async {
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('filter_${filter.name}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add page'));
    await tester.pumpAndSettle();
  }

  PageFilter editorFilter(WidgetTester tester) => tester
      .widget<CornerAdjustScreen>(find.byType(CornerAdjustScreen))
      .initialFilter;

  Future<void> capture(WidgetTester tester, String name) async {
    picker.cameraPhoto = XFile(photo(name).path);
    await tester.tap(find.byTooltip('Capture Image'));
    await waitForEditor(tester);
  }

  testWidgets(
    'camera pages start with the last new-page filter until Clear all',
    (tester) async {
      final existing = ScannedPage(
        originalBytes: bytes,
        corners: _corners,
        processedBytes: bytes,
        filter: PageFilter.grayscale,
      );
      await pumpHome(tester, pages: [existing]);

      await capture(tester, 'first');
      expect(editorFilter(tester), PageFilter.original);
      await acceptWithFilter(tester, PageFilter.blackAndWhite);
      expect(find.byType(Card), findsNWidgets(2));

      // Editing an existing page keeps its own filter and does not replace
      // the carried-over choice.
      await tester.tap(find.byType(Card).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit page'));
      await tester.pumpAndSettle();
      expect(editorFilter(tester), PageFilter.grayscale);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await capture(tester, 'second');
      expect(editorFilter(tester), PageFilter.blackAndWhite);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Clear all'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsNothing);

      await capture(tester, 'third');
      expect(editorFilter(tester), PageFilter.original);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'gallery batch pages start with the filter chosen for the previous page',
    (tester) async {
      picker.galleryPhotos = [
        for (var i = 0; i < 3; i++) XFile(photo('batch-$i').path),
      ];
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Import from gallery'));

      await waitForEditor(tester);
      expect(editorFilter(tester), PageFilter.original);
      var previousBytes = tester
          .widget<CornerAdjustScreen>(find.byType(CornerAdjustScreen))
          .originalBytes;
      await acceptWithFilter(tester, PageFilter.grayscale);

      await waitForEditor(tester, previousBytes: previousBytes);
      expect(editorFilter(tester), PageFilter.grayscale);
      previousBytes = tester
          .widget<CornerAdjustScreen>(find.byType(CornerAdjustScreen))
          .originalBytes;
      await acceptWithFilter(tester, PageFilter.autoEnhance);

      await waitForEditor(tester, previousBytes: previousBytes);
      expect(editorFilter(tester), PageFilter.autoEnhance);
      await accept(tester);
      expect(find.byType(Card), findsNWidgets(3));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final size in [const Size(320, 568), const Size(640, 300)]) {
    testWidgets('batch guidance fits $size at 200% text', (tester) async {
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
            source: PageReviewSource.gallery,
            isBatchImport: true,
            batchPosition: 2,
            batchCount: 5,
            onStopImport: () {},
            operations: operations,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(_skipNotice), findsOneWidget);
      // The position scales down instead of being ellipsized beside Stop.
      expect(find.text('Image 2 of 5').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Stop importing').hitTestable(), findsOneWidget);
      expect(find.text('Skip image'), findsOneWidget);
      await tester.ensureVisible(find.text('Skip image'));
      await tester.pumpAndSettle();
      expect(find.text('Skip image').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
