import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:share_plus/share_plus.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/draft_store.dart';

class _DraftStore implements DraftStore {
  _DraftStore({
    Future<List<ScannedPage>>? loaded,
    this.clearCompleter,
    this.clearError,
  }) : loaded = loaded ?? Future.value(const []);

  final Future<List<ScannedPage>> loaded;
  final Completer<void>? clearCompleter;
  final Object? clearError;
  final saves = <List<ScannedPage>>[];
  var clearCalls = 0;

  @override
  Future<List<ScannedPage>> load() => loaded;

  @override
  Future<void> save(List<ScannedPage> pages) async {
    saves.add(List.of(pages));
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    if (clearError case final error?) throw error;
    final completer = clearCompleter;
    if (completer != null) await completer.future;
  }
}

class _SerialStore extends _DraftStore {
  _SerialStore({super.clearCompleter});

  final firstSave = Completer<void>();

  @override
  Future<void> save(List<ScannedPage> pages) async {
    saves.add(List.of(pages));
    if (saves.length == 1) await firstSave.future;
  }
}

class _ImagePickerPlatform extends ImagePickerPlatform {
  _ImagePickerPlatform({this.multiImageCompleter});

  final Completer<List<XFile>>? multiImageCompleter;

  @override
  bool supportsImageSource(ImageSource source) => false;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) => multiImageCompleter?.future ?? Future.value(const <XFile>[]);
}

class _SharePlatform implements SharePlatform {
  var calls = 0;

  @override
  Future<ShareResult> share(ShareParams params) async {
    calls++;
    return const ShareResult('shared', ShareResultStatus.success);
  }
}

