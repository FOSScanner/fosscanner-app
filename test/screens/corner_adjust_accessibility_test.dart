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

  for (final size in [const Size(390, 844), const Size(800, 320)]) {
    testWidgets('crop and filter respect body cutouts at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.view.padding = const FakeViewPadding(
        left: 38,
        right: 24,
        bottom: 20,
      );
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: CornerAdjustScreen(
            originalBytes: imageBytes,
            operations: _Operations(imageBytes),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final crop = tester.getRect(find.byType(CornerOverlay));
      expect(crop.left, greaterThanOrEqualTo(38));
      expect(crop.right, lessThanOrEqualTo(size.width - 24));
      await tester.ensureVisible(find.text('Preview page'));
      await tester.tap(find.text('Preview page'));
      await tester.pumpAndSettle();
      for (final slider in find.byType(Slider).evaluate()) {
        final finder = find.byWidget(slider.widget);
        await tester.ensureVisible(finder);
        final rect = tester.getRect(finder);
        expect(rect.left, greaterThanOrEqualTo(38));
        expect(rect.right, lessThanOrEqualTo(size.width - 24));
      }
      final save = find.widgetWithText(FilledButton, 'Add page');
      await tester.ensureVisible(save);
      await tester.pump();
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(size.height - 20));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'initialization failure scrolls to recovery on short inset screen',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 220);
      tester.view.padding = const FakeViewPadding(
        left: 38,
        right: 24,
        bottom: 20,
      );
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: CornerAdjustScreen(
            originalBytes: imageBytes,
            operations: _Operations(
              imageBytes,
              decodeError: StateError('private data'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final back = find.widgetWithText(FilledButton, 'Go back');
      await tester.ensureVisible(back);
      await tester.pumpAndSettle();
      final rect = tester.getRect(back);
      expect(rect.left, greaterThanOrEqualTo(38));
      expect(rect.right, lessThanOrEqualTo(576));
      expect(rect.top, greaterThanOrEqualTo(kToolbarHeight));
      expect(rect.bottom, lessThanOrEqualTo(200));
      expect(back.hitTestable(), findsOneWidget);
      expect(find.textContaining('private data'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

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

    expect(find.text('Adjust appearance'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('normal portrait filter screen keeps the fixed layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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

  testWidgets(
    'failed detection selects the full image without persistent text',
    (tester) async {
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
        findsNothing,
      );
      expect(find.text('Reset crop'), findsNothing);
      expect(find.text('Use full image'), findsNothing);
      await tester.tap(find.text('Preview page'));
      await tester.pumpAndSettle();
      expect(find.text('Add page'), findsOneWidget);
    },
  );

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
    expect(find.text('Adjust appearance'), findsOneWidget);
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
    expect(find.text('Adjust appearance'), findsOneWidget);
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
      expect(find.text('Adjust appearance'), findsOneWidget);
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
