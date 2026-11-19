import 'dart:io';

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

  @override
  void setListener(VoidCallback? onAvailable) => listener = onAvailable;

  @override
  Future<SharedImageBatch> take({required int maxCount}) async {
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
  List<XFile> recoveredPhotos = [];

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => galleryPhotos;

  @override
  Future<LostDataResponse> getLostData() async => recoveredPhotos.isEmpty
      ? LostDataResponse.empty()
      : LostDataResponse(files: recoveredPhotos);
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

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
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
}
