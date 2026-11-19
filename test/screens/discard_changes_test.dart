import 'dart:async';

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
    PageReviewSource? source = PageReviewSource.camera,
    bool batch = false,
    VoidCallback? onStopImport,
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
              batchPosition: batch ? 1 : null,
              batchCount: batch ? 3 : null,
              onStopImport: onStopImport,
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

  Finder dialog() => find.text('Discard changes?');

  testWidgets('Back without changes leaves at once', (tester) async {
    final result = await openEditor(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(dialog(), findsNothing);
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

    expect(dialog(), findsNothing);
    expect(find.byType(CornerAdjustScreen), findsNothing);
    expect(await result, isNull);
  });

  testWidgets('a moved corner asks before leaving; Keep editing keeps it', (
    tester,
  ) async {
    final result = await openEditor(tester);
    await dragTopLeft(tester);
    final edited = tester
        .widget<CornerOverlay>(find.byType(CornerOverlay))
        .corners;
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
    expect(
      tester.widget<CornerOverlay>(find.byType(CornerOverlay)).corners,
      edited,
    );

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

  testWidgets('discarding a batch image with Back still stops the import', (
    tester,
  ) async {
    var stops = 0;
    await openEditor(
      tester,
      source: PageReviewSource.gallery,
      batch: true,
      onStopImport: () => stops++,
    );
    await dragTopLeft(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(dialog(), findsOneWidget);
    expect(stops, 0);

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(stops, 1);
    expect(find.byType(CornerAdjustScreen), findsNothing);
  });

  testWidgets('explicit Retake does not ask', (tester) async {
    var retakes = 0;
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(
            MaterialPageRoute<ScannedPage>(
              builder: (_) => CornerAdjustScreen(
                originalBytes: bytes,
                source: PageReviewSource.camera,
                onRetake: () => retakes++,
                operations: _Operations(bytes),
              ),
            ),
          ),
    );
    await tester.pumpAndSettle();
    await dragTopLeft(tester);
    await tester.tap(find.text('Retake'));
    await tester.pumpAndSettle();

    expect(dialog(), findsNothing);
    expect(retakes, 1);
    expect(find.byType(CornerAdjustScreen), findsNothing);
  });
}
