import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';

import '../support/layout_stability.dart';

const _corners = [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)];

/// Final previews complete only when the test says so, so every preview
/// status can be held on screen while rects are measured.
class _Operations implements CornerAdjustOperations {
  _Operations(this.bytes);

  final Uint8List bytes;
  final finalPreviews = <Completer<Uint8List>>[];

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
  }) {
    final completer = Completer<Uint8List>();
    finalPreviews.add(completer);
    return completer.future;
  }

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

const _phoneCases = [
  LayoutCase(Size(390, 844), 1.0),
  LayoutCase(Size(390, 844), 1.3),
  LayoutCase(Size(320, 568), 1.0),
  LayoutCase(Size(320, 568), 1.3),
];

void main() {
  late Uint8List bytes;

  setUp(() async {
    final data = await rootBundle.load('assets/icon/icon.png');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  Future<void> pumpWork(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<_Operations> openAppearance(
    WidgetTester tester,
    LayoutCase layoutCase,
  ) async {
    final operations = _Operations(bytes);
    await tester.pumpWidget(
      MaterialApp(
        builder: withTextScale(layoutCase.textScale),
        home: CornerAdjustScreen(
          originalBytes: bytes,
          initialCorners: _corners,
          operations: operations,
        ),
      ),
    );
    await tester.pumpAndSettle();
    operations.finalPreviews.single.complete(bytes);
    await tester.ensureVisible(find.text('Preview page'));
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    expect(find.text('Adjust appearance'), findsOneWidget);
    return operations;
  }

  Finder retryButton() => find.ancestor(
    of: find.text('Retry preview'),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  );

  Map<String, Finder> appearanceAnchors({bool includeAdjustments = true}) => {
    'preview': find.byKey(const Key('adjusted_page_preview')),
    if (includeAdjustments) ...{
      'brightness': find.byType(Slider).first,
      'contrast': find.byType(Slider).last,
      'reset': find.widgetWithText(TextButton, 'Reset adjustments'),
    },
    'confirm': find.widgetWithText(FilledButton, 'Save changes'),
  };

  /// Walks ready -> pending -> updating -> failed -> updating -> ready,
  /// asserting that no anchor moves at any step.
  Future<void> cyclePreviewStatus(
    WidgetTester tester,
    _Operations operations,
    Map<String, Finder> anchors,
  ) async {
    Slider slider() => tester.widget<Slider>(find.byType(Slider).first);
    await expectStableRects(tester, anchors, () async {
      slider().onChanged!(35);
      await tester.pump();
    }, reason: 'ready -> pending');
    await expectStableRects(tester, anchors, () async {
      slider().onChangeEnd!(35);
      await pumpWork(tester);
    }, reason: 'pending -> updating');
    expect(find.text('Updating preview…'), findsOneWidget);
    await expectStableRects(tester, anchors, () async {
      operations.finalPreviews.last.completeError(StateError('failed'));
      await tester.pumpAndSettle();
    }, reason: 'updating -> failed');
    expect(find.text('Retry preview'), findsOneWidget);
    await expectStableRects(tester, anchors, () async {
      tester.widget<ButtonStyleButton>(retryButton()).onPressed!();
      await pumpWork(tester);
    }, reason: 'failed -> updating');
    await expectStableRects(tester, anchors, () async {
      operations.finalPreviews.last.complete(bytes);
      await tester.pumpAndSettle();
    }, reason: 'updating -> ready');
    expect(find.text('Retry preview'), findsNothing);
    expect(tester.takeException(), isNull);
  }

  group('appearance preview status (#148)', () {
    testLayoutMatrix(
      'preview, adjustments and confirm stay fixed across preview states',
      (tester, layoutCase) async {
        final operations = await openAppearance(tester, layoutCase);
        await cyclePreviewStatus(tester, operations, appearanceAnchors());
      },
      cases: _phoneCases,
    );

    testLayoutMatrix(
      'scrollable layout keeps confirm fixed across preview states',
      (tester, layoutCase) async {
        final operations = await openAppearance(tester, layoutCase);
        expect(
          find.byKey(const Key('filter_step_scroll_view')),
          findsOneWidget,
        );
        await cyclePreviewStatus(tester, operations, {
          'confirm': find.widgetWithText(FilledButton, 'Save changes'),
        });
      },
      cases: const [LayoutCase(Size(640, 300), 2.0)],
    );
  });
}
