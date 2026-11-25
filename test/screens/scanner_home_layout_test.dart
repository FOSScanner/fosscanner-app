import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/services/image_metadata.dart' show maxDocumentPages;
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/main.dart' show registerBundledLicenses;
import '../support/layout_stability.dart';
import '../support/worker_isolates.dart';

class _Picker extends ImagePickerPlatform {
  Completer<List<XFile>>? selection;

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => await selection?.future ?? const [];
}

void main() {
  setUpAll(registerBundledLicenses);
  late ImagePickerPlatform originalPicker;
  late _Picker picker;
  late Uint8List imageBytes;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = picker = _Picker();
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    PackageInfo.setMockInitialValues(
      appName: 'FOSScanner',
      packageName: 'com.fosscanner.app',
      version: '1.4.0',
      buildNumber: '7',
      buildSignature: '',
    );
  });

  tearDown(() => ImagePickerPlatform.instance = originalPicker);

  Future<void> pumpHome(
    WidgetTester tester, {
    int pageCount = 1,
    bool searchable = true,
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: brightness,
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: ScannerHomePage(
          searchablePdfEnabled: searchable,
          initialPages: [
            for (var index = 0; index < pageCount; index++)
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

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> openOptions(WidgetTester tester) async {
    await tester.tap(find.byTooltip('PDF export options'));
    await tester.pumpAndSettle();
  }

  testWidgets('home has one compact export row, not an inline OCR panel', (
    tester,
  ) async {
    setViewport(tester, const Size(390, 844));
    await pumpHome(tester, pageCount: 3);

    expect(find.text('Export PDF (3 pages)'), findsOneWidget);
    expect(find.byTooltip('PDF export options'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('About FOSScanner'), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('pdf_export_bar'))).height,
      lessThanOrEqualTo(88),
    );
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(240, 640),
    const Size(320, 568),
    const Size(390, 844),
    const Size(640, 300),
  ]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        'export and OCR options stay on the same row at $size / $scale',
        (tester) async {
          setViewport(tester, size);
          await pumpHome(tester, pageCount: maxDocumentPages, textScale: scale);
          final export = find.widgetWithText(
            FilledButton,
            'Export PDF ($maxDocumentPages pages)',
          );
          final options = find.ancestor(
            of: find.byTooltip('PDF export options'),
            matching: find.byType(IconButton),
          );
          final exportRect = tester.getRect(export);
          final optionsRect = tester.getRect(options);
          final bar = tester.getRect(find.byKey(const Key('pdf_export_bar')));
          expect(optionsRect.center.dy, closeTo(exportRect.center.dy, 0.5));
          expect(optionsRect.left, greaterThanOrEqualTo(exportRect.right + 8));
          expect(optionsRect.right, lessThanOrEqualTo(bar.right));
          expect(optionsRect.bottom, lessThanOrEqualTo(bar.bottom));
          expect(optionsRect.width, greaterThanOrEqualTo(48));
          expect(optionsRect.height, greaterThanOrEqualTo(48));
          expect(export.hitTestable(), findsOneWidget);
          expect(options.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(options);
          await tester.pumpAndSettle();
          expect(find.byType(SwitchListTile), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('export options explain OCR and retain the selection on reopen', (
    tester,
  ) async {
    await pumpHome(tester);
    await openOptions(tester);
    expect(find.text('Searchable text'), findsOneWidget);
    expect(find.textContaining('Latin-script'), findsOneWidget);
    expect(find.textContaining('entirely on your device'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );

    await tester.tap(find.text('Searchable text'));
    await tester.pumpAndSettle();
    expect(
      find.text('Recognize text so you can search and select it in the PDF.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNothing);

    await openOptions(tester);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tester.tap(find.text('Searchable text'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
  });

  for (final size in [const Size(390, 844), const Size(320, 568)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'searchable switch and sheet remain fixed at $size / $scale',
        (tester) async {
          setViewport(tester, size);
          await pumpHome(tester, textScale: scale);
          await openOptions(tester);
          await tester.ensureVisible(find.text('Searchable text'));
          await tester.pumpAndSettle();
          final anchors = [
            find.byType(SwitchListTile),
            find.byType(BottomSheet),
            find.widgetWithText(FilledButton, 'Done'),
          ];
          for (var toggle = 0; toggle < 2; toggle++) {
            await expectStableRects(tester, anchors, () async {
              await tester.tap(find.text('Searchable text'));
              await tester.pumpAndSettle();
            });
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('About exposes registered native licenses at 200% text', (
    tester,
  ) async {
    setViewport(tester, const Size(320, 568));
    await pumpHome(tester, pageCount: 0, textScale: 2);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About FOSScanner'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('View licenses'));
    await tester.tap(find.text('View licenses'));
    // License decoding uses real compute isolates for the larger notice texts.
    await pumpUntilFound(
      tester,
      find.descendant(
        of: find.byType(LicensePage),
        matching: find.byType(ListView),
      ),
    );
    expect(find.byType(LicensePage), findsOneWidget);
    for (final label in [
      'AndroidX CameraX and libyuv',
      'KleidiCV',
      'OpenCV and native image dependencies',
      'Tesseract language data',
      'Tesseract4Android and native OCR dependencies',
      'ZXing and Zint native barcode libraries',
    ]) {
      // Flutter pins the first registered package ahead of alphabetical order.
      tester
          .state<ScrollableState>(find.byType(Scrollable).last)
          .position
          .jumpTo(0);
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text(label),
        200,
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 100,
      );
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('image-only platforms do not offer unavailable OCR settings', (
    tester,
  ) async {
    await pumpHome(tester, searchable: false);
    expect(find.text('Export PDF (1 page)'), findsOneWidget);
    expect(find.byTooltip('PDF export options'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('empty home has no footer and About is in the overflow menu', (
    tester,
  ) async {
    await pumpHome(tester, pageCount: 0);
    expect(find.byKey(const Key('pdf_export_bar')), findsNothing);
    expect(find.byTooltip('PDF export options'), findsNothing);
    expect(find.text('About FOSScanner'), findsNothing);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About FOSScanner'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Version 1.4.0 (build 7)'), findsOneWidget);
    expect(find.text('View source code'), findsOneWidget);
    expect(find.text('Licensed under the GNU GPL v3.0'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final size in [const Size(320, 568), const Size(640, 300)]) {
      testWidgets('large-text home and options fit $size in $brightness', (
        tester,
      ) async {
        setViewport(tester, size);
        await pumpHome(tester, textScale: 2, brightness: brightness);
        expect(tester.takeException(), isNull);
        expect(find.text('Export PDF (1 page)').hitTestable(), findsOneWidget);
        await openOptions(tester);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Searchable text'));
        await tester.tap(find.text('Searchable text'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue,
        );
        await tester.ensureVisible(find.widgetWithText(FilledButton, 'Done'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Done'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final size in [const Size(320, 568), const Size(640, 300)]) {
    testWidgets('intake-limit status and guidance fit large text on $size', (
      tester,
    ) async {
      setViewport(tester, size);
      await pumpHome(tester, pageCount: maxDocumentPages, textScale: 2);
      expect(find.text('Image intake help'), findsNothing);
      expect(
        tester
            .widget<Semantics>(find.byKey(const Key('image_intake')))
            .properties
            .hint,
        contains('$maxDocumentPages-page limit'),
      );
      expect(tester.takeException(), isNull);
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    for (final size in [
      const Size(320, 568),
      const Size(640, 300),
      const Size(1024, 768),
    ]) {
      testWidgets(
        'top-right delete controls fit $size at 200% text in $brightness',
        (tester) async {
          setViewport(tester, size);
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
          addTearDown(tester.view.resetPadding);
          await pumpHome(
            tester,
            pageCount: 8,
            textScale: 2,
            brightness: brightness,
          );
          final delete = find.byTooltip('Delete page 8');
          await tester.scrollUntilVisible(
            delete,
            200,
            maxScrolls: 50,
            scrollable: find.descendant(
              of: find.byType(GridView),
              matching: find.byType(Scrollable),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final cardRect = tester.getRect(
            find.byKey(const ValueKey('page_preview_7')),
          );
          final deleteButton = find.ancestor(
            of: delete,
            matching: find.byType(IconButton),
          );
          final deleteRect = tester.getRect(deleteButton);
          expect(deleteRect.right, closeTo(cardRect.right, 1));
          expect(deleteRect.top, closeTo(cardRect.top, 1));
          expect(deleteRect.width, greaterThanOrEqualTo(48));
          expect(deleteRect.height, greaterThanOrEqualTo(48));
          expect(delete.hitTestable(), findsOneWidget);
          expect(
            deleteRect.overlaps(
              tester.getRect(find.byTooltip('Capture Image')),
            ),
            isFalse,
          );
          expect(find.byIcon(Icons.swap_vert), findsNothing);
          await tester.tap(delete);
          await tester.pumpAndSettle();
          expect(find.text('Export PDF (7 pages)'), findsOneWidget);
          expect(find.text('Page deleted.'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final size in [const Size(320, 568), const Size(390, 844)]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets(
        'portrait keeps compact two-column previews at $size / $scale',
        (tester) async {
          setViewport(tester, size);
          await pumpHome(tester, pageCount: 8, textScale: scale);
          final grid = tester.widget<GridView>(find.byType(GridView));
          final delegate =
              grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
          expect(delegate.crossAxisCount, 2);
          expect(
            delegate.mainAxisExtent,
            lessThan(size.width < 350 ? 240 : 300),
          );
          expect(find.text('Image intake help'), findsNothing);
          expect(
            find.text('Drafts are temporary. Export a PDF to keep a copy.'),
            findsNothing,
          );
          expect(find.byIcon(Icons.swap_vert), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('short empty home scrolls without large-text overflow', (
    tester,
  ) async {
    setViewport(tester, const Size(640, 260));
    await pumpHome(tester, pageCount: 0, textScale: 2);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.textContaining('Tap the camera button'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'page label stays outside the image with deletion at the preview corner',
    (tester) async {
      await pumpHome(tester);
      final preview = find.descendant(
        of: find.byType(Card).first,
        matching: find.byType(Image),
      );
      final image = tester.widget<Image>(preview);
      final bounds = tester.getRect(preview);
      expect(image.fit, BoxFit.contain);
      expect(bounds.overlaps(tester.getRect(find.text('Page 1'))), isFalse);
      final tile = tester.getRect(find.byKey(const ValueKey('page_preview_0')));
      final delete = tester.getRect(
        find.ancestor(
          of: find.byTooltip('Delete page 1'),
          matching: find.byType(IconButton),
        ),
      );
      expect(delete.top, closeTo(tile.top, 1));
      expect(delete.right, closeTo(tile.right, 1));
    },
  );

  testWidgets('About content remains usable on a narrow large-text screen', (
    tester,
  ) async {
    setViewport(tester, const Size(320, 568));
    await pumpHome(tester, pageCount: 0, textScale: 2);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About FOSScanner'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('View source code'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('last grid page and delete action clear the camera button', (
    tester,
  ) async {
    setViewport(tester, const Size(390, 600));
    await pumpHome(tester, pageCount: 8);
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(GridView),
        matching: find.byType(Scrollable),
      ),
    );
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();

    final camera = tester.getRect(find.byType(FloatingActionButton));
    final delete = tester.getRect(find.byTooltip('Delete page 8'));
    final page = tester.getRect(find.byKey(const ValueKey('page_semantics_7')));
    expect(delete.overlaps(camera), isFalse);
    expect(page.overlaps(camera), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('busy intake rejects a stale export-options callback', (
    tester,
  ) async {
    picker.selection = Completer<List<XFile>>();
    await pumpHome(tester);
    final options = tester
        .widget<IconButton>(
          find.ancestor(
            of: find.byTooltip('PDF export options'),
            matching: find.byType(IconButton),
          ),
        )
        .onPressed!;
    await tester.tap(find.byTooltip('Import from gallery'));
    await tester.pump();
    options();
    await tester.pump();
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('PDF export options'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
    picker.selection!.complete([]);
    await tester.pumpAndSettle();
    await openOptions(tester);
    expect(find.text('Searchable text'), findsOneWidget);
  });
}
