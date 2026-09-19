import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';

Future<Uint8List> _iconBytes() async {
  final data = await rootBundle.load('assets/icon/icon.png');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

class _Operations implements CornerAdjustOperations {
  _Operations(this.bytes);

  final Uint8List bytes;
  final decodeCompleted = Completer<void>();
  final previewsRequested = Completer<void>();

  @override
  Future<Size> decodeSize(Uint8List imageBytes) async {
    decodeCompleted.complete();
    return const Size(100, 100);
  }

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async => null;

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List imageBytes,
    List<Offset> corners,
  ) async {
    if (!previewsRequested.isCompleted) previewsRequested.complete();
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
  testWidgets('an invalid crop cannot enter the preview step', (tester) async {
    final bytes = await _iconBytes();
    final operations = _Operations(bytes);

    await tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(
          originalBytes: bytes,
          initialCorners: const [
            Offset(80, 80),
            Offset(95, 5),
            Offset(95, 95),
            Offset(5, 95),
          ],
          operations: operations,
        ),
      ),
    );
    await tester.pump();
    expect(operations.decodeCompleted.isCompleted, isTrue);
    await tester.pumpAndSettle();

    expect(find.text('Next'), findsOneWidget);
    expect(operations.previewsRequested.isCompleted, isFalse);
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'))
        .onPressed!();
    await tester.pump();

    expect(find.text('Edit page'), findsOneWidget);
    expect(find.text('Preview'), findsNothing);
    expect(find.textContaining('Could not preview this crop'), findsOneWidget);
  });

  testWidgets('malformed initial corners fall back without crashing', (
    tester,
  ) async {
    final bytes = await _iconBytes();
    final operations = _Operations(bytes);

    await tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(
          originalBytes: bytes,
          initialCorners: const [Offset.zero, Offset(100, 0), Offset(100, 100)],
          operations: operations,
        ),
      ),
    );
    await tester.pump();
    expect(operations.decodeCompleted.isCompleted, isTrue);
    await tester.pump();
    expect(operations.previewsRequested.isCompleted, isTrue);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Next'), findsOneWidget);
  });
}
