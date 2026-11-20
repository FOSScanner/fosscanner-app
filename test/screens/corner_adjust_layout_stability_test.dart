import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/services/adjustment_scale.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

import '../support/layout_stability.dart';

const _corners = [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)];

/// Final previews complete only when the test says so, so every preview
/// status can be held on screen while rects are measured.
class _Operations implements CornerAdjustOperations {
  _Operations(this.bytes, {this.detection, this.holdFinalPreviews = true});

  final Uint8List bytes;
  final List<Offset>? detection;
  final bool holdFinalPreviews;
  final finalPreviews = <Completer<Uint8List>>[];

  @override
  Future<Size> decodeSize(Uint8List imageBytes) async => const Size(100, 100);

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async => detection;

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
    // The processing queue is serial: a held preview would block crop work.
    if (!holdFinalPreviews) return Future.value(imageBytes);
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

const _reviewCases = [
  LayoutCase(Size(390, 844), 1.0),
  LayoutCase(Size(390, 844), 1.3),
  LayoutCase(Size(360, 740), 1.0),
  LayoutCase(Size(360, 740), 1.3),
];

const _fullImageNotice = 'No page edges detected. Full image selected.';

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
    expect(find.text('Appearance'), findsOneWidget);
    return operations;
  }

  Finder retryButton() => find.ancestor(
    of: find.text('Retry preview'),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  );

  final previewAndConfirm = {
    'preview': find.byKey(const Key('adjusted_page_preview')),
    'confirm': find.widgetWithText(FilledButton, 'Save changes'),
  };

  final adjustSheetControls = {
    'brightness': find.byType(Slider).first,
    'contrast': find.byType(Slider).last,
    'reset': find.widgetWithText(TextButton, 'Reset adjustments'),
  };

  Future<void> openAdjustments(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Adjust'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNWidgets(2));
  }

  /// With the Adjust sheet open, walks ready -> pending -> updating ->
  /// failed -> updating -> ready, asserting that no anchor moves at any
  /// step. The preview and confirm button stay measurable under the sheet.
  Future<void> cyclePreviewStatus(
    WidgetTester tester,
    _Operations operations,
    Map<String, Finder> anchors,
  ) async {
    if (find.byType(Slider).evaluate().isEmpty) await openAdjustments(tester);
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
        await cyclePreviewStatus(tester, operations, {
          ...previewAndConfirm,
          ...adjustSheetControls,
        });
      },
      cases: _phoneCases,
    );

    testLayoutMatrix(
      'landscape side column keeps confirm fixed across preview states',
      (tester, layoutCase) async {
        final operations = await openAppearance(tester, layoutCase);
        expect(find.byKey(const Key('filter_step_controls')), findsOneWidget);
        await cyclePreviewStatus(tester, operations, {
          'confirm': find.widgetWithText(FilledButton, 'Save changes'),
        });
      },
      cases: const [LayoutCase(Size(640, 300), 2.0)],
    );
  });

  group('Adjust sheet (#146)', () {
    testLayoutMatrix('opening and closing Adjust never moves the preview', (
      tester,
      layoutCase,
    ) async {
      final operations = await openAppearance(tester, layoutCase);
      await expectStableRects(tester, previewAndConfirm, () async {
        await openAdjustments(tester);
      }, reason: 'open');
      final slider = tester.widget<Slider>(find.byType(Slider).last);
      final position = contrastToSliderPosition(1.5);
      slider.onChanged!(position);
      slider.onChangeEnd!(position);
      await tester.pump();
      await tester.pump();
      operations.finalPreviews.last.complete(bytes);
      await tester.pumpAndSettle();
      await expectStableRects(tester, previewAndConfirm, () async {
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
      }, reason: 'close');
      await expectStableRects(tester, previewAndConfirm, () async {
        await openAdjustments(tester);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }, reason: 'reopen and Back');
      expect(find.byType(Slider), findsNothing);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Contrast: 1.50×'), findsNothing);
      await openAdjustments(tester);
      expect(find.text('Contrast: 1.50×'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('crop canvas (#150)', () {
    final canvas = find.byType(CornerOverlay);

    testLayoutMatrix(
      'fallback canvas keeps its rect when the notice fades after a drag',
      (tester, layoutCase) async {
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          MaterialApp(
            builder: withTextScale(layoutCase.textScale),
            home: CornerAdjustScreen(
              originalBytes: bytes,
              operations: _Operations(bytes, holdFinalPreviews: false),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(_fullImageNotice), findsOneWidget);
        expect(
          tester
              .getSemantics(find.text(_fullImageNotice))
              .getSemanticsData()
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
        final anchors = {
          'canvas': canvas,
          'preview page': find.widgetWithText(FilledButton, 'Preview page'),
        };
        await expectStableRects(tester, anchors, () async {
          await tester.dragFrom(
            tester.getCenter(find.byKey(const ValueKey('corner-handle-0'))),
            const Offset(30, 30),
          );
          await tester.pumpAndSettle();
        });
        expect(find.text(_fullImageNotice), findsNothing);
        expect(
          tester.widget<CornerOverlay>(canvas).corners.first,
          isNot(Offset.zero),
        );
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
      cases: _reviewCases,
    );

    testLayoutMatrix(
      'the notice does not block a drag that starts beneath it',
      (tester, layoutCase) async {
        await tester.pumpWidget(
          MaterialApp(
            builder: withTextScale(layoutCase.textScale),
            home: CornerAdjustScreen(
              originalBytes: bytes,
              operations: _Operations(bytes, holdFinalPreviews: false),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final notice = tester.getRect(
          find.byKey(const Key('full_image_notice')),
        );
        expect(tester.getRect(canvas).contains(notice.center), isTrue);
        expect(
          find.byKey(const Key('full_image_notice')).hitTestable(),
          findsNothing,
        );
      },
      cases: const [LayoutCase(Size(390, 844), 2.0)],
    );

    testLayoutMatrix('canvas and actions match on batch images 1/3 to 3/3', (
      tester,
      layoutCase,
    ) async {
      var stops = 0;
      Future<void> showImage(int position) async {
        await tester.pumpWidget(
          MaterialApp(
            builder: withTextScale(layoutCase.textScale),
            home: CornerAdjustScreen(
              key: ValueKey(position),
              originalBytes: bytes,
              source: PageReviewSource.gallery,
              isBatchImport: true,
              batchPosition: position,
              batchCount: 3,
              onStopImport: () => stops++,
              operations: _Operations(
                bytes,
                detection: _corners,
                holdFinalPreviews: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Image $position of 3'), findsOneWidget);
        expect(
          find.text(
            'Skip this image only. Any remaining images will still be '
            'reviewed.',
          ),
          findsNothing,
        );
      }

      final anchors = {
        'canvas': canvas,
        'title': find.byKey(const Key('batch_progress')),
        'stop': find.byTooltip('Stop importing'),
        'skip': find.widgetWithText(OutlinedButton, 'Skip image'),
        'preview page': find.widgetWithText(FilledButton, 'Preview page'),
      };
      IconButton stop() => tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.stop_circle_outlined),
      );

      await showImage(1);
      expect(stop().onPressed, isNotNull);
      await expectStableRects(
        tester,
        anchors,
        () => showImage(2),
        reason: '1/3 -> 2/3',
      );
      expect(stop().onPressed, isNotNull);
      await expectStableRects(
        tester,
        anchors,
        () => showImage(3),
        reason: '2/3 -> 3/3',
      );
      // Nothing remains to stop, but the action keeps its place.
      expect(stop().onPressed, isNull);
      expect(stops, 0);
      expect(tester.takeException(), isNull);
    });
  });
}
