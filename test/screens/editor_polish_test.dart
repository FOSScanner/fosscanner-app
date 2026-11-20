import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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

void main() {
  late Uint8List bytes;

  setUp(() async {
    final data = await rootBundle.load('assets/icon/icon.png');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  Future<void> pumpEditor(
    WidgetTester tester, {
    double textScale = 1.0,
    bool existingPage = true,
    PageReviewSource? source,
    bool batch = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: withTextScale(textScale),
        home: CornerAdjustScreen(
          originalBytes: bytes,
          source: source,
          isBatchImport: batch,
          batchPosition: batch ? 1 : null,
          batchCount: batch ? 3 : null,
          onStopImport: batch ? () {} : null,
          initialCorners: existingPage ? _corners : null,
          operations: _Operations(bytes),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openFilters(WidgetTester tester) async {
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
  }

  testLayoutMatrix(
    'selecting a filter never resizes or moves the filter tiles',
    (tester, layoutCase) async {
      await pumpEditor(tester, textScale: layoutCase.textScale);
      await openFilters(tester);
      final tiles = {
        for (final filter in PageFilter.values)
          filter.name: find.byKey(ValueKey('filter_${filter.name}')),
      };
      for (final filter in PageFilter.values.reversed) {
        await expectStableRects(tester, tiles, () async {
          await tester.tap(tiles[filter.name]!);
          await tester.pumpAndSettle();
        }, reason: 'select ${filter.name}');
      }
      expect(tester.takeException(), isNull);
    },
    cases: const [
      LayoutCase(Size(390, 844), 1.0),
      LayoutCase(Size(390, 844), 2.0),
      LayoutCase(Size(320, 568), 2.0),
    ],
  );

  testLayoutMatrix(
    'crop actions keep one line and one height at any text size',
    (tester, layoutCase) async {
      await pumpEditor(tester, textScale: layoutCase.textScale);
      final cancel = find.widgetWithText(OutlinedButton, 'Cancel');
      final preview = find.widgetWithText(FilledButton, 'Preview page');
      expect(tester.getSize(cancel).height, tester.getSize(preview).height);
      for (final label in ['Cancel', 'Preview page']) {
        final text = tester.widget<Text>(find.text(label));
        expect(text.maxLines, 1, reason: label);
        expect(text.softWrap, isFalse, reason: label);
      }
      expect(tester.takeException(), isNull);
    },
    cases: [
      for (final size in const [Size(390, 844), Size(320, 568)])
        for (final scale in layoutTextScales) LayoutCase(size, scale),
    ],
  );

  testWidgets('PDF pages are called pages, images are called images', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      existingPage: false,
      source: PageReviewSource.pdf,
      batch: true,
    );
    expect(find.text('Page 1 of 3'), findsOneWidget);
    expect(find.text('Skip page'), findsOneWidget);
    expect(find.textContaining('mage'), findsNothing);

    await pumpEditor(
      tester,
      existingPage: false,
      source: PageReviewSource.gallery,
      batch: true,
    );
    expect(find.text('Image 1 of 3'), findsOneWidget);
    expect(find.text('Skip image'), findsOneWidget);
  });

  testWidgets('filter tiles and sliders are read once', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpEditor(tester);
    await openFilters(tester);

    final grayscale = tester
        .getSemantics(find.byKey(const ValueKey('filter_grayscale')))
        .getSemanticsData();
    expect(grayscale.label, 'Grayscale filter');
    expect(grayscale.hasAction(SemanticsAction.tap), isTrue);
    expect(find.bySemanticsLabel('Grayscale'), findsNothing);
    tester.semantics.tap(find.semantics.byLabel('Grayscale filter'));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('filter_grayscale')))
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Adjust'));
    await tester.pumpAndSettle();
    expect(find.text('Brightness: 0'), findsOneWidget);
    // The caption is shown, but only the slider speaks.
    expect(find.bySemanticsLabel(RegExp('Brightness:')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Contrast:')), findsNothing);
    expect(find.bySemanticsLabel('Brightness'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('corner handles are named without pixel coordinates', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpEditor(tester);
    for (var i = 0; i < 4; i++) {
      final data = tester
          .getSemantics(find.byKey(ValueKey('corner-handle-$i')))
          .getSemanticsData();
      expect(data.label, endsWith('corner'));
      expect(data.value, isEmpty);
      expect(data.label, isNot(contains('pixels')));
    }
    semantics.dispose();
  });
}
