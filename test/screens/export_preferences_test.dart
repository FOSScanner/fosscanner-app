import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/app_preferences.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import '../support/export_bar.dart';

class _Picker extends ImagePickerPlatform {
  @override
  bool supportsImageSource(ImageSource source) => false;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

class _Store implements AppPreferencesStore {
  _Store([AppPreferences initial = const AppPreferences()])
    : loaded = Completer<AppPreferences>()..complete(initial);

  _Store.pending() : loaded = Completer<AppPreferences>();

  final Completer<AppPreferences> loaded;
  final saved = <AppPreferences>[];

  @override
  Future<AppPreferences> load() => loaded.future;

  @override
  Future<void> save(AppPreferences preferences) async => saved.add(preferences);
}

void main() {
  late Uint8List image;
  late ImagePickerPlatform originalPicker;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _Picker();
    final data = await rootBundle.load('assets/icon/icon.png');
    image = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  tearDown(() => ImagePickerPlatform.instance = originalPicker);

  Future<void> pumpHome(
    WidgetTester tester,
    AppPreferencesStore store, {
    bool searchable = true,
    int pages = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          searchablePdfEnabled: searchable,
          preferencesStore: store,
          initialPages: [
            for (var i = 0; i < pages; i++)
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
  }

  testWidgets('a remembered searchable choice is restored and labelled', (
    tester,
  ) async {
    await pumpHome(
      tester,
      _Store(const AppPreferences(searchablePdf: true)),
      pages: 2,
    );
    expect(findShareButton(2, searchable: true), findsOneWidget);
    await tester.tap(find.byTooltip('PDF export options'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
  });

  testWidgets('toggling searchable text persists it and updates the label', (
    tester,
  ) async {
    final store = _Store();
    await pumpHome(tester, store);
    expect(findShareButton(1), findsOneWidget);

    await tester.tap(find.byTooltip('PDF export options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Searchable text'));
    await tester.pumpAndSettle();
    expect(store.saved, [const AppPreferences(searchablePdf: true)]);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(findShareButton(1, searchable: true), findsOneWidget);

    await tester.tap(find.byTooltip('PDF export options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Searchable text'));
    await tester.pumpAndSettle();
    expect(store.saved.last, const AppPreferences());
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(findShareButton(1), findsOneWidget);
  });

  testWidgets('platforms without OCR ignore a stored searchable choice', (
    tester,
  ) async {
    final store = _Store(const AppPreferences(searchablePdf: true));
    await pumpHome(tester, store, searchable: false);
    expect(findShareButton(1), findsOneWidget);
    expect(find.textContaining('searchable'), findsNothing);
    expect(store.saved, isEmpty);
  });

  testWidgets('a slow load does not undo a choice made meanwhile', (
    tester,
  ) async {
    final store = _Store.pending();
    await pumpHome(tester, store);
    await tester.tap(find.byTooltip('PDF export options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Searchable text'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    store.loaded.complete(const AppPreferences());
    await tester.pumpAndSettle();
    expect(findShareButton(1, searchable: true), findsOneWidget);
  });

  for (final size in [const Size(320, 568), const Size(640, 300)]) {
    testWidgets('searchable label fits at 200% text on $size', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ScannerHomePage(
            searchablePdfEnabled: true,
            preferencesStore: _Store(const AppPreferences(searchablePdf: true)),
            initialPages: [
              for (var i = 0; i < 12; i++)
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
      expect(tester.takeException(), isNull);
      final label = findShareButton(12, searchable: true);
      expect(label.hitTestable(), findsOneWidget);
      final bar = tester.getRect(find.byKey(const Key('pdf_export_bar')));
      expect(tester.getRect(label).right, lessThanOrEqualTo(bar.right));
      // The page count and mode are read with the short label.
      expect(
        tester.getSemantics(find.text('Share PDF')),
        matchesSemantics(
          label: 'Share PDF',
          value: '12 pages, searchable text',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      semantics.dispose();
    });
  }
}
