import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/draft_store.dart';
import 'package:fosscanner/services/pdf_page_importer.dart';
import 'package:fosscanner/services/shared_image_inbox.dart';

const _corners = [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)];
final _iOS = TargetPlatformVariant.only(TargetPlatform.iOS);

class _Inbox implements SharedImageInbox {
  VoidCallback? listener;
  SharedImageBatch? batch;
  Completer<SharedImageBatch>? pending;

  @override
  void setListener(VoidCallback? onAvailable) => listener = onAvailable;

  @override
  Future<SharedImageBatch> take({required int maxCount}) async {
    if (pending case final waiting?) return waiting.future;
    final taken = batch ?? const SharedImageBatch();
    batch = null;
    return taken;
  }
}

class _PdfImporter implements PdfPageImporter {
  PdfImportBatch batch = const PdfImportBatch();

  @override
  Future<bool> pickDocument() async => true;

  @override
  Future<PdfImportBatch> renderPages(
    PdfImportRequest request, {
    void Function(int completed, int total)? onProgress,
  }) async => batch;

  @override
  Future<void> cancel() async {}
}

class _Store implements DraftStore {
  @override
  Future<List<ScannedPage>> load() async => const [];

  @override
  Future<void> save(List<ScannedPage> pages) async {}

  @override
  Future<void> clear() async {}
}

class _Picker extends ImagePickerPlatform {
  List<XFile> galleryPhotos = [];
  Completer<List<XFile>>? pendingGallery;
  List<XFile> recoveredPhotos = [];

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => await pendingGallery?.future ?? galleryPhotos;

  @override
  Future<LostDataResponse> getLostData() async => recoveredPhotos.isEmpty
      ? LostDataResponse.empty()
      : LostDataResponse(files: recoveredPhotos);
}

/// A file whose declared length is over the per-image limit.
class _OversizedXFile extends XFile {
  _OversizedXFile(super.path);

  @override
  Future<int> length() async => 40 * 1024 * 1024;
}

class _Operations implements CornerAdjustOperations {
  @override
  Future<Size> decodeSize(Uint8List bytes) async => const Size(100, 100);

