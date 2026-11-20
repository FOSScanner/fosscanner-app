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

class _DelayedDraftStore implements DraftStore {
  final loaded = Completer<List<ScannedPage>>();
  final saves = <List<ScannedPage>>[];
  var loadCalls = 0;
  var clearCalls = 0;
  Object? clearError;
  List<ScannedPage> retryPages = [];
  Future<List<ScannedPage>>? retryResult;

  @override
  Future<List<ScannedPage>> load() {
    loadCalls++;
    return loadCalls == 1
        ? loaded.future
        : retryResult ?? Future.value(retryPages);
  }

  @override
  Future<void> save(List<ScannedPage> pages) async => saves.add(List.of(pages));

  @override
  Future<void> clear() async {
    clearCalls++;
    if (clearError case final error?) throw error;
  }
}

class _Picker extends ImagePickerPlatform {
  _Picker({this.recoveredFiles = const []});

  final List<XFile> recoveredFiles;
  var cameraCalls = 0;
  var galleryCalls = 0;
  var lostDataCalls = 0;

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    cameraCalls++;
    return null;
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    galleryCalls++;
    return [];
  }

  @override
  Future<LostDataResponse> getLostData() async {
    lostDataCalls++;
    return recoveredFiles.isEmpty
        ? LostDataResponse.empty()
        : LostDataResponse(files: recoveredFiles);
  }
}

