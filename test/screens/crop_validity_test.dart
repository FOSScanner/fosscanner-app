import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

import '../support/layout_stability.dart';

const _rect = [Offset(10, 10), Offset(90, 10), Offset(90, 90), Offset(10, 90)];

class _Operations implements CornerAdjustOperations {
  _Operations(this.bytes);

  final Uint8List bytes;
  final previewRequests = <List<Offset>>[];

  @override
  Future<Size> decodeSize(Uint8List imageBytes) async => const Size(100, 100);

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async => _rect;

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List imageBytes,
    List<Offset> corners,
  ) async {
    previewRequests.add(corners);
    return {for (final filter in PageFilter.values) filter: bytes};
  }

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

  Offset toScreen(WidgetTester tester, Offset imagePoint) {
    final image = tester.getRect(
      find.descendant(
        of: find.byType(CornerOverlay),
        matching: find.byType(Image),
      ),
    );
    return image.topLeft + imagePoint * (image.width / 100);
  }

  Future<void> dragCorner(WidgetTester tester, Offset from, Offset to) async {
    final start = toScreen(tester, from);
    final gesture = await tester.startGesture(start);
    // Two moves: past the touch slop, then exactly onto the target.
    await gesture.moveBy(const Offset(20, 20));
    await tester.pump();
    await gesture.moveTo(toScreen(tester, to));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  List<Offset> corners(WidgetTester tester) =>
      tester.widget<CornerOverlay>(find.byType(CornerOverlay)).corners;

  void expectCorners(List<Offset> actual, List<Offset> expected) {
    for (var i = 0; i < 4; i++) {
      expect(
        (actual[i] - expected[i]).distance,
        lessThan(1.5),
        reason: 'corner $i: $actual',
      );
    }
  }

  FilledButton previewButton(WidgetTester tester) => tester
      .widget<FilledButton>(find.widgetWithText(FilledButton, 'Preview page'));

  Future<_Operations> pumpEditor(
    WidgetTester tester, {
    List<Offset>? initialCorners,
    double textScale = 1,
  }) async {
    final operations = _Operations(bytes);
    await tester.pumpWidget(
      MaterialApp(
        builder: withTextScale(textScale),
        home: CornerAdjustScreen(
          originalBytes: bytes,
          source: PageReviewSource.gallery,
          initialCorners: initialCorners,
          operations: operations,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return operations;
  }

  testWidgets('a corner dragged past its neighbour is re-sorted clockwise', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpEditor(tester);

    // Top-left pulled to the right of top-right makes a bow-tie.
    await dragCorner(tester, const Offset(10, 10), const Offset(95, 30));

    expectCorners(corners(tester), const [
      Offset(90, 10),
      Offset(95, 30),
      Offset(90, 90),
      Offset(10, 90),
    ]);
    expect(find.byKey(const Key('crop_problem')), findsNothing);
    expect(previewButton(tester).onPressed, isNotNull);
    // Labels follow positions: the top-left handle is the top-left point.
    final topLeftHandle = tester.getCenter(
      find.byKey(const ValueKey('corner-handle-0')),
    );
    final expectedTopLeft = toScreen(tester, const Offset(90, 10));
    expect((topLeftHandle - expectedTopLeft).distance, lessThan(25));
    expect(
      tester.getSemantics(find.byKey(const ValueKey('corner-handle-0'))),
      matchesSemantics(
        label: 'Top-left corner',
        value: '90, 10 pixels',
        hint: 'Use actions to move this corner',
        customActions: const [
          CustomSemanticsAction(label: 'Move left'),
          CustomSemanticsAction(label: 'Move right'),
          CustomSemanticsAction(label: 'Move up'),
          CustomSemanticsAction(label: 'Move down'),
        ],
      ),
    );
    semantics.dispose();
  });

  for (final textScale in [1.0, 2.0]) {
    testWidgets(
      'a concave crop is explained in place, disables Preview and resets '
      'on double-tap [@${textScale}x]',
      (tester) async {
        final operations = await pumpEditor(tester, textScale: textScale);
        final requestsBefore = operations.previewRequests.length;
        final anchors = {
          'canvas': find.byType(CornerOverlay),
          'cancel': find.widgetWithText(OutlinedButton, 'Cancel'),
          'preview page': find.widgetWithText(FilledButton, 'Preview page'),
        };

        await expectStableRects(tester, anchors, () async {
          await dragCorner(tester, const Offset(90, 90), const Offset(30, 30));
        }, reason: 'valid -> invalid');

        expect(
          find.text(
            'A corner is inside the crop. Double-tap the image to reset.',
          ),
          findsOneWidget,
        );
        expect(find.byType(SnackBar), findsNothing);
        expect(previewButton(tester).onPressed, isNull);
        expect(operations.previewRequests, hasLength(requestsBefore));
        // The pill never blocks a drag on the canvas.
        expect(
          find.byKey(const Key('crop_problem')).hitTestable(),
          findsNothing,
        );

        await expectStableRects(tester, anchors, () async {
          final center = tester.getCenter(find.byType(CornerOverlay));
          await tester.tapAt(center);
          await tester.pump(const Duration(milliseconds: 50));
          await tester.tapAt(center);
          await tester.pumpAndSettle();
        }, reason: 'invalid -> reset');

        expect(corners(tester), _rect);
        expect(find.byKey(const Key('crop_problem')), findsNothing);
        expect(previewButton(tester).onPressed, isNotNull);
        expect(operations.previewRequests.last, _rect);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('collinear corners say the area is too small', (tester) async {
    await pumpEditor(
      tester,
      initialCorners: const [
        Offset(10, 10),
        Offset(50, 10),
        Offset(90, 10),
        Offset(10, 90),
      ],
    );

    expect(
      find.text('Crop is too small. Double-tap the image to reset.'),
      findsOneWidget,
    );
    expect(previewButton(tester).onPressed, isNull);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('screen readers can reset the corners', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpEditor(tester);
    await dragCorner(tester, const Offset(90, 90), const Offset(30, 30));
    expect(find.byKey(const Key('crop_problem')), findsOneWidget);

    final node = tester.getSemantics(
      find
          .descendant(
            of: find.byType(CornerOverlay),
            matching: find.byType(RawGestureDetector),
          )
          .first,
    );
    final reset = node
        .getSemanticsData()
        .customSemanticsActionIds!
        .map(CustomSemanticsAction.getAction)
        .firstWhere((action) => action!.label == 'Reset corners');
    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.customAction,
      CustomSemanticsAction.getIdentifier(reset!),
    );
    await tester.pumpAndSettle();

    expect(corners(tester), _rect);
    expect(find.byKey(const Key('crop_problem')), findsNothing);
    semantics.dispose();
  });
}
