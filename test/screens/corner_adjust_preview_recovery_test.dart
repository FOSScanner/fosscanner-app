import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';

const _corners = [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)];
const _oldResultMessage =
    'Preview could not be updated. Previous result shown.';

typedef _Request = ({
  Uint8List bytes,
  int rotation,
  double brightness,
  double contrast,
  Completer<Uint8List> result,
});

class _Operations implements CornerAdjustOperations {
  _Operations(this.bytes)
    : filters = {
        for (final filter in PageFilter.values)
          filter: Uint8List.fromList(bytes),
      };

  final Uint8List bytes;
  final Map<PageFilter, Uint8List> filters;
  final requests = <_Request>[];
  final exports =
      <
        ({PageFilter filter, int rotation, double brightness, double contrast})
      >[];
  var activeWorkers = 0;
  var maxActiveWorkers = 0;

  @override
  Future<Size> decodeSize(Uint8List imageBytes) async => const Size(100, 100);

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async => _corners;

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List imageBytes,
    List<Offset> corners,
  ) async => filters;

  @override
  Future<Uint8List> buildFinalPreview(
    Uint8List imageBytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) {
    final result = Completer<Uint8List>();
    requests.add((
      bytes: imageBytes,
      rotation: rotationQuarterTurns,
      brightness: brightness,
      contrast: contrast,
      result: result,
    ));
    activeWorkers++;
    if (activeWorkers > maxActiveWorkers) maxActiveWorkers = activeWorkers;
    return result.future.whenComplete(() => activeWorkers--);
  }

  @override
  Future<Uint8List> processForExport(
    Uint8List imageBytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async {
    exports.add((
      filter: filter,
      rotation: rotationQuarterTurns,
      brightness: brightness,
      contrast: contrast,
    ));
    return bytes;
  }
}

