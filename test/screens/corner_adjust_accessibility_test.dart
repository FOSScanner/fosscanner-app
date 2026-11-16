import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

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
    await tester.ensureVisible(find.text('Preview page'));
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
  }

  testWidgets('short landscape with large text scrolls to Save changes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await openFilterStep(tester, textScaler: const TextScaler.linear(2));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('filter_step_scroll_view')), findsOneWidget);

    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Save changes'),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
    await tester.pumpAndSettle();

    expect(find.text('Adjust appearance'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('normal-height filter screen keeps the fixed layout', (
    tester,
  ) async {
    await openFilterStep(tester);

    expect(find.byKey(const Key('filter_step_scroll_view')), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Save changes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sliders name their values and reset without changing crop', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await openFilterStep(tester);
    final sliders = find.byType(Slider);
    expect(tester.getSemantics(sliders.first).label, 'Brightness');
    expect(
      tester.getSemantics(sliders.first).getSemanticsData().value,
      contains('neutral 0'),
    );
    expect(tester.getSemantics(sliders.last).label, 'Contrast');
    expect(
      tester.getSemantics(sliders.last).getSemanticsData().value,
      contains('neutral 1'),
    );
    tester.widget<Slider>(sliders.first).onChanged!(100);
    tester.widget<Slider>(sliders.last).onChanged!(2);
    await tester.pump();
    expect(find.text('Brightness: +100'), findsOneWidget);
    expect(find.text('Contrast: 2.00×'), findsOneWidget);
    await tester.tap(find.text('Reset adjustments'));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(sliders.first).value, 0);
    expect(tester.widget<Slider>(sliders.last).value, 1);
    await tester.tap(find.text('Adjust crop'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CornerOverlay>(find.byType(CornerOverlay)).corners,
      const [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)],
    );
    semantics.dispose();
  });

  testWidgets('reset restores saved crop after dragging or using full image', (
    tester,
  ) async {
    await openFilterStep(tester);
    await tester.tap(find.text('Adjust crop'));
    await tester.pumpAndSettle();
    final overlay = find.byType(CornerOverlay);
    final original = List<Offset>.of(
      tester.widget<CornerOverlay>(overlay).corners,
    );
    tester.widget<CornerOverlay>(overlay).onChanged(const [
      Offset(10, 10),
      Offset(90, 10),
      Offset(90, 90),
      Offset(10, 90),
    ]);
    await tester.pumpAndSettle();
    expect(tester.widget<CornerOverlay>(overlay).corners, isNot(original));
    await tester.tap(find.text('Reset crop'));
    await tester.pumpAndSettle();
    expect(tester.widget<CornerOverlay>(overlay).corners, original);
    await tester.tap(find.text('Use full image'));
    await tester.pumpAndSettle();
    expect(tester.widget<CornerOverlay>(overlay).corners, const [
      Offset.zero,
      Offset(99, 0),
      Offset(99, 99),
      Offset(0, 99),
    ]);
    await tester.tap(find.text('Reset crop'));
    await tester.pumpAndSettle();
    expect(tester.widget<CornerOverlay>(overlay).corners, original);
  });

  testWidgets('failed detection explains the fallback and offers recovery', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CornerAdjustScreen(
          originalBytes: imageBytes,
          operations: _Operations(imageBytes),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Page edges were not detected'), findsOneWidget);
    expect(find.text('Reset crop'), findsOneWidget);
    expect(find.text('Use full image'), findsOneWidget);
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    expect(find.text('Add page'), findsOneWidget);
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
