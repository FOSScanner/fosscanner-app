import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/barcode_scan_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/draft_store.dart';
import 'package:fosscanner/services/pdf_page_importer.dart';
import 'package:fosscanner/services/shared_image_inbox.dart';

import '../support/layout_stability.dart';

final _android = TargetPlatformVariant.only(TargetPlatform.android);

class _Picker extends ImagePickerPlatform {
  List<XFile> gallery = [];
  XFile? camera;
  List<XFile> recovered = [];

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => gallery;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    final taken = camera;
    camera = null;
    return taken;
  }

  @override
  Future<LostDataResponse> getLostData() async => recovered.isEmpty
      ? LostDataResponse.empty()
      : LostDataResponse(files: recovered);
}

class _Inbox implements SharedImageInbox {
  SharedImageBatch? batch;

  @override
  void setListener(VoidCallback? onAvailable) {}

  @override
  Future<SharedImageBatch> take({required int maxCount}) async {
    final taken = batch ?? const SharedImageBatch();
    batch = null;
    return taken;
  }
}

class _PdfImporter implements PdfPageImporter {
  @override
  Future<bool> pickDocument() async => false;

  @override
  Future<PdfImportBatch> renderPages(
    PdfImportRequest request, {
    void Function(int completed, int total)? onProgress,
  }) async => const PdfImportBatch();

  @override
  Future<void> cancel() async {}
}

class _Store implements DraftStore {
  @override
  Future<List<ScannedPage>> load() async => const [];

  @override
  Future<void> save(List<ScannedPage> pages) async {}

  @override
  Future<void> clear() async {}
}

