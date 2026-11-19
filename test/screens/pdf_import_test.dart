import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/app_preferences.dart';
import 'package:fosscanner/services/draft_store.dart';
import 'package:fosscanner/services/image_metadata.dart';
import 'package:fosscanner/services/pdf_export_options.dart';
import 'package:fosscanner/services/pdf_page_importer.dart';

const _corners = [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)];

/// Stands in for MainActivity's pdf_import channel: hands out pre-rendered
/// files and deletes them itself when cancelled, like the native worker.
class _FakePdfImporter implements PdfPageImporter {
  bool pickResult = true;
  var pickCalls = 0;
  var cancelCalls = 0;
  final requests = <PdfImportRequest>[];
  PdfImportBatch batch = const PdfImportBatch();
  Object? error;
  Completer<PdfImportBatch>? pending;
  void Function(int completed, int total)? onProgress;

  @override
  Future<bool> pickDocument() async {
    pickCalls++;
    return pickResult;
  }

  @override
  Future<PdfImportBatch> renderPages(
    PdfImportRequest request, {
    void Function(int completed, int total)? onProgress,
  }) async {
    requests.add(request);
    this.onProgress = onProgress;
    final waiting = pending;
    if (waiting != null) return waiting.future;
    final failure = error;
    if (failure != null) throw failure;
    return batch;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    pending?.completeError(
      const PdfImportException(PdfImportFailure.cancelled),
    );
  }
}

class _Store implements DraftStore {
  Completer<List<ScannedPage>>? _loaded;
  Completer<List<ScannedPage>> get loaded => _loaded ??= Completer();
  final saves = <List<ScannedPage>>[];
  var clearCalls = 0;

  @override
  Future<List<ScannedPage>> load() => loaded.future;

  @override
  Future<void> save(List<ScannedPage> pages) async => saves.add(List.of(pages));

  @override
  Future<void> clear() async => clearCalls++;
}

class _Operations implements CornerAdjustOperations {
  var detectCalls = 0;

  @override
  Future<Size> decodeSize(Uint8List bytes) async => const Size(100, 100);

