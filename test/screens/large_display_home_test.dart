import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/barcode_scan_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';

import '../support/export_bar.dart';
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

  // #160: before any scrolling, too.
  testLayoutMatrix(
    'the empty-state gallery button is never under the camera button',
    (tester, layoutCase) async {
      await pumpHome(tester, layoutCase, pageCount: 0);
      final button = find.widgetWithText(OutlinedButton, 'Import from gallery');
      final scrollView = find.ancestor(
        of: button,
        matching: find.byType(SingleChildScrollView),
      );
      final cameraRect = tester.getRect(camera);
      for (final offset in [0.0, 120.0, 2000.0]) {
        if (offset > 0) {
          await tester.drag(scrollView, Offset(0, -offset));
          await tester.pumpAndSettle();
        }
        final visible = tester
            .getRect(button)
            .intersect(tester.getRect(scrollView));
        expect(
          visible.width > 0 &&
              visible.height > 0 &&
              visible.overlaps(cameraRect.deflate(0.5)),
          isFalse,
          reason: 'scrolled by $offset',
        );
      }
      expect(tester.takeException(), isNull);
    },
    cases: [...largeDisplayCases, ...layoutMatrix],
  );

  testLayoutMatrix(
    'the empty state shows its copy and button unscrolled where they fit, '
    'and a scrollbar where they do not',
    (tester, layoutCase) async {
      await pumpHome(tester, layoutCase, pageCount: 0);
      final scrollView = find.byKey(const Key('empty_state_scroll_view'));
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: scrollView, matching: find.byType(Scrollable)),
          )
          .position;
      final viewport = tester.getRect(scrollView);
      final button = find.widgetWithText(OutlinedButton, 'Import from gallery');
      final copy = find.text(
        'Scan your first page, or import from your gallery.',
      );
      if (position.maxScrollExtent == 0) {
        for (final finder in [copy, button]) {
          final rect = tester.getRect(finder);
          expect(viewport.intersect(rect), rect, reason: '$finder is cut off');
        }
      } else {
        // Content that does not fit starts at the top margin instead of
        // being pushed below the fold by centring (the 412 × 915 @2.0× QA
        // phone with Roboto fits; the wider test font does not).
        expect(
          tester.getRect(find.byKey(const Key('empty_state_icon'))).top -
              viewport.top,
          moreOrLessEquals(32, epsilon: 0.5),
        );
        // Whatever does not fit is reachable, and the scrollbar says so.
        final scrollbar = tester.widget<Scrollbar>(
          find.ancestor(of: scrollView, matching: find.byType(Scrollbar)),
        );
        expect(scrollbar.thumbVisibility, isTrue);
      }
      expect(tester.takeException(), isNull);
    },
    cases: [...largeDisplayCases, ...layoutMatrix],
  );

  // #153
  testLayoutMatrix(
    'every page card shows its whole page number on one line',
    (tester, layoutCase) async {
      const pageCount = 12;
      await pumpHome(tester, layoutCase, pageCount: pageCount);
      final semantics = tester.ensureSemantics();
      final labels = <String>{};
      for (var i = 0; i < pageCount; i++) {
        final label = find.byKey(ValueKey('page_label_$i'));
        if (label.evaluate().isEmpty) continue;
        final text = tester.widget<Text>(label).data!;
        expect(text, anyOf('Page ${i + 1}', '${i + 1}'));
        labels.add(text.startsWith('Page') ? 'long' : 'short');
        final paragraph = tester.renderObject<RenderParagraph>(label);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(
          paragraph.size.width,
          greaterThanOrEqualTo(
            paragraph.getMaxIntrinsicWidth(double.infinity) - 0.5,
          ),
          reason: '"$text" is clipped',
        );
        expect(
          find.bySemanticsLabel('Page ${i + 1} of $pageCount'),
          findsOneWidget,
        );
      }
      // All cards make the same choice.
      expect(labels.length, 1);
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
    cases: [...largeDisplayCases, ...layoutMatrix],
  );

  testLayoutMatrix(
    'the export label is shown whole',
    (tester, layoutCase) async {
      await pumpHome(tester, layoutCase, pageCount: 12);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text('Share PDF'),
      );
      // "Share PDF" on at most the lines the button shows, never cut by an
      // ellipsis; the page count is in its semantics value.
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(findShareButton(12), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    // At 2.0× on 320 and 308 px wide phones the square test font fits
    // fewer than five glyphs on a line, so even "Share" wraps; Roboto fits
    // "Share" and "PDF" on the two lines there.
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
        // Tall screens wrap the hint over two lines, taller ones over three.
        // The test font is about twice as wide as Roboto, so at 2.0× it can
        // need more.
        expect(
          !hint.didExceedMaxLines ||
              hint.maxLines == (layoutCase.size.height < 600 ? 2 : 3),
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
