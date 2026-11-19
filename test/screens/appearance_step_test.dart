import 'dart:async';

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

void main() {
  late Uint8List bytes;

  setUp(() async {
    final data = await rootBundle.load('assets/icon/icon.png');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  testLayoutMatrix(
    'a batch image keeps "Image N of M" in place on both steps',
    (tester, layoutCase) async {
      // Pushed like the real review, so both steps show Back.
      await tester.pumpWidget(
        MaterialApp(
          builder: withTextScale(layoutCase.textScale),
          home: const Scaffold(),
        ),
      );
      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator))
            .push(
              MaterialPageRoute<ScannedPage>(
                builder: (_) => CornerAdjustScreen(
                  originalBytes: bytes,
                  source: PageReviewSource.gallery,
                  isBatchImport: true,
                  batchPosition: 2,
                  batchCount: 3,
                  onStopImport: () {},
                  operations: _Operations(bytes),
                ),
              ),
            ),
      );
      await tester.pumpAndSettle();
      final title = find.byKey(const Key('batch_progress'));
      expect(find.text('Image 2 of 3'), findsOneWidget);

      final before = tester.getRect(title);
      await tester.tap(find.text('Preview page'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Adjust'), findsOneWidget);
      expect(find.text('Image 2 of 3'), findsOneWidget);
      expect(find.text('Appearance'), findsNothing);
      // Same start and baseline; the appearance step's extra actions may
      // only scale the text down when it does not fit (always, with the
      // square-glyph test font).
      final after = tester.getRect(title);
      expect(after.left, before.left);
      expect(after.center.dy, closeTo(before.center.dy, 0.5));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Image 2 of 3'), findsOneWidget);
      expect(find.text('Preview page'), findsOneWidget);
    },
    cases: const [
      LayoutCase(Size(390, 844), 1.0),
      LayoutCase(Size(320, 568), 2.0),
    ],
  );

  for (final sheet in ['Filters', 'Adjust']) {
    testWidgets('the $sheet sheet leaves the preview undimmed', (tester) async {
      // Portrait: side by side, the controls open beside the preview.
      applyLayoutCase(tester, const LayoutCase(Size(390, 844), 1.0));
      await tester.pumpWidget(
        MaterialApp(
          home: CornerAdjustScreen(
            originalBytes: bytes,
            initialCorners: _corners,
            startWithAdjustments: true,
            operations: _Operations(bytes),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final barriersBefore = find.byType(ModalBarrier).evaluate().length;
      await tester.tap(find.byTooltip(sheet));
      await tester.pumpAndSettle();

      final barriers = tester
          .widgetList<ModalBarrier>(find.byType(ModalBarrier))
          .toList();
      expect(barriers.length, greaterThan(barriersBefore));
      for (final barrier in barriers) {
        expect(barrier.color == null || barrier.color!.a == 0, isTrue);
      }
      // Tapping the preview still closes the sheet.
      await tester.tapAt(
        tester
                .getRect(find.byKey(const Key('adjusted_page_preview')))
                .topCenter +
            const Offset(0, 24),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(sheet == 'Filters' ? 'Grayscale' : 'Brightness: 0'),
        findsNothing,
      );
    });
  }
}