  @override
  Future<List<Offset>?> detectCorners(Uint8List bytes) async {
    detectCalls++;
    return _corners;
  }

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

final _iOS = TargetPlatformVariant.only(TargetPlatform.iOS);

void main() {
  late _FakePdfImporter importer;
  late _Store store;
  late _Operations operations;
  late Directory directory;
  late Uint8List bytes;
  var fileCount = 0;

  setUp(() async {
    importer = _FakePdfImporter();
    store = _Store();
    operations = _Operations();
    directory = Directory.systemTemp.createTempSync('pdf-import-');
    final data = await rootBundle.load('assets/icon/icon.png');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  tearDown(() => directory.deleteSync(recursive: true));

  List<File> renderedPages(int count) => [
    for (var i = 0; i < count; i++)
      File('${directory.path}/page_${fileCount++}.jpg')
        ..writeAsBytesSync(bytes),
  ];

  PdfImportBatch batchOf(
    List<File> files, {
    int? pageCount,
    int rejected = 0,
    bool truncated = false,
  }) => PdfImportBatch(
    paths: [for (final file in files) file.path],
    pageCount: pageCount ?? files.length,
    rejected: rejected,
    truncated: truncated,
  );

  ScannedPage savedPage() => ScannedPage(
    originalBytes: bytes,
    corners: _corners,
    processedBytes: bytes,
  );

  Future<void> pumpHome(
    WidgetTester tester, {
    List<ScannedPage> initialPages = const [],
    bool withImporter = true,
    AppPreferences preferences = const AppPreferences(),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          draftStore: store,
          initialPages: initialPages,
          searchablePdfEnabled: false,
          cornerAdjustOperations: operations,
          sourceImageSizeReader: (_) async => const Size(100, 100),
          pdfPageImporter: withImporter ? importer : null,
          preferencesStore: MemoryAppPreferencesStore(preferences),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpFrames(WidgetTester tester, [int count = 10]) async {
    for (var i = 0; i < count; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    await pumpFrames(tester);
    await tester.pumpAndSettle();
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
  }

  Future<void> startImport(WidgetTester tester) async {
    await openMenu(tester);
    await tester.tap(find.text('Import from PDF'));
    // The progress dialog animates indeterminately; never pumpAndSettle here.
    await pumpFrames(tester, 4);
  }

  Future<CornerAdjustScreen> waitForEditor(
    WidgetTester tester, {
    CornerAdjustScreen? previous,
  }) async {
    for (var i = 0; i < 100; i++) {
      final editors = find.byType(CornerAdjustScreen);
      if (editors.evaluate().length == 1 &&
          !identical(tester.widget<CornerAdjustScreen>(editors), previous) &&
          find.text('Preview page').evaluate().isNotEmpty) {
        await tester.pumpAndSettle();
        return tester.widget<CornerAdjustScreen>(editors);
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    fail('Expected a review route');
  }

  Future<void> accept(WidgetTester tester) async {
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add page'));
    await tester.pumpAndSettle();
  }

  testWidgets('a multi-page PDF is reviewed page by page as full-page crops', (
    tester,
  ) async {
    final files = renderedPages(3);
    importer.batch = batchOf(files);
    await pumpHome(tester);
    store.loaded.complete([]);
    await settle(tester);

    await startImport(tester);
    var editor = await waitForEditor(tester);
    expect(importer.pickCalls, 1);
    final request = importer.requests.single;
    expect(request.dpi, 300);
    expect(request.maxPages, maxDocumentPages);
    expect(request.maxPagePixels, maxSourceImagePixels);
    expect(request.maxTotalBytes, maxRetainedDocumentBytes);

    expect(editor.source, PageReviewSource.pdf);
    expect(editor.detectPageEdges, isFalse);
    expect(find.text('Image 1 of 3'), findsOneWidget);
    expect(find.text('Skip image'), findsOneWidget);
    expect(find.byTooltip('Stop importing'), findsOneWidget);
    // A PDF page is not a failed detection.
    expect(
      find.text('No page edges detected. Full image selected.'),
      findsNothing,
    );
    expect(files.first.existsSync(), isFalse);

    for (var page = 1; page <= 3; page++) {
      if (page > 1) {
        editor = await waitForEditor(tester, previous: editor);
        expect(find.text('Image $page of 3'), findsOneWidget);
      }
      await accept(tester);
    }
    await settle(tester);

    expect(operations.detectCalls, 0);
    expect(find.byType(CornerAdjustScreen), findsNothing);
    expect(find.text('Export PDF (3 pages)'), findsOneWidget);
    expect(store.saves.last, hasLength(3));
    expect(files.every((file) => !file.existsSync()), isTrue);
  }, variant: _iOS);

  testWidgets('the quality preset sets the render density', (tester) async {
    importer.batch = const PdfImportBatch();
    await pumpHome(
      tester,
      preferences: const AppPreferences(pdfQuality: PdfQuality.small),
    );
    store.loaded.complete([]);
    await settle(tester);
    await startImport(tester);
    await settle(tester);
    expect(importer.requests.single.dpi, 150);
    expect(importer.requests.single.jpegQuality, 85);
  }, variant: _iOS);

  testWidgets('Skip image skips one page and Stop keeps accepted pages', (
    tester,
  ) async {
    final files = renderedPages(4);
    importer.batch = batchOf(files);
    await pumpHome(tester);
    store.loaded.complete([]);
    await settle(tester);

    await startImport(tester);
    final first = await waitForEditor(tester);
    await tester.tap(find.text('Skip image'));
    await tester.pumpAndSettle();
    final second = await waitForEditor(tester, previous: first);
    expect(find.text('Image 2 of 4'), findsOneWidget);
    await accept(tester);
    await waitForEditor(tester, previous: second);
    expect(find.text('Image 3 of 4'), findsOneWidget);
    await tester.tap(find.byTooltip('Stop importing'));
    await settle(tester);

    expect(find.byType(CornerAdjustScreen), findsNothing);
    expect(find.text('Export PDF (1 page)'), findsOneWidget);
    expect(
      find.text(
        'Import stopped. Pages already added were kept; the remaining '
        'pages were not added.',
      ),
      findsOneWidget,
    );
    expect(files.every((file) => !file.existsSync()), isTrue);
  }, variant: _iOS);

  testWidgets('the page limit stops the review with the existing message', (
    tester,
  ) async {
    final files = renderedPages(2);
    importer.batch = batchOf(files, pageCount: 5, truncated: true);
    await pumpHome(
      tester,
      initialPages: List.generate(maxDocumentPages - 1, (_) => savedPage()),
    );
    await startImport(tester);
    await waitForEditor(tester);
    expect(importer.requests.single.maxPages, 1);
    expect(find.text('Image 1 of 2'), findsOneWidget);
    await accept(tester);
    await settle(tester);

    expect(find.byType(CornerAdjustScreen), findsNothing);
    expect(find.text('Export PDF ($maxDocumentPages pages)'), findsOneWidget);
    expect(
      find.textContaining('reached the $maxDocumentPages-page limit'),
      findsOneWidget,
    );
    expect(find.textContaining('Some PDF pages'), findsNothing);
    expect(files.every((file) => !file.existsSync()), isTrue);
  }, variant: _iOS);

  testWidgets('pages left out by the native page cap are reported', (
    tester,
  ) async {
    importer.batch = batchOf(renderedPages(1), pageCount: 5, truncated: true);
    await pumpHome(
      tester,
      initialPages: List.generate(maxDocumentPages - 1, (_) => savedPage()),
    );
    await startImport(tester);
    await waitForEditor(tester);
    expect(find.text('Cancel'), findsOneWidget);
    await accept(tester);
    await settle(tester);
    expect(
      find.text(
        'Some PDF pages were not added: a document can have up to '
        '$maxDocumentPages pages.',
      ),
      findsOneWidget,
    );
  }, variant: _iOS);

  testWidgets('a full document disables PDF import and intake help explains', (
    tester,
  ) async {
    await pumpHome(
      tester,
      initialPages: List.generate(maxDocumentPages, (_) => savedPage()),
    );
    await openMenu(tester);
    final item = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Import from PDF'),
    );
    expect(item.enabled, isFalse);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    expect(importer.pickCalls, 0);

    await tester.tap(find.text('Image intake help'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('reached the $maxDocumentPages-page limit'),
      findsOneWidget,
    );
  }, variant: _iOS);

  testWidgets('rendering shows cancellable progress in a dialog', (
    tester,
  ) async {
    importer.pending = Completer<PdfImportBatch>();
    await pumpHome(tester);
    store.loaded.complete([]);
    await settle(tester);
    final emptyState = tester.getRect(find.text('Ready to scan'));

    await startImport(tester);
    expect(find.text('Importing PDF'), findsOneWidget);
    expect(find.text('Opening PDF...'), findsOneWidget);
    importer.onProgress!(0, 3);
    await tester.pump();
    expect(find.text('Rendering page 1 of 3'), findsOneWidget);
    importer.onProgress!(1, 3);
    await tester.pump();
    expect(find.text('Rendering page 2 of 3'), findsOneWidget);
    // The dialog overlays the screen; nothing behind it moves.
    expect(tester.getRect(find.text('Ready to scan')), emptyState);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await settle(tester);
    expect(importer.cancelCalls, 1);
    expect(find.text('Importing PDF'), findsNothing);
    expect(find.byType(CornerAdjustScreen), findsNothing);
    expect(find.text('PDF import cancelled.'), findsOneWidget);

    // Intake is released afterwards.
    importer.pending = null;
    await startImport(tester);
    await settle(tester);
    expect(importer.pickCalls, 2);
  }, variant: _iOS);

  testWidgets('Back on the progress dialog cancels too', (tester) async {
    importer.pending = Completer<PdfImportBatch>();
    await pumpHome(tester);
    store.loaded.complete([]);
    await settle(tester);
    await startImport(tester);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Cancelling...'), findsOneWidget);
    await settle(tester);
    expect(importer.cancelCalls, 1);
    expect(find.text('Importing PDF'), findsNothing);
  }, variant: _iOS);

  testWidgets('an unreadable PDF shows a short message', (tester) async {
    importer.error = const PdfImportException(PdfImportFailure.unreadable);
    await pumpHome(tester);
    store.loaded.complete([]);
    await settle(tester);
    await startImport(tester);
    await settle(tester);
    expect(find.text("This PDF can't be opened."), findsOneWidget);
    expect(find.text('Importing PDF'), findsNothing);
    expect(find.byType(CornerAdjustScreen), findsNothing);
  }, variant: _iOS);

  testWidgets('other failures show a generic message', (tester) async {
    importer.error = const PdfImportException(PdfImportFailure.failed);
    await pumpHome(tester);
    store.loaded.complete([]);
    await settle(tester);
    await startImport(tester);
    await settle(tester);
    expect(find.text('Could not import the PDF.'), findsOneWidget);
  }, variant: _iOS);

  testWidgets('rejected pages are explained and the rest reviewed', (
    tester,
  ) async {
    importer.batch = batchOf(renderedPages(1), pageCount: 3, rejected: 2);
    await pumpHome(tester);
    store.loaded.complete([]);
    await settle(tester);
    await startImport(tester);
    await waitForEditor(tester);
    await accept(tester);
    await settle(tester);
    expect(find.text('Export PDF (1 page)'), findsOneWidget);
    expect(
      find.text("2 of 3 pages couldn't be added: 2 too large to render."),
      findsOneWidget,
    );
  }, variant: _iOS);

  testWidgets('cancelling the picker renders nothing', (tester) async {
    importer.pickResult = false;
    await pumpHome(tester);
    store.loaded.complete([]);
    await settle(tester);
    await startImport(tester);
    await settle(tester);
    expect(importer.pickCalls, 1);
    expect(importer.requests, isEmpty);
    expect(find.text('Importing PDF'), findsNothing);
  }, variant: _iOS);

  testWidgets('a failed draft restore keeps PDF import unavailable', (
    tester,
  ) async {
    importer.batch = batchOf(renderedPages(1));
    await pumpHome(tester);
    store.loaded.completeError(const DraftRestoreException());
    await settle(tester);
    expect(find.text('Could not restore the saved draft'), findsOneWidget);
    // The restore-failure screen offers no intake, PDF import included.
    expect(find.byTooltip('More options'), findsNothing);
    expect(importer.pickCalls, 0);

    await tester.tap(find.text('Discard saved draft'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Discard draft'));
    await settle(tester);
    expect(store.clearCalls, 1);

    await startImport(tester);
    final editor = await waitForEditor(tester);
    expect(editor.source, PageReviewSource.pdf);
    expect(store.saves, isEmpty);
  }, variant: _iOS);

  testWidgets('renders finishing after the screen is gone are deleted', (
    tester,
  ) async {
    final files = renderedPages(2);
    importer.pending = Completer<PdfImportBatch>();
    await pumpHome(tester, initialPages: [savedPage()]);
    await startImport(tester);
    expect(find.text('Importing PDF'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    importer.pending!.complete(batchOf(files));
    await pumpFrames(tester);
    expect(files.every((file) => !file.existsSync()), isTrue);
  }, variant: _iOS);

  testWidgets('platforms without an importer do not offer the action', (
    tester,
  ) async {
    await pumpHome(tester, withImporter: false);
    store.loaded.complete([]);
    await settle(tester);
    await openMenu(tester);
    expect(find.text('Import from PDF'), findsNothing);
    expect(find.text('About FOSScanner'), findsOneWidget);
  }, variant: _iOS);
}
