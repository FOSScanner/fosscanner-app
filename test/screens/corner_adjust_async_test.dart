import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

const _corners = [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)];

Future<Uint8List> _iconBytes() async {
  final data = await rootBundle.load('assets/icon/icon.png');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Map<PageFilter, Uint8List> _previews(Uint8List bytes) => {
  for (final filter in PageFilter.values) filter: bytes,
};

class _ControlledOperations implements CornerAdjustOperations {
  _ControlledOperations({
    required this.detectResult,
    this.completeFinalImmediately = false,
  });

  final List<Offset>? detectResult;
  final bool completeFinalImmediately;
  final detectStarted = Completer<void>();
  final decodeCompleted = Completer<void>();
  final previewStarted = <Completer<void>>[
    for (var i = 0; i < 4; i++) Completer<void>(),
  ];
  final finalStarted = <Completer<void>>[
    for (var i = 0; i < 4; i++) Completer<void>(),
  ];
  final previewResults = <Completer<Map<PageFilter, Uint8List>>>[];
  final finalResults = <Completer<Uint8List>>[];
  final exportResults = <Completer<Uint8List>>[];
  final previewCorners = <List<Offset>>[];
  var activeWorkers = 0;
  var maxConcurrentWorkers = 0;

  Future<T> _trackWorker<T>(Future<T> future) {
    activeWorkers++;
    if (activeWorkers > maxConcurrentWorkers) {
      maxConcurrentWorkers = activeWorkers;
    }
    return future.whenComplete(() => activeWorkers--);
  }

  @override
  Future<Size> decodeSize(Uint8List imageBytes) async {
    if (!decodeCompleted.isCompleted) decodeCompleted.complete();
    return const Size(100, 100);
  }

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) {
    detectStarted.complete();
    return _trackWorker(Future.value(detectResult));
  }

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List imageBytes,
    List<Offset> corners,
  ) {
    final index = previewResults.length;
    final result = Completer<Map<PageFilter, Uint8List>>();
    previewResults.add(result);
    previewCorners.add(List<Offset>.of(corners));
    previewStarted[index].complete();
    return _trackWorker(result.future);
  }

  @override
  Future<Uint8List> buildFinalPreview(
    Uint8List imageBytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) {
    if (completeFinalImmediately) {
      return _trackWorker(Future.value(imageBytes));
    }
    final index = finalResults.length;
    final result = Completer<Uint8List>();
    finalResults.add(result);
    finalStarted[index].complete();
    return _trackWorker(result.future);
  }

  @override
  Future<Uint8List> processForExport(
    Uint8List imageBytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) {
    final result = Completer<Uint8List>();
    exportResults.add(result);
    return _trackWorker(result.future);
  }
}

Future<void> _waitForPreviewStart(
  WidgetTester tester,
  _ControlledOperations operations,
  int index,
) async {
  await tester.pump();
  await tester.pump();
  expect(operations.previewStarted[index].isCompleted, isTrue);
}

Future<void> _waitForFinalStart(
  WidgetTester tester,
  _ControlledOperations operations,
  int index,
) async {
  await tester.pump();
  await tester.pump();
  expect(operations.finalStarted[index].isCompleted, isTrue);
}

