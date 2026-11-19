import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

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

const _landscapeCases = [
  LayoutCase(Size(844, 390), 1.0),
  LayoutCase(Size(844, 390), 1.3),
  LayoutCase(Size(640, 300), 1.0),
  LayoutCase(Size(640, 300), 1.3),
];

void main() {
  late Uint8List bytes;

  setUp(() async {
    final data = await rootBundle.load('assets/icon/icon.png');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  /// Fully on screen and hit-testable without scrolling.
  void expectReachable(WidgetTester tester, Finder button, Size screen) {
    expect(button.hitTestable(), findsOneWidget);
    final rect = tester.getRect(button);
    expect(
      (Offset.zero & screen).intersect(rect).size,
      rect.size,
      reason: '$button is cut off: $rect',
    );
  }

  void expectSingleLine(WidgetTester tester, String label) {
    final text = tester.widget<Text>(find.text(label));
    expect(text.maxLines, 1, reason: label);
    expect(text.softWrap, isFalse, reason: label);
  }

  testLayoutMatrix(
    'camera review keeps its actions beside the canvas and preview',
    (tester, layoutCase) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: withTextScale(layoutCase.textScale),
          home: CornerAdjustScreen(
            originalBytes: bytes,
            source: PageReviewSource.camera,
            onRetake: (_) {},
            onScanNext: () {},
            operations: _Operations(bytes),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final previewPage = find.widgetWithText(FilledButton, 'Preview page');
      final retake = find.widgetWithText(OutlinedButton, 'Retake');
      final canvas = tester.getRect(find.byType(CornerOverlay));
      expectReachable(tester, previewPage, layoutCase.size);
      expectReachable(tester, retake, layoutCase.size);
      expectSingleLine(tester, 'Preview page');
      expectSingleLine(tester, 'Retake');
      expect(tester.getSize(previewPage).height, tester.getSize(retake).height);
      // Side by side: the canvas keeps the full body height.
      expect(canvas.right, lessThanOrEqualTo(tester.getRect(retake).left));
      expect(canvas.width, greaterThan(layoutCase.size.width / 2));

      await tester.tap(previewPage);
      await tester.pumpAndSettle();
      final scanNext = find.widgetWithText(FilledButton, 'Add & scan next');
      final addPage = find.widgetWithText(OutlinedButton, 'Add page');
      expectReachable(tester, scanNext, layoutCase.size);
      expectReachable(tester, addPage, layoutCase.size);
      expectSingleLine(tester, 'Add & scan next');
      final preview = tester.getRect(
        find.byKey(const Key('adjusted_page_preview')),
      );
      expect(preview.right, lessThanOrEqualTo(tester.getRect(addPage).left));
      // The preview has the body to itself vertically, as the canvas did.
      expect(preview.height, closeTo(canvas.height + 16, 1));
      expect(tester.takeException(), isNull);
    },
    cases: _landscapeCases,
  );

  testLayoutMatrix('editing a page keeps Save changes visible', (
    tester,
    layoutCase,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: withTextScale(layoutCase.textScale),
        home: CornerAdjustScreen(
          originalBytes: bytes,
          initialCorners: _corners,
          startWithAdjustments: true,
          operations: _Operations(bytes),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expectReachable(
      tester,
      find.widgetWithText(FilledButton, 'Save changes'),
      layoutCase.size,
    );
    expect(tester.takeException(), isNull);
  }, cases: _landscapeCases);
}
