import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/draft_store.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:share_plus/share_plus.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import '../support/worker_isolates.dart';

class _Picker extends ImagePickerPlatform {
  late final result = Completer<List<XFile>>();
  var calls = 0;

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) {
    calls++;
    return result.future;
  }

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    calls++;
    return null;
  }
}

class _Share implements SharePlatform {
  var calls = 0;
  Object? error;

  @override
  Future<ShareResult> share(ShareParams params) async {
    calls++;
    if (error case final value?) throw value;
    return const ShareResult('', ShareResultStatus.dismissed);
  }
}

class _Store implements DraftStore {
  Completer<void>? pendingSave;
  var saveCalls = 0;

  @override
  Future<List<ScannedPage>> load() async => const [];

  @override
  Future<void> save(List<ScannedPage> pages) async {
    saveCalls++;
    await pendingSave?.future;
  }

  @override
  Future<void> clear() async {}
}

class _Operations implements CornerAdjustOperations {
  Completer<Map<PageFilter, Uint8List>>? pendingPreview;
  var previewCalls = 0;

  @override
  Future<Size> decodeSize(Uint8List imageBytes) async => const Size(100, 100);

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async => null;

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List imageBytes,
    List<Offset> corners,
  ) async {
    previewCalls++;
    return await pendingPreview?.future ??
        {for (final filter in PageFilter.values) filter: imageBytes};
  }

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
  late _Picker picker;
  late _Share share;
  late _Store store;
  late _Operations operations;
  late Uint8List imageBytes;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = picker = _Picker();
    share = _Share();
    store = _Store();
    operations = _Operations();
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
  });

  ScannedPage page({Uint8List? original}) => ScannedPage(
    originalBytes: original ?? imageBytes,
    processedBytes: imageBytes,
    corners: const [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)],
  );

  Future<void> pumpHome(
    WidgetTester tester, {
    List<ScannedPage>? pages,
    Size sourceSize = const Size(100, 100),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: pages ?? [page(), page()],
          draftStore: store,
          sharePlus: SharePlus.custom(share),
          searchablePdfEnabled: false,
          cornerAdjustOperations: operations,
          sourceImageSizeReader: (_) async => sourceSize,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  IconButton button(WidgetTester tester, String tooltip) =>
      tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(IconButton),
        ),
      );

  Future<void> tapDelete(WidgetTester tester) async {
    final delete = find.byTooltip('Delete page 1');
    await tester.ensureVisible(delete);
    await tester.pump();
    await tester.tap(delete);
    await tester.pump();
  }

  Future<void> editFirstPage(WidgetTester tester) async {
    await tester.ensureVisible(find.byType(Card).first);
    await tester.tap(find.byType(Card).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit page'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets(
    'export blocks mutation controls and stale callbacks',
    (tester) async {
      await pumpHome(tester);
      final gallery = button(tester, 'Import from gallery').onPressed!;
      final camera = tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed!;
      final barcode = button(tester, 'Scan QR/barcode').onPressed!;
      final delete = button(tester, 'Delete page 1').onPressed!;
      final clear = button(tester, 'Clear all').onPressed!;
      final reorder = tester
          .widget<DragTarget<int>>(find.byType(DragTarget<int>).last)
          .onAcceptWithDetails!;
      final openPage = tester
          .widget<InkWell>(
            find
                .descendant(
                  of: find.byType(Card).first,
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .onTap!;

      await tester.tap(find.text('Save as PDF (2 pages)'));
      await tester.pump();
      for (final tooltip in [
        'Import from gallery',
        'Delete page 1',
        'Clear all',
        'Scan QR/barcode',
      ]) {
        expect(button(tester, tooltip).onPressed, isNull);
      }
      expect(
        tester
            .widget<FloatingActionButton>(find.byType(FloatingActionButton))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<LongPressDraggable<int>>(
              find.byType(LongPressDraggable<int>).first,
            )
            .maxSimultaneousDrags,
        0,
      );
      gallery();
      camera();
      barcode();
      delete();
      clear();
      openPage();
      reorder(DragTargetDetails<int>(data: 0, offset: Offset.zero));
      await tester.pump();
      expect(picker.calls, 0);
      expect(store.saveCalls, 0);
      expect(find.text('Clear all pages?'), findsNothing);
      expect(find.byType(CornerAdjustScreen), findsNothing);

      await pumpUntil(tester, () => share.calls == 1);
      expect(find.text('Save as PDF (2 pages)'), findsOneWidget);
      expect(button(tester, 'Import from gallery').onPressed, isNotNull);
      expect(button(tester, 'Delete page 1').onPressed, isNotNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('export invalidates Undo without retaining a removed page', (
    tester,
  ) async {
    await pumpHome(tester, pages: [page(), page(), page()]);
    await tapDelete(tester);
    await tester.pumpAndSettle();
    final undo = tester
        .widget<SnackBarAction>(find.byType(SnackBarAction))
        .onPressed;
    await tester.tap(find.text('Save as PDF (2 pages)'));
    await tester.pump();
    undo();
    await tester.pump();
    expect(store.saveCalls, 1);
    await pumpUntil(tester, () => share.calls == 1);
    undo();
    await tester.pump();
    expect(store.saveCalls, 1);
    expect(find.text('Save as PDF (2 pages)'), findsOneWidget);
    expect(find.byType(SnackBarAction), findsNothing);
  });

  testWidgets('picker admission rejects stale export callbacks', (
    tester,
  ) async {
    await pumpHome(tester);
    final export = tester
        .widget<ElevatedButton>(find.byType(ElevatedButton))
        .onPressed!;
    await tester.tap(find.byTooltip('Import from gallery'));
    await tester.pump();
    expect(picker.calls, 1);
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );
    export();
    await tester.pump();
    expect(find.textContaining('Generating PDF'), findsNothing);
    expect(share.calls, 0);
    picker.result.complete([]);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('export waits for workers left running by a popped editor', (
    tester,
  ) async {
    operations.pendingPreview = Completer<Map<PageFilter, Uint8List>>();
    await pumpHome(tester);
    final export = tester
        .widget<ElevatedButton>(find.byType(ElevatedButton))
        .onPressed!;
    await editFirstPage(tester);
    expect(operations.previewCalls, 1);
    export();
    await tester.pump();
    expect(share.calls, 0);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save as PDF (2 pages)'));
    await tester.pump();
    expect(find.text('Generating PDF 0%'), findsOneWidget);
    expect(share.calls, 0);
    operations.pendingPreview!.complete({
      for (final filter in PageFilter.values) filter: imageBytes,
    });
    await pumpUntil(tester, () => share.calls == 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued export cancellation releases admission without sharing', (
    tester,
  ) async {
    operations.pendingPreview = Completer<Map<PageFilter, Uint8List>>();
    await pumpHome(tester);
    await editFirstPage(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save as PDF (2 pages)'));
    await tester.pump();
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    operations.pendingPreview!.complete({
      for (final filter in PageFilter.values) filter: imageBytes,
    });
    await tester.pumpAndSettle();
    expect(share.calls, 0);
    expect(find.text('PDF generation cancelled.'), findsOneWidget);
    expect(button(tester, 'Import from gallery').onPressed, isNotNull);
  });

  testWidgets('share failure releases admission', (tester) async {
    share.error = StateError('injected share failure');
    await pumpHome(tester);
    await tester.tap(find.text('Save as PDF (2 pages)'));
    await pumpUntilFound(
      tester,
      find.text('Could not generate or share the PDF.'),
    );
    expect(button(tester, 'Import from gallery').onPressed, isNotNull);
    expect(button(tester, 'Delete page 1').onPressed, isNotNull);
  });

  // A small valid PNG view retaining a larger backing allocation lets these
  // tests exercise the memory budget without decoding a large bitmap.
  Uint8List retainedImage() {
    final allocation = Uint8List(48 * 1024 * 1024);
    allocation.setRange(0, imageBytes.length, imageBytes);
    return Uint8List.sublistView(allocation, 0, imageBytes.length);
  }

  testWidgets('Undo-held images remain in the processing budget', (
    tester,
  ) async {
    await pumpHome(
      tester,
      pages: [
        page(original: retainedImage()),
        page(),
      ],
      sourceSize: const Size(4000, 5000),
    );
    await tapDelete(tester);
    await tester.pumpAndSettle();
    await editFirstPage(tester);
    expect(operations.previewCalls, 0);
    expect(find.textContaining('too much temporary memory'), findsOneWidget);
    expect(find.byType(CornerAdjustScreen), findsNothing);
  });

  testWidgets('dismissing Undo releases image-processing headroom', (
    tester,
  ) async {
    await pumpHome(
      tester,
      pages: [
        page(original: retainedImage()),
        page(),
      ],
      sourceSize: const Size(4000, 5000),
    );
    await tapDelete(tester);
    await tester.pumpAndSettle();
    ScaffoldMessenger.of(
      tester.element(find.byType(ScannerHomePage)),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.byType(SnackBarAction), findsNothing);
    await editFirstPage(tester);
    expect(operations.previewCalls, 1);
    expect(find.byType(CornerAdjustScreen), findsOneWidget);
  });

  for (final failSave in [false, true]) {
    testWidgets(
      'draft-held images stay budgeted until save ${failSave ? 'fails' : 'finishes'}',
      (tester) async {
        store.pendingSave = Completer<void>();
        await pumpHome(
          tester,
          pages: [
            page(),
            page(original: retainedImage()),
            page(),
          ],
          sourceSize: const Size(4000, 5000),
        );
        await tapDelete(tester);
        await tester.pump();
        expect(store.saveCalls, 1);
        await tapDelete(tester);
        await tester.pumpAndSettle();
        ScaffoldMessenger.of(
          tester.element(find.byType(ScannerHomePage)),
        ).clearSnackBars();
        await tester.pumpAndSettle();
        await editFirstPage(tester);
        expect(operations.previewCalls, 0);
        expect(
          find.textContaining('too much temporary memory'),
          findsOneWidget,
        );

        final pending = store.pendingSave!;
        store.pendingSave = null;
        if (failSave) {
          pending.completeError(StateError('injected save failure'));
        } else {
          pending.complete();
        }
        await tester.pumpAndSettle();
        await editFirstPage(tester);
        expect(operations.previewCalls, 1);
        expect(find.byType(CornerAdjustScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
