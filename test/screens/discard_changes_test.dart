import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

import '../support/layout_stability.dart';

const _corners = [
  Offset(10, 10),
  Offset(90, 10),
  Offset(90, 90),
  Offset(10, 90),
];

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

  /// Pushes the editor like the home screen does; completes with its result.
  Future<Future<ScannedPage?>> openEditor(
    WidgetTester tester, {
    bool existingPage = false,
    PageReviewSource? source = PageReviewSource.gallery,
    bool batch = false,
    int batchPosition = 1,
    VoidCallback? onStopImport,
    ValueChanged<PageReviewState>? onRetake,
    PageReviewState? restoredReview,
  }) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final result = tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          MaterialPageRoute<ScannedPage>(
            builder: (_) => CornerAdjustScreen(
              originalBytes: bytes,
              source: existingPage ? null : source,
              isBatchImport: batch,
              batchPosition: batch ? batchPosition : null,
              batchCount: batch ? 3 : null,
              onStopImport: onStopImport,
              onRetake: onRetake,
              restoredReview: restoredReview,
              initialCorners: existingPage ? _corners : null,
              startWithAdjustments: existingPage,
              operations: _Operations(bytes),
            ),
          ),
        );
    await tester.pumpAndSettle();
    return result;
  }

  Future<void> dragTopLeft(WidgetTester tester) async {
    await tester.dragFrom(
      tester.getCenter(find.byKey(const ValueKey('corner-handle-0'))),
      const Offset(20, 20),
    );
    await tester.pumpAndSettle();
  }

  List<Offset> overlayCorners(WidgetTester tester) =>
      tester.widget<CornerOverlay>(find.byType(CornerOverlay)).corners;

  Finder dialog() => find.text('Discard changes?');

  testWidgets('Back without changes leaves at once', (tester) async {
    final result = await openEditor(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(CornerAdjustScreen), findsNothing);
    expect(await result, isNull);
  });

  testWidgets('Back after visiting appearance without changes leaves at once', (
    tester,
  ) async {
    final result = await openEditor(tester, existingPage: true);
    expect(find.text('Appearance'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Edit page'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(CornerAdjustScreen), findsNothing);
    expect(await result, isNull);
  });

  testWidgets('a moved corner asks before leaving; Keep editing keeps it', (
    tester,
  ) async {
    final result = await openEditor(tester);
    await dragTopLeft(tester);
    final edited = overlayCorners(tester);
    expect(edited, isNot(_corners));

    final anchors = {
      'canvas': find.byType(CornerOverlay),
      'cancel': find.widgetWithText(OutlinedButton, 'Cancel'),
      'preview page': find.widgetWithText(FilledButton, 'Preview page'),
    };
    await expectStableRects(tester, anchors, () async {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }, reason: 'dialog opens');
    expect(dialog(), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);

    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(dialog(), findsNothing);
    expect(find.byType(CornerAdjustScreen), findsOneWidget);
    expect(overlayCorners(tester), edited);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(dialog(), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(CornerAdjustScreen), findsNothing);
    expect(await result, isNull);
  });

  testWidgets('appearance edits on an existing page ask before leaving', (
    tester,
  ) async {
    final result = await openEditor(tester, existingPage: true);
    await tester.tap(find.byTooltip('Rotate clockwise'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Rotate clockwise'));
    await tester.pumpAndSettle();

    // Back returns to the crop step without asking: nothing is lost yet.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(dialog(), findsNothing);
    expect(find.text('Edit page'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(dialog(), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(CornerAdjustScreen), findsNothing);
    expect(await result, isNull);
  });

  group('Cancel follows the same rule as Back (#161)', () {
    testWidgets('without changes it leaves at once', (tester) async {
      final result = await openEditor(tester, existingPage: true);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(await result, isNull);
    });

    testWidgets('with changes it asks first', (tester) async {
      final result = await openEditor(tester, existingPage: true);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await dragTopLeft(tester);
      final edited = overlayCorners(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(dialog(), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Edit page'), findsOneWidget);
      expect(overlayCorners(tester), edited);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(await result, isNull);
    });
  });

  group('a fresh camera capture is unsaved work (#161)', () {
    testWidgets('Back asks "Discard this scan?" even without edits', (
      tester,
    ) async {
      final result = await openEditor(
        tester,
        source: PageReviewSource.camera,
        onRetake: (_) {},
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard this scan?'), findsOneWidget);
      expect(dialog(), findsNothing);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(CornerAdjustScreen), findsOneWidget);

      // Edits do not add a second question.
      await dragTopLeft(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Discard this scan?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(await result, isNull);
    });

    testWidgets('Cancel without Retake asks the same', (tester) async {
      await openEditor(tester, source: PageReviewSource.camera);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard this scan?'), findsOneWidget);
    });
  });

  group('Back in a batch asks once (#161)', () {
    const body =
        'This image and the remaining ones will not be added. '
        'Pages already added are kept.';

    testWidgets('an unedited image asks "Stop importing?"', (tester) async {
      var stops = 0;
      await openEditor(tester, batch: true, onStopImport: () => stops++);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Stop importing?'), findsOneWidget);
      expect(find.text(body), findsOneWidget);

      await tester.tap(find.text('Keep reviewing'));
      await tester.pumpAndSettle();
      expect(stops, 0);
      expect(find.byType(CornerAdjustScreen), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(stops, 1);
      expect(find.byType(CornerAdjustScreen), findsNothing);
    });

    testWidgets('an edited image asks a single question that covers both', (
      tester,
    ) async {
      var stops = 0;
      await openEditor(tester, batch: true, onStopImport: () => stops++);
      await dragTopLeft(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Stop importing?'), findsOneWidget);
      expect(find.text('Your changes are discarded. $body'), findsOneWidget);
      expect(dialog(), findsNothing);

      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(stops, 1);
      expect(find.byType(CornerAdjustScreen), findsNothing);
    });

    testWidgets('PDF pages are called pages', (tester) async {
      await openEditor(
        tester,
        source: PageReviewSource.pdf,
        batch: true,
        onStopImport: () {},
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This page and the remaining ones will not be added. '
          'Pages already added are kept.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the last image has nothing left to stop', (tester) async {
      var stops = 0;
      final result = await openEditor(
        tester,
        batch: true,
        batchPosition: 3,
        onStopImport: () => stops++,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(stops, 0);
      expect(await result, isNull);
    });

    testWidgets('Skip image never asks', (tester) async {
      var stops = 0;
      await openEditor(tester, batch: true, onStopImport: () => stops++);
      await dragTopLeft(tester);
      await tester.tap(find.text('Skip image'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(stops, 0);
      expect(find.byType(CornerAdjustScreen), findsNothing);
    });
  });

  group('Retake (#161)', () {
    testWidgets('does not ask and hands over the crop and settings', (
      tester,
    ) async {
      final states = <PageReviewState>[];
      await openEditor(
        tester,
        source: PageReviewSource.camera,
        onRetake: states.add,
      );
      await dragTopLeft(tester);
      final edited = overlayCorners(tester);
      await tester.tap(find.text('Preview page'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Rotate clockwise'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retake'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(CornerAdjustScreen), findsNothing);
      final state = states.single;
      expect(state.corners, edited);
      expect(state.startCorners, _corners);
      expect(state.rotationQuarterTurns, 1);
    });

    testWidgets('a restored review reopens with its corners and settings', (
      tester,
    ) async {
      const edited = [
        Offset(20, 20),
        Offset(90, 10),
        Offset(90, 90),
        Offset(10, 90),
      ];
      await openEditor(
        tester,
        source: PageReviewSource.camera,
        onRetake: (_) {},
        restoredReview: const PageReviewState(
          corners: edited,
          startCorners: _corners,
          filter: PageFilter.grayscale,
          rotationQuarterTurns: 3,
          brightness: 40,
          contrast: 1,
        ),
      );
      expect(overlayCorners(tester), edited);
      expect(
        find.text('No page edges detected. Full image selected.'),
        findsNothing,
      );

      // Double-tap still restores the detected corners.
      final canvas = tester.getCenter(find.byType(CornerOverlay));
      await tester.tapAt(canvas);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(canvas);
      await tester.pumpAndSettle();
      expect(overlayCorners(tester), _corners);

      await tester.tap(find.text('Preview page'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Adjust'));
      await tester.pumpAndSettle();
      expect(find.text('Brightness: +40'), findsOneWidget);
    });
  });
}