void main() {
  testWidgets('uses injectable corner detection before generating previews', (
    tester,
  ) async {
    final bytes = await _iconBytes();
    final operations = _ControlledOperations(
      detectResult: _corners,
      completeFinalImmediately: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(originalBytes: bytes, operations: operations),
      ),
    );
    await tester.pump();
    expect(operations.detectStarted.isCompleted, isTrue);
    await _waitForPreviewStart(tester, operations, 0);

    expect(
      tester.widget<CornerOverlay>(find.byType(CornerOverlay)).corners,
      _corners,
    );
    operations.previewResults.single.complete(_previews(bytes));
    await tester.pump();
  });

  testWidgets('second preview worker waits for the active preview', (
    tester,
  ) async {
    final bytes = await _iconBytes();
    final operations = _ControlledOperations(
      detectResult: _corners,
      completeFinalImmediately: true,
    );
    const updatedCorners = [
      Offset(10, 10),
      Offset(90, 10),
      Offset(90, 90),
      Offset(10, 90),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(
          originalBytes: bytes,
          initialCorners: _corners,
          operations: operations,
        ),
      ),
    );
    await _waitForPreviewStart(tester, operations, 0);
    tester
        .widget<CornerOverlay>(find.byType(CornerOverlay))
        .onChanged(updatedCorners);
    await tester.pump();
    await tester.pump();

    expect(operations.previewResults, hasLength(1));
    expect(operations.activeWorkers, 1);

    operations.previewResults[0].complete(_previews(bytes));
    await _waitForPreviewStart(tester, operations, 1);

    expect(operations.previewCorners[1], updatedCorners);
    expect(operations.maxConcurrentWorkers, 1);
    operations.previewResults[1].complete(_previews(bytes));
    await tester.pump();
    await tester.pump();
  });

  testWidgets('stale queued preview is skipped in favor of the newest', (
    tester,
  ) async {
    final bytes = await _iconBytes();
    final operations = _ControlledOperations(
      detectResult: _corners,
      completeFinalImmediately: true,
    );
    const staleCorners = [
      Offset(8, 8),
      Offset(92, 8),
      Offset(92, 92),
      Offset(8, 92),
    ];
    const newestCorners = [
      Offset(12, 12),
      Offset(88, 12),
      Offset(88, 88),
      Offset(12, 88),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(
          originalBytes: bytes,
          initialCorners: _corners,
          operations: operations,
        ),
      ),
    );
    await _waitForPreviewStart(tester, operations, 0);
    final overlay = tester.widget<CornerOverlay>(find.byType(CornerOverlay));
    overlay.onChanged(staleCorners);
    await tester.pump();
    await tester.pump();
    tester
        .widget<CornerOverlay>(find.byType(CornerOverlay))
        .onChanged(newestCorners);
    await tester.pump();
    await tester.pump();

    expect(operations.previewResults, hasLength(1));
    operations.previewResults.single.complete(_previews(bytes));
    await _waitForPreviewStart(tester, operations, 1);

    expect(operations.previewResults, hasLength(2));
    expect(operations.previewCorners, [_corners, newestCorners]);
    expect(operations.maxConcurrentWorkers, 1);
    operations.previewResults[1].complete(_previews(bytes));
    await tester.pump();
    await tester.pump();
  });

  testWidgets(
    'confirm skips stale final work and exports after active worker',
    (tester) async {
      final bytes = await _iconBytes();
      final operations = _ControlledOperations(detectResult: _corners);

      await tester.pumpWidget(
        MaterialApp(
          home: CornerAdjustScreen(
            originalBytes: bytes,
            initialCorners: _corners,
            operations: operations,
          ),
        ),
      );
      await _waitForPreviewStart(tester, operations, 0);
      operations.previewResults.single.complete(_previews(bytes));
      await _waitForFinalStart(tester, operations, 0);
      await tester.tap(find.text('Next'));
      await tester.pump();
      await tester.tap(find.text('Gray'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await tester.pump();

      expect(operations.finalResults, hasLength(1));
      expect(operations.exportResults, isEmpty);
      expect(operations.activeWorkers, 1);

      operations.finalResults.single.complete(bytes);
      await tester.pump();
      await tester.pump();

      expect(operations.finalResults, hasLength(1));
      expect(operations.exportResults, hasLength(1));
      expect(operations.activeWorkers, 1);
      expect(operations.maxConcurrentWorkers, 1);

      operations.exportResults.single.complete(bytes);
      await tester.pump();
    },
  );

  testWidgets('a disposed screen cannot overlap work from its replacement', (
    tester,
  ) async {
    final bytes = await _iconBytes();
    final operations = _ControlledOperations(
      detectResult: _corners,
      completeFinalImmediately: true,
    );
    final processingQueue = ImageProcessingQueue();

    Future<void> showEditor() => tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(
          originalBytes: bytes,
          initialCorners: _corners,
          operations: operations,
          processingQueue: processingQueue,
        ),
      ),
    );

    await showEditor();
    await _waitForPreviewStart(tester, operations, 0);
    await tester.pumpWidget(const SizedBox());
    await showEditor();
    await tester.pump();
    await tester.pump();

    expect(
      operations.previewResults,
      hasLength(1),
      reason: 'replacement screens must share the active worker queue',
    );

    operations.previewResults[0].complete(_previews(bytes));
    await _waitForPreviewStart(tester, operations, 1);
    expect(operations.maxConcurrentWorkers, 1);
    operations.previewResults[1].complete(_previews(bytes));
    await tester.pump();
    await tester.pump();
  });

  testWidgets('disposing with pending preview work is safe', (tester) async {
    final bytes = await _iconBytes();
    final operations = _ControlledOperations(detectResult: _corners);

    await tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(
          originalBytes: bytes,
          initialCorners: _corners,
          operations: operations,
        ),
      ),
    );
    await _waitForPreviewStart(tester, operations, 0);
    await tester.pumpWidget(const SizedBox());
    operations.previewResults.single.complete(_previews(bytes));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing with pending final-preview work is safe', (
    tester,
  ) async {
    final bytes = await _iconBytes();
    final operations = _ControlledOperations(detectResult: _corners);

    await tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(
          originalBytes: bytes,
          initialCorners: _corners,
          operations: operations,
        ),
      ),
    );
    await _waitForPreviewStart(tester, operations, 0);
    operations.previewResults.single.complete(_previews(bytes));
    await _waitForFinalStart(tester, operations, 0);
    await tester.pumpWidget(const SizedBox());
    operations.finalResults.single.complete(bytes);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
