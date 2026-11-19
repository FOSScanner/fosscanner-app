import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/app_preferences.dart';
import 'package:fosscanner/services/pdf_document_saver.dart';
import 'package:fosscanner/services/pdf_export_files.dart';
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

class _Share implements SharePlatform {
  var calls = 0;

  @override
  Future<ShareResult> share(ShareParams params) async {
    calls++;
    return const ShareResult('', ShareResultStatus.success);
  }
}

class _Target implements PdfSaveTarget {
  _Target(this.fileName);

  @override
  final String fileName;
  Completer<void> outcome = Completer<void>();
  String? header;
  String? path;
  var discarded = 0;
  final renameRequests = <String>[];
  // Whether the provider supports renaming.
  bool canRename = true;

  @override
  Future<String?> rename(String fileName) async {
    renameRequests.add(fileName);
    return canRename ? fileName : null;
  }

  @override
  Future<void> write(File pdf) {
    path = pdf.path;
    header = String.fromCharCodes(pdf.readAsBytesSync().take(5));
    return outcome.future;
  }

  @override
  Future<void> discard() async => discarded++;
}

class _Saver implements PdfDocumentSaver {
  // Null keeps the suggested name, as when the user does not rename it.
  String? chosenName = 'My scan.pdf';
  bool canRename = true;
  Completer<bool> picked = Completer<bool>();
  String? suggestedName;
  // Whether an export existed when the picker opened.
  bool? exportExistedAtPick;
  bool Function()? exportsRemain;
  _Target? target;

  @override
  bool get isSupported => true;

