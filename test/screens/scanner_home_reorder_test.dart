import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  DragTarget<int> target(WidgetTester tester, int index) =>
      tester.widget<DragTarget<int>>(
        find.descendant(
          of: find.byKey(ValueKey('page_semantics_$index')),
          matching: find.byType(DragTarget<int>),
        ),
      );

  testWidgets('cards omit reorder arrows and the persistent draft sentence', (
    tester,
  ) async {
    await pumpHome(tester);
    expect(find.byIcon(Icons.swap_vert), findsNothing);
    expect(find.byType(PopupMenuButton<int>), findsNothing);
    expect(
      find.text('Drafts are temporary. Export a PDF to keep a copy.'),
      findsNothing,
    );
    await tester.tap(find.byTooltip('Delete page 1'));
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals([pages[1], pages[2]]));
    expect(find.byType(PagePreviewScreen), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals(pages));
  });

  testWidgets('a reordered draft restores in the saved order', (tester) async {
    await pumpHome(tester);
    target(tester, 0).onAcceptWithDetails!(
      DragTargetDetails(data: 1, offset: Offset.zero),
    );
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals([pages[1], pages[0], pages[2]]));
    await tester.pumpWidget(const SizedBox());
    await pumpHome(tester, initial: []);
    final image = tester.widget<Image>(
      find.descendant(
        of: find.byKey(const ValueKey('page_semantics_0')),
        matching: find.byType(Image),
      ),
    );
    expect(
      (image.image as ResizeImage).imageProvider,
      MemoryImage(pages[1].processedBytes),
    );
    target(tester, 1).onAcceptWithDetails!(
      DragTargetDetails(data: 0, offset: Offset.zero),
    );
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals(pages));
  });

  testWidgets('picker locks dragging and stale callbacks cannot mutate', (
    tester,
  ) async {
    await pumpHome(tester);
    final staleMove = target(tester, 0).onAcceptWithDetails!;
    picker.selection = Completer<List<XFile>>();
    await tester.tap(find.byTooltip('Import from gallery'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LongPressDraggable<int>>(
            find.byType(LongPressDraggable<int>).first,
          )
          .maxSimultaneousDrags,
      0,
    );
    staleMove(DragTargetDetails(data: 1, offset: Offset.zero));
    await tester.pump();
    expect(store.saves, isEmpty);
    picker.selection!.complete([]);
    await tester.pumpAndSettle();
    staleMove(DragTargetDetails(data: 1, offset: Offset.zero));
    await tester.pumpAndSettle();
    expect(store.saves.last, orderedEquals([pages[1], pages[0], pages[2]]));
  });

  testWidgets('clearing locks dragging and invalidates saved callbacks', (
    tester,
  ) async {
    await pumpHome(tester);
    final staleMove = target(tester, 0).onAcceptWithDetails!;
    store.clearing = Completer<void>();
    await tester.tap(find.byTooltip('Clear all'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    staleMove(DragTargetDetails(data: 1, offset: Offset.zero));
    await tester.pump();
    expect(store.saves, isEmpty);
    store.clearing!.complete();
    await tester.pumpAndSettle();
    staleMove(DragTargetDetails(data: 1, offset: Offset.zero));
    await tester.pumpAndSettle();
    expect(store.saves, isEmpty);
    expect(find.text('Ready to Scan'), findsOneWidget);
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
