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

  @override
  Future<List<ScannedPage>> load() {
    loadCalls++;
    return loaded.future;
  }

  @override
  Future<void> save(List<ScannedPage> pages) async => saves.add(List.of(pages));

  @override
  Future<void> clear() async {}
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
  }) => tester.pumpWidget(
    MaterialApp(
      home: ScannerHomePage(
        draftStore: store,
        initialPages: initialPages,
        cornerAdjustOperations: _ImmediateOperations(),
        searchablePdfEnabled: false,
      ),
    ),
  );

  for (final tooltip in ['Capture Image', 'Import from gallery']) {
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
        expect(find.text('Restoring draft...'), findsOneWidget);
        expect(find.textContaining('Document memory limit'), findsNothing);

        store.loaded.complete([savedPage()]);
        await tester.pumpAndSettle();
        expect(find.text('Save as PDF (1 pages)'), findsOneWidget);
        expect(find.text('Restoring draft...'), findsNothing);
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
      for (var i = 0; i < 50 && find.text('Next').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(picker.lostDataCalls, 1);
      expect(find.byType(CornerAdjustScreen), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(find.text('Save as PDF (2 pages)'), findsOneWidget);
      expect(store.saves.single, hasLength(2));
      expect(store.saves.single.first, same(restored));
      expect(store.saves.single.last.originalBytes, orderedEquals(imageBytes));
      expect(recovered.existsSync(), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'a failed restoration releases image intake with a recovery message',
    (tester) async {
      final store = _DelayedDraftStore();
      final picker = _Picker();
      ImagePickerPlatform.instance = picker;
      await pumpHome(tester, store);
      expect(find.text('Restoring draft...'), findsOneWidget);

      store.loaded.completeError(StateError('synthetic load failure'));
      await tester.pumpAndSettle();
      expect(find.text('Could not restore the saved draft.'), findsOneWidget);
      expect(find.text('Restoring draft...'), findsNothing);
      await tester.tap(find.byTooltip('Import from gallery'));
      await tester.pumpAndSettle();
      expect(picker.galleryCalls, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

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
      expect(find.text('Restoring draft...'), findsNothing);
      expect(picker.galleryCalls, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
