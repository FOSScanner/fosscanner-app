import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';

class _Operations implements CornerAdjustOperations {
  _Operations(this.bytes, {this.exportCompleter});

  final Uint8List bytes;
  final Completer<Uint8List>? exportCompleter;

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
  }) => exportCompleter?.future ?? Future.value(bytes);
}

void main() {
  late Uint8List imageBytes;

  setUp(() async {
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  });

  const corners = [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)];

  Future<void> openAdjuster(
    WidgetTester tester,
    CornerAdjustOperations operations,
    Uint8List originalBytes, {
    ValueChanged<ScannedPage?>? onResult,
    bool startWithAdjustments = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                final result = await Navigator.of(context).push(
                  MaterialPageRoute<ScannedPage>(
                    builder: (_) => CornerAdjustScreen(
                      originalBytes: originalBytes,
                      initialCorners: corners,
                      startWithAdjustments: startWithAdjustments,
                      operations: operations,
                    ),
                  ),
                );
                onResult?.call(result);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(
      find.text(startWithAdjustments ? 'Adjust appearance' : 'Edit page'),
      findsOneWidget,
    );
  }

  testWidgets(
    'saved appearance opens directly and back cancels without saving',
    (tester) async {
      ScannedPage? result;
      await openAdjuster(
        tester,
        _Operations(imageBytes),
        imageBytes,
        startWithAdjustments: true,
        onResult: (page) => result = page,
      );
      expect(find.text('Save changes'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(result, isNull);
    },
  );

  testWidgets('direct appearance can adjust crop and save the existing page', (
    tester,
  ) async {
    ScannedPage? result;
    await openAdjuster(
      tester,
      _Operations(imageBytes),
      imageBytes,
      startWithAdjustments: true,
      onResult: (page) => result = page,
    );
    await tester.tap(find.text('Adjust crop'));
    await tester.pumpAndSettle();
    expect(find.text('Edit page'), findsOneWidget);
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(result?.corners, corners);
    expect(result?.brightness, 0);
    expect(result?.contrast, 1);
  });

  testWidgets('filter navigation uses removable local history', (tester) async {
    await openAdjuster(tester, _Operations(imageBytes), imageBytes);

    await tester.tap(find.text('Preview page'));
    await tester.pump();
    expect(find.text('Adjust appearance'), findsOneWidget);
    expect(
      ModalRoute.of(
        tester.element(find.text('Adjust appearance')),
      )!.willHandlePopInternally,
      isTrue,
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Edit page'), findsOneWidget);
    expect(find.text('Open'), findsNothing);
    expect(
      ModalRoute.of(
        tester.element(find.text('Edit page')),
      )!.willHandlePopInternally,
      isFalse,
    );

    await tester.tap(find.text('Preview page'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Adjust crop'));
    await tester.pump();
    expect(find.text('Edit page'), findsOneWidget);
    expect(
      ModalRoute.of(
        tester.element(find.text('Edit page')),
      )!.willHandlePopInternally,
      isFalse,
    );

    await tester.tap(find.text('Preview page'));
    await tester.pump();
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    expect(find.text('Edit page'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Edit page'), findsNothing);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('route pop is blocked while final processing is active', (
    tester,
  ) async {
    final completer = Completer<Uint8List>();
    ScannedPage? result;
    await openAdjuster(
      tester,
      _Operations(imageBytes, exportCompleter: completer),
      imageBytes,
      onResult: (value) => result = value,
    );
    await tester.tap(find.text('Preview page'));
    await tester.pump();

    await tester.tap(find.text('Save changes'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Adjust appearance'), findsOneWidget);
    expect(find.text('Open'), findsNothing);

    completer.complete(imageBytes);
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Adjust appearance'), findsNothing);
    expect(result, isNotNull);
    expect(result!.processedBytes, orderedEquals(imageBytes));
  });
}
