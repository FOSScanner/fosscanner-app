import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';

class _Operations implements CornerAdjustOperations {
  _Operations(this.bytes, {this.decodeError});

  final Uint8List bytes;
  final Object? decodeError;

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
  Future<Size> decodeSize(Uint8List imageBytes) async {
    if (decodeError case final error?) throw error;
    return const Size(100, 100);
  }

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async => null;

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
  late Uint8List imageBytes;

  setUp(() async {
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  });

  Future<void> openFilterStep(
    WidgetTester tester, {
    TextScaler? textScaler,
  }) async {
    final screen = CornerAdjustScreen(
      originalBytes: imageBytes,
      initialCorners: const [
        Offset(5, 5),
        Offset(95, 5),
        Offset(95, 95),
        Offset(5, 95),
      ],
      operations: _Operations(imageBytes),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: textScaler == null
            ? screen
            : MediaQuery(
                data: MediaQueryData(textScaler: textScaler),
                child: screen,
              ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
  }

  testWidgets('short landscape with large text scrolls to Confirm', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await openFilterStep(tester, textScaler: const TextScaler.linear(2));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('filter_step_scroll_view')), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();

    expect(find.text('Preview'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('normal-height filter screen keeps the fixed layout', (
    tester,
  ) async {
    await openFilterStep(tester);

    expect(find.byKey(const Key('filter_step_scroll_view')), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Confirm'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('corner initialization hides raw exception details', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(
          originalBytes: imageBytes,
          operations: _Operations(
            imageBytes,
            decodeError: StateError('private file path'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not read this photo.'), findsOneWidget);
    expect(find.textContaining('private file path'), findsNothing);
  });

  testWidgets('filter choices expose selected semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    await openFilterStep(tester);

    final original = tester.getSemantics(
      find.byKey(const ValueKey('filter_original')),
    );
    final grayscale = tester.getSemantics(
      find.byKey(const ValueKey('filter_grayscale')),
    );
    expect(
      original.getSemanticsData().flagsCollection.isSelected,
      Tristate.isTrue,
    );
    expect(
      grayscale.getSemanticsData().flagsCollection.isSelected,
      Tristate.isFalse,
    );

    semantics.dispose();
  });
}
