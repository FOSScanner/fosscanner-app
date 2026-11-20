import 'dart:async';

import 'package:flutter/foundation.dart' show LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:fosscanner/main.dart' show registerBundledLicenses;
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/services/image_metadata.dart' show maxDocumentPages;
import 'package:fosscanner/screens/scanner_home_page.dart';

class _Picker extends ImagePickerPlatform {
  Completer<List<XFile>>? selection;
  var galleryCalls = 0;

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    galleryCalls++;
    return await selection?.future ?? const [];
  }
}

void main() {
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

    expect(find.text('Export 3 pages as PDF'), findsOneWidget);
    expect(find.byTooltip('PDF export options'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('About FOSScanner'), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('pdf_export_bar'))).height,
      lessThanOrEqualTo(88),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('export options explain OCR and retain the selection on reopen', (
    tester,
  ) async {
    await pumpHome(tester);
    await openOptions(tester);
    expect(find.text('Searchable text'), findsOneWidget);
    expect(find.textContaining('Latin-script'), findsOneWidget);
    expect(
      find.text('Supports Latin-script text. Runs on your device.'),
      findsOneWidget,
    );
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );

    await tester.tap(find.text('Searchable text'));
    await tester.pumpAndSettle();
    expect(find.text('Search and copy text in the PDF.'), findsOneWidget);
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

  testWidgets('image-only platforms offer layout but not OCR settings', (
    tester,
  ) async {
    await pumpHome(tester, searchable: false);
    expect(find.text('Export 1 page as PDF'), findsOneWidget);
    await openOptions(tester);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.textContaining('Latin-script'), findsNothing);
    expect(find.text('Page size'), findsOneWidget);
    expect(find.text('Quality'), findsOneWidget);
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
        expect(find.text('Export 1 page as PDF').hitTestable(), findsOneWidget);
        await openOptions(tester);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Searchable text'));
        await tester.tap(find.text('Searchable text'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue,
        );
        await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Small'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, 'Small'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
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
      final status = find.text('Image intake help');
      await tester.ensureVisible(status);
      await tester.pumpAndSettle();
      await tester.tap(status);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('$maxDocumentPages-page limit'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Close'));
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
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
        'reorder controls and menu fit $size at 200% text in $brightness',
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
          final reorder = find.byTooltip('Reorder page 8');
          await tester.scrollUntilVisible(
            reorder,
            200,
            maxScrolls: 50,
            scrollable: find.descendant(
              of: find.byType(GridView),
              matching: find.byType(Scrollable),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final preview = find.descendant(
            of: find.byKey(const ValueKey('page_semantics_7')),
            matching: find.byType(Image),
          );
          expect(
            tester.getRect(preview).overlaps(tester.getRect(reorder)),
            isFalse,
          );
          await tester.tap(reorder);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Move earlier'));
          await tester.pumpAndSettle();
          expect(find.text('Move earlier').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.text('Move earlier'), findsNothing);
        },
      );
    }
  }
  testWidgets(
    'empty home offers scanning and gallery import as first actions',
    (tester) async {
      await pumpHome(tester, pageCount: 0);
      final title = tester.widget<Text>(find.text('Ready to scan'));
      expect(
        title.style,
        Theme.of(
          tester.element(find.text('Ready to scan')),
        ).textTheme.headlineSmall,
      );
      expect(
        find.text('Scan your first page, or import from your gallery.'),
        findsOneWidget,
      );
      expect(find.textContaining('Privacy-first'), findsNothing);
      expect(find.byTooltip('Scan a page'), findsOneWidget);

      final import = find.widgetWithText(OutlinedButton, 'Import from gallery');
      expect(import, findsOneWidget);
      await tester.tap(import);
      await tester.pumpAndSettle();
      expect(picker.galleryCalls, 1);
    },
  );

  testWidgets('short empty home scrolls without large-text overflow', (
    tester,
  ) async {
    setViewport(tester, const Size(640, 260));
    await pumpHome(tester, pageCount: 0, textScale: 2);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.textContaining('Scan your first page'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('page labels and delete controls do not cover document content', (
    tester,
  ) async {
    await pumpHome(tester);
    final preview = find.descendant(
      of: find.byType(Card).first,
      matching: find.byType(Image),
    );
    final image = tester.widget<Image>(preview);
    final bounds = tester.getRect(preview);
    expect(image.fit, BoxFit.contain);
    expect(bounds.overlaps(tester.getRect(find.text('Page 1'))), isFalse);
    expect(
      bounds.overlaps(tester.getRect(find.byTooltip('Delete page 1'))),
      isFalse,
    );
  });

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
    await tester.ensureVisible(find.text('View licenses'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  for (final (size, columns) in [
    (const Size(320, 568), 2),
    (const Size(390, 844), 2),
    (const Size(640, 300), 3),
    (const Size(800, 1280), 4),
    (const Size(1280, 800), 6),
  ]) {
    testWidgets('page grid uses $columns columns at $size', (tester) async {
      setViewport(tester, size);
      await pumpHome(tester, pageCount: 8);
      final firstRowTop = tester.getTopLeft(find.byType(Card).first).dy;
      final cards = find.byType(Card);
      final cardsInFirstRow = [
        for (var i = 0; i < cards.evaluate().length; i++)
          if (tester.getTopLeft(cards.at(i)).dy == firstRowTop) i,
      ].length;
      expect(cardsInFirstRow, columns);
      expect(tester.getSize(cards.first).width, lessThanOrEqualTo(240));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('About opens the license page with the bundled OCR licenses', (
    tester,
  ) async {
    registerBundledLicenses();
    addTearDown(LicenseRegistry.reset);
    await pumpHome(tester, pageCount: 0);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About FOSScanner'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('View licenses'));
    // The license page collects entries asynchronously from asset bundles.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('1.4.0'), findsOneWidget);
    expect(find.text('Tesseract language data'), findsOneWidget);
    expect(
      find.text('Tesseract4Android and native OCR dependencies'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  // 640x300 at 200% text is left out: the header and export row leave the
  // grid less height than its FAB clearance (already with the former fixed
  // two columns), so the last page is never laid out at max scroll. Its reorder controls are
  // covered by the large-text reorder test above.
  for (final (size, textScale) in [
    (const Size(390, 600), 1.0),
    (const Size(390, 600), 2.0),
    (const Size(640, 300), 1.0),
    (const Size(1024, 768), 1.0),
    (const Size(1024, 768), 2.0),
    (const Size(1280, 800), 1.0),
    (const Size(1280, 800), 2.0),
  ]) {
    testWidgets(
      'last grid page and delete action clear the camera button at $size '
      'and ${textScale}x text',
      (tester) async {
        setViewport(tester, size);
        await pumpHome(tester, pageCount: 8, textScale: textScale);
        final scroll = tester.state<ScrollableState>(
          find.descendant(
            of: find.byType(GridView),
            matching: find.byType(Scrollable),
          ),
        );
        scroll.position.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();

        final camera = tester.getRect(find.byType(FloatingActionButton));
        final page = tester.getRect(
          find.byKey(const ValueKey('page_semantics_7')),
        );
        for (final tooltip in ['Delete page 8', 'Reorder page 8']) {
          expect(
            tester.getRect(find.byTooltip(tooltip)).overlaps(camera),
            isFalse,
            reason: tooltip,
          );
        }
        expect(page.overlaps(camera), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

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