  @override
  Future<List<Offset>?> detectCorners(Uint8List bytes) async => _corners;

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List bytes,
    List<Offset> corners,
  ) async => {for (final filter in PageFilter.values) filter: bytes};

  @override
  Future<Uint8List> buildFinalPreview(
    Uint8List bytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async => bytes;

  @override
  Future<Uint8List> processForExport(
    Uint8List bytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async => bytes;
}

void main() {
  late ImagePickerPlatform originalPicker;
  late _Picker picker;
  late _Inbox inbox;
  late _PdfImporter importer;
  late Directory directory;
  late Uint8List validBytes;
  final tinyBytes = img.encodePng(img.Image(width: 2, height: 2));
  final notImageBytes = Uint8List.fromList('not an image, just text'.codeUnits);
  var fileCount = 0;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = picker = _Picker();
    inbox = _Inbox();
    importer = _PdfImporter();
    directory = Directory.systemTemp.createTempSync('intake-summary-');
    final data = await rootBundle.load('assets/icon/icon.png');
    validBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    directory.deleteSync(recursive: true);
  });

  String file(List<int> bytes) => (File(
    '${directory.path}/item_${fileCount++}.img',
  )..writeAsBytesSync(bytes)).path;

  String valid() => file(validBytes);
  String tiny() => file(tinyBytes);
  String notImage() => file(notImageBytes);

  Future<void> pumpHome(
    WidgetTester tester, {
    List<ScannedPage> initialPages = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: initialPages,
          draftStore: _Store(),
          searchablePdfEnabled: false,
          cornerAdjustOperations: _Operations(),
          sourceImageSizeReader: (_) async => const Size(100, 100),
          sharedImageInbox: inbox,
          pdfPageImporter: importer,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<void> waitForEditor(WidgetTester tester, String progress) async {
    for (var i = 0; i < 100; i++) {
      if (find.text(progress).evaluate().isNotEmpty &&
          find.text('Preview page').evaluate().isNotEmpty) {
        await tester.pumpAndSettle();
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    fail('Expected the review of "$progress"');
  }

  Future<void> accept(WidgetTester tester) async {
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add page'));
    await tester.pumpAndSettle();
  }

  /// The only message on screen, which must be [message].
  void expectOnlyMessage(String message) {
    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.descendant(of: find.byType(SnackBar), matching: find.text(message)),
      findsOneWidget,
    );
  }

  testWidgets('a gallery batch reports skipped images once, after the review', (
    tester,
  ) async {
    picker.galleryPhotos = [
      XFile(tiny()),
      XFile(notImage()),
      XFile(valid()),
      XFile(valid()),
    ];
    await pumpHome(tester);
    await settle(tester);
    await tester.tap(find.byTooltip('Import from gallery'));
    // Images 1 and 2 are rejected before review, so the first review is
    // image 3 — the emulator's "Image 3 of 4" — and nothing covers it.
    await waitForEditor(tester, 'Image 3 of 4');
    expect(find.byType(SnackBar), findsNothing);
    await accept(tester);
    await waitForEditor(tester, 'Image 4 of 4');
    await accept(tester);
    await settle(tester);

    expect(find.byType(CornerAdjustScreen), findsNothing);
    expect(find.text('Export PDF (2 pages)'), findsOneWidget);
    expectOnlyMessage(
      "2 of 4 images couldn't be added: 1 unsupported size, "
      '1 not an image.',
    );
  }, variant: _iOS);

  testWidgets('a share mixing unusable items reports every one of them', (
    tester,
  ) async {
    inbox.batch = SharedImageBatch(
      paths: [tiny(), notImage()],
      // The platform could not read one shared item at all.
      rejected: 1,
    );
    await pumpHome(tester);
    await settle(tester);

    expect(find.byType(CornerAdjustScreen), findsNothing);
    expectOnlyMessage(
      "3 images couldn't be added: 1 unsupported size, 1 not an image, "
      '1 unreadable file.',
    );
  }, variant: _iOS);

  testWidgets(
    'stopping a share after a rejection reports both in one message',
    (tester) async {
      inbox.batch = SharedImageBatch(paths: [notImage(), valid(), valid()]);
      await pumpHome(tester);
      await waitForEditor(tester, 'Image 2 of 3');
      await tester.tap(find.byTooltip('Stop importing'));
      await settle(tester);

      expectOnlyMessage(
        "1 of 3 images couldn't be added: 1 not an image. Import stopped. "
        'Pages already added were kept; the remaining images were not '
        'added.',
      );
    },
    variant: _iOS,
  );

  testWidgets('a PDF with unrendered and unreadable pages gets one summary', (
    tester,
  ) async {
    importer.batch = PdfImportBatch(
      paths: [notImage(), valid()],
      pageCount: 3,
      rejected: 1,
    );
    await pumpHome(tester);
    await settle(tester);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from PDF'));
    await waitForEditor(tester, 'Image 2 of 2');
    await accept(tester);
    await settle(tester);

    expect(find.text('Export PDF (1 page)'), findsOneWidget);
    expectOnlyMessage(
      "2 of 3 pages couldn't be added: 1 not an image, "
      '1 too large to render.',
    );
  }, variant: _iOS);

  testWidgets(
    'recovered images report what could not be added',
    (tester) async {
      picker.recoveredPhotos = [XFile(tiny()), XFile(valid())];
      await pumpHome(tester);
      await waitForEditor(tester, 'Image 2 of 2');
      await accept(tester);
      await settle(tester);

      expect(find.text('Export PDF (1 page)'), findsOneWidget);
      expectOnlyMessage("1 of 2 images couldn't be added: 1 unsupported size.");
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('a single unsupported image gets the detailed explanation', (
    tester,
  ) async {
    picker.galleryPhotos = [XFile(tiny())];
    await pumpHome(tester);
    await settle(tester);
    await tester.tap(find.byTooltip('Import from gallery'));
    await settle(tester);

    expectOnlyMessage(
      'This image is too small or has unsupported dimensions. '
      'Choose another image, or resize a large image and try again.',
    );
  }, variant: _iOS);

  // #91: every way a batch item is not added has a reason.
  ScannedPage page([Uint8List? bytes]) => ScannedPage(
    originalBytes: bytes ?? validBytes,
    processedBytes: bytes ?? validBytes,
    corners: const [],
  );

  Future<void> clearAllPages(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear all pages'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await settle(tester);
  }

  testWidgets(
    'unreadable and oversized files are reported and logged without paths',
    (tester) async {
      final logs = <String>[];
      final DebugPrintCallback originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');

      picker.galleryPhotos = [
        XFile('${directory.path}/missing.png'),
        _OversizedXFile(valid()),
        XFile(valid()),
      ];
      await pumpHome(tester);
      await settle(tester);
      await tester.tap(find.byTooltip('Import from gallery'));
      await waitForEditor(tester, 'Image 3 of 3');
      await accept(tester);
      await settle(tester);

      // Restored before the test ends, which checks debug variables.
      debugPrint = originalDebugPrint;
      expectOnlyMessage(
        "2 of 3 images couldn't be added: 1 unreadable file, "
        '1 file over 32 MB.',
      );
      expect(logs, contains('Intake gallery 1/3: unreadable.'));
      expect(logs, contains('Intake gallery 2/3: fileTooLarge.'));
      expect(logs.where((line) => line.contains(directory.path)), isEmpty);
    },
    variant: _iOS,
  );

  testWidgets('images that need too much memory to process are reported', (
    tester,
  ) async {
    // 250 MB of retained page storage leaves no processing headroom.
    final storage = Uint8List(50 * 5 * 1024 * 1024)
      ..setRange(0, validBytes.length, validBytes);
    final retained = Uint8List.sublistView(storage, 0, validBytes.length);
    picker.galleryPhotos = [XFile(valid()), XFile(valid())];
    await pumpHome(tester, initialPages: List.filled(50, page(retained)));
    await settle(tester);
    await tester.tap(find.byTooltip('Import from gallery'));
    await settle(tester);

    expect(find.byType(CornerAdjustScreen), findsNothing);
    expectOnlyMessage("2 images couldn't be added: 2 too large to process.");
  }, variant: _iOS);

  testWidgets(
    'clearing the pages while the gallery is open cancels with a reason',
    (tester) async {
      picker.pendingGallery = Completer();
      await pumpHome(tester, initialPages: [page()]);
      await settle(tester);
      await tester.tap(find.byTooltip('Import from gallery'));
      await tester.pump();
      await clearAllPages(tester);
      picker.pendingGallery!.complete([XFile(valid()), XFile(valid())]);
      await settle(tester);

      expect(find.byType(CornerAdjustScreen), findsNothing);
      expectOnlyMessage('Import cancelled because the pages were cleared.');
    },
    variant: _iOS,
  );

  testWidgets(
    'clearing the pages while a share is being read discards it with a '
    'reason',
    (tester) async {
      inbox.pending = Completer();
      await pumpHome(tester, initialPages: [page()]);
      await settle(tester);
      await clearAllPages(tester);
      final shared = valid();
      inbox.pending!.complete(SharedImageBatch(paths: [shared]));
      await settle(tester);

      expect(find.byType(CornerAdjustScreen), findsNothing);
      expectOnlyMessage('Import cancelled because the pages were cleared.');
      expect(File(shared).existsSync(), isFalse);
    },
    variant: _iOS,
  );

  testWidgets('skipping an image is the user\'s choice, not a rejection', (
    tester,
  ) async {
    picker.galleryPhotos = [XFile(valid()), XFile(valid())];
    await pumpHome(tester);
    await settle(tester);
    await tester.tap(find.byTooltip('Import from gallery'));
    await waitForEditor(tester, 'Image 1 of 2');
    await tester.tap(find.text('Skip image'));
    await waitForEditor(tester, 'Image 2 of 2');
    await accept(tester);
    await settle(tester);

    expect(find.text('Export PDF (1 page)'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  }, variant: _iOS);
}