  @override
  Future<PdfSaveTarget?> chooseTarget({required String fileName}) async {
    suggestedName = fileName;
    exportExistedAtPick = exportsRemain?.call();
    if (!await picked.future) return null;
    return target = _Target(chosenName ?? fileName)..canRename = canRename;
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
    cache = Directory.systemTemp.createTempSync('save_test_');
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    cache.deleteSync(recursive: true);
  });

  bool exportsRemain() => cache.listSync().any(
    (entry) => entry.path.contains(pdfExportDirectoryPrefix),
  );

  Future<_Share> pumpHome(
    WidgetTester tester, {
    PdfDocumentSaver saver = const PlatformPdfDocumentSaver(),
    double textScale = 1,
    int pages = 1,
    bool searchable = false,
  }) async {
    final share = _Share();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: ScannerHomePage(
          searchablePdfEnabled: searchable,
          preferencesStore: searchable
              ? MemoryAppPreferencesStore(
                  const AppPreferences(searchablePdf: true),
                )
              : null,
          sharePlus: SharePlus.custom(share),
          temporaryDirectory: () async => cache,
          documentSaver: saver,
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
    return share;
  }

  Finder saveButton() => find.byTooltip('Save PDF to device');

  testWidgets('Save is offered on Android and hidden on iOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpHome(tester);
    expect(saveButton(), findsOneWidget);

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(const SizedBox());
    await pumpHome(tester);
    expect(saveButton(), findsNothing);
    expect(find.text('Export PDF (1 page)'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the picker opens before the PDF is generated', (tester) async {
    final saver = _Saver()..exportsRemain = exportsRemain;
    final share = await pumpHome(tester, saver: saver);
    await tester.tap(saveButton());
    await pumpUntil(tester, () => saver.suggestedName != null, settle: false);
    await tester.pump();

    expect(
      saver.suggestedName,
      matches(RegExp(r'^Scan \d{4}-\d\d-\d\d \d\d-\d\d\.pdf$')),
    );
    expect(saver.exportExistedAtPick, isFalse);
    expect(find.text('Choose where to save…'), findsOneWidget);
    expect(saveButton(), findsNothing);

    saver.picked.complete(true);
    await pumpUntil(tester, () => saver.target?.path != null, settle: false);
    final target = saver.target!;
    expect(target.header, '%PDF-');
    expect(target.path, endsWith('/${saver.suggestedName}'));
    expect(find.text('Saving PDF…'), findsOneWidget);

    target.outcome.complete();
    // Confirms the name the user chose in the picker.
    await pumpUntilFound(tester, find.text('Saved “My scan.pdf”'));
    expect(exportsRemain(), isFalse);
    expect(target.discarded, 0);
    expect(share.calls, 0);
    expect(saveButton(), findsOneWidget);
  });

  testWidgets('cancelling the picker generates nothing and says nothing', (
    tester,
  ) async {
    final saver = _Saver();
    await pumpHome(tester, saver: saver);
    await tester.tap(saveButton());
    await pumpUntil(tester, () => saver.suggestedName != null, settle: false);
    saver.picked.complete(false);
    await pumpUntilFound(tester, find.text('Export PDF (1 page)'));
    expect(cache.listSync(), isEmpty);
    expect(saver.target, isNull);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('cancelling generation discards the chosen location', (
    tester,
  ) async {
    final saver = _Saver();
    await pumpHome(tester, saver: saver, pages: 3);
    await tester.tap(saveButton());
    await pumpUntil(tester, () => saver.suggestedName != null, settle: false);
    saver.picked.complete(true);
    await pumpUntilFound(
      tester,
      find.widgetWithText(TextButton, 'Cancel'),
      settle: false,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await pumpUntilFound(tester, find.text('Export canceled'));
    expect(saver.target!.path, isNull);
    expect(saver.target!.discarded, 1);
    expect(exportsRemain(), isFalse);
  });

  testWidgets('a failed save shows a generic, actionable message', (
    tester,
  ) async {
    final saver = _Saver();
    await pumpHome(tester, saver: saver);
    await tester.tap(saveButton());
    await pumpUntil(tester, () => saver.suggestedName != null, settle: false);
    saver.picked.complete(true);
    await pumpUntil(tester, () => saver.target?.path != null, settle: false);
    saver.target!.outcome.completeError(
      PlatformException(code: 'save_failed', message: '/data/user/0/x'),
    );
    await pumpUntilFound(
      tester,
      find.text(
        'Could not save the PDF. Try again, or choose another location.',
      ),
    );
    expect(find.textContaining('/data'), findsNothing);
    expect(exportsRemain(), isFalse);
    expect(saver.target!.discarded, 1);
  });

  group('an image-only fallback after a failed searchable export', () {
    // OCR has no native side in tests, so every searchable export fails.
    Future<_Target> saveWithFallback(WidgetTester tester, _Saver saver) async {
      await pumpHome(tester, saver: saver, searchable: true);
      await tester.tap(saveButton());
      await pumpUntil(tester, () => saver.suggestedName != null, settle: false);
      expect(saver.suggestedName, endsWith(' (searchable).pdf'));
      saver.picked.complete(true);
      await pumpUntilFound(
        tester,
        find.text('Export image-only PDF'),
        settle: false,
      );
      await tester.tap(find.text('Export image-only PDF'));
      await pumpUntil(tester, () => saver.target?.path != null, settle: false);
      saver.target!.outcome.complete();
      await tester.pumpAndSettle();
      return saver.target!;
    }

    testWidgets('drops " (searchable)" from the suggested name', (
      tester,
    ) async {
      final saver = _Saver()..chosenName = null;
      final target = await saveWithFallback(tester, saver);
      final plain = saver.suggestedName!.replaceFirst(' (searchable)', '');
      expect(target.renameRequests, [plain]);
      expect(target.path, isNot(contains('searchable')));
      expect(find.text('Saved “$plain”'), findsOneWidget);
    });

    testWidgets('keeps a name the user typed', (tester) async {
      final saver = _Saver();
      final target = await saveWithFallback(tester, saver);
      expect(target.renameRequests, isEmpty);
      expect(find.text('Saved “My scan.pdf”'), findsOneWidget);
    });

    testWidgets('keeps the name where the provider cannot rename', (
      tester,
    ) async {
      final saver = _Saver()
        ..chosenName = null
        ..canRename = false;
      final target = await saveWithFallback(tester, saver);
      expect(target.renameRequests, hasLength(1));
      expect(find.text('Saved “${saver.suggestedName}”'), findsOneWidget);
    });
  });

  testWidgets('a searchable save that succeeds is not renamed', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('com.fosscanner.app/ocr');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'createSearchablePdf') return null;
      final output = File('${(call.arguments as Map)['outputPath']}.pdf');
      output.writeAsStringSync('%PDF-1.5\nfixture\n%%EOF');
      return output.path;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final saver = _Saver()..chosenName = null;
    await pumpHome(tester, saver: saver, searchable: true);
    await tester.tap(saveButton());
    await pumpUntil(tester, () => saver.suggestedName != null, settle: false);
    saver.picked.complete(true);
    await pumpUntil(tester, () => saver.target?.path != null, settle: false);
    saver.target!.outcome.complete();
    await pumpUntilFound(tester, find.text('Saved “${saver.suggestedName}”'));
    debugDefaultTargetPlatformOverride = null;
    expect(saver.target!.renameRequests, isEmpty);
  });

  testWidgets('the channel contract reaches MainActivity', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('com.fosscanner.app/ocr');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final received = <MethodCall>[];
    var existed = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received.add(call);
      if (call.method == 'chooseSaveTarget') return {'fileName': 'Taxes.pdf'};
      if (call.method == 'writeSaveTarget') {
        existed = File(
          (call.arguments as Map)['sourcePath'] as String,
        ).existsSync();
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await pumpHome(tester);
    await tester.tap(saveButton());
    await pumpUntilFound(tester, find.text('Saved “Taxes.pdf”'));
    debugDefaultTargetPlatformOverride = null;

    expect(received.map((call) => call.method), [
      'chooseSaveTarget',
      'writeSaveTarget',
    ]);
    final suggested = (received.first.arguments as Map)['fileName'] as String;
    expect(received.first.arguments, {'fileName': suggested});
    final args = received.last.arguments as Map;
    expect(args.keys, ['sourcePath']);
    expect(args['sourcePath'], endsWith('/$suggested'));
    expect(args['sourcePath'], contains(pdfExportDirectoryPrefix));
    expect(existed, isTrue);
    expect(exportsRemain(), isFalse);
  });

  for (final size in [const Size(320, 568), const Size(640, 300)]) {
    testWidgets('export bar with Save fits 200% text on $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpHome(tester, saver: _Saver(), textScale: 2);
      expect(tester.takeException(), isNull);
      expect(saveButton().hitTestable(), findsOneWidget);
      expect(
        find.byTooltip('PDF export options').hitTestable(),
        findsOneWidget,
      );
      expect(find.text('Export PDF (1 page)').hitTestable(), findsOneWidget);
    });
  }
}
