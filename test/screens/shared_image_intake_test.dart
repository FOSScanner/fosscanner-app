import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/draft_store.dart';
import 'package:fosscanner/services/image_metadata.dart';
import 'package:fosscanner/services/shared_image_inbox.dart';

const _corners = [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)];

class _FakeInbox implements SharedImageInbox {
  VoidCallback? listener;
  final batches = <SharedImageBatch>[];
  final takeCalls = <int>[];
  Object? error;

  @override
  void setListener(VoidCallback? onAvailable) => listener = onAvailable;

  @override
  Future<SharedImageBatch> take({required int maxCount}) async {
    takeCalls.add(maxCount);
    final failure = error;
    if (failure != null) throw failure;
    return batches.isEmpty ? const SharedImageBatch() : batches.removeAt(0);
  }
}

class _Store implements DraftStore {
  // Created on first use inside the test's zone: a completer made in setUp
  // could not deliver an error across the FakeAsync error-zone boundary.
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

class _Picker extends ImagePickerPlatform {
  List<XFile> galleryPhotos = [];
  List<XFile> recoveredPhotos = [];
  var galleryCalls = 0;

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => null;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    galleryCalls++;
    return galleryPhotos;
  }

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
  late _FakeInbox inbox;
  late _Store store;
  late Directory directory;
  late Uint8List bytes;
  var fileCount = 0;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    picker = _Picker();
    ImagePickerPlatform.instance = picker;
    inbox = _FakeInbox();
    store = _Store();
    directory = Directory.systemTemp.createTempSync('shared-image-intake-');
    final data = await rootBundle.load('assets/icon/icon.png');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    directory.deleteSync(recursive: true);
  });

  File sharedFile() =>
      File('${directory.path}/shared_${fileCount++}.img')
        ..writeAsBytesSync(bytes);

  ScannedPage savedPage() => ScannedPage(
    originalBytes: bytes,
    corners: _corners,
    processedBytes: bytes,
  );

  Future<void> pumpHome(
    WidgetTester tester, {
    List<ScannedPage> initialPages = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          draftStore: store,
          initialPages: initialPages,
          searchablePdfEnabled: false,
          cornerAdjustOperations: _Operations(),
          sourceImageSizeReader: (_) async => const Size(100, 100),
          sharedImageInbox: inbox,
        ),
      ),
    );
    await tester.pump();
  }

  Future<CornerAdjustScreen> waitForEditor(
    WidgetTester tester, {
    CornerAdjustScreen? previous,
  }) async {
    // File IO and image metadata decoding require real event-loop turns.
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

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<void> accept(WidgetTester tester) async {
    await tester.tap(find.text('Preview page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add page'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a cold-start share waits for the draft and is appended to it',
    (tester) async {
      final file = sharedFile();
      inbox.batches.add(SharedImageBatch(paths: [file.path]));
      await pumpHome(tester);
      expect(inbox.listener, isNotNull);
      expect(inbox.takeCalls, isEmpty);

      final restored = savedPage();
      store.loaded.complete([restored]);
      final editor = await waitForEditor(tester);
      expect(inbox.takeCalls, [maxDocumentPages - 1]);
      expect(editor.source, PageReviewSource.shared);
      expect(editor.isBatchImport, isFalse);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Add & scan next'), findsNothing);
      expect(file.existsSync(), isFalse);

      await accept(tester);
      await settle(tester);
      expect(find.text('Export PDF (2 pages)'), findsOneWidget);
      expect(store.saves.last, hasLength(2));
      expect(store.saves.last.first, same(restored));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'multiple shares use batch review and Stop deletes the remaining copies',
    (tester) async {
      final files = [for (var i = 0; i < 3; i++) sharedFile()];
      inbox.batches.add(
        SharedImageBatch(paths: [for (final file in files) file.path]),
      );
      await pumpHome(tester);
      store.loaded.complete([]);
      final first = await waitForEditor(tester);
      expect(find.text('Image 1 of 3'), findsOneWidget);
      expect(find.text('Skip image'), findsOneWidget);
      await accept(tester);

      await waitForEditor(tester, previous: first);
      expect(find.text('Image 2 of 3'), findsOneWidget);
      await tester.tap(find.byTooltip('Stop importing'));
      await settle(tester);

      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(find.text('Export PDF (1 page)'), findsOneWidget);
      expect(find.textContaining('Import stopped.'), findsOneWidget);
      expect(files.every((file) => !file.existsSync()), isTrue);

      // Intake is released afterwards.
      await tester.tap(find.byTooltip('Import from gallery'));
      await settle(tester);
      expect(picker.galleryCalls, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a failed draft restore defers shares until the draft is discarded',
    (tester) async {
      final file = sharedFile();
      inbox.batches.add(SharedImageBatch(paths: [file.path]));
      await pumpHome(tester);
      store.loaded.completeError(const DraftRestoreException());
      await settle(tester);
      expect(find.text('Could not restore the saved draft'), findsOneWidget);
      expect(inbox.takeCalls, isEmpty);

      // A share arriving now is deferred as well.
      inbox.listener!();
      await settle(tester);
      expect(inbox.takeCalls, isEmpty);
      expect(store.saves, isEmpty);
      expect(file.existsSync(), isTrue);

      await tester.tap(find.text('Discard saved draft'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Discard draft'));
      final editor = await waitForEditor(tester);
      expect(store.clearCalls, 1);
      expect(inbox.takeCalls, [maxDocumentPages]);
      expect(editor.source, PageReviewSource.shared);
      expect(file.existsSync(), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a failed draft restore defers shares until restoration is retried',
    (tester) async {
      final file = sharedFile();
      inbox.batches.add(SharedImageBatch(paths: [file.path]));
      await pumpHome(tester);
      store.loaded.completeError(const DraftRestoreException());
      await settle(tester);
      expect(inbox.takeCalls, isEmpty);

      store._loaded = Completer()..complete(const []);
      await tester.tap(find.text('Retry restoration'));
      final editor = await waitForEditor(tester);
      expect(store.clearCalls, 0);
      expect(inbox.takeCalls, [maxDocumentPages]);
      expect(editor.source, PageReviewSource.shared);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a share during another review waits until that review ends',
    (tester) async {
      final gallery = File('${directory.path}/gallery.png')
        ..writeAsBytesSync(bytes);
      picker.galleryPhotos = [XFile(gallery.path)];
      await pumpHome(tester);
      store.loaded.complete([]);
      await settle(tester);
      expect(inbox.takeCalls, [maxDocumentPages]);

      await tester.tap(find.byTooltip('Import from gallery'));
      final galleryEditor = await waitForEditor(tester);
      expect(galleryEditor.source, PageReviewSource.gallery);

      final shared = sharedFile();
      inbox.batches.add(SharedImageBatch(paths: [shared.path]));
      inbox.listener!();
      await tester.pump();
      expect(inbox.takeCalls, hasLength(1));
      expect(shared.existsSync(), isTrue);

      await accept(tester);
      final sharedEditor = await waitForEditor(tester, previous: galleryEditor);
      expect(sharedEditor.source, PageReviewSource.shared);
      expect(inbox.takeCalls, [maxDocumentPages, maxDocumentPages - 1]);
      await accept(tester);
      await settle(tester);
      expect(find.text('Export PDF (2 pages)'), findsOneWidget);
      // Gallery originals belong to the user.
      expect(gallery.existsSync(), isTrue);
      expect(shared.existsSync(), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a full document reports the page limit and takes nothing',
    (tester) async {
      inbox.batches.add(const SharedImageBatch(truncated: true));
      await pumpHome(
        tester,
        initialPages: List.generate(maxDocumentPages, (_) => savedPage()),
      );
      await settle(tester);
      expect(inbox.takeCalls, [0]);
      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(
        find.text(
          'Some shared images were not added: page limit reached '
          '($maxDocumentPages pages).',
        ),
        findsOneWidget,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'reaching the page limit mid-batch reports it once and deletes the rest',
    (tester) async {
      final files = [sharedFile(), sharedFile()];
      inbox.batches.add(
        SharedImageBatch(
          paths: [for (final file in files) file.path],
          truncated: true,
        ),
      );
      await pumpHome(
        tester,
        initialPages: List.generate(maxDocumentPages - 1, (_) => savedPage()),
      );
      await waitForEditor(tester);
      expect(find.text('Image 1 of 2'), findsOneWidget);
      await accept(tester);
      await settle(tester);

      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(find.text('Export PDF ($maxDocumentPages pages)'), findsOneWidget);
      expect(
        find.textContaining('reached the $maxDocumentPages-page limit'),
        findsOneWidget,
      );
      expect(find.textContaining('Some shared images'), findsNothing);
      expect(files.every((file) => !file.existsSync()), isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'rejected shares are explained without exposing details',
    (tester) async {
      inbox.batches.add(const SharedImageBatch(rejected: 2));
      await pumpHome(tester);
      store.loaded.complete([]);
      await settle(tester);
      expect(
        find.text("2 images couldn't be added: 2 unreadable files."),
        findsOneWidget,
      );
      expect(find.byType(CornerAdjustScreen), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a failed take shows a generic message and releases intake',
    (tester) async {
      inbox.error = PlatformException(
        code: 'share_failed',
        message: 'content://secret/path',
      );
      await pumpHome(tester);
      store.loaded.complete([]);
      await settle(tester);
      expect(find.text('Could not add the shared images.'), findsOneWidget);
      expect(find.textContaining('content://'), findsNothing);

      await tester.tap(find.byTooltip('Import from gallery'));
      await settle(tester);
      expect(picker.galleryCalls, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Android lost-image recovery runs before pending shares',
    (tester) async {
      final recovered = File('${directory.path}/recovered.png')
        ..writeAsBytesSync(bytes);
      picker.recoveredPhotos = [XFile(recovered.path)];
      final shared = sharedFile();
      inbox.batches.add(SharedImageBatch(paths: [shared.path]));
      await pumpHome(tester);
      store.loaded.complete([]);

      final first = await waitForEditor(tester);
      expect(first.source, PageReviewSource.recovered);
      expect(inbox.takeCalls, isEmpty);
      await tester.tap(find.text('Cancel'));
      final second = await waitForEditor(tester, previous: first);
      expect(second.source, PageReviewSource.shared);
      expect(inbox.takeCalls, [maxDocumentPages]);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(find.byType(Card), findsNothing);
      expect(recovered.existsSync(), isFalse);
      expect(shared.existsSync(), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  test('platform replies are decoded defensively', () {
    expect(parseSharedImageBatch(null).isEmpty, isTrue);
    final batch = parseSharedImageBatch({
      'paths': ['/cache/a', 3, '', null, '/cache/b'],
      'rejected': -1,
      'truncated': 'yes',
    });
    expect(batch.paths, ['/cache/a', '/cache/b']);
    expect(batch.rejected, 0);
    expect(batch.truncated, isFalse);
    expect(
      parseSharedImageBatch({'rejected': 2, 'truncated': true}).truncated,
      isTrue,
    );
  });
}
