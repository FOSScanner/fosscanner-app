import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

class _Operations implements CornerAdjustOperations {
  _Operations(
    this.bytes, {
    this.decodeError,
    this.imageSize = const Size(100, 100),
  });

  final Uint8List bytes;
  final Object? decodeError;
  final Size imageSize;

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
    return imageSize;
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

  for (final configuration in [
    (size: const Size(390, 844), textScale: 1.0),
    (size: const Size(390, 844), textScale: 1.5),
    (size: const Size(320, 568), textScale: 2.0),
    (size: const Size(800, 360), textScale: 1.0),
    (size: const Size(640, 300), textScale: 2.0),
  ]) {
    testWidgets('crop canvas gets priority at ${configuration.size} with '
        '${configuration.textScale}x text', (tester) async {
      tester.view.physicalSize = configuration.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              textScaler: TextScaler.linear(configuration.textScale),
            ),
            child: CornerAdjustScreen(
              originalBytes: imageBytes,
              operations: _Operations(
                imageBytes,
                imageSize: const Size(600, 900),
              ),
              source: PageReviewSource.gallery,
              isBatchImport: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final canvas = find.byType(CornerOverlay);
      final before = tester.getRect(canvas);
      final bodyHeight =
          configuration.size.height -
          tester.getBottomRight(find.byType(AppBar)).dy;
      final landscape = configuration.size.width > bodyHeight;
      expect(
        before.height,
        greaterThanOrEqualTo(bodyHeight * (landscape ? 0.9 : 0.6)),
      );
      expect(before.width, greaterThan(configuration.size.width * 0.5));

      // Scrolling controls must not shrink or move the crop canvas.
      for (final label in ['Skip image', 'Preview page']) {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        expect(find.text(label).hitTestable(), findsOneWidget);
        expect(tester.getRect(canvas), before);
      }
      final oldCorner = tester.widget<CornerOverlay>(canvas).corners.first;
      await tester.dragFrom(
        tester.getCenter(find.byKey(const ValueKey('corner-handle-0'))),
        const Offset(20, 20),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<CornerOverlay>(canvas).corners.first,
        isNot(oldCorner),
      );
      expect(tester.takeException(), isNull);
    });
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

    expect(find.text('Appearance'), findsNothing);
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
    expect(sliders, findsNothing);
    await tester.tap(find.byTooltip('Adjust'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.byTooltip('Close adjustments'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CornerOverlay>(find.byType(CornerOverlay)).corners,
      const [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)],
    );
    semantics.dispose();
  });

  testWidgets(
    'corner editor omits persistent guidance and crop utility buttons',
    (tester) async {
      await openFilterStep(tester);
      expect(find.text('Adjust crop'), findsNothing);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(
        find.text('Drag the corners to match the page edges.'),
        findsNothing,
      );
      expect(find.text('Reset crop'), findsNothing);
      expect(find.text('Use full image'), findsNothing);
      expect(find.byType(CornerOverlay), findsOneWidget);
    },
  );

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
    expect(
      find.text('No page edges detected. Full image selected.'),
      findsOneWidget,
    );
    expect(find.text('Reset crop'), findsNothing);
    expect(find.text('Use full image'), findsNothing);
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    expect(find.text('Add page'), findsOneWidget);
  });

  testWidgets('filters open on demand and retain selection after dismissal', (
    tester,
  ) async {
    await openFilterStep(tester);
    expect(find.byKey(const ValueKey('filter_grayscale')), findsNothing);
    expect(find.text('Adjust crop'), findsNothing);
    final preview = tester.getRect(
      find.byKey(const Key('adjusted_page_preview')),
    );
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Grayscale'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close filters'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter_grayscale')), findsNothing);
    expect(find.text('Appearance'), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('adjusted_page_preview'))),
      preview,
    );
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    final semantics = tester.ensureSemantics();
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('filter_grayscale')))
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.byKey(const ValueKey('filter_grayscale')), findsNothing);
    semantics.dispose();
  });

  for (final size in [const Size(320, 568), const Size(640, 300)]) {
    testWidgets('on-demand filters fit $size with large text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await openFilterStep(tester, textScaler: const TextScaler.linear(2));
      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Black & white'));
      await tester.pumpAndSettle();
      expect(find.text('Black & white').hitTestable(), findsOneWidget);
      expect(find.text('Adjust crop'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Appearance'), findsOneWidget);
    });
  }

  testWidgets('adjustments open on demand, persist, and Back closes first', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await openFilterStep(tester);
    expect(find.byType(Slider), findsNothing);
    expect(find.text('Reset adjustments'), findsNothing);
    final adjust = tester.getSemantics(find.byTooltip('Adjust'));
    expect(adjust.getSemanticsData().flagsCollection.isButton, isTrue);

    await tester.tap(find.byTooltip('Adjust'));
    await tester.pumpAndSettle();
    final brightness = tester.widget<Slider>(find.byType(Slider).first);
    brightness.onChanged!(40);
    brightness.onChangeEnd!(40);
    await tester.pumpAndSettle();
    expect(find.text('Brightness: +40'), findsOneWidget);

    // System Back dismisses the sheet before it can leave the step.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    expect(find.text('Appearance'), findsOneWidget);

    await tester.tap(find.byTooltip('Adjust'));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byType(Slider).first).value, 40);
    expect(find.text('Brightness: +40'), findsOneWidget);
    await tester.tap(find.byTooltip('Close adjustments'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    expect(find.text('Appearance'), findsOneWidget);
    semantics.dispose();
  });

  for (final size in [const Size(320, 568), const Size(640, 300)]) {
    testWidgets('on-demand adjustments fit $size with large text', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await openFilterStep(tester, textScaler: const TextScaler.linear(2));
      await tester.tap(find.byTooltip('Adjust'));
      await tester.pumpAndSettle();
      for (final target in [
        find.byType(Slider).first,
        find.byType(Slider).last,
        find.text('Reset adjustments'),
      ]) {
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        expect(target.hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Appearance'), findsOneWidget);
    });
  }

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

    expect(find.byKey(const ValueKey('filter_original')), findsNothing);
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
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