void main() {
  late ImagePickerPlatform originalImagePicker;
  late Uint8List imageBytes;

  setUp(() async {
    originalImagePicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _ImagePickerPlatform();
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalImagePicker;
  });

  ScannedPage page(int marker) => ScannedPage(
    originalBytes: Uint8List.fromList(imageBytes),
    processedBytes: Uint8List.fromList(imageBytes),
    corners: [
      Offset(marker.toDouble(), 0),
      const Offset(10, 0),
      const Offset(10, 10),
      const Offset(0, 10),
    ],
  );

  Future<void> pumpHome(
    WidgetTester tester,
    DraftStore store, {
    List<ScannedPage> pages = const [],
    SharePlus? sharePlus,
  }) => tester.pumpWidget(
    MaterialApp(
      home: ScannerHomePage(
        initialPages: pages,
        draftStore: store,
        sharePlus: sharePlus,
      ),
    ),
  );

  IconButton iconButton(WidgetTester tester, String tooltip) =>
      tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(IconButton),
        ),
      );

  Future<void> tapDelete(WidgetTester tester, int pageNumber) async {
    final delete = find.byTooltip('Delete page $pageNumber');
    await tester.ensureVisible(delete);
    await tester.pump();
    await tester.tap(delete);
    await tester.pump();
  }

  testWidgets('restores a saved draft asynchronously at startup', (
    tester,
  ) async {
    final completer = Completer<List<ScannedPage>>();
    final store = _DraftStore(loaded: completer.future);
    final restored = [page(1), page(2)];

    await pumpHome(tester, store);
    expect(find.text('Ready to Scan'), findsOneWidget);

    completer.complete(restored);
    await tester.pump();

    expect(find.text('Save as PDF (2 pages)'), findsOneWidget);
    expect(find.byTooltip('Delete page 1'), findsOneWidget);
    expect(find.byTooltip('Delete page 2'), findsOneWidget);
    expect(store.saves, isEmpty);
  });

  testWidgets('delete Undo restores the page at its exact index', (
    tester,
  ) async {
    final store = _DraftStore();
    final first = page(1);
    final second = page(2);
    final third = page(3);
    await pumpHome(tester, store, pages: [first, second, third]);

    await tapDelete(tester, 2);
    expect(store.saves.single, orderedEquals([first, third]));
    expect(find.text('Page deleted.'), findsOneWidget);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
    await tester.pump();

    expect(store.saves.last, orderedEquals([first, second, third]));
    expect(find.byTooltip('Delete page 2'), findsOneWidget);
  });

  testWidgets('two rapid deletes expose only the newest Undo', (tester) async {
    final store = _DraftStore();
    final first = page(1);
    final second = page(2);
    final third = page(3);
    await pumpHome(tester, store, pages: [first, second, third]);

    await tapDelete(tester, 1);
    await tapDelete(tester, 1);

    expect(find.text('Page deleted.'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, 'Undo'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
    await tester.pump();

    expect(store.saves.last, orderedEquals([second, third]));
  });

  testWidgets('snapshot writes are serialized in mutation order', (
    tester,
  ) async {
    final store = _SerialStore();
    final first = page(1);
    final second = page(2);
    final third = page(3);
    await pumpHome(tester, store, pages: [first, second, third]);

    await tapDelete(tester, 1);
    expect(store.saves, hasLength(1));
    expect(store.saves.single, orderedEquals([second, third]));

    await tapDelete(tester, 1);
    expect(store.saves, hasLength(1));

    store.firstSave.complete();
    await tester.pump();
    await tester.pump();
    expect(store.saves, hasLength(2));
    expect(store.saves.last, orderedEquals([third]));
  });

  testWidgets('Clear all requires confirmation and clears persisted data', (
    tester,
  ) async {
    final store = _DraftStore();
    await pumpHome(tester, store, pages: [page(1), page(2)]);

    await tester.tap(find.byTooltip('Clear all'));
    await tester.pumpAndSettle();
    expect(find.text('Clear all pages?'), findsOneWidget);
    expect(store.clearCalls, 0);
    expect(find.text('Save as PDF (2 pages)'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(store.clearCalls, 0);

    await tester.tap(find.byTooltip('Clear all'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Ready to Scan'), findsOneWidget);
    expect(store.clearCalls, 1);
  });

  testWidgets(
    'Clear all blocks delete, reorder, and add while queued save and clear wait',
    (tester) async {
      final clearCompleter = Completer<void>();
      final store = _SerialStore(clearCompleter: clearCompleter);
      await pumpHome(tester, store, pages: [page(1), page(2), page(3)]);

      await tapDelete(tester, 1);
      expect(store.saves, hasLength(1));
      final staleDelete = iconButton(tester, 'Delete page 1').onPressed!;
      final staleAdd = iconButton(tester, 'Import from gallery').onPressed!;
      final staleReorder = tester
          .widget<DragTarget<int>>(find.byType(DragTarget<int>).last)
          .onAcceptWithDetails!;
      await tester.tap(find.byTooltip('Clear all'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
      await tester.pump();

      expect(store.clearCalls, 0);
      expect(find.text('Clearing draft...'), findsOneWidget);
      expect(iconButton(tester, 'Import from gallery').onPressed, isNull);
      expect(iconButton(tester, 'Delete page 1').onPressed, isNull);
      expect(
        tester
            .widget<LongPressDraggable<int>>(
              find.byType(LongPressDraggable<int>).first,
            )
            .maxSimultaneousDrags,
        0,
      );

      // Invoke callbacks captured before the lock as well as tapping the now
      // disabled controls. The guards must reject stale in-flight gestures.
      staleDelete();
      staleAdd();
      staleReorder(DragTargetDetails<int>(data: 0, offset: Offset.zero));
      await tester.pump();

      expect(store.saves, hasLength(1));
      expect(find.text('Clearing draft...'), findsOneWidget);

      store.firstSave.complete();
      await tester.pump();
      await tester.pump();
      expect(store.clearCalls, 1);
      expect(store.saves, hasLength(1));
      expect(find.text('Clearing draft...'), findsOneWidget);

      clearCompleter.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('Ready to Scan'), findsOneWidget);
      expect(store.saves, hasLength(1));
      expect(iconButton(tester, 'Import from gallery').onPressed, isNotNull);
    },
  );

  testWidgets('picker result cannot repopulate a successfully cleared draft', (
    tester,
  ) async {
    final pickerCompleter = Completer<List<XFile>>();
    ImagePickerPlatform.instance = _ImagePickerPlatform(
      multiImageCompleter: pickerCompleter,
    );
    final clearCompleter = Completer<void>();
    final store = _DraftStore(clearCompleter: clearCompleter);
    await pumpHome(tester, store, pages: [page(1)]);

    await tester.tap(find.byTooltip('Import from gallery'));
    await tester.pump();
    await tester.tap(find.byTooltip('Clear all'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pump();
    expect(find.text('Clearing draft...'), findsOneWidget);

    clearCompleter.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Ready to Scan'), findsOneWidget);

    pickerCompleter.complete([
      XFile.fromData(imageBytes, name: 'late-picker-result.png'),
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.text('Ready to Scan'), findsOneWidget);
    expect(store.saves, isEmpty);
    expect(store.clearCalls, 1);
  });

  testWidgets('clear failure keeps in-memory pages and shows an error', (
    tester,
  ) async {
    final store = _DraftStore(clearError: StateError('injected clear failure'));
    await pumpHome(tester, store, pages: [page(1), page(2)]);

    await tester.tap(find.byTooltip('Clear all'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pump();
    await tester.pump();

    expect(store.clearCalls, 1);
    expect(find.text('Save as PDF (2 pages)'), findsOneWidget);
    expect(find.text('Could not clear the saved draft.'), findsOneWidget);
    expect(find.text('Clearing draft...'), findsNothing);
    expect(iconButton(tester, 'Delete page 1').onPressed, isNotNull);
    expect(iconButton(tester, 'Clear all').onPressed, isNotNull);
  });

  testWidgets('successful share keeps the draft unless clear is chosen', (
    tester,
  ) async {
    final keepStore = _DraftStore();
    final sharePlatform = _SharePlatform();
    await pumpHome(
      tester,
      keepStore,
      pages: [page(1)],
      sharePlus: SharePlus.custom(sharePlatform),
    );

    await tester.tap(find.text('Save as PDF (1 pages)'));
    await tester.pumpAndSettle();
    expect(find.text('Keep this draft?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Keep draft'));
    await tester.pumpAndSettle();
    expect(keepStore.clearCalls, 0);
    expect(find.text('Save as PDF (1 pages)'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    final clearStore = _DraftStore();
    await pumpHome(
      tester,
      clearStore,
      pages: [page(2)],
      sharePlus: SharePlus.custom(sharePlatform),
    );
    await tester.tap(find.text('Save as PDF (1 pages)'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear draft'));
    await tester.pump();
    await tester.pump();

    expect(clearStore.clearCalls, 1);
    expect(find.text('Ready to Scan'), findsOneWidget);
    expect(sharePlatform.calls, 2);
  });
}
