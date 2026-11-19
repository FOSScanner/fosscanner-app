import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';

import '../support/layout_stability.dart';

class _Picker extends ImagePickerPlatform {
  _Picker({required this.camera});

  final bool camera;

  @override
  bool supportsImageSource(ImageSource source) =>
      camera || source != ImageSource.camera;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

/// The phone landscape sizes QA used, at the default and an enlarged scale.
const _landscapeCases = [
  LayoutCase(Size(844, 390), 1.0),
  LayoutCase(Size(844, 390), 1.3),
];

/// Large text and high display density (a 560 dpi phone at 2.0×).
const _largeDisplayCases = [
  LayoutCase(Size(320, 568), 2.0),
  LayoutCase(Size(390, 844), 2.0),
  LayoutCase(Size(412, 915), 2.0),
];

Finder _card(int index) => find.ancestor(
  of: find.byKey(ValueKey('page_thumbnail_$index')),
  matching: find.byType(Card),
);

void main() {
  late ImagePickerPlatform originalPicker;
  late Uint8List imageBytes;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
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
    bool camera = true,
  }) async {
    ImagePickerPlatform.instance = _Picker(camera: camera);
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

  /// Indexes of the cards in the first row.
  List<int> firstRow(WidgetTester tester, int pageCount) {
    final top = tester.getRect(_card(0)).top;
    return [
      for (var i = 0; i < pageCount; i++)
        if (_card(i).evaluate().isNotEmpty &&
            (tester.getRect(_card(i)).top - top).abs() < 0.5)
          i,
    ];
  }

  void expectInside(Rect inner, Rect outer, String reason) {
    expect(inner.top, greaterThanOrEqualTo(outer.top - 0.5), reason: reason);
    expect(inner.left, greaterThanOrEqualTo(outer.left - 0.5), reason: reason);
    expect(inner.bottom, lessThanOrEqualTo(outer.bottom + 0.5), reason: reason);
    expect(inner.right, lessThanOrEqualTo(outer.right + 0.5), reason: reason);
  }

  // #159
  for (final camera in [true, false]) {
    testLayoutMatrix(
      'a whole row of cards is visible and clear of the camera button '
      '(camera: $camera)',
      (tester, layoutCase) async {
        const pageCount = 9;
        await pumpHome(
          tester,
          layoutCase,
          pageCount: pageCount,
          camera: camera,
        );
        final grid = tester.getRect(find.byType(GridView));
        final row = firstRow(tester, pageCount);
        expect(row, isNotEmpty);
        for (final index in row) {
          final page = 'page ${index + 1}';
          expectInside(tester.getRect(_card(index)), grid, '$page card');
          if (!camera) continue;
          final cameraButton = tester.getRect(
            find.byType(FloatingActionButton),
          );
          for (final control in ['Delete $page', 'Reorder $page']) {
            expect(
              tester.getRect(find.byTooltip(control)).overlaps(cameraButton),
              isFalse,
              reason: '$control is under the camera button',
            );
          }
        }
        expect(tester.takeException(), isNull);
      },
      cases: [...layoutMatrix, ..._landscapeCases],
    );
  }

  testLayoutMatrix(
    'landscape cards are shortened rather than cut off',
    (tester, layoutCase) async {
      await pumpHome(tester, layoutCase, pageCount: 2);
      final card = tester.getSize(_card(0));
      // Portrait-shaped cards would not fit in a landscape phone's grid.
      expect(card.height, lessThan(card.width / 0.7));
      expect(tester.takeException(), isNull);
    },
    cases: [
      ..._landscapeCases,
      for (final scale in layoutTextScales)
        LayoutCase(const Size(640, 300), scale),
    ],
  );

  // #160
  testLayoutMatrix('page labels stay on one line', (tester, layoutCase) async {
    await pumpHome(tester, layoutCase, pageCount: 12);
    // Material 3 labelLarge: 14 px on a 20 px line.
    final lineHeight = layoutCase.textScale * 20;
    for (final index in [0, 1, 9, 10, 11]) {
      final label = find.text('Page ${index + 1}');
      await tester.scrollUntilVisible(label, 100);
      final paragraph = tester.renderObject<RenderParagraph>(label);
      expect(paragraph.size.height, lessThan(lineHeight * 1.5));
      expect(paragraph.didExceedMaxLines, isFalse);
    }
    expect(tester.takeException(), isNull);
  }, cases: [..._largeDisplayCases, ...layoutMatrix]);

  testLayoutMatrix('the dragged copy of a card has the card\'s size', (
    tester,
    layoutCase,
  ) async {
    await pumpHome(tester, layoutCase, pageCount: 2);
    final card = tester.getSize(_card(0));
    final gesture = await tester.startGesture(
      tester.getRect(_card(0)).topCenter + const Offset(0, 16),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    final feedback = find.byKey(const Key('page_drag_feedback'));
    expect(tester.getSize(feedback), card);
    // The copy shows the same one-line label as the card.
    expect(
      find.descendant(of: feedback, matching: find.text('Page 1')),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, cases: _largeDisplayCases);

  testLayoutMatrix(
    'the camera button never covers card controls at rest',
    (tester, layoutCase) async {
      for (final pageCount in [2, 7]) {
        await pumpHome(tester, layoutCase, pageCount: pageCount);
        // At rest at the end of the grid, where the last row's controls are.
        await tester.drag(find.byType(GridView), const Offset(0, -10000));
        await tester.pumpAndSettle();
        final cameraButton = tester.getRect(find.byType(FloatingActionButton));
        for (var i = 0; i < pageCount; i++) {
          final delete = find.byTooltip('Delete page ${i + 1}');
          if (delete.evaluate().isEmpty) continue;
          expect(
            tester.getRect(delete).overlaps(cameraButton),
            isFalse,
            reason: 'Delete page ${i + 1} of $pageCount',
          );
        }
      }
      expect(tester.takeException(), isNull);
    },
    cases: [..._largeDisplayCases, ...layoutMatrix],
  );
}