class _ImmediateOperations implements CornerAdjustOperations {
  @override
  Future<Size> decodeSize(Uint8List imageBytes) async => const Size(1024, 1024);

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
  late ImagePickerPlatform originalPicker;
  late Uint8List imageBytes;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  });

  tearDown(() => ImagePickerPlatform.instance = originalPicker);

  ScannedPage savedPage() => ScannedPage(
    originalBytes: imageBytes,
    processedBytes: imageBytes,
    corners: const [],
  );

  Future<void> pumpHome(
    WidgetTester tester,
    _DelayedDraftStore store, {
    List<ScannedPage> initialPages = const [],
    double textScale = 1,
  }) => tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: ScannerHomePage(
        draftStore: store,
        initialPages: initialPages,
        cornerAdjustOperations: _ImmediateOperations(),
        searchablePdfEnabled: false,
      ),
    ),
  );

  for (final tooltip in ['Scan a page', 'Import from gallery']) {
    testWidgets(
      '$tooltip waits for draft restoration before opening the picker',
      (tester) async {
        final store = _DelayedDraftStore();
        final picker = _Picker();
        ImagePickerPlatform.instance = picker;
        await pumpHome(tester, store);

        await tester.tap(find.byTooltip(tooltip));
        await tester.pump();
        expect(picker.cameraCalls + picker.galleryCalls, 0);
        expect(find.text('Restoring draft…'), findsOneWidget);
        expect(find.textContaining('Document memory limit'), findsNothing);

        store.loaded.complete([savedPage()]);
        await tester.pumpAndSettle();
        expect(find.text('Export 1 page as PDF'), findsOneWidget);
        expect(find.text('Restoring draft…'), findsNothing);
        await tester.tap(find.byTooltip(tooltip));
        await tester.pumpAndSettle();
        expect(picker.cameraCalls + picker.galleryCalls, 1);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'Android recovery waits for restoration and saves both old and new pages',
    (tester) async {
      final store = _DelayedDraftStore();
      final restored = savedPage();
      final directory = Directory.systemTemp.createTempSync('draft-recovery-');
      final recovered = File('${directory.path}/recovered.png')
        ..writeAsBytesSync(imageBytes);
      addTearDown(() => directory.deleteSync(recursive: true));
      final picker = _Picker(recoveredFiles: [XFile(recovered.path)]);
      ImagePickerPlatform.instance = picker;
      await pumpHome(tester, store);
      await tester.pump();

      expect(picker.lostDataCalls, 0);
      expect(recovered.existsSync(), isTrue);
      expect(find.byType(CornerAdjustScreen), findsNothing);

      store.loaded.complete([restored]);
      for (
        var i = 0;
        i < 50 && find.text('Preview page').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(picker.lostDataCalls, 1);
      expect(find.byType(CornerAdjustScreen), findsOneWidget);
      await tester.tap(find.text('Preview page'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add page'));
      await tester.pumpAndSettle();

      expect(find.text('Export 2 pages as PDF'), findsOneWidget);
      expect(store.saves.single, hasLength(2));
      expect(store.saves.single.first, same(restored));
      expect(store.saves.single.last.originalBytes, orderedEquals(imageBytes));
      expect(recovered.existsSync(), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'failed restoration blocks intake and retry restores without clearing',
    (tester) async {
      final store = _DelayedDraftStore();
      final picker = _Picker();
      ImagePickerPlatform.instance = picker;
      await pumpHome(tester, store);
      store.loaded.completeError(StateError('PRIVATE path and details'));
      await tester.pumpAndSettle();
      expect(find.text('Could not restore the saved draft'), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(find.byTooltip('Import from gallery'), findsNothing);
      expect(find.byTooltip('Scan a page'), findsNothing);
      expect(store.saves, isEmpty);
      expect(
        picker.galleryCalls + picker.cameraCalls + picker.lostDataCalls,
        0,
      );
      final semantics = tester.ensureSemantics();
      expect(
        tester
            .getSemantics(find.text('Could not restore the saved draft'))
            .getSemanticsData()
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );

      semantics.dispose();

      store.retryPages = [savedPage()];
      await tester.tap(find.text('Retry restoration'));
      await tester.pumpAndSettle();
      expect(store.loadCalls, 2);
      expect(store.clearCalls, 0);
      expect(find.text('Export 1 page as PDF'), findsOneWidget);
      await tester.tap(find.byTooltip('Import from gallery'));
      await tester.pumpAndSettle();
      expect(picker.galleryCalls, 1);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'pending and failed retries cannot reopen intake or overlap loads',
    (tester) async {
      final store = _DelayedDraftStore();
      ImagePickerPlatform.instance = _Picker();
      await pumpHome(tester, store);
      store.loaded.completeError(const DraftRestoreException());
      await tester.pumpAndSettle();
      final pending = Completer<List<ScannedPage>>();
      store.retryResult = pending.future;
      final retry = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Retry restoration'),
          )
          .onPressed!;
      retry();
      retry();
      await tester.pump();
      expect(store.loadCalls, 2);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Retry restoration'),
            )
            .onPressed,
        isNull,
      );
      expect(find.byTooltip('Import from gallery'), findsNothing);
      pending.completeError(StateError('PRIVATE retry error'));
      await tester.pumpAndSettle();
      expect(find.text('Could not restore the saved draft'), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(store.saves, isEmpty);
      expect(store.clearCalls, 0);
    },
  );

  testWidgets(
    'discard requires confirmation and failed clear remains blocked',
    (tester) async {
      final store = _DelayedDraftStore();
      ImagePickerPlatform.instance = _Picker();
      await pumpHome(tester, store);
      store.loaded.completeError(const DraftRestoreException());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard saved draft'));
      await tester.pumpAndSettle();
      expect(find.textContaining('might still be recoverable'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.clearCalls, 0);
      expect(find.text('Retry restoration'), findsOneWidget);

      store.clearError = StateError('PRIVATE filesystem details');
      await tester.tap(find.text('Discard saved draft'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard draft'));
      await tester.pumpAndSettle();
      expect(store.clearCalls, 1);
      expect(find.text('Could not clear the saved draft.'), findsOneWidget);
      expect(find.byTooltip('Import from gallery'), findsNothing);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(store.saves, isEmpty);

      store.clearError = null;
      await tester.tap(find.text('Discard saved draft'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard draft'));
      await tester.pumpAndSettle();
      expect(store.clearCalls, 2);
      expect(find.text('Ready to scan'), findsOneWidget);
      expect(find.byTooltip('Import from gallery'), findsOneWidget);
    },
  );

  testWidgets(
    'Android lost image remains available until successful restore retry',
    (tester) async {
      final store = _DelayedDraftStore();
      final directory = Directory.systemTemp.createTempSync('draft-retry-');
      final recovered = File('${directory.path}/recovered.png')
        ..writeAsBytesSync(imageBytes);
      addTearDown(() => directory.deleteSync(recursive: true));
      final picker = _Picker(recoveredFiles: [XFile(recovered.path)]);
      ImagePickerPlatform.instance = picker;
      await pumpHome(tester, store);
      store.loaded.completeError(const DraftRestoreException());
      await tester.pumpAndSettle();
      expect(picker.lostDataCalls, 0);
      expect(recovered.existsSync(), isTrue);
      expect(store.saves, isEmpty);

      store.retryPages = [savedPage()];
      await tester.tap(find.text('Retry restoration'));
      for (
        var i = 0;
        i < 50 && find.byType(CornerAdjustScreen).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(picker.lostDataCalls, 1);
      expect(find.byType(CornerAdjustScreen), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Export 1 page as PDF'), findsOneWidget);
      expect(store.saves, isEmpty);
      expect(recovered.existsSync(), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final size in [const Size(320, 568), const Size(640, 300)]) {
    testWidgets(
      'restore failure and discard confirmation fit 200% text on $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        ImagePickerPlatform.instance = _Picker();
        final store = _DelayedDraftStore();
        await pumpHome(tester, store, textScale: 2);
        store.loaded.completeError(const DraftRestoreException());
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Discard saved draft'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Discard saved draft'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Cancel'));
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'explicit initial pages enable intake without loading a saved draft',
    (tester) async {
      final store = _DelayedDraftStore();
      final picker = _Picker();
      ImagePickerPlatform.instance = picker;
      await pumpHome(tester, store, initialPages: [savedPage()]);
      await tester.tap(find.byTooltip('Import from gallery'));
      await tester.pumpAndSettle();

      expect(store.loadCalls, 0);
      expect(find.text('Restoring draft…'), findsNothing);
      expect(picker.galleryCalls, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
