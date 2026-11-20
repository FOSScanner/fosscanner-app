import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/barcode_scan_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';

import '../support/layout_stability.dart';

class _Picker extends ImagePickerPlatform {
  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

// #160: very large display size and font.
void main() {
  late ImagePickerPlatform originalPicker;
  late Uint8List imageBytes;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _Picker();
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
    required int pageCount,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: withTextScale(layoutCase.textScale),
        home: ScannerHomePage(
          searchablePdfEnabled: false,
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
    await tester.pumpAndSettle();
  }

  final camera = find.byType(FloatingActionButton);

  testLayoutMatrix(
    'no page card is under the camera button at any scroll offset',
    (tester, layoutCase) async {
      const pageCount = 7;
      await pumpHome(tester, layoutCase, pageCount: pageCount);
      final cameraRect = tester.getRect(camera);
      final grid = tester.getRect(find.byType(GridView));
      final position = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byType(GridView),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      final end = position.maxScrollExtent;
      for (var offset = 0.0; ; offset = (offset + 24).clamp(0, end)) {
        position.jumpTo(offset);
        await tester.pump();
        for (var i = 0; i < pageCount; i++) {
          final card = find.byKey(ValueKey('page_semantics_$i'));
          if (card.evaluate().isEmpty) continue;
          // Only the part inside the grid's viewport can be seen or tapped.
          final visible = tester.getRect(card).intersect(grid);
          if (visible.width <= 0 || visible.height <= 0) continue;
          expect(
            visible.overlaps(cameraRect.deflate(0.5)),
            isFalse,
            reason: 'page ${i + 1} at scroll offset $offset',
          );
        }
        if (offset >= end) break;
      }
      expect(tester.takeException(), isNull);
    },
    cases: [...largeDisplayCases, ...layoutMatrix],
  );

  testLayoutMatrix(
    'the empty-state gallery button scrolls fully clear of the camera button',
    (tester, layoutCase) async {
      await pumpHome(tester, layoutCase, pageCount: 0);
      final button = find.widgetWithText(OutlinedButton, 'Import from gallery');
      final scrollView = find.ancestor(
        of: button,
        matching: find.byType(SingleChildScrollView),
      );
      await tester.drag(scrollView, const Offset(0, -2000));
      await tester.pumpAndSettle();
      final rect = tester.getRect(button);
      final viewport = tester.getRect(scrollView);
      final cameraRect = tester.getRect(camera);
      // A short landscape screen at 2.0× is barely taller than the button
      // and its 32 px margins; there it must still stay beside the camera
      // button.
      if (rect.height + 64 <= viewport.height) {
        expect(rect.top, greaterThanOrEqualTo(viewport.top - 0.5));
        expect(rect.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
      }
      expect(rect.intersect(viewport).overlaps(cameraRect), isFalse);
      expect(tester.takeException(), isNull);
    },
    cases: [...largeDisplayCases, ...layoutMatrix],
  );

  testLayoutMatrix(
    'the export label shows the page count',
    (tester, layoutCase) async {
      await pumpHome(tester, layoutCase, pageCount: 12);
      const label = 'Export 12 pages as PDF';
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      // Lay the label out without a line limit: the count has to be on one
      // of the lines the button shows, so no ellipsis can hide it.
      final painter = TextPainter(
        text: paragraph.text,
        textDirection: TextDirection.ltr,
        textScaler: paragraph.textScaler,
      )..layout(maxWidth: paragraph.constraints.maxWidth);
      final count = label.indexOf('12');
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: count, extentOffset: count + 2),
      );
      final shownHeight = painter
          .computeLineMetrics()
          .take(paragraph.maxLines!)
          .fold(0.0, (sum, line) => sum + line.height);
      painter.dispose();
      expect(boxes, isNotEmpty);
      for (final box in boxes) {
        expect(box.bottom, lessThanOrEqualTo(shownHeight + 0.5));
      }
      expect(tester.takeException(), isNull);
    },
    // At 2.0× on 320 and 308 px wide phones the square test font fits
    // fewer than six glyphs on a line, so even "Export" wraps; Roboto fits
    // "Export" and the count on the two lines there.
    cases: [
      for (final layoutCase in [...largeDisplayCases, ...layoutMatrix])
        if (layoutCase.textScale < 2 || layoutCase.size.width > 380) layoutCase,
    ],
  );

  testLayoutMatrix(
    'the title and the draft hint are not cut off',
    (tester, layoutCase) async {
      await pumpHome(tester, layoutCase, pageCount: 2);
      final title = tester.getRect(find.text('FOSScanner'));
      final firstAction = tester.getRect(
        find.byTooltip('Scan QR code or barcode'),
      );
      expect(title.right, lessThanOrEqualTo(firstAction.left + 0.5));
      final hint = tester.renderObject<RenderParagraph>(
        find.text('Drafts are temporary. Export a PDF to keep a copy.'),
      );
      if (layoutCase.size.height >= 480) {
        // Tall screens wrap the hint over two lines. The test font is about
        // twice as wide as Roboto, so at 2.0× it can need more.
        expect(
          !hint.didExceedMaxLines || hint.maxLines == 2,
          isTrue,
          reason: 'cut off after ${hint.maxLines} lines',
        );
      }
      expect(tester.takeException(), isNull);
    },
    cases: [...largeDisplayCases, ...layoutMatrix],
  );

  testLayoutMatrix('the QR screen title is not cut off', (
    tester,
    layoutCase,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: withTextScale(layoutCase.textScale),
        home: BarcodeScanScreen(
          scanViewBuilder: (context, onScan) => const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final title = tester.getRect(find.text('Scan QR code or barcode'));
    final action = tester.getRect(find.byTooltip('Scan an image'));
    expect(title.right, lessThanOrEqualTo(action.left + 0.5));
    expect(title.left, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  }, cases: largeDisplayCases);
}
