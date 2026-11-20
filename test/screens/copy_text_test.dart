import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import '../support/worker_isolates.dart';
import '../support/export_bar.dart';

class _Picker extends ImagePickerPlatform {
  @override
  bool supportsImageSource(ImageSource source) => false;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

const _ocrChannel = MethodChannel('com.fosscanner.app/ocr');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ImagePickerPlatform originalPicker;
  late Uint8List image;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _Picker();
    final data = await rootBundle.load('assets/icon/icon.png');
    image = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    messenger.setMockMethodCallHandler(_ocrChannel, null);
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    int pages = 2,
    bool ocrSupported = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          searchablePdfEnabled: ocrSupported,
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

  Future<void> tapCopyText(WidgetTester tester) async {
    await tester.tap(find.byTooltip('PDF export options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy text'));
  }

  testWidgets(
    'copies the text of every page with progress and a confirmation',
    (tester) async {
      final calls = <MethodCall>[];
      final (started, finish) = (await tester.runAsync(
        () async => (Completer<void>(), Completer<void>()),
      ))!;
      List<String>? pagePaths;
      messenger.setMockMethodCallHandler(_ocrChannel, (call) async {
        calls.add(call);
        if (call.method == 'ensureTessdata') return null;
        pagePaths = ((call.arguments as Map)['imagePaths'] as List)
            .cast<String>();
        for (final path in pagePaths!) {
          expect(File(path).readAsBytesSync(), image);
        }
        started.complete();
        await finish.future;
        return 120;
      });
      await pumpHome(tester);

      await tapCopyText(tester);
      await pumpUntil(tester, () => started.isCompleted, settle: false);
      // Lets the sheet close; the spinner keeps animating until progress.
      await tester.pump(const Duration(seconds: 1));
      expect(pagePaths, hasLength(2));
      expect(find.text('Recognizing text · page 1 of 2'), findsOneWidget);
      // The document is locked like during a PDF export.
      expect(find.byTooltip('PDF export options'), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byTooltip('Delete page 1'),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );

      await messenger.handlePlatformMessage(
        _ocrChannel.name,
        _ocrChannel.codec.encodeMethodCall(
          const MethodCall('ocrProgress', {'completed': 1, 'total': 2}),
        ),
        (_) {},
      );
      await tester.pump();
      expect(find.text('Recognizing text · page 2 of 2'), findsOneWidget);

      finish.complete();
      await pumpUntilFound(tester, find.text('Text copied'));
      expect(calls.map((call) => call.method), [
        'ensureTessdata',
        'copyRecognizedText',
      ]);
      expect(findShareButton(2), findsOneWidget);
      // The page copies written for the native worker are gone.
      expect(File(pagePaths!.first).parent.existsSync(), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'an empty result says no text was found',
    (tester) async {
      messenger.setMockMethodCallHandler(_ocrChannel, (call) async {
        return call.method == 'copyRecognizedText' ? 0 : null;
      });
      await pumpHome(tester, pages: 1);
      await tapCopyText(tester);
      await pumpUntilFound(tester, find.text('No text found'));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'a native failure shows a short message without platform details',
    (tester) async {
      messenger.setMockMethodCallHandler(_ocrChannel, (call) async {
        if (call.method != 'copyRecognizedText') return null;
        throw PlatformException(
          code: 'ocr_failed',
          message: 'OCR operation failed',
        );
      });
      await pumpHome(tester, pages: 1);
      await tapCopyText(tester);
      await pumpUntilFound(tester, find.text('Could not recognize text.'));
      expect(find.textContaining('ocr_failed'), findsNothing);
      expect(find.textContaining('PlatformException'), findsNothing);
      expect(findShareButton(1), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'cancelling stops the native job and copies nothing',
    (tester) async {
      final (started, finish) = (await tester.runAsync(
        () async => (Completer<void>(), Completer<void>()),
      ))!;
      var cancelled = false;
      messenger.setMockMethodCallHandler(_ocrChannel, (call) async {
        switch (call.method) {
          case 'ensureTessdata':
            return null;
          case 'cancelSearchablePdf':
            cancelled = true;
            return null;
        }
        started.complete();
        await finish.future;
        throw PlatformException(code: 'ocr_cancelled');
      });
      await pumpHome(tester, pages: 1);
      await tapCopyText(tester);
      await pumpUntil(tester, () => started.isCompleted, settle: false);
      // Lets the sheet close; the spinner keeps animating until progress.
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      expect(cancelled, isTrue);
      expect(find.text('Canceling…'), findsOneWidget);
      finish.complete();
      await pumpUntilFound(tester, find.text('Text recognition canceled'));
      expect(find.text('Text copied'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('platforms without on-device OCR do not offer Copy text', (
    tester,
  ) async {
    await pumpHome(tester, ocrSupported: false);
    await tester.tap(find.byTooltip('PDF export options'));
    await tester.pumpAndSettle();
    expect(find.text('Copy text'), findsNothing);
  });
}
