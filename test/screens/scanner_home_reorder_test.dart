import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/page_preview_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/draft_store.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

class _Store implements DraftStore {
  final saves = <List<ScannedPage>>[];
  Completer<void>? clearing;

  @override
  Future<List<ScannedPage>> load() async => saves.isEmpty ? [] : saves.last;

  @override
  Future<void> save(List<ScannedPage> pages) async => saves.add(List.of(pages));

  @override
  Future<void> clear() async => await clearing?.future;
}

class _Picker extends ImagePickerPlatform {
  Completer<List<XFile>>? selection;

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => await selection?.future ?? [];
}

void main() {
  late ImagePickerPlatform originalPicker;
  late _Picker picker;
  late _Store store;
  late List<ScannedPage> pages;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = picker = _Picker();
    store = _Store();
    final data = await rootBundle.load('assets/icon/icon.png');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    pages = List.generate(
      3,
      (index) => ScannedPage(
        originalBytes: bytes,
        processedBytes: bytes,
        corners: const [],
        brightness: index.toDouble(),
      ),
    );
  });

  tearDown(() => ImagePickerPlatform.instance = originalPicker);

  Future<void> pumpHome(
    WidgetTester tester, {
    List<ScannedPage>? initial,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: initial ?? pages,
          draftStore: store,
          searchablePdfEnabled: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Map<CustomSemanticsAction, VoidCallback> actions(
    WidgetTester tester,
    int page,
  ) =>
      tester
          .widget<Semantics>(find.byKey(ValueKey('page_semantics_${page - 1}')))
          .properties
          .customSemanticsActions ??
      {};

  VoidCallback move(WidgetTester tester, int page, String label) => actions(
    tester,
    page,
  ).entries.singleWhere((entry) => entry.key.label == label).value;

  testWidgets(
    'compact previews have delete buttons but no visible reorder controls',
    (tester) async {
      await pumpHome(tester);
      expect(find.byIcon(Icons.swap_vert), findsNothing);
      expect(find.byTooltip('Reorder page 1'), findsNothing);
      expect(find.text('Move earlier'), findsNothing);
      for (var i = 1; i <= 3; i++) {
        expect(find.byTooltip('Delete page $i'), findsOneWidget);
      }
    },
  );

  testWidgets(
    'accessible earlier/later actions preserve pages and persist order',
    (tester) async {
      await pumpHome(tester);
      move(tester, 2, 'Move earlier')();
      await tester.pumpAndSettle();
      expect(store.saves.last, orderedEquals([pages[1], pages[0], pages[2]]));
      expect(find.byType(PagePreviewScreen), findsNothing);
      move(tester, 1, 'Move later')();
      await tester.pumpAndSettle();
      expect(store.saves.last, orderedEquals(pages));
      expect(store.saves, hasLength(2));
    },
  );

  testWidgets('boundary pages only offer valid accessible moves', (
    tester,
  ) async {
    await pumpHome(tester);
    expect(actions(tester, 1).keys.map((action) => action.label), [
      'Move later',
    ]);
    expect(actions(tester, 3).keys.map((action) => action.label), [
      'Move earlier',
    ]);
    expect(store.saves, isEmpty);
  });

  testWidgets('a reordered draft restores in the saved order', (tester) async {
    await pumpHome(tester);
    move(tester, 2, 'Move earlier')();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await pumpHome(tester, initial: []);
    move(tester, 1, 'Move later')();
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals(pages));
  });

  testWidgets('single-page drafts need no reorder actions', (tester) async {
    await pumpHome(tester, initial: [pages.first]);
    expect(actions(tester, 1), isEmpty);
    expect(find.byTooltip('Delete page 1'), findsOneWidget);
  });

  testWidgets('picker locks accessible moves and stale callbacks', (
    tester,
  ) async {
    await pumpHome(tester);
    final staleMove = move(tester, 2, 'Move earlier');
    picker.selection = Completer<List<XFile>>();
    await tester.tap(find.byTooltip('Import from gallery'));
    await tester.pumpAndSettle();
    expect(actions(tester, 2), isEmpty);
    staleMove();
    await tester.pump();
    expect(store.saves, isEmpty);
    picker.selection!.complete([]);
    await tester.pumpAndSettle();
    move(tester, 2, 'Move earlier')();
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals([pages[1], pages[0], pages[2]]));
  });

  testWidgets('clearing locks moves and invalidates stale callbacks', (
    tester,
  ) async {
    await pumpHome(tester);
    final staleMove = move(tester, 2, 'Move earlier');
    store.clearing = Completer<void>();
    await tester.tap(find.byTooltip('Clear all'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(actions(tester, 2), isEmpty);
    staleMove();
    await tester.pump();
    expect(store.saves, isEmpty);
    store.clearing!.complete();
    await tester.pumpAndSettle();
    staleMove();
    await tester.pumpAndSettle();
    expect(store.saves, isEmpty);
    expect(find.text('Ready to Scan'), findsOneWidget);
  });

  testWidgets('stale actions cannot move the wrong page after a reorder', (
    tester,
  ) async {
    await pumpHome(tester);
    final staleMove = move(tester, 1, 'Move later');
    move(tester, 2, 'Move earlier')();
    await tester.pumpAndSettle();
    staleMove();
    await tester.pumpAndSettle();
    expect(store.saves, hasLength(1));
    expect(store.saves.last, orderedEquals([pages[1], pages[0], pages[2]]));
  });

  testWidgets('cancelling a drag leaves order and persistence unchanged', (
    tester,
  ) async {
    await pumpHome(tester);
    final source = find.descendant(
      of: find.byKey(const ValueKey('page_semantics_0')),
      matching: find.byType(Image),
    );
    final gesture = await tester.startGesture(tester.getCenter(source));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(10, 10));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(store.saves, isEmpty);
  });

  testWidgets('drag-and-drop remains available and persists the same way', (
    tester,
  ) async {
    await pumpHome(tester);
    final source = find.byKey(const ValueKey('page_semantics_0'));
    final target = find.byKey(const ValueKey('page_semantics_1'));
    final start = tester.getCenter(
      find.descendant(of: source, matching: find.byType(Image)),
    );
    final end = tester.getCenter(
      find.descendant(of: target, matching: find.byType(Image)),
    );
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals([pages[1], pages[0], pages[2]]));
  });
}