// Small consistency fixes from QA round 2.
void main() {
  late ImagePickerPlatform originalPicker;
  late _Picker picker;
  late _Inbox inbox;
  late Directory directory;
  late Uint8List imageBytes;
  var fileCount = 0;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = picker = _Picker();
    inbox = _Inbox();
    directory = Directory.systemTemp.createTempSync('round2-');
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    directory.deleteSync(recursive: true);
  });

  String tiny() => (File(
    '${directory.path}/tiny_${fileCount++}.png',
  )..writeAsBytesSync(img.encodePng(img.Image(width: 2, height: 2)))).path;

  Future<void> pumpHome(
    WidgetTester tester, {
    int pageCount = 0,
    LayoutCase layoutCase = const LayoutCase(Size(390, 844), 1),
  }) async {
    applyLayoutCase(tester, layoutCase);
    await tester.pumpWidget(
      MaterialApp(
        builder: withTextScale(layoutCase.textScale),
        home: ScannerHomePage(
          draftStore: _Store(),
          searchablePdfEnabled: true,
          sharedImageInbox: inbox,
          pdfPageImporter: _PdfImporter(),
          initialPages: [
            for (var i = 0; i < pageCount; i++)
              ScannedPage(
                originalBytes: imageBytes,
                processedBytes: imageBytes,
                corners: const [],
              ),
          ],
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  String? shownMessage(WidgetTester tester) {
    final texts = find.descendant(
      of: find.byType(SnackBar),
      matching: find.byType(Text),
    );
    return texts.evaluate().isEmpty
        ? null
        : tester.widget<Text>(texts.first).data;
  }

  const unsupportedSize =
      'This image is too small or has unsupported dimensions. '
      'Choose another image, or resize a large image and try again.';

  group('a 2 × 2 px image is rejected the same way on every intake path', () {
    testWidgets('gallery', (tester) async {
      picker.gallery = [XFile(tiny())];
      await pumpHome(tester);
      await settle(tester);
      await tester.tap(find.byTooltip('Import from gallery'));
      await settle(tester);
      expect(shownMessage(tester), unsupportedSize);
      expect(find.text('Ready to scan'), findsOneWidget);
    }, variant: _android);

    testWidgets('camera', (tester) async {
      picker.camera = XFile(tiny());
      await pumpHome(tester);
      await settle(tester);
      await tester.tap(find.byTooltip('Scan a page'));
      await settle(tester);
      expect(shownMessage(tester), unsupportedSize);
      expect(find.text('Ready to scan'), findsOneWidget);
    }, variant: _android);

    testWidgets('share', (tester) async {
      inbox.batch = SharedImageBatch(paths: [tiny()]);
      await pumpHome(tester);
      await settle(tester);
      expect(shownMessage(tester), unsupportedSize);
      expect(find.text('Ready to scan'), findsOneWidget);
    }, variant: _android);

    testWidgets('recovered picker result', (tester) async {
      picker.recovered = [XFile(tiny())];
      await pumpHome(tester);
      await settle(tester);
      expect(shownMessage(tester), unsupportedSize);
      expect(find.text('Ready to scan'), findsOneWidget);
    }, variant: _android);
  });

  testWidgets(
    'a shared item the platform cannot open names no size limit',
    (tester) async {
      inbox.batch = const SharedImageBatch(rejected: 1);
      await pumpHome(tester);
      await settle(tester);
      expect(shownMessage(tester), 'Could not open the shared file.');
    },
    variant: _android,
  );

  testWidgets('every overflow menu item has an icon and aligned text', (
    tester,
  ) async {
    await pumpHome(tester, pageCount: 1);
    await settle(tester);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    final titles = [
      'Import from PDF',
      'Clear all pages',
      'Block screenshots',
      'About FOSScanner',
    ];
    final starts = <double>{};
    for (final title in titles) {
      final tile = find.ancestor(
        of: find.text(title),
        matching: find.byType(ListTile),
      );
      expect(tester.widget<ListTile>(tile).leading, isA<Icon>(), reason: title);
      starts.add(tester.getRect(find.text(title)).left);
    }
    expect(starts, hasLength(1), reason: 'titles start at $starts');
  }, variant: _android);

  testWidgets('Block screenshots keeps its width when checked', (tester) async {
    await pumpHome(tester, pageCount: 1);
    await settle(tester);
    Future<Rect> openAndMeasure() async {
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      return tester.getRect(find.text('Block screenshots'));
    }

    Icon check() =>
        tester.widget<Icon>(find.byKey(const Key('block_screenshots_check')));
    final off = await openAndMeasure();
    // Visible when off too, so the item reads as a setting.
    expect(check().icon, Icons.check_box_outline_blank);
    expect(check().color, isNot(Colors.transparent));
    await tester.tap(find.text('Block screenshots'));
    await tester.pumpAndSettle();
    final on = await openAndMeasure();
    expect(on, off);
    expect(check().icon, Icons.check_box);
    expect(check().color, isNot(Colors.transparent));
  }, variant: _android);

  for (final brightness in Brightness.values) {
    testWidgets('a selected export option shows a check without moving '
        'the chips ($brightness)', (tester) async {
      applyLayoutCase(tester, const LayoutCase(Size(390, 844), 1));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: ScannerHomePage(
            draftStore: _Store(),
            searchablePdfEnabled: false,
            initialPages: [
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
      await tester.tap(find.byTooltip('PDF export options'));
      await tester.pumpAndSettle();

      Finder chip(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(ChoiceChip),
      );
      Color? checkColor(String label) => tester
          .widget<Icon>(
            find.descendant(
              of: chip(label),
              matching: find.byIcon(Icons.check),
            ),
          )
          .color;
      final labels = ['Original', 'A4', 'Letter', 'High', 'Balanced', 'Small'];
      final selected = {
        for (final label in labels)
          if (tester.widget<ChoiceChip>(chip(label)).selected) label,
      };
      expect(selected, hasLength(2));
      for (final label in labels) {
        expect(
          checkColor(label) == Colors.transparent,
          !selected.contains(label),
          reason: label,
        );
      }
      await expectStableRects(
        tester,
        {for (final label in labels) label: chip(label)},
        () async {
          await tester.tap(find.text('Letter'));
          await tester.tap(find.text('Small'));
          await tester.pumpAndSettle();
        },
      );
      expect(checkColor('Letter'), isNot(Colors.transparent));
      expect(checkColor('Small'), isNot(Colors.transparent));
      expect(checkColor('Original'), Colors.transparent);
    });
  }

  testWidgets(
    'screen readers get labelled page cards and one options stop',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpHome(tester, pageCount: 2);
      await settle(tester);

      final unlabelled = <SemanticsNode>[];
      void visit(SemanticsNode node) {
        final data = node.getSemanticsData();
        if (!node.isMergedIntoParent &&
            (data.hasAction(SemanticsAction.tap) ||
                data.hasAction(SemanticsAction.focus)) &&
            data.label.isEmpty &&
            data.tooltip.isEmpty) {
          unlabelled.add(node);
        }
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      // ignore: deprecated_member_use
      visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
      expect(unlabelled, isEmpty, reason: '$unlabelled');

      final page = tester
          .getSemantics(find.byKey(const ValueKey('page_semantics_0')))
          .getSemanticsData();
      expect(page.label, contains('Page 1 of 2'));
      expect(page.hasAction(SemanticsAction.tap), isTrue);

      // The options button and its current choices are one focus stop.
      final options = tester
          .getSemantics(find.byTooltip('PDF export options'))
          .getSemanticsData();
      expect(options.tooltip, 'PDF export options');
      expect(options.value, startsWith('Searchable text o'));
      expect(options.hasAction(SemanticsAction.tap), isTrue);
      var valueNodes = 0;
      void countValues(SemanticsNode node) {
        if (node.getSemanticsData().value.startsWith('Searchable text')) {
          valueNodes++;
        }
        node.visitChildren((child) {
          countValues(child);
          return true;
        });
      }

      countValues(
        // ignore: deprecated_member_use
        tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!,
      );
      expect(valueNodes, 1);
      semantics.dispose();
    },
    variant: _android,
  );

  for (final brightness in Brightness.values) {
    testWidgets('a QR image message clears the camera controls in the app\'s '
        'message style ($brightness)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: BarcodeScanScreen(
            scanViewBuilder: (context, onScan) => const SizedBox.expand(),
            imageScanner: () async =>
                const BarcodeScanResult(isValid: false, text: null),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Scan an image'));
      await tester.pumpAndSettle();
      expect(find.text('No code found in this image.'), findsOneWidget);

      final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
      // The theme's message style, like every other screen.
      expect(snackBar.backgroundColor, isNull);
      final screen = tester.getRect(find.byType(BarcodeScanScreen));
      final message = tester.getRect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.byType(Material),
        ),
      );
      // The reader draws its flashlight and switch-camera buttons in the
      // bottom 68 px (48 px buttons with 10 px padding).
      expect(message.bottom, lessThanOrEqualTo(screen.bottom - 68));
    });
  }
}
