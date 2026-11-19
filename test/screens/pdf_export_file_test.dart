import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/app_preferences.dart';
import 'package:fosscanner/services/pdf_export_files.dart';
import 'package:fosscanner/services/pdf_export_options.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:share_plus/share_plus.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import '../support/worker_isolates.dart';

class _Picker extends ImagePickerPlatform {
  @override
  bool supportsImageSource(ImageSource source) => false;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

/// Records what the platform would receive while the file still exists.
class _Share implements SharePlatform {
  _Share({this.fail = false});

  final bool fail;
  ShareParams? params;
  String? sharedPath;
  String? header;
  Uint8List? bytes;

  @override
  Future<ShareResult> share(ShareParams params) async {
    this.params = params;
    final file = params.files!.single;
    sharedPath = file.path;
    // Synchronous on purpose: the platform reads the file before returning.
    bytes = File(file.path).readAsBytesSync();
    header = latin1.decode(bytes!.take(5).toList());
    if (fail) throw PlatformException(code: 'share_failed', message: '/x/y');
    return const ShareResult('', ShareResultStatus.success);
  }
}

void main() {
  late Uint8List image;
  late ImagePickerPlatform originalPicker;
  late Directory cache;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _Picker();
    final data = await rootBundle.load('assets/icon/icon.png');
    image = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    cache = Directory.systemTemp.createTempSync('export_cache_test_');
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    cache.deleteSync(recursive: true);
  });

  List<FileSystemEntity> exportDirectories() => cache
      .listSync()
      .where((entry) => entry.path.contains(pdfExportDirectoryPrefix))
      .toList();

  Future<void> pumpHome(
    WidgetTester tester,
    SharePlatform share, {
    int pages = 1,
    bool searchable = false,
    AppPreferences preferences = const AppPreferences(),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          searchablePdfEnabled: searchable,
          sharePlus: SharePlus.custom(share),
          temporaryDirectory: () async => cache,
          preferencesStore: MemoryAppPreferencesStore(preferences),
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

  testWidgets('shares the PDF by path and removes it once sharing returns', (
    tester,
  ) async {
    final share = _Share();
    await pumpHome(tester, share);
    await tester.tap(find.text('Export PDF (1 page)'));
    await pumpUntil(tester, () => share.params != null);
    await pumpUntil(tester, () => exportDirectories().isEmpty);

    final shared = share.params!.files!.single;
    expect(shared.path, contains('/$pdfExportDirectoryPrefix'));
    expect(shared.path, startsWith(cache.path));
    expect(shared.mimeType, 'application/pdf');
    expect(share.header, '%PDF-');
    expect(
      shared.path.split('/').last,
      share.params!.fileNameOverrides!.single,
    );
    expect(File(share.sharedPath!).existsSync(), isFalse);
  });

  testWidgets('a failed share shows a generic message and cleans up', (
    tester,
  ) async {
    final share = _Share(fail: true);
    await pumpHome(tester, share);
    await tester.tap(find.text('Export PDF (1 page)'));
    await pumpUntilFound(
      tester,
      find.text('Could not generate or share the PDF.'),
    );
    await pumpUntil(tester, () => exportDirectories().isEmpty);
    expect(find.textContaining('/x/y'), findsNothing);
    expect(share.header, '%PDF-');
  });

  testWidgets('a cancelled export leaves no file behind', (tester) async {
    final share = _Share();
    await pumpHome(tester, share, pages: 2);
    await tester.tap(find.text('Export PDF (2 pages)'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await pumpUntilFound(tester, find.text('PDF generation cancelled.'));
    await pumpUntil(tester, () => exportDirectories().isEmpty);
    expect(share.params, isNull);
  });

  testWidgets('a searchable export moves the native PDF and cleans up', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('com.fosscanner.app/ocr');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => cache.path,
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ensureTessdata') return null;
      final output = File('${(call.arguments as Map)['outputPath']}.pdf');
      output.writeAsStringSync('%PDF-1.5\nfixture\n%%EOF');
      return output.path;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final share = _Share();
    await pumpHome(
      tester,
      share,
      searchable: true,
      preferences: const AppPreferences(searchablePdf: true),
    );
    await tester.tap(find.text('Export searchable PDF (1 page)'));
    await pumpUntil(tester, () => share.params != null);
    await pumpUntil(tester, () => cache.listSync().isEmpty);
    debugDefaultTargetPlatformOverride = null;

    expect(share.header, '%PDF-');
    expect(share.sharedPath, contains('/$pdfExportDirectoryPrefix'));
    // Nothing is added to the user's message.
    expect(share.params!.text, isNull);
  });

  testWidgets('chosen page size and quality persist and shape the export', (
    tester,
  ) async {
    final share = _Share();
    final store = MemoryAppPreferencesStore();
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          searchablePdfEnabled: false,
          sharePlus: SharePlus.custom(share),
          temporaryDirectory: () async => cache,
          preferencesStore: store,
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
    await tester.tap(find.widgetWithText(ChoiceChip, 'Letter'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Small'));
    await tester.pumpAndSettle();
    expect(find.textContaining('email and upload limits'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(
      await tester.runAsync(store.load),
      const AppPreferences(
        pdfPageSize: PdfPageSize.letter,
        pdfQuality: PdfQuality.small,
      ),
    );

    await tester.tap(find.text('Export PDF (1 page)'));
    await pumpUntil(tester, () => share.bytes != null);
    expect(latin1.decode(share.bytes!), contains('/MediaBox[0 0 612 792]'));
    await pumpUntil(tester, () => exportDirectories().isEmpty);
  });

  testWidgets('the export bar keeps its height while exporting at 200%', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final share = _Share();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: ScannerHomePage(
          searchablePdfEnabled: false,
          sharePlus: SharePlus.custom(share),
          temporaryDirectory: () async => cache,
          initialPages: [
            for (var i = 0; i < 2; i++)
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
    final bar = find.byKey(const Key('pdf_export_bar'));
    final idle = tester.getSize(bar).height;

    await tester.tap(find.text('Export PDF (2 pages)'));
    await tester.pump();
    expect(find.textContaining('Generating PDF'), findsOneWidget);
    expect(tester.getSize(bar).height, idle);
    expect(tester.takeException(), isNull);

    await pumpUntil(tester, () => share.params != null);
    expect(tester.getSize(bar).height, idle);
    await pumpUntil(tester, () => exportDirectories().isEmpty);
  });
}
