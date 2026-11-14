import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';

class _Picker extends ImagePickerPlatform {
  Completer<List<XFile>>? selection;

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => await selection?.future ?? const [];
}

void main() {
  late ImagePickerPlatform originalPicker;
  late _Picker picker;
  late Uint8List imageBytes;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = picker = _Picker();
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    PackageInfo.setMockInitialValues(
      appName: 'FOSScanner',
      packageName: 'com.fosscanner.app',
      version: '1.4.0',
      buildNumber: '7',
      buildSignature: '',
    );
  });

  tearDown(() => ImagePickerPlatform.instance = originalPicker);

  Future<void> pumpHome(
    WidgetTester tester, {
    int pageCount = 1,
    bool searchable = true,
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: brightness,
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: ScannerHomePage(
          searchablePdfEnabled: searchable,
          initialPages: [
            for (var index = 0; index < pageCount; index++)
              ScannedPage(
                originalBytes: imageBytes,
                processedBytes: imageBytes,
                corners: const [],
              ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> openOptions(WidgetTester tester) async {
    await tester.tap(find.byTooltip('PDF export options'));
    await tester.pumpAndSettle();
  }

  testWidgets('home has one compact export row, not an inline OCR panel', (
    tester,
  ) async {
    setViewport(tester, const Size(390, 844));
    await pumpHome(tester, pageCount: 3);

    expect(find.text('Export PDF (3 pages)'), findsOneWidget);
    expect(find.byTooltip('PDF export options'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('About FOSScanner'), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('pdf_export_bar'))).height,
      lessThanOrEqualTo(88),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('export options explain OCR and retain the selection on reopen', (
    tester,
  ) async {
    await pumpHome(tester);
    await openOptions(tester);
    expect(find.text('Searchable text'), findsOneWidget);
    expect(find.textContaining('Latin-script'), findsOneWidget);
    expect(find.textContaining('entirely on your device'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );

    await tester.tap(find.text('Searchable text'));
    await tester.pumpAndSettle();
    expect(
      find.text('Image-only PDF without text recognition.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNothing);

    await openOptions(tester);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    await tester.tap(find.text('Searchable text'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
  });

  testWidgets('image-only platforms do not offer unavailable OCR settings', (
    tester,
  ) async {
    await pumpHome(tester, searchable: false);
    expect(find.text('Export PDF (1 page)'), findsOneWidget);
    expect(find.byTooltip('PDF export options'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('empty home has no footer and About is in the overflow menu', (
    tester,
  ) async {
    await pumpHome(tester, pageCount: 0);
    expect(find.byKey(const Key('pdf_export_bar')), findsNothing);
    expect(find.byTooltip('PDF export options'), findsNothing);
    expect(find.text('About FOSScanner'), findsNothing);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About FOSScanner'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Version 1.4.0 (build 7)'), findsOneWidget);
    expect(find.text('View source code'), findsOneWidget);
    expect(find.text('Licensed under the GNU GPL v3.0'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final size in [const Size(320, 568), const Size(640, 300)]) {
      testWidgets('large-text home and options fit $size in $brightness', (
        tester,
      ) async {
        setViewport(tester, size);
        await pumpHome(tester, textScale: 2, brightness: brightness);
        expect(tester.takeException(), isNull);
        expect(find.text('Export PDF (1 page)').hitTestable(), findsOneWidget);
        await openOptions(tester);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Searchable text'));
        await tester.tap(find.text('Searchable text'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse,
        );
        await tester.ensureVisible(find.widgetWithText(FilledButton, 'Done'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Done'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('short empty home scrolls without large-text overflow', (
    tester,
  ) async {
    setViewport(tester, const Size(640, 260));
    await pumpHome(tester, pageCount: 0, textScale: 2);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.textContaining('Tap the camera button'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('page labels and delete controls do not cover document content', (
    tester,
  ) async {
    await pumpHome(tester);
    final preview = find.descendant(
      of: find.byType(Card).first,
      matching: find.byType(Image),
    );
    final image = tester.widget<Image>(preview);
    final bounds = tester.getRect(preview);
    expect(image.fit, BoxFit.contain);
    expect(bounds.overlaps(tester.getRect(find.text('Page 1'))), isFalse);
    expect(
      bounds.overlaps(tester.getRect(find.byTooltip('Delete page 1'))),
      isFalse,
    );
  });

  testWidgets('About content remains usable on a narrow large-text screen', (
    tester,
  ) async {
    setViewport(tester, const Size(320, 568));
    await pumpHome(tester, pageCount: 0, textScale: 2);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About FOSScanner'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('View source code'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('last grid page and delete action clear the camera button', (
    tester,
  ) async {
    setViewport(tester, const Size(390, 600));
    await pumpHome(tester, pageCount: 8);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();

    final camera = tester.getRect(find.byType(FloatingActionButton));
    final delete = tester.getRect(find.byTooltip('Delete page 8'));
    final page = tester.getRect(find.byKey(const ValueKey('page_semantics_7')));
    expect(delete.overlaps(camera), isFalse);
    expect(page.overlaps(camera), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('busy intake rejects a stale export-options callback', (
    tester,
  ) async {
    picker.selection = Completer<List<XFile>>();
    await pumpHome(tester);
    final options = tester
        .widget<IconButton>(
          find.ancestor(
            of: find.byTooltip('PDF export options'),
            matching: find.byType(IconButton),
          ),
        )
        .onPressed!;
    await tester.tap(find.byTooltip('Import from gallery'));
    await tester.pump();
    options();
    await tester.pump();
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('PDF export options'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
    picker.selection!.complete([]);
    await tester.pumpAndSettle();
    await openOptions(tester);
    expect(find.text('Searchable text'), findsOneWidget);
  });
}
