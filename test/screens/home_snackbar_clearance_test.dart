import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/draft_store.dart';

import '../support/layout_stability.dart';

/// Gallery requests fail, so the gallery button shows a plain message.
class _Picker extends ImagePickerPlatform {
  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) => throw PlatformException(code: 'unexpected');
}

class _Store implements DraftStore {
  final saves = <List<ScannedPage>>[];

  @override
  Future<List<ScannedPage>> load() async => const [];

  @override
  Future<void> save(List<ScannedPage> pages) async => saves.add(List.of(pages));

  @override
  Future<void> clear() async {}
}

/// Phones in portrait and landscape, at default and large text.
const _cases = [
  LayoutCase(Size(390, 844), 1.0),
  LayoutCase(Size(390, 844), 2.0),
  LayoutCase(Size(320, 568), 1.0),
  LayoutCase(Size(844, 390), 1.0),
  LayoutCase(Size(800, 1280), 1.0),
  ...highDensityLargeTextCases,
];

// #169: deletion Undo and drag reordering near the grid's edges.
void main() {
  late ImagePickerPlatform originalPicker;
  late Uint8List imageBytes;
  late _Store store;
  late List<ScannedPage> pages;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _Picker();
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    store = _Store();
  });

  tearDown(() => ImagePickerPlatform.instance = originalPicker);

  Future<void> pumpHome(
    WidgetTester tester,
    LayoutCase layoutCase, {
    required int pageCount,
  }) async {
    pages = [
      for (var i = 0; i < pageCount; i++)
        ScannedPage(
          originalBytes: imageBytes,
          processedBytes: imageBytes,
          corners: const [],
          brightness: i.toDouble(),
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        builder: withTextScale(layoutCase.textScale),
        home: ScannerHomePage(
          searchablePdfEnabled: false,
          draftStore: store,
          initialPages: pages,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ScrollPosition gridPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  Future<void> scrollToEnd(WidgetTester tester) async {
    final position = gridPosition(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
  }

  Finder card(int index) => find.byKey(ValueKey('page_semantics_$index'));

  testLayoutMatrix('the last row can be scrolled above the Undo message', (
    tester,
    layoutCase,
  ) async {
    await pumpHome(tester, layoutCase, pageCount: 9);
    await tester.tap(find.byTooltip('Delete page 1'));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOneWidget);
    await scrollToEnd(tester);

    final message = tester.getRect(find.byType(SnackBar));
    final grid = tester.getRect(find.byType(GridView));
    for (var i = 0; i < 8; i++) {
      final delete = find.byTooltip('Delete page ${i + 1}');
      final move = find.byTooltip('Reorder page ${i + 1}');
      if (delete.evaluate().isEmpty) continue;
      for (final control in [delete, move]) {
        final rect = tester.getRect(control).intersect(grid);
        if (rect.width <= 0 || rect.height <= 0) continue;
        expect(
          rect.overlaps(message),
          isFalse,
          reason: 'page ${i + 1} is under the message',
        );
      }
    }
    // The last page's controls are among them.
    expect(
      tester.getRect(find.byTooltip('Delete page 8')).bottom,
      lessThanOrEqualTo(message.top + 0.5),
    );
    expect(tester.takeException(), isNull);
  }, cases: _cases);

  testLayoutMatrix('a message coming and going does not move the cards', (
    tester,
    layoutCase,
  ) async {
    await pumpHome(tester, layoutCase, pageCount: 9);
    await scrollToEnd(tester);
    Map<String, Finder> cards() => {
      for (var i = 0; i < 9; i++)
        if (card(i).evaluate().isNotEmpty) 'page ${i + 1}': card(i),
    };
    await expectStableRects(tester, cards(), () async {
      await tester.tap(find.byTooltip('Import from gallery'));
      await tester.pumpAndSettle();
      expect(find.text('Could not open the gallery.'), findsOneWidget);
    }, reason: 'appears');
    // Scrolled into the space kept clear of the message, then it leaves.
    await scrollToEnd(tester);
    final extent = gridPosition(tester).maxScrollExtent;
    await expectStableRects(tester, cards(), () async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    }, reason: 'leaves');
    // The extra space goes once the user scrolls away from the end.
    await tester.drag(find.byType(GridView), const Offset(0, 300));
    await tester.pumpAndSettle();
    if (extent > 0) {
      expect(gridPosition(tester).maxScrollExtent, lessThan(extent));
    }
    expect(tester.takeException(), isNull);
  }, cases: _cases);

  testWidgets('a tap right after Undo expires does not reach the cards', (
    tester,
  ) async {
    await pumpHome(tester, const LayoutCase(Size(390, 844), 1.0), pageCount: 4);
    await tester.tap(find.byTooltip('Delete page 4'));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOneWidget);
    expect(store.saves.last, hasLength(3));

    // Undo times out and leaves just before the finger lands.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsNothing);
    await tester.tap(find.byTooltip('Delete page 3'));
    await tester.tap(find.byTooltip('Reorder page 1'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(store.saves.last, hasLength(3), reason: 'the delete was ignored');
    expect(find.text('Move later'), findsNothing, reason: 'no menu opened');

    // A moment later the cards respond again.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Delete page 3'));
    await tester.pumpAndSettle();
    expect(store.saves.last, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Undo restores the page while the tap guard is unused', (
    tester,
  ) async {
    await pumpHome(tester, const LayoutCase(Size(390, 844), 1.0), pageCount: 3);
    await tester.tap(find.byTooltip('Delete page 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals(pages));
    // Undo is the user's own action, not a timeout: cards respond at once.
    await tester.tap(find.byTooltip('Delete page 1'));
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals(pages.skip(1)));
    expect(tester.takeException(), isNull);
  });

  for (final layoutCase in [
    const LayoutCase(Size(390, 844), 1.0),
    const LayoutCase(Size(412, 915), 2.0),
    const LayoutCase(Size(844, 390), 1.0),
  ]) {
    testWidgets('dragging a page near the edges scrolls the grid '
        '[$layoutCase]', (tester) async {
      applyLayoutCase(tester, layoutCase);
      await pumpHome(tester, layoutCase, pageCount: 20);
      final grid = tester.getRect(find.byType(GridView));
      final position = gridPosition(tester);
      expect(position.pixels, 0);

      final column = tester.getRect(card(0)).center.dx;
      final gesture = await tester.startGesture(tester.getRect(card(0)).center);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      // Hold the page just above the grid's bottom edge.
      await gesture.moveTo(Offset(column, grid.bottom - 8));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final scrolled = position.pixels;
      expect(scrolled, greaterThan(100));

      // Released without moving again: it lands on the card under the
      // finger now, not on the one it hovered before the grid scrolled.
      final target = [
        for (var i = 0; i < 20; i++)
          if (card(i).evaluate().isNotEmpty &&
              tester.getRect(card(i)).contains(Offset(column, grid.bottom - 8)))
            i,
      ];
      await gesture.up();
      await tester.pumpAndSettle();
      if (target.isNotEmpty) {
        expect(store.saves.last.indexOf(pages[0]), target.single);
      }
      expect(store.saves.last.indexOf(pages[0]), greaterThan(0));

      // And the top edge scrolls back.
      final visible = [
        for (var i = 0; i < 20; i++)
          if (card(i).evaluate().isNotEmpty &&
              grid.contains(tester.getRect(card(i)).center))
            i,
      ];
      final back = await tester.startGesture(
        tester.getRect(card(visible.first)).center,
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await back.moveTo(Offset(column, grid.top + 8));
      final before = position.pixels;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(position.pixels, lessThan(before));
      await back.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
