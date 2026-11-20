import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/app_preferences.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import '../support/layout_stability.dart';

class _Picker extends ImagePickerPlatform {
  @override
  bool supportsImageSource(ImageSource source) => false;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

void main() {
  late ImagePickerPlatform originalPicker;
  late Uint8List image;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _Picker();
    final data = await rootBundle.load('assets/icon/icon.png');
    image = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  tearDown(() => ImagePickerPlatform.instance = originalPicker);

  Future<void> openOptions(
    WidgetTester tester,
    LayoutCase layoutCase, {
    AppPreferences preferences = const AppPreferences(),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: withTextScale(layoutCase.textScale),
        home: ScannerHomePage(
          searchablePdfEnabled: true,
          preferencesStore: MemoryAppPreferencesStore(preferences),
          initialPages: [
            ScannedPage(
              originalBytes: image,
              processedBytes: image,
              corners: const [],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('PDF export options'));
    await tester.pumpAndSettle();
  }

  final sheet = find.byType(BottomSheet);
  final toggle = find.byType(SwitchListTile);
  final anchors = {
    'sheet': sheet,
    'switch': toggle,
    'done': find.widgetWithText(FilledButton, 'Done'),
    // Neighbouring chips must not be pushed sideways or onto a new row.
    for (final label in ['Original', 'A4', 'Letter', 'High', 'Balanced'])
      'chip $label': find.widgetWithText(ChoiceChip, label),
    'chip Small': find.widgetWithText(ChoiceChip, 'Small'),
  };

  testLayoutMatrix('changing export options never moves the sheet', (
    tester,
    layoutCase,
  ) async {
    await openOptions(tester, layoutCase);
    Future<void> change(Finder control) async {
      await tester.ensureVisible(control);
      await tester.pumpAndSettle();
      await expectStableRects(tester, anchors, () async {
        await tester.tap(control);
        await tester.pumpAndSettle();
      }, reason: 'tapping $control');
    }

    await change(find.text('Searchable text'));
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await change(find.text('Searchable text'));
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    for (final label in ['A4', 'Letter', 'Original', 'Balanced', 'Small']) {
      await change(find.widgetWithText(ChoiceChip, label));
    }
    await change(find.widgetWithText(ChoiceChip, 'High'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the subtitle and disclosure are the same in both states', (
    tester,
  ) async {
    await openOptions(tester, const LayoutCase(Size(390, 844), 1));
    for (var i = 0; i < 2; i++) {
      expect(find.text('Search and copy text in the PDF.'), findsOneWidget);
      expect(
        find.text('Supports Latin-script text. Runs on your device.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Searchable text'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('only the chosen quality is described to assistive tech', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await openOptions(
      tester,
      const LayoutCase(Size(390, 844), 1),
      preferences: const AppPreferences(),
    );
    expect(find.bySemanticsLabel('Full resolution. Largest files.'), findsOne);
    expect(find.bySemanticsLabel(RegExp('Up to 150 DPI')), findsNothing);
    semantics.dispose();
  });

  testWidgets('the options button announces Searchable text on or off', (
    tester,
  ) async {
    await openOptions(tester, const LayoutCase(Size(390, 844), 1));
    String? summary() => tester
        .widget<Semantics>(
          find.ancestor(
            of: find.byTooltip('PDF export options'),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.value != null,
            ),
          ),
        )
        .properties
        .value;
    await tester.tap(find.text('Searchable text'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(summary(), startsWith('Searchable text on,'));
    await tester.tap(find.byTooltip('PDF export options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Searchable text'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(summary(), startsWith('Searchable text off,'));
  });
}