void main() {
  late Uint8List source;
  late Uint8List previous;
  late Uint8List updated;
  late _Operations operations;

  setUp(() async {
    final data = await rootBundle.load('assets/icon/icon.png');
    source = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    previous = Uint8List.fromList(source);
    updated = Uint8List.fromList(source);
    operations = _Operations(source);
  });

  Future<void> pumpWork(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> openPreview(
    WidgetTester tester, {
    bool finishInitial = true,
    double textScale = 1,
    ValueChanged<ScannedPage?>? onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                final result = await Navigator.of(context).push<ScannedPage>(
                  MaterialPageRoute(
                    builder: (_) => CornerAdjustScreen(
                      originalBytes: source,
                      initialCorners: _corners,
                      operations: operations,
                    ),
                  ),
                );
                onResult?.call(result);
              },
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    expect(operations.requests, hasLength(1));
    if (finishInitial) operations.requests.single.result.complete(previous);
    await tester.tap(find.text('Next'));
    if (finishInitial) {
      await tester.pumpAndSettle();
    } else {
      await pumpWork(tester);
    }
  }

  Finder previewImage() => find.descendant(
    of: find.byKey(const Key('adjusted_page_preview')),
    matching: find.byType(Image),
  );

  Uint8List previewBytes(WidgetTester tester) {
    final resize = tester.widget<Image>(previewImage()).image as ResizeImage;
    return (resize.imageProvider as MemoryImage).bytes;
  }

  FilledButton confirm(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'));

  Future<void> change(
    WidgetTester tester,
    String adjustment, {
    bool release = true,
  }) async {
    switch (adjustment) {
      case 'rotation':
        await tester.tap(find.byTooltip('Rotate'));
      case 'filter':
        await tester.tap(find.text('Gray'));
      case 'brightness' || 'contrast':
        final slider = tester.widget<Slider>(
          adjustment == 'brightness'
              ? find.byType(Slider).first
              : find.byType(Slider).last,
        );
        final value = adjustment == 'brightness' ? 35.0 : 1.5;
        slider.onChanged!(value);
        if (release) slider.onChangeEnd!(value);
    }
    await pumpWork(tester);
  }

  testWidgets('first preview failure never falls back to the base filter', (
    tester,
  ) async {
    await openPreview(tester, finishInitial: false);
    expect(previewImage(), findsNothing);
    expect(confirm(tester).onPressed, isNull);
    operations.requests.single.result.completeError(StateError('private path'));
    await tester.pumpAndSettle();

    expect(previewImage(), findsNothing);
    expect(
      find.text('Preview unavailable. Retry to review this page.'),
      findsOneWidget,
    );
    expect(find.textContaining('private path'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(confirm(tester).onPressed, isNull);

    await tester.tap(find.text('Retry preview'));
    await pumpWork(tester);
    expect(operations.requests, hasLength(2));
    operations.requests.last.result.complete(updated);
    await tester.pumpAndSettle();
    expect(previewBytes(tester), same(updated));
    expect(confirm(tester).onPressed, isNotNull);
  });

  for (final adjustment in ['rotation', 'brightness', 'contrast', 'filter']) {
    testWidgets(
      '$adjustment failure retains the previous result and supports retry',
      (tester) async {
        ScannedPage? saved;
        await openPreview(tester, onResult: (page) => saved = page);
        final staleConfirm = confirm(tester).onPressed!;
        await change(tester, adjustment);
        expect(operations.requests, hasLength(2));
        expect(previewBytes(tester), same(previous));
        expect(
          find.text('Updating preview. Previous result shown.'),
          findsOneWidget,
        );
        expect(confirm(tester).onPressed, isNull);
        staleConfirm();
        await tester.pump();
        expect(operations.exports, isEmpty);

        final failed = operations.requests.last;
        failed.result.completeError(StateError('private exception detail'));
        await tester.pumpAndSettle();
        expect(previewBytes(tester), same(previous));
        expect(find.text(_oldResultMessage), findsOneWidget);
        expect(find.textContaining('private exception detail'), findsNothing);
        expect(confirm(tester).onPressed, isNull);
        staleConfirm();
        await tester.pump();
        expect(operations.exports, isEmpty);

        await tester.tap(find.text('Retry preview'));
        await pumpWork(tester);
        final retry = operations.requests.last;
        expect(operations.requests, hasLength(3));
        expect(retry.bytes, same(failed.bytes));
        expect(
          (retry.rotation, retry.brightness, retry.contrast),
          (failed.rotation, failed.brightness, failed.contrast),
        );
        expect(previewBytes(tester), same(previous));
        expect(confirm(tester).onPressed, isNull);
        retry.result.complete(updated);
        await tester.pumpAndSettle();
        expect(previewBytes(tester), same(updated));
        expect(find.text('Retry preview'), findsNothing);
        expect(confirm(tester).onPressed, isNotNull);

        await tester.tap(find.text('Confirm'));
        await tester.pumpAndSettle();
        expect(saved, isNotNull);
        expect(
          saved!.filter,
          adjustment == 'filter' ? PageFilter.grayscale : PageFilter.original,
        );
        expect(saved!.rotationQuarterTurns, retry.rotation);
        expect(saved!.brightness, retry.brightness);
        expect(saved!.contrast, retry.contrast);
        expect(operations.exports, hasLength(1));
        expect(operations.maxActiveWorkers, 1);
      },
    );
  }

  testWidgets(
    'slider drag immediately invalidates confirmation without processing each move',
    (tester) async {
      await openPreview(tester);
      final staleConfirm = confirm(tester).onPressed!;
      await change(tester, 'brightness', release: false);
      expect(operations.requests, hasLength(1));
      expect(previewBytes(tester), same(previous));
      expect(
        find.text('Release the slider to update the preview.'),
        findsOneWidget,
      );
      expect(confirm(tester).onPressed, isNull);
      staleConfirm();
      await tester.pump();
      expect(operations.exports, isEmpty);

      tester.widget<Slider>(find.byType(Slider).first).onChangeEnd!(35);
      await pumpWork(tester);
      expect(operations.requests, hasLength(2));
      expect(operations.requests.last.brightness, 35);
      operations.requests.last.result.complete(updated);
      await tester.pumpAndSettle();
      expect(confirm(tester).onPressed, isNotNull);
    },
  );

  testWidgets(
    'a worker finishing during a slider drag cannot mark the new settings ready',
    (tester) async {
      await openPreview(tester);
      await change(tester, 'rotation');
      await change(tester, 'brightness', release: false);
      operations.requests.last.result.complete(updated);
      await tester.pumpAndSettle();
      expect(previewBytes(tester), same(previous));
      expect(confirm(tester).onPressed, isNull);
      expect(
        find.text('Release the slider to update the preview.'),
        findsOneWidget,
      );

      tester.widget<Slider>(find.byType(Slider).first).onChangeEnd!(35);
      await pumpWork(tester);
      expect(operations.requests, hasLength(3));
      expect(operations.requests.last.rotation, 1);
      expect(operations.requests.last.brightness, 35);
      operations.requests.last.result.complete(updated);
      await tester.pumpAndSettle();
      expect(previewBytes(tester), same(updated));
      expect(confirm(tester).onPressed, isNotNull);
    },
  );

  testWidgets(
    'rapid changes skip stale queued work and ignore stale failures',
    (tester) async {
      await openPreview(tester);
      await change(tester, 'rotation');
      await change(tester, 'filter');
      await change(tester, 'brightness');
      expect(operations.requests, hasLength(2));
      operations.requests.last.result.completeError(
        StateError('stale failure'),
      );
      await pumpWork(tester);
      expect(operations.requests, hasLength(3));
      final latest = operations.requests.last;
      expect(latest.bytes, same(operations.filters[PageFilter.grayscale]));
      expect((latest.rotation, latest.brightness, latest.contrast), (1, 35, 1));
      expect(find.text(_oldResultMessage), findsNothing);
      expect(previewBytes(tester), same(previous));
      expect(confirm(tester).onPressed, isNull);
      latest.result.complete(updated);
      await tester.pumpAndSettle();
      expect(previewBytes(tester), same(updated));
      expect(confirm(tester).onPressed, isNotNull);
      expect(operations.maxActiveWorkers, 1);
    },
  );

  testWidgets('preview failures are announced as a live region', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await openPreview(tester);
      await change(tester, 'rotation');
      operations.requests.last.result.completeError(
        StateError('preview failed'),
      );
      await tester.pumpAndSettle();
      final node = tester.getSemantics(
        find.bySemanticsLabel(_oldResultMessage),
      );
      expect(node.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
      expect(confirm(tester).onPressed, isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('failure after disposal is safely ignored', (tester) async {
    await openPreview(tester, finishInitial: false);
    await tester.pumpWidget(const SizedBox());
    operations.requests.single.result.completeError(StateError('late failure'));
    await pumpWork(tester);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 568), const Size(640, 300)]) {
    testWidgets('error recovery remains reachable at $size with 200% text', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await openPreview(tester, textScale: 2);
      await change(tester, 'rotation');
      operations.requests.last.result.completeError(
        StateError('preview failed'),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Retry preview'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry preview'));
      await pumpWork(tester);
      operations.requests.last.result.complete(updated);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pumpAndSettle();
      expect(confirm(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }
}
