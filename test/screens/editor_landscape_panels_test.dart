import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';

import '../support/layout_stability.dart';

const _corners = [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)];

class _Operations implements CornerAdjustOperations {
  _Operations(this.bytes);

  final Uint8List bytes;

  @override
  Future<Size> decodeSize(Uint8List imageBytes) async => const Size(100, 100);

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async => _corners;

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List imageBytes,
    List<Offset> corners,
  ) async => {for (final filter in PageFilter.values) filter: bytes};

  @override
  Future<Uint8List> buildFinalPreview(
    Uint8List imageBytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async => imageBytes;

  @override
  Future<Uint8List> processForExport(
    Uint8List imageBytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async => bytes;
}

final _landscapeCases = [
  for (final size in const [Size(844, 390), Size(640, 300)])
    for (final scale in layoutTextScales) LayoutCase(size, scale),
];

void main() {
  late Uint8List bytes;

  setUp(() async {
    final data = await rootBundle.load('assets/icon/icon.png');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  /// Opens a new camera capture's appearance step: the tallest set of
  /// actions (Add & scan next above Add page). Completes with the result.
  Future<Future<ScannedPage?>> openAppearance(
    WidgetTester tester,
    LayoutCase layoutCase,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: withTextScale(layoutCase.textScale),
        home: const Scaffold(),
      ),
    );
    final result = tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          MaterialPageRoute<ScannedPage>(
            builder: (_) => CornerAdjustScreen(
              originalBytes: bytes,
              source: PageReviewSource.camera,
              onScanNext: () {},
              onRetake: (_) {},
              operations: _Operations(bytes),
            ),
          ),
        );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
    return result;
  }

  final preview = find.byKey(const Key('adjusted_page_preview'));
  final scanNext = find.widgetWithText(FilledButton, 'Add & scan next');
  final addPage = find.widgetWithText(OutlinedButton, 'Add page');
  final panel = find.byKey(const Key('appearance_side_panel'));

  void expectPreviewAndActionsClear(WidgetTester tester, Size screen) {
    final previewRect = tester.getRect(preview);
    final panelRect = tester.getRect(panel);
    expect(
      (Offset.zero & screen).intersect(previewRect),
      previewRect,
      reason: 'preview is cut off',
    );
    expect(
      previewRect.overlaps(panelRect),
      isFalse,
      reason: 'panel $panelRect covers the preview $previewRect',
    );
    for (final button in [scanNext, addPage]) {
      expect(button.hitTestable(), findsOneWidget);
      final rect = tester.getRect(button);
      expect(rect.overlaps(panelRect), isFalse, reason: '$button is covered');
      expect((Offset.zero & screen).intersect(rect), rect);
    }
  }

  testLayoutMatrix(
    'Filters and Adjust open beside the preview without covering it',
    (tester, layoutCase) async {
      final result = await openAppearance(tester, layoutCase);
      final anchors = {
        'preview': preview,
        'scan next': scanNext,
        'add page': addPage,
      };

      await expectStableRects(tester, anchors, () async {
        await tester.tap(find.byTooltip('Filters'));
        await tester.pumpAndSettle();
      }, reason: 'open Filters');
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(const ValueKey('filter_grayscale')), findsOneWidget);
      expectPreviewAndActionsClear(tester, layoutCase.size);

      await expectStableRects(tester, anchors, () async {
        await tester.ensureVisible(
          find.byKey(const ValueKey('filter_grayscale')),
        );
        await tester.tap(find.byKey(const ValueKey('filter_grayscale')));
        await tester.pumpAndSettle();
      }, reason: 'choose a filter');

      await expectStableRects(tester, anchors, () async {
        await tester.tap(find.byTooltip('Adjust'));
        await tester.pumpAndSettle();
      }, reason: 'switch to Adjust');
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(Slider), findsNWidgets(2));
      expect(find.byKey(const ValueKey('filter_grayscale')), findsNothing);
      expectPreviewAndActionsClear(tester, layoutCase.size);

      // Back closes the panel first, then returns to the crop step.
      await expectStableRects(tester, anchors, () async {
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }, reason: 'Back closes the panel');
      expect(find.byType(Slider), findsNothing);
      expect(find.text('Appearance'), findsOneWidget);

      // Confirming with a panel open completes the review.
      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      await tester.tap(addPage);
      await tester.pumpAndSettle();
      final page = await result;
      expect(page, isNotNull);
      expect(page!.filter, PageFilter.grayscale);
      expect(tester.takeException(), isNull);
    },
    cases: _landscapeCases,
  );

  for (final textScale in const [1.0, 2.0]) {
    testWidgets('an open panel follows the layout when the phone turns '
        '[@${textScale}x]', (tester) async {
      const portrait = LayoutCase(Size(412, 915), 2.0);
      applyLayoutCase(tester, LayoutCase(portrait.size, textScale));
      final result = await openAppearance(
        tester,
        LayoutCase(portrait.size, textScale),
      );
      Future<void> turn(Size size) async {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
      }

      // Adjust opens as a sheet top to bottom.
      await tester.tap(find.byTooltip('Adjust'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.drag(find.byType(Slider).first, const Offset(60, 0));
      await tester.pumpAndSettle();
      final brightness = tester.widget<Slider>(find.byType(Slider).first).value;
      expect(brightness, isNot(0));

      // Side by side, the sheet becomes the side panel, values kept.
      await turn(const Size(915, 412));
      expect(find.byType(BottomSheet), findsNothing);
      expect(panel, findsOneWidget);
      expect(find.byType(Slider), findsNWidgets(2));
      expect(
        tester.widget<Slider>(find.byType(Slider).first).value,
        brightness,
      );
      expectPreviewAndActionsClear(tester, const Size(915, 412));

      // Switch to Filters in the column, then turn back: a Filters sheet.
      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      await turn(portrait.size);
      expect(panel, findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('filter_original')), findsOneWidget);
      expect(find.byType(Slider), findsNothing);

      // And once more: one panel, never a sheet and the column together.
      await turn(const Size(915, 412));
      expect(find.byType(BottomSheet), findsNothing);
      expect(panel, findsOneWidget);
      expect(find.byKey(const ValueKey('filter_original')), findsOneWidget);

      // Back closes the panel, then the page is added with its settings.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(find.text('Appearance'), findsOneWidget);
      await tester.tap(addPage);
      await tester.pumpAndSettle();
      final page = await result;
      expect(page, isNotNull);
      expect(page!.brightness, brightness);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the Close button and a second tap close the panel', (
    tester,
  ) async {
    applyLayoutCase(tester, const LayoutCase(Size(844, 390), 1.0));
    await openAppearance(tester, const LayoutCase(Size(844, 390), 1.0));
    await tester.tap(find.byTooltip('Adjust'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNWidgets(2));
    await tester.tap(find.byTooltip('Adjust'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter_original')), findsNothing);
    expect(find.text('Appearance'), findsOneWidget);
  });

  testWidgets(
    'each panel scrolls on its own and the app bar ignores it (#167)',
    (tester) async {
      const layoutCase = LayoutCase(Size(640, 300), 2.0);
      applyLayoutCase(tester, layoutCase);
      await openAppearance(tester, layoutCase);

      Material appBarMaterial() => tester.widget<Material>(
        find
            .descendant(
              of: find.byType(AppBar),
              matching: find.byType(Material),
            )
            .first,
      );
      final restingAppBar = appBarMaterial();
      ScrollPosition panelPosition(String name) => tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byKey(ValueKey('side_panel_scroll_$name')),
              matching: find.byType(Scrollable),
            ),
          )
          .position;

      await tester.tap(find.byTooltip('Adjust'));
      await tester.pumpAndSettle();
      final adjust = panelPosition('adjust');
      expect(adjust.pixels, 0);
      // Large text does not fit: a scrollbar shows there is more below.
      expect(adjust.maxScrollExtent, greaterThan(0));
      final scrollbar = tester.widget<Scrollbar>(
        find.descendant(of: panel, matching: find.byType(Scrollbar)),
      );
      expect(scrollbar.thumbVisibility, isTrue);

      adjust.jumpTo(adjust.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('Reset adjustments').hitTestable(), findsOneWidget);
      expect(appBarMaterial().color, restingAppBar.color);
      expect(appBarMaterial().elevation, restingAppBar.elevation);

      // Filters opens at its top, not at Adjust's scroll position.
      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      expect(panelPosition('filters').pixels, 0);
      expect(appBarMaterial().color, restingAppBar.color);

      // Back to Adjust, and reopening it, both start at the top again.
      await tester.tap(find.byTooltip('Adjust'));
      await tester.pumpAndSettle();
      expect(panelPosition('adjust').pixels, 0);
      panelPosition('adjust').jumpTo(panelPosition('adjust').maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Adjust'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Adjust'));
      await tester.pumpAndSettle();
      expect(panelPosition('adjust').pixels, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the appearance preview has the crop canvas hairline (#166)', (
    tester,
  ) async {
    applyLayoutCase(tester, const LayoutCase(Size(390, 844), 1.0));
    await openAppearance(tester, const LayoutCase(Size(390, 844), 1.0));
    final image = find.descendant(
      of: find.byKey(const Key('adjusted_page_image')),
      matching: find.byType(RawImage),
    );
    // Real image decoding needs real event-loop turns.
    for (var i = 0; i < 50; i++) {
      if (tester.renderObject<RenderImage>(image).image != null) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump();
    final renderImage = tester.renderObject<RenderImage>(image);
    final decoded = renderImage.image!;
    final imageSize = Size(decoded.width.toDouble(), decoded.height.toDouble());
    final slot = renderImage.size;
    final drawn = Alignment.center.inscribe(
      applyBoxFit(BoxFit.contain, imageSize, slot).destination,
      Offset.zero & slot,
    );
    final border = find.byKey(const Key('adjusted_page_border'));
    expect(tester.getRect(border), tester.getRect(image));
    final context = tester.element(border);
    expect(
      border,
      paints..rect(
        rect: drawn.deflate(0.5),
        color: Theme.of(context).colorScheme.outlineVariant,
        style: PaintingStyle.stroke,
        strokeWidth: 1,
      ),
    );
  });

  testWidgets('portrait still uses bottom sheets', (tester) async {
    applyLayoutCase(tester, const LayoutCase(Size(390, 844), 1.0));
    await openAppearance(tester, const LayoutCase(Size(390, 844), 1.0));
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(panel, findsNothing);
  });
}
