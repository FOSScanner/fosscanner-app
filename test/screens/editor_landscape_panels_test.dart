import 'package:flutter/material.dart';
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
              onRetake: () {},
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

  testWidgets('portrait still uses bottom sheets', (tester) async {
    applyLayoutCase(tester, const LayoutCase(Size(390, 844), 1.0));
    await openAppearance(tester, const LayoutCase(Size(390, 844), 1.0));
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(panel, findsNothing);
  });
}
