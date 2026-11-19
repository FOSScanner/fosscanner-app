import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/draft_store.dart';
import 'package:fosscanner/services/review_journal.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

final _iOS = TargetPlatformVariant.only(TargetPlatform.iOS);

/// The real journal in a temporary folder, recording what the screen did.
class _Journal extends FileReviewJournal {
  _Journal(Directory directory) : super(directory: directory);

  final noted = <(String, int)>[];
  final keptSources = <String>[];
  var clears = 0;

  @override
  Future<List<String>> keep(String source, List<String> paths) {
    keptSources.add(source);
    return super.keep(source, paths);
  }

  @override
  Future<void> notePending(String source, int count) {
    noted.add((source, count));
    return super.notePending(source, count);
  }

  @override
  Future<void> clear() {
    clears++;
    return super.clear();
  }
}

class _Store implements DraftStore {
  // Created in the test's zone, so a failed restore is not an uncaught error.
  Completer<List<ScannedPage>>? _loaded;
  Completer<List<ScannedPage>> get loaded => _loaded ??= Completer();

  @override
  Future<List<ScannedPage>> load() => loaded.future;

  @override
  Future<void> save(List<ScannedPage> pages) async {}

  @override
  Future<void> clear() async {}
}

class _Picker extends ImagePickerPlatform {
  List<XFile> gallery = const [];
  XFile? camera;

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => gallery;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    final result = camera;
    camera = null;
    return result;
  }
}

