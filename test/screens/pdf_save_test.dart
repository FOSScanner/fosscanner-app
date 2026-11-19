import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
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

class _Saver implements PdfDocumentSaver {
  Completer<bool> outcome = Completer<bool>();
  String? fileName;
  String? header;
  String? path;

  @override
  bool get isSupported => true;

  @override
  Future<bool> save(File pdf, {required String fileName}) {
    this.fileName = fileName;
    path = pdf.path;
    header = String.fromCharCodes(pdf.readAsBytesSync().take(5));
    return outcome.future;
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
          searchablePdfEnabled: false,
          sharePlus: SharePlus.custom(share),
          temporaryDirectory: () async => cache,
          documentSaver: saver,
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

  testWidgets('saving hands over a readable name and confirms success', (
    tester,
  ) async {
    final saver = _Saver();
    final share = await pumpHome(tester, saver: saver);
    await tester.tap(saveButton());
    await pumpUntil(tester, () => saver.fileName != null, settle: false);

    expect(saver.header, '%PDF-');
    expect(
      saver.fileName,
      matches(RegExp(r'^Scan \d{4}-\d\d-\d\d \d\d-\d\d\.pdf$')),
    );
    expect(saver.path, endsWith('/${saver.fileName}'));
    expect(find.text('Choose where to save...'), findsOneWidget);
    expect(saveButton(), findsNothing);

    saver.outcome.complete(true);
    await pumpUntilFound(tester, find.text('PDF saved.'));
    expect(exportsRemain(), isFalse);
    expect(share.calls, 0);
    expect(saveButton(), findsOneWidget);
  });

  testWidgets('cancelling the picker is a silent no-op', (tester) async {
    final saver = _Saver();
    await pumpHome(tester, saver: saver);
    await tester.tap(saveButton());
    await pumpUntil(tester, () => saver.fileName != null, settle: false);
    saver.outcome.complete(false);
    await pumpUntil(tester, () => !exportsRemain());
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Export PDF (1 page)'), findsOneWidget);
  });

  testWidgets('a failed save shows a generic, actionable message', (
    tester,
  ) async {
    final saver = _Saver();
    await pumpHome(tester, saver: saver);
    await tester.tap(saveButton());
    await pumpUntil(tester, () => saver.fileName != null, settle: false);
    saver.outcome.completeError(
      PlatformException(code: 'save_failed', message: '/data/user/0/x'),
    );
    await pumpUntilFound(
      tester,
      find.text(
        'Could not save the PDF. Try again or choose another location.',
      ),
    );
    expect(find.textContaining('/data'), findsNothing);
    expect(exportsRemain(), isFalse);
  });

  testWidgets('the channel contract reaches MainActivity', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('com.fosscanner.app/ocr');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MethodCall? received;
    var existed = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      existed = File(
        (call.arguments as Map)['sourcePath'] as String,
      ).existsSync();
      return false;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await pumpHome(tester);
    await tester.tap(saveButton());
    await pumpUntil(tester, () => received != null);
    await pumpUntil(tester, () => !exportsRemain());
    debugDefaultTargetPlatformOverride = null;

    expect(received!.method, 'savePdfDocument');
    final args = received!.arguments as Map;
    expect(args.keys, unorderedEquals(['sourcePath', 'fileName']));
    expect(args['sourcePath'], endsWith('/${args['fileName']}'));
    expect(args['sourcePath'], contains(pdfExportDirectoryPrefix));
    expect(existed, isTrue);
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
