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

import '../support/home_menu.dart';
import '../support/worker_isolates.dart';

class _DraftStore implements DraftStore {
  _DraftStore({
    Future<List<ScannedPage>>? loaded,
    this.clearCompleter,
    this.clearError,
    this.saveError,
  }) : loaded = loaded ?? Future.value(const []);

  final Future<List<ScannedPage>> loaded;
  final Completer<void>? clearCompleter;
  final Object? clearError;
  Object? saveError;
  final saves = <List<ScannedPage>>[];
  var clearCalls = 0;

  @override
  Future<List<ScannedPage>> load() => loaded;

  @override
  Future<void> save(List<ScannedPage> pages) async {
    saves.add(List.of(pages));
    if (saveError case final error?) throw error;
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

class _FailingPicker extends _ImagePickerPlatform {
  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => throw StateError('private platform details');
}

class _SharePlatform implements SharePlatform {
  _SharePlatform({
    this.error,
    this.completer,
    this.status = ShareResultStatus.success,
  });

  final Object? error;
  final ShareResultStatus status;
  final Completer<ShareResult>? completer;
  var calls = 0;

  @override
  Future<ShareResult> share(ShareParams params) async {
    calls++;
    if (error case final value?) throw value;
    if (completer case final pending?) return pending.future;
    return ShareResult('result', status);
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
    bool accessibleNavigation = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(accessibleNavigation: accessibleNavigation),
          child: child!,
        ),
        home: ScannerHomePage(
          initialPages: pages,
          draftStore: store,
          sharePlus: sharePlus,
          searchablePdfEnabled: false,
        ),
      ),
    );
    await tester.pump();
  }

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
    expect(find.text('Restoring draft…'), findsOneWidget);

    completer.complete(restored);
    await tester.pump();

    expect(find.text('Export PDF (2 pages)'), findsOneWidget);
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

  for (final accessibleNavigation in [false, true]) {
    for (final pageCount in [1, 2]) {
      testWidgets('deletion Undo expires after four seconds '
          '($pageCount pages, accessibleNavigation=$accessibleNavigation)', (
        tester,
      ) async {
        final store = _DraftStore();
        await pumpHome(
          tester,
          store,
          pages: [for (var i = 1; i <= pageCount; i++) page(i)],
          accessibleNavigation: accessibleNavigation,
        );
        await tapDelete(tester, 1);
        await tester.pumpAndSettle();
        expect(find.text('Page deleted.'), findsOneWidget);
        expect(find.widgetWithText(SnackBarAction, 'Undo'), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
        expect(find.widgetWithText(SnackBarAction, 'Undo'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.text('Page deleted.'), findsNothing);
        expect(find.widgetWithText(SnackBarAction, 'Undo'), findsNothing);
        expect(store.saves.single, hasLength(pageCount - 1));
        expect(tester.takeException(), isNull);
      });
    }
  }

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

  testWidgets('slow storage keeps only the newest pending draft snapshot', (
    tester,
  ) async {
    final store = _SerialStore();
    addTearDown(() {
      if (!store.firstSave.isCompleted) store.firstSave.complete();
    });
    final first = page(1);
    final second = page(2);
    await pumpHome(tester, store, pages: [page(3), first, second]);
    await tapDelete(tester, 1);
    expect(store.saves, hasLength(1));

    // A blocked disk write must not retain one snapshot and schedule another
    // complete document write for every subsequent edit.
    for (var i = 0; i < 101; i++) {
      final reorder = tester
          .widget<DragTarget<int>>(find.byType(DragTarget<int>).last)
          .onAcceptWithDetails!;
      reorder(DragTargetDetails<int>(data: 0, offset: Offset.zero));
      await tester.pump();
    }
    expect(store.saves, hasLength(1));
    store.firstSave.complete();
    await tester.pumpAndSettle();

    expect(store.saves, hasLength(2));
    expect(store.saves.last, orderedEquals([second, first]));
  });

  testWidgets('a failed active save still commits the newest queued revision', (
    tester,
  ) async {
    final store = _SerialStore();
    addTearDown(() {
      if (!store.firstSave.isCompleted) store.firstSave.complete();
    });
    final last = page(3);
    await pumpHome(tester, store, pages: [page(1), page(2), last]);
    await tapDelete(tester, 1);
    await tapDelete(tester, 1);
    store.firstSave.completeError(StateError('injected write failure'));
    await tester.pumpAndSettle();

    expect(store.saves, hasLength(2));
    expect(store.saves.last, orderedEquals([last]));
    expect(tester.takeException(), isNull);
    iconButton(tester, 'Delete page 1').onPressed!();
    await tester.pumpAndSettle();
    expect(store.saves.last, isEmpty);
  });

  testWidgets('Clear all requires confirmation and clears persisted data', (
    tester,
  ) async {
    final store = _DraftStore();
    await pumpHome(tester, store, pages: [page(1), page(2)]);

    await tapClearAllPages(tester);
    expect(find.text('Clear all pages?'), findsOneWidget);
    expect(store.clearCalls, 0);
    expect(find.text('Export PDF (2 pages)'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(store.clearCalls, 0);

    await tapClearAllPages(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Ready to scan'), findsOneWidget);
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
      await tapClearAllPages(tester);
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
      expect(find.text('Ready to scan'), findsOneWidget);
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
    await tapClearAllPages(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pump();
    expect(find.text('Clearing draft...'), findsOneWidget);

    clearCompleter.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Ready to scan'), findsOneWidget);

    pickerCompleter.complete([
      XFile.fromData(imageBytes, name: 'late-picker-result.png'),
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.text('Ready to scan'), findsOneWidget);
    expect(store.saves, isEmpty);
    expect(store.clearCalls, 1);
  });

  testWidgets('clear failure keeps in-memory pages and shows an error', (
    tester,
  ) async {
    final store = _DraftStore(clearError: StateError('injected clear failure'));
    await pumpHome(tester, store, pages: [page(1), page(2)]);

    await tapClearAllPages(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pump();
    await tester.pump();

    expect(store.clearCalls, 1);
    expect(find.text('Export PDF (2 pages)'), findsOneWidget);
    expect(find.text('Could not clear the saved draft.'), findsOneWidget);
    expect(find.text('Clearing draft...'), findsNothing);
    expect(iconButton(tester, 'Delete page 1').onPressed, isNotNull);
    expect(await isClearAllPagesEnabled(tester), isTrue);
  });

  testWidgets('PDF failures hide raw exception details', (tester) async {
    final store = _DraftStore();
    final sharePlatform = _SharePlatform(
      error: StateError('private share provider details'),
    );
    await pumpHome(
      tester,
      store,
      pages: [page(1)],
      sharePlus: SharePlus.custom(sharePlatform),
    );

    await tester.tap(find.text('Export PDF (1 page)'));
    await pumpUntilFound(
      tester,
      find.text('Could not generate or share the PDF.'),
    );

    expect(find.text('Could not generate or share the PDF.'), findsOneWidget);
    expect(find.textContaining('private share provider details'), findsNothing);
  });

  testWidgets('sharing locks document mutations until the platform returns', (
    tester,
  ) async {
    final store = _DraftStore();
    final share = Completer<ShareResult>();
    final platform = _SharePlatform(completer: share);
    addTearDown(() {
      if (!share.isCompleted) {
        share.complete(const ShareResult('', ShareResultStatus.dismissed));
      }
    });
    final first = page(1);
    await pumpHome(
      tester,
      store,
      pages: [first, page(2)],
      sharePlus: SharePlus.custom(platform),
    );
    final staleDelete = iconButton(tester, 'Delete page 2').onPressed!;
    await tester.tap(find.text('Export PDF (2 pages)'));
    // The share is still parked on its Completer here, so the export spinner
    // keeps scheduling frames and nothing can settle yet.
    await pumpUntil(tester, () => platform.calls == 1, settle: false);
    expect(iconButton(tester, 'Delete page 2').onPressed, isNull);
    staleDelete();
    await tester.pump();
    expect(store.saves, isEmpty);
    share.complete(const ShareResult('shared', ShareResultStatus.success));
    await tester.pumpAndSettle();

    expect(find.text('Keep this draft?'), findsNothing);
    expect(store.clearCalls, 0);
    expect(find.text('Export PDF (2 pages)'), findsOneWidget);
    staleDelete();
    await tester.pump();
    expect(store.saves.last, orderedEquals([first]));
  });

  for (final status in ShareResultStatus.values) {
    testWidgets('share $status retains draft without cleanup or success claims', (
      tester,
    ) async {
      final store = _DraftStore();
      final platform = _SharePlatform(status: status);
      await pumpHome(
        tester,
        store,
        pages: [page(1)],
        sharePlus: SharePlus.custom(platform),
      );
      await tester.tap(find.text('Export PDF (1 page)'));
      await pumpUntil(tester, () => platform.calls == 1);
      expect(find.text('Keep this draft?'), findsNothing);
      expect(find.textContaining('The PDF was shared'), findsNothing);
      expect(find.text('Export PDF (1 page)'), findsOneWidget);
      expect(
        find.text('Drafts are temporary. Export a PDF to keep a copy.'),
        findsOneWidget,
      );
      expect(store.clearCalls, 0);
      // Exporting again also leaves the draft intact without an extra decision.
      await tester.tap(find.text('Export PDF (1 page)'));
      await pumpUntil(tester, () => platform.calls == 2);
      expect(find.byType(AlertDialog), findsNothing);
      expect(store.clearCalls, 0);
      // Cleanup is explicit and still requires confirmation.
      await tapClearAllPages(tester);
      expect(find.text('Clear all pages?'), findsOneWidget);
      expect(store.clearCalls, 0);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Export PDF (1 page)'), findsOneWidget);
      await tapClearAllPages(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
      await tester.pumpAndSettle();
      expect(store.clearCalls, 1);
      expect(find.text('Ready to scan'), findsOneWidget);
    });
  }

  testWidgets('failed saves remain actionable and retry the current pages', (
    tester,
  ) async {
    final store = _DraftStore(saveError: StateError('private file path'));
    final first = page(1);
    final second = page(2);
    final third = page(3);
    final semantics = tester.ensureSemantics();
    await pumpHome(tester, store, pages: [first, second, third]);
    await tapDelete(tester, 1);
    await tester.pumpAndSettle();
    // The fixed status slot shows a short error; the full explanation is the
    // live-region announcement.
    final failure = find.bySemanticsLabel(
      'Could not save the latest draft changes. Keep the app open and retry.',
    );
    expect(failure, findsOneWidget);
    expect(find.text('Draft not saved'), findsOneWidget);
    expect(
      find.text('Drafts are temporary. Export a PDF to keep a copy.'),
      findsNothing,
    );
    expect(find.textContaining('private file path'), findsNothing);
    expect(
      tester
          .getSemantics(failure)
          .getSemanticsData()
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );
    expect(find.widgetWithText(SnackBarAction, 'Undo'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(failure, findsOneWidget);
    await tester.tap(find.byKey(const Key('retry_draft_save')));
    await tester.pumpAndSettle();
    expect(store.saves, hasLength(2));
    expect(failure, findsOneWidget);
    // New edits may fail too; retry must save the newest state, not a held
    // snapshot of the first failure.
    await tapDelete(tester, 1);
    await tester.pumpAndSettle();
    store.saveError = null;
    await tester.tap(find.byKey(const Key('retry_draft_save')));
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals([third]));
    expect(failure, findsNothing);
    expect(find.widgetWithText(SnackBarAction, 'Undo'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('unrelated feedback waits until deletion Undo is used', (
    tester,
  ) async {
    final store = _DraftStore();
    final first = page(1);
    final second = page(2);
    await pumpHome(tester, store, pages: [first, second]);
    await tapDelete(tester, 1);
    await tester.pumpAndSettle();
    // A gallery failure is ordinary feedback that previously displaced Undo.
    ImagePickerPlatform.instance = _FailingPicker();
    await tester.tap(find.byTooltip('Import from gallery'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SnackBarAction, 'Undo'), findsOneWidget);
    expect(find.text('Could not open the photo gallery.'), findsNothing);
    await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals([first, second]));
    expect(find.text('Could not open the photo gallery.'), findsOneWidget);
  });

  testWidgets('deferred feedback appears after Undo expires', (tester) async {
    final store = _DraftStore();
    await pumpHome(tester, store, pages: [page(1), page(2)]);
    await tapDelete(tester, 1);
    await tester.pumpAndSettle();
    ImagePickerPlatform.instance = _FailingPicker();
    await tester.tap(find.byTooltip('Import from gallery'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SnackBarAction, 'Undo'), findsNothing);
    expect(find.text('Could not open the photo gallery.'), findsOneWidget);
    expect(store.saves, hasLength(1));
  });
}
