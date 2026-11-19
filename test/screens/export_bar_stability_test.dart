import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/app_preferences.dart';
import 'package:fosscanner/services/pdf_export_options.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:share_plus/share_plus.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import '../support/layout_stability.dart';
import '../support/worker_isolates.dart';
import '../support/export_bar.dart';

class _Picker extends ImagePickerPlatform {
  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

class _Share implements SharePlatform {
  Completer<void>? gate;
  var calls = 0;

  @override
  Future<ShareResult> share(ShareParams params) async {
    calls++;
    await gate?.future;
    return const ShareResult('', ShareResultStatus.dismissed);
  }
}

/// Stands in for MainActivity's OCR channel. A non-null [gate] holds the
/// native job until the test completes it.
class _FakeOcr {
  Completer<void>? gate;
  var fail = false;
  var cancelRequested = false;
  var jobs = 0;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'ensureTessdata':
        return null;
      case 'cancelSearchablePdf':
        cancelRequested = true;
        return null;
    }
    jobs++;
    await gate?.future;
    if (cancelRequested) {
      cancelRequested = false;
      throw PlatformException(code: 'ocr_cancelled');
    }
    if (fail) throw PlatformException(code: 'ocr_failed');
    if (call.method == 'copyRecognizedText') return 12;
    final output = File('${(call.arguments as Map)['outputPath']}.pdf');
    await output.writeAsString('%PDF-1.5\nfixture\n%%EOF');
    return output.path;
  }
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
    WidgetTester tester,
    LayoutCase layoutCase, {
    required int pages,
    _Share? share,
    AppPreferences preferences = const AppPreferences(searchablePdf: true),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: withTextScale(layoutCase.textScale),
        home: ScannerHomePage(
          searchablePdfEnabled: true,
          preferencesStore: MemoryAppPreferencesStore(preferences),
          sharePlus: share == null ? null : SharePlus.custom(share),
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

  final bar = find.byKey(const Key('pdf_export_bar'));
  final fab = find.byType(FloatingActionButton);
  final frame = {'export bar': bar, 'camera button': fab};

  void expectRects(
    WidgetTester tester,
    Map<String, Finder> anchors,
    Map<String, Rect> expected,
    String state,
  ) {
    final actual = captureRects(tester, anchors);
    for (final name in anchors.keys) {
      final a = expected[name]!;
      final b = actual[name]!;
      expect(
        (a.left - b.left).abs() <= 0.5 &&
            (a.top - b.top).abs() <= 0.5 &&
            (a.width - b.width).abs() <= 0.5 &&
            (a.height - b.height).abs() <= 0.5,
        isTrue,
        reason: '$state: "$name" moved from $a to $b',
      );
    }
  }

  Future<void> dismissMessages(WidgetTester tester) async {
    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold)),
    ).removeCurrentSnackBar();
    await tester.pumpAndSettle();
  }

  Future<Completer<void>> newGate(WidgetTester tester) async =>
      (await tester.runAsync(() async => Completer<void>()))!;

  testLayoutMatrix(
    'export bar and camera button keep their place for every page count',
    (tester, layoutCase) async {
      final idle = {
        ...frame,
        'save button': find.byTooltip('Save PDF to device'),
        'options button': find.byTooltip('PDF export options'),
      };
      await pumpHome(tester, layoutCase, pages: 1);
      // The options are not the editor's Adjust (tune) icon.
      expect(find.byIcon(Icons.tune_outlined), findsNothing);
      final baseline = captureRects(tester, idle);
      for (final pages in [9, 10, 100]) {
        await pumpHome(tester, layoutCase, pages: pages);
        expect(tester.takeException(), isNull);
        expectRects(tester, idle, baseline, '$pages pages');
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testLayoutMatrix(
    'searchable export reports page preparation in place before OCR',
    (tester, layoutCase) async {
      final ocr = _FakeOcr();
      messenger.setMockMethodCallHandler(_ocrChannel, ocr.handle);
      final share = _Share();
      await pumpHome(
        tester,
        layoutCase,
        pages: 12,
        share: share,
        preferences: const AppPreferences(
          searchablePdf: true,
          pdfPageSize: PdfPageSize.a4,
          pdfQuality: PdfQuality.small,
        ),
      );
      final idle = captureRects(tester, frame);
      ocr.gate = await newGate(tester);
      await tester.tap(find.byIcon(Icons.share_outlined));
      await tester.pump();
      final seen = <String>[];
      await pumpUntil(tester, () {
        final status = find.textContaining('Preparing pages');
        if (status.evaluate().isNotEmpty) {
          seen.add(tester.widget<Text>(status).data!);
          expectRects(tester, frame, idle, 'preparing pages');
          expect(
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
                .onPressed,
            isNotNull,
          );
        }
        return ocr.jobs == 1;
      }, settle: false);
      expect(seen, isNotEmpty);
      for (final status in seen) {
        expect(
          status,
          matches(RegExp(r'^Preparing pages · ([1-9]|1[0-2]) of 12$')),
        );
      }
      // Recognition starts only once every page is prepared.
      expect(find.text('Recognizing text…'), findsOneWidget);
      expectRects(tester, frame, idle, 'recognizing');
      ocr.gate!.complete();
      await pumpUntil(tester, () => share.calls == 1);
      expect(tester.takeException(), isNull);
    },
    cases: const [
      LayoutCase(Size(390, 844), 1.0),
      LayoutCase(Size(412, 915), 2.0),
      LayoutCase(Size(320, 568), 2.0),
    ],
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testLayoutMatrix(
    'export bar and camera button keep their place in every export state',
    (tester, layoutCase) async {
      final ocr = _FakeOcr();
      messenger.setMockMethodCallHandler(_ocrChannel, ocr.handle);
      final share = _Share();
      await pumpHome(tester, layoutCase, pages: 1, share: share);
      final idle = captureRects(tester, frame);
      void expectFrame(String state) => expectRects(tester, frame, idle, state);
      Future<void> startExport() async {
        await tester.tap(find.byIcon(Icons.share_outlined));
        await tester.pump();
      }

      // Generating, with progress, then cancelling.
      ocr.gate = await newGate(tester);
      await startExport();
      await pumpUntil(tester, () => ocr.jobs == 1, settle: false);
      expect(find.text('Recognizing text…'), findsOneWidget);
      double? ring() => tester
          .widget<CircularProgressIndicator>(
            find.descendant(
              of: bar,
              matching: find.byType(CircularProgressIndicator),
            ),
          )
          .value;
      // Spinning until the first page is done, never an empty ring.
      expect(ring(), isNull);
      expectFrame('generating');
      await messenger.handlePlatformMessage(
        _ocrChannel.name,
        _ocrChannel.codec.encodeMethodCall(
          const MethodCall('ocrProgress', {'completed': 1, 'total': 3}),
        ),
        (_) {},
      );
      await tester.pump();
      expect(find.text('Recognizing text · page 2 of 3'), findsOneWidget);
      expect(ring(), closeTo(1 / 3, 1e-9));
      expectFrame('generating with progress');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      expect(find.text('Canceling…'), findsOneWidget);
      expectFrame('cancelling');
      ocr.gate!.complete();
      await pumpUntilFound(tester, find.text('Export canceled'));
      await dismissMessages(tester);
      expectFrame('idle after cancel');

      // Sharing.
      ocr.gate = null;
      share.gate = await newGate(tester);
      await startExport();
      await pumpUntilFound(
        tester,
        find.text('Opening share sheet…'),
        settle: false,
      );
      expectFrame('sharing');
      share.gate!.complete();
      await pumpUntilFound(tester, find.byIcon(Icons.share_outlined));
      expectFrame('idle after sharing');

      // Preparing: the OCR job failed and the fallback is being offered.
      ocr.fail = true;
      await startExport();
      await pumpUntilFound(
        tester,
        find.text('Searchable export failed'),
        settle: false,
      );
      expect(find.text('Preparing PDF…'), findsOneWidget);
      expectFrame('preparing');
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expectFrame('idle after declining the fallback');

      // Copying text, then cancelling it.
      ocr.fail = false;
      ocr.gate = await newGate(tester);
      await tester.tap(find.byTooltip('PDF export options'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Copy text'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy text'));
      await pumpUntil(tester, () => ocr.jobs == 4, settle: false);
      // Lets the sheet close; the spinner keeps animating until progress.
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Recognizing text…'), findsOneWidget);
      expectFrame('recognizing text');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      expect(find.text('Canceling…'), findsOneWidget);
      expectFrame('canceling text recognition');
      ocr.gate!.complete();
      await pumpUntilFound(tester, find.text('Text recognition canceled'));
      await dismissMessages(tester);
      expectFrame('idle after text recognition');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Cancel keeps its slot for the whole job and is off while preparing',
    (tester) async {
      final ocr = _FakeOcr()..fail = true;
      messenger.setMockMethodCallHandler(_ocrChannel, ocr.handle);
      await pumpHome(tester, layoutMatrix.first, pages: 1, share: _Share());
      await tester.tap(find.byIcon(Icons.share_outlined));
      await pumpUntilFound(
        tester,
        find.text('Searchable export failed'),
        settle: false,
      );
      final cancel = find.descendant(
        of: bar,
        matching: find.widgetWithText(TextButton, 'Cancel'),
      );
      expect(tester.widget<TextButton>(cancel).onPressed, isNull);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(cancel, findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'the label wraps to two lines at most',
    (tester) async {
      applyLayoutCase(tester, const LayoutCase(Size(320, 568), 2.0));
      await pumpHome(tester, const LayoutCase(Size(320, 568), 2.0), pages: 100);
      expect(findShareButton(100, searchable: true), findsOneWidget);
      final label = tester.widget<Text>(find.text('Share PDF'));
      expect(label.maxLines, 2);
      expect(label.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'system Back does nothing while an export runs',
    (tester) async {
      final ocr = _FakeOcr()..gate = await newGate(tester);
      messenger.setMockMethodCallHandler(_ocrChannel, ocr.handle);
      final exits = <MethodCall>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemNavigator.pop') exits.add(call);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      Future<void> pressBack() async {
        await messenger.handlePlatformMessage(
          SystemChannels.navigation.name,
          SystemChannels.navigation.codec.encodeMethodCall(
            const MethodCall('popRoute'),
          ),
          (_) {},
        );
        await tester.pump();
      }

      await pumpHome(tester, layoutMatrix.first, pages: 1, share: _Share());
      await tester.tap(find.byIcon(Icons.share_outlined));
      await pumpUntil(tester, () => ocr.jobs == 1, settle: false);
      await pressBack();
      expect(exits, isEmpty);
      expect(find.text('Recognizing text…'), findsOneWidget);

      ocr.gate!.complete();
      await pumpUntilFound(tester, find.byIcon(Icons.share_outlined));
      await pressBack();
      expect(exits, hasLength(1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
