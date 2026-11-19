import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/page_preview_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/draft_store.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import '../support/home_menu.dart';

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

  Future<void> openMenu(WidgetTester tester, int page) async {
    final menu = find.byTooltip('Reorder page $page');
    await tester.scrollUntilVisible(
      menu,
      200,
      maxScrolls: 50,
      scrollable: find.descendant(
        of: find.byType(GridView),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(menu);
    await tester.pumpAndSettle();
  }

  PopupMenuButton<int> menu(WidgetTester tester, int page) =>
      tester.widget<PopupMenuButton<int>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is PopupMenuButton<int> &&
              widget.tooltip == 'Reorder page $page',
        ),
      );

  testWidgets(
    'visible earlier/later actions preserve pages and persist order',
    (tester) async {
      await pumpHome(tester);
      await openMenu(tester, 2);
      await tester.tap(find.text('Move earlier'));
      await tester.pumpAndSettle();
      expect(store.saves.last, orderedEquals([pages[1], pages[0], pages[2]]));
      expect(find.byType(PagePreviewScreen), findsNothing);

      await openMenu(tester, 1);
      expect(
        tester
            .widget<PopupMenuItem<int>>(
              find.ancestor(
                of: find.text('Move earlier'),
                matching: find.byType(PopupMenuItem<int>),
              ),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(find.text('Move later'));
      await tester.pumpAndSettle();
      expect(store.saves.last, orderedEquals(pages));
      expect(store.saves, hasLength(2));
      expect(find.byType(PagePreviewScreen), findsNothing);
    },
  );

  testWidgets(
    'last-page bounds and cancelling the menu do not change a draft',
    (tester) async {
      await pumpHome(tester);
      await openMenu(tester, 3);
      expect(
        tester
            .widget<PopupMenuItem<int>>(
              find.ancestor(
                of: find.text('Move later'),
                matching: find.byType(PopupMenuItem<int>),
              ),
            )
            .enabled,
        isFalse,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(store.saves, isEmpty);
      expect(find.byType(PagePreviewScreen), findsNothing);
      await openMenu(tester, 3);
      await tester.tap(find.text('Move earlier'));
      await tester.pumpAndSettle();
      expect(store.saves.last, orderedEquals([pages[0], pages[2], pages[1]]));
    },
  );

  testWidgets('a reordered draft restores in the saved order', (tester) async {
    await pumpHome(tester);
    await openMenu(tester, 2);
    await tester.tap(find.text('Move earlier'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await pumpHome(tester, initial: []);
    // Moving the restored first page later must recover the original order.
    await openMenu(tester, 1);
    await tester.tap(find.text('Move later'));
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals(pages));
  });

  testWidgets('a single page keeps a disabled reorder menu', (tester) async {
    await pumpHome(tester, initial: [pages.first]);
    // The slot stays so every card footer has the same layout.
    expect(menu(tester, 1).enabled, isFalse);
    expect(find.byTooltip('Delete page 1'), findsOneWidget);
  });

  testWidgets('picker locks visible menus and stale selections cannot mutate', (
    tester,
  ) async {
    await pumpHome(tester);
    final staleMove = menu(tester, 2).onSelected!;
    picker.selection = Completer<List<XFile>>();
    await tester.tap(find.byTooltip('Import from gallery'));
    await tester.pumpAndSettle();
    expect(menu(tester, 2).enabled, isFalse);
    staleMove(-1);
    await tester.pump();
    expect(store.saves, isEmpty);
    picker.selection!.complete([]);
    await tester.pumpAndSettle();
    expect(menu(tester, 2).enabled, isTrue);
    await openMenu(tester, 2);
    await tester.tap(find.text('Move earlier'));
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals([pages[1], pages[0], pages[2]]));
  });

  testWidgets('clearing locks menus and invalidates saved menu callbacks', (
    tester,
  ) async {
    await pumpHome(tester);
    final staleMove = menu(tester, 2).onSelected!;
    store.clearing = Completer<void>();
    await tapClearAllPages(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(menu(tester, 2).enabled, isFalse);
    staleMove(-1);
    await tester.pump();
    expect(store.saves, isEmpty);
    store.clearing!.complete();
    await tester.pumpAndSettle();
    staleMove(-1);
    await tester.pumpAndSettle();
    expect(store.saves, isEmpty);
    expect(find.text('Ready to Scan'), findsOneWidget);
  });

  testWidgets('stale selections cannot move the wrong page after a reorder', (
    tester,
  ) async {
    await pumpHome(tester);
    final staleMove = menu(tester, 1).onSelected!;
    await openMenu(tester, 2);
    await tester.tap(find.text('Move earlier'));
    await tester.pumpAndSettle();
    staleMove(1);
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