class _Operations implements CornerAdjustOperations {
  @override
  Future<Size> decodeSize(Uint8List imageBytes) async => const Size(100, 100);

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async => null;

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List imageBytes,
    List<Offset> corners,
  ) async => {for (final filter in PageFilter.values) filter: imageBytes};

  @override
  Future<Uint8List> buildFinalPreview(
    Uint8List imageBytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async => imageBytes;

  @override
  Future<Uint8List> processForExport(
    Uint8List imageBytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async => imageBytes;
}

void main() {
  late Directory temp;
  late Directory cache;
  late _Journal journal;
  late _Store store;
  late _Picker picker;
  late ImagePickerPlatform originalPicker;
  late Uint8List bytes;
  var fileCount = 0;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('interrupted_review_test');
    cache = Directory('${temp.path}/cache')..createSync();
    journal = _Journal(Directory('${temp.path}/draft/review'));
    store = _Store();
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = picker = _Picker();
    final data = await rootBundle.load('assets/icon/icon.png');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    temp.deleteSync(recursive: true);
  });

  String image() => (File(
    '${cache.path}/image_${fileCount++}.png',
  )..writeAsBytesSync(bytes)).path;

  Future<void> frames(WidgetTester tester, [int count = 10]) async {
    for (var i = 0; i < count; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    await frames(tester);
    await tester.pumpAndSettle();
  }

  /// Lets real file I/O finish until [finder] matches something.
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
      await frames(tester, 1);
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          draftStore: store,
          searchablePdfEnabled: false,
          cornerAdjustOperations: _Operations(),
          sourceImageSizeReader: (_) async => const Size(100, 100),
          reviewJournal: journal,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> waitForEditor(WidgetTester tester, String text) async {
    for (var i = 0; i < 100; i++) {
      if (find.text(text).evaluate().isNotEmpty &&
          find.text('Preview page').evaluate().isNotEmpty) {
        await tester.pumpAndSettle();
        return;
      }
      await frames(tester, 1);
    }
    fail('Expected the review of "$text"');
  }

  Future<void> accept(WidgetTester tester) async {
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add page'));
    await tester.pumpAndSettle();
  }

  bool journalExists() => Directory('${temp.path}/draft/review').existsSync();

  /// Whether the journal folder is gone once pending file I/O has finished.
  Future<bool> journalGone(WidgetTester tester) async {
    for (var i = 0; i < 50 && journalExists(); i++) {
      await frames(tester, 1);
    }
    return !journalExists();
  }

  group('a killed review', () {
    testWidgets('is offered after the draft is restored and continues', (
      tester,
    ) async {
      final kept = await tester.runAsync(
        () => journal.keep('shared', [image(), image(), image()]),
      );
      await tester.runAsync(() => journal.release(kept![0]));
      await pumpHome(tester);
      await frames(tester);
      // Draft restore gates the offer.
      expect(find.text('Continue reviewing 2 images?'), findsNothing);
      store.loaded.complete([]);
      await waitFor(tester, find.byType(AlertDialog));

      expect(find.text('Continue reviewing 2 images?'), findsOneWidget);
      expect(
        find.text('The app closed before they were added.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Continue'));
      await waitForEditor(tester, 'Image 1 of 2');
      expect(
        tester
            .widget<CornerAdjustScreen>(find.byType(CornerAdjustScreen))
            .source,
        PageReviewSource.shared,
      );
      await accept(tester);
      await waitForEditor(tester, 'Image 2 of 2');
      await accept(tester);
      await waitFor(tester, find.text('Export 2 pages as PDF'));

      expect(find.text('Export 2 pages as PDF'), findsOneWidget);
      // Nothing is left on disk once the review is over.
      expect(await journalGone(tester), isTrue);
    }, variant: _iOS);

    testWidgets('can be discarded, deleting the kept images', (tester) async {
      final kept = (await tester.runAsync(
        () => journal.keep('pdf', [image()]),
      ))!;
      await pumpHome(tester);
      store.loaded.complete([]);
      await waitFor(tester, find.byType(AlertDialog));
      expect(find.text('Continue reviewing 1 page?'), findsOneWidget);
      expect(find.text('The app closed before it was added.'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await settle(tester);
      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(find.byType(Card), findsNothing);
      expect(File(kept.single).existsSync(), isFalse);
      expect(await journalGone(tester), isTrue);
    }, variant: _iOS);

    testWidgets('a camera photo is reviewed again on its own', (tester) async {
      await tester.runAsync(() => journal.keep('camera', [image()]));
      await pumpHome(tester);
      store.loaded.complete([]);
      await waitFor(tester, find.byType(AlertDialog));
      await tester.tap(find.text('Continue'));
      await waitForEditor(tester, 'Preview page');
      expect(
        tester
            .widget<CornerAdjustScreen>(find.byType(CornerAdjustScreen))
            .source,
        PageReviewSource.recovered,
      );
      expect(find.text('Scan next'), findsNothing);
    }, variant: _iOS);

    testWidgets('of gallery images is reported, not resumed', (tester) async {
      await tester.runAsync(() => journal.notePending('gallery', 7));
      await pumpHome(tester);
      store.loaded.complete([]);
      await waitFor(tester, find.byType(SnackBar));
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.text(
          "7 images from an interrupted import weren't added. Select them "
          'again to add them.',
        ),
        findsOneWidget,
      );
      expect(await journalGone(tester), isTrue);
    }, variant: _iOS);

    testWidgets('waits while the saved draft could not be restored', (
      tester,
    ) async {
      await tester.runAsync(() => journal.keep('shared', [image()]));
      await pumpHome(tester);
      store.loaded.completeError(const DraftRestoreException());
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(journalExists(), isTrue);
    }, variant: _iOS);

    testWidgets('nothing is offered when there is no journal', (tester) async {
      await pumpHome(tester);
      store.loaded.complete([]);
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    }, variant: _iOS);
  });

  group('a running review', () {
    testWidgets('journals the gallery count without copying', (tester) async {
      final originals = [image(), image()];
      picker.gallery = [for (final path in originals) XFile(path)];
      await pumpHome(tester);
      store.loaded.complete([]);
      await settle(tester);
      await tester.tap(find.byTooltip('Import from gallery'));
      await waitForEditor(tester, 'Image 1 of 2');
      expect(journal.noted, [('gallery', 2)]);
      expect(journal.keptSources, isEmpty);
      await accept(tester);
      await waitForEditor(tester, 'Image 2 of 2');
      expect(journal.noted.last, ('gallery', 1));
      await accept(tester);
      await settle(tester);
      expect(await journalGone(tester), isTrue);
      // The user's images are never touched.
      expect(originals.every((path) => File(path).existsSync()), isTrue);
    }, variant: _iOS);

    testWidgets('keeps a camera photo in the journal until it is reviewed', (
      tester,
    ) async {
      final captured = image();
      picker.camera = XFile(captured);
      await pumpHome(tester);
      store.loaded.complete([]);
      await settle(tester);
      await tester.tap(find.byType(FloatingActionButton));
      await waitForEditor(tester, 'Preview page');
      expect(find.byType(CornerAdjustScreen), findsOneWidget);
      // Moved, not copied: still on disk only inside the journal.
      expect(File(captured).existsSync(), isFalse);
      final review = (await tester.runAsync(journal.read))!;
      expect(review.source, 'camera');
      expect(review.paths, hasLength(1));
      await accept(tester);
      await waitFor(tester, find.text('Export 1 page as PDF'));
      expect(find.text('Export 1 page as PDF'), findsOneWidget);
      expect(await journalGone(tester), isTrue);
    }, variant: _iOS);
  });
}
