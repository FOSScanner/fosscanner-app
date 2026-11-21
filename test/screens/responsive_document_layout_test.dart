import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import '../support/document_ui_fixtures.dart';
import '../support/layout_stability.dart';

class _Picker extends ImagePickerPlatform {
  @override
  bool supportsImageSource(ImageSource source) => true;
  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

void main() {
  late ImagePickerPlatform original;
  late Uint8List bytes;
  setUp(() async {
    original = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _Picker();
    bytes = (await rootBundle.load(
      'assets/icon/icon.png',
    )).buffer.asUint8List();
    PackageInfo.setMockInitialValues(
      appName: 'FOSScanner',
      packageName: 'com.fosscanner.app',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });
  tearDown(() => ImagePickerPlatform.instance = original);

  ScannerHomePage home(int count) => ScannerHomePage(
    initialPages: [
      for (var i = 0; i < count; i++)
        ScannedPage(
          originalBytes: bytes,
          processedBytes: bytes,
          corners: const [],
        ),
    ],
  );

  for (final layout in responsiveLayouts) {
    testWidgets('last page controls clear the camera on ${layout.name}', (
      tester,
    ) async {
      layout.apply(tester);
      await tester.pumpWidget(layout.wrap(home(12)));
      await tester.pumpAndSettle();
      final grid = find.byType(GridView);
      final delegate =
          tester.widget<GridView>(grid).gridDelegate
              as SliverGridDelegateWithFixedCrossAxisCount;
      if (layout.size.width <= 320) expect(delegate.crossAxisCount, 1);
      if (layout.size.width >= 800) {
        expect(delegate.crossAxisCount, greaterThan(2));
      }
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: grid, matching: find.byType(Scrollable)),
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final delete = find.byTooltip('Delete page 12');
      // Delete is now at the top of the card, not in its bottom footer.
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      expect(delete.hitTestable(), findsOneWidget);
      final camera = tester.getRect(find.byTooltip('Capture Image'));
      expect(tester.getRect(delete).overlaps(camera), isFalse);
      final image = find.descendant(
        of: find.byType(Card).last,
        matching: find.byType(Image),
      );
      expect(tester.getSize(image).height, greaterThanOrEqualTo(160));
      expect(find.text('Export PDF (12 pages)').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty state and About scroll on ${layout.name}', (
      tester,
    ) async {
      layout.apply(tester);
      await tester.pumpWidget(layout.wrap(home(0)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Ready to Scan'));
      expect(find.text('Ready to Scan').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About FOSScanner'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('View source code'));
      expect(find.text('View source code').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [
    const Size(240, 700),
    const Size(320, 520),
    const Size(390, 640),
    const Size(800, 300),
    const Size(1024, 768),
  ]) {
    testWidgets('useful preview near layout breakpoints at $size', (
      tester,
    ) async {
      final layout = LayoutConfiguration('preview', size);
      layout.apply(tester);
      final operations = FixtureOperations(bytes);
      await tester.pumpWidget(
        layout.wrap(
          CornerAdjustScreen(
            originalBytes: bytes,
            initialCorners: fixtureCorners,
            startWithAdjustments: true,
            operations: operations,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final preview = find.byKey(const Key('adjusted_page_preview'));
      final bounds = tester.getRect(preview);
      expect(bounds.width, greaterThanOrEqualTo(240));
      expect(bounds.height, greaterThanOrEqualTo(240));
      operations.previewState = PreviewFixtureState.failed;
      final slider = tester.widget<Slider>(find.byType(Slider).first);
      slider.onChanged!(25);
      slider.onChangeEnd!(25);
      await tester.pumpAndSettle();
      expect(tester.getSize(preview).height, greaterThanOrEqualTo(240));
      final confirm = find.widgetWithText(FilledButton, 'Save changes');
      await tester.ensureVisible(confirm);
      expect(confirm.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [
    const Size(240, 640),
    const Size(320, 220),
    const Size(640, 300),
  ]) {
    testWidgets('crop actions remain legible and reachable at $size', (
      tester,
    ) async {
      final layout = LayoutConfiguration(
        'crop actions',
        size,
        textScaler: const TextScaler.linear(2),
      );
      layout.apply(tester);
      await tester.pumpWidget(
        layout.wrap(
          CornerAdjustScreen(
            originalBytes: bytes,
            initialCorners: fixtureCorners,
            operations: FixtureOperations(bytes),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final next = find.widgetWithText(FilledButton, 'Preview page');
      await tester.ensureVisible(next);
      await tester.pumpAndSettle();
      expect(next.hitTestable(), findsOneWidget);
      expect(tester.getSize(next).width, greaterThanOrEqualTo(200));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('resize preserves filter and adjustment state', (tester) async {
    const layout = LayoutConfiguration('resize', Size(390, 844));
    layout.apply(tester);
    final operations = FixtureOperations(bytes);
    await tester.pumpWidget(
      layout.wrap(
        CornerAdjustScreen(
          originalBytes: bytes,
          initialCorners: fixtureCorners,
          startWithAdjustments: true,
          operations: operations,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byType(Slider).first);
    slider.onChanged!(35);
    slider.onChangeEnd!(35);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter_grayscale')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close filters'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1024, 768);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byType(Slider).first).value, 35);
    expect(
      tester.getSize(find.byKey(const Key('adjusted_page_preview'))).height,
      greaterThan(500),
    );
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Semantics>(find.byKey(const ValueKey('filter_grayscale')))
          .properties
          .selected,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow app bar retains secondary actions in overflow',
    (tester) async {
      responsiveLayouts.last.apply(tester);
      await tester.pumpWidget(responsiveLayouts.last.wrap(home(2)));
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('Import from gallery').hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      expect(find.text('Scan QR/barcode'), findsOneWidget);
      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();
      expect(find.text('Clear all pages?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
