import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/services/gesture_exclusion.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

const _screen = Size(400, 800);
const _insets = EdgeInsets.only(left: 30, right: 30, bottom: 40);

class _Operations implements CornerAdjustOperations {
  _Operations(this.bytes);

  final Uint8List bytes;

  @override
  Future<Size> decodeSize(Uint8List imageBytes) async => const Size(100, 100);

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async => null;

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

List<Rect> _decode(List<int> values) => [
  for (var i = 0; i < values.length; i += 4)
    Rect.fromLTRB(
      values[i].toDouble(),
      values[i + 1].toDouble(),
      values[i + 2].toDouble(),
      values[i + 3].toDouble(),
    ),
];

void main() {
  group('gestureExclusionRects', () {
    test('regions away from the edges exclude nothing', () {
      expect(
        gestureExclusionRects(
          const [Rect.fromLTWH(100, 100, 48, 48)],
          screen: _screen,
          gestureInsets: _insets,
        ),
        isEmpty,
      );
    });

    test('only the overlap with each edge zone is excluded', () {
      expect(
        gestureExclusionRects(
          const [
            Rect.fromLTWH(8, 100, 48, 48),
            Rect.fromLTWH(360, 300, 48, 48),
            Rect.fromLTWH(16, 500, 368, 48),
          ],
          screen: _screen,
          gestureInsets: _insets,
        ),
        const [
          Rect.fromLTRB(8, 100, 30, 148),
          Rect.fromLTRB(16, 500, 30, 548),
          Rect.fromLTRB(370, 300, 400, 348),
          Rect.fromLTRB(370, 500, 384, 548),
        ],
      );
    });

    test('without gesture navigation nothing is excluded', () {
      expect(
        gestureExclusionRects(
          const [Rect.fromLTWH(0, 100, 48, 48)],
          screen: _screen,
          gestureInsets: EdgeInsets.zero,
        ),
        isEmpty,
      );
    });

    test('each edge is capped at Android\'s limit, in order', () {
      final rects = gestureExclusionRects(
        [for (var i = 0; i < 5; i++) Rect.fromLTWH(0, i * 100.0, 20, 60)],
        screen: _screen,
        gestureInsets: _insets,
      );
      expect(rects, const [
        Rect.fromLTWH(0, 0, 20, 60),
        Rect.fromLTWH(0, 100, 20, 60),
        Rect.fromLTWH(0, 200, 20, 60),
        Rect.fromLTWH(0, 300, 20, 20),
      ]);
      final total = rects.fold<double>(0, (sum, rect) => sum + rect.height);
      expect(total, maxGestureExclusionPerEdge);
    });
  });

  group('GestureExclusionRegion', () {
    late List<List<Rect>> sent;
    late Uint8List bytes;

    setUp(() async {
      sent = [];
      GestureExclusionRegistry.instance
        ..resetForTesting()
        ..sendOverride = (values) async => sent.add(_decode(values));
      final data = await rootBundle.load('assets/icon/icon.png');
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    });

    tearDown(() {
      GestureExclusionRegistry.instance
        ..sendOverride = null
        ..resetForTesting();
    });

    void useGestureNavigation(WidgetTester tester, Size size) {
      tester.view
        ..physicalSize = size * 2
        ..devicePixelRatio = 2
        ..systemGestureInsets = const FakeViewPadding(
          left: 60,
          right: 60,
          bottom: 80,
        );
      addTearDown(tester.view.reset);
    }

    testWidgets('handles at the screen edge are excluded from Back', (
      tester,
    ) async {
      useGestureNavigation(tester, _screen);
      await tester.pumpWidget(
        MaterialApp(
          home: CornerOverlay(
            imageBytes: bytes,
            imageSize: const Size(100, 100),
            corners: const [
              Offset.zero,
              Offset(99, 0),
              Offset(99, 99),
              Offset(0, 99),
            ],
            onChanged: (_) {},
          ),
        ),
      );
      await tester.pump();

      // Physical pixels: each 48 dp handle target clipped to the 30 dp zone.
      final rects = sent.last;
      expect(rects, hasLength(4));
      for (final rect in rects) {
        expect(rect.height, closeTo(96, 1));
        expect(rect.width, lessThanOrEqualTo(60));
        expect(rect.left == 0 || rect.left == 740, isTrue, reason: '$rect');
      }

      // Unmounting clears the exclusion so Back works everywhere again.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(sent.last, isEmpty);
    });

    for (final size in const [Size(390, 844), Size(844, 390)]) {
      testWidgets('editor handles stay out of the gesture zones [$size]', (
        tester,
      ) async {
        useGestureNavigation(tester, size);
        await tester.pumpWidget(
          MaterialApp(
            home: CornerAdjustScreen(
              originalBytes: bytes,
              operations: _Operations(bytes),
            ),
          ),
        );
        await tester.pumpAndSettle();

        for (var i = 0; i < 4; i++) {
          final handle = tester.getRect(
            find.byKey(ValueKey('corner-handle-$i')),
          );
          expect(handle.left, greaterThanOrEqualTo(30), reason: 'handle $i');
          expect(
            handle.right,
            lessThanOrEqualTo(size.width - 30),
            reason: 'handle $i',
          );
          if (size.width > size.height) {
            expect(
              handle.bottom,
              lessThanOrEqualTo(size.height - 40),
              reason: 'handle $i above the Home gesture zone',
            );
          }
        }
        // Inset handles need no exclusion at all.
        expect(sent.isEmpty || sent.last.isEmpty, isTrue);
      });
    }

    testWidgets('Adjust sliders are excluded from Back on both edges', (
      tester,
    ) async {
      useGestureNavigation(tester, const Size(390, 844));
      await tester.pumpWidget(
        MaterialApp(
          home: CornerAdjustScreen(
            originalBytes: bytes,
            initialCorners: const [
              Offset(5, 5),
              Offset(95, 5),
              Offset(95, 95),
              Offset(5, 95),
            ],
            startWithAdjustments: true,
            operations: _Operations(bytes),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Adjust'));
      await tester.pumpAndSettle();

      final sliders = [
        for (final element in find.byType(Slider).evaluate())
          tester.getRect(find.byWidget(element.widget)),
      ];
      expect(sliders, hasLength(2));
      final rects = sent.last;
      for (final slider in sliders) {
        final top = slider.top * 2;
        expect(
          rects.where((rect) => rect.left < 60 && rect.top == top.floor()),
          hasLength(1),
        );
        expect(
          rects.where((rect) => rect.right > 720 && rect.top == top.floor()),
          hasLength(1),
        );
      }

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(sent.last, isEmpty);
    });
  });
}
