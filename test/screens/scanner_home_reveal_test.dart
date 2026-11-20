import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';

import '../support/layout_stability.dart';

const _corners = [Offset(5, 5), Offset(95, 5), Offset(95, 95), Offset(5, 95)];

class _Picker extends ImagePickerPlatform {
  List<XFile> galleryPhotos = [];

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => galleryPhotos;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
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

Finder _thumbnail(int index) => find.byKey(ValueKey('page_thumbnail_$index'));

Finder _card(int index) =>
    find.ancestor(of: _thumbnail(index), matching: find.byType(Card));

void main() {
  late ImagePickerPlatform originalPicker;
  late _Picker picker;
  late Uint8List imageBytes;
  late Directory directory;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = picker = _Picker();
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    directory = Directory.systemTemp.createTempSync('reveal-');
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    directory.deleteSync(recursive: true);
  });

  Future<void> pumpHome(
    WidgetTester tester,
    LayoutCase layoutCase, {
    required int pageCount,
    bool disableAnimations = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(layoutCase.textScale),
            disableAnimations: disableAnimations,
          ),
          child: child!,
        ),
        home: ScannerHomePage(
          searchablePdfEnabled: false,
          cornerAdjustOperations: _Operations(),
          initialPages: [
            for (var i = 0; i < pageCount; i++)
              ScannedPage(
                originalBytes: imageBytes,
                processedBytes: imageBytes,
                corners: const [],
              ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double gridOffset(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        ),
      )
      .position
      .pixels;

  /// The whole card is inside the grid and clear of the camera button.
  void expectRevealed(WidgetTester tester, int index) {
    final grid = tester.getRect(find.byType(GridView));
    final card = tester.getRect(_card(index));
    expect(card.top, greaterThanOrEqualTo(grid.top - 0.5));
    expect(card.bottom, lessThanOrEqualTo(grid.bottom + 0.5));
    final camera = tester.getRect(find.byType(FloatingActionButton));
    expect(
      tester
          .getRect(find.byTooltip('Delete page ${index + 1}'))
          .overlaps(camera),
      isFalse,
    );
  }

  /// Scrolls to the end, then moves the first page of the first fully visible
  /// row one place earlier, into the row above it, which is out of view.
  /// Returns the moved page's new index and the scroll offset before the move.
  Future<(int, double)> movePageIntoHiddenRow(
    WidgetTester tester,
    int pageCount,
  ) async {
    await tester.drag(find.byType(GridView), const Offset(0, -10000));
    await tester.pumpAndSettle();
    expect(gridOffset(tester), greaterThan(0));
    final grid = tester.getRect(find.byType(GridView));
    final built = [
      for (var i = 0; i < pageCount; i++)
        if (_thumbnail(i).evaluate().isNotEmpty) i,
    ];
    final firstColumn = built
        .map((i) => tester.getRect(_card(i)).left)
        .reduce(math.min);
    final index = built.firstWhere((i) {
      final card = tester.getRect(_card(i));
      return i > 0 &&
          (card.left - firstColumn).abs() < 0.5 &&
          card.top >= grid.top - 0.5;
    });
    await tester.tap(find.byTooltip('Reorder page ${index + 1}'));
    await tester.pumpAndSettle();
    final offset = gridOffset(tester);
    await tester.tap(find.text('Move earlier'));
    return (index - 1, offset);
  }

  // #164
  testLayoutMatrix(
    '"Move earlier" into a hidden row scrolls the moved page into view',
    (tester, layoutCase) async {
      const pageCount = 30;
      await pumpHome(tester, layoutCase, pageCount: pageCount);
      final (moved, before) = await movePageIntoHiddenRow(tester, pageCount);
      await tester.pumpAndSettle();
      expect(gridOffset(tester), lessThan(before));
      expectRevealed(tester, moved);
      expect(tester.takeException(), isNull);
    },
    cases: [
      for (final size in layoutSizes) LayoutCase(size, 1.0),
      const LayoutCase(Size(390, 844), 2.0),
    ],
  );

  testLayoutMatrix(
    'the scroll animates, or jumps with reduced motion',
    (tester, layoutCase) async {
      for (final reduceMotion in [false, true]) {
        await pumpHome(
          tester,
          layoutCase,
          pageCount: 12,
          disableAnimations: reduceMotion,
        );
        await movePageIntoHiddenRow(tester, 12);
        // The move, then the scroll after its layout.
        await tester.pump();
        await tester.pump();
        final early = gridOffset(tester);
        await tester.pumpAndSettle();
        final settled = gridOffset(tester);
        if (reduceMotion) {
          expect(early, settled);
        } else {
          expect(early, greaterThan(settled));
        }
      }
    },
    cases: const [LayoutCase(Size(390, 844), 1.0)],
  );

  testLayoutMatrix(
    'a page already in view does not scroll when moved',
    (tester, layoutCase) async {
      await pumpHome(tester, layoutCase, pageCount: 12);
      await tester.tap(find.byTooltip('Reorder page 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move later'));
      await tester.pumpAndSettle();
      expect(gridOffset(tester), 0);
    },
    cases: const [LayoutCase(Size(390, 844), 1.0)],
  );

  testLayoutMatrix(
    'a page added by an import is scrolled into view',
    (tester, layoutCase) async {
      final file = File('${directory.path}/added.png')
        ..writeAsBytesSync(imageBytes);
      picker.galleryPhotos = [XFile(file.path)];
      await pumpHome(tester, layoutCase, pageCount: 10);
      expect(gridOffset(tester), 0);
      await tester.tap(find.byTooltip('Import from gallery'));
      for (var i = 0; i < 100; i++) {
        if (find.text('Preview page').evaluate().isNotEmpty) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview page'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add page'));
      await tester.pumpAndSettle();

      expect(find.byType(CornerAdjustScreen), findsNothing);
      expect(gridOffset(tester), greaterThan(0));
      expectRevealed(tester, 10);
      expect(tester.takeException(), isNull);
    },
    cases: [
      const LayoutCase(Size(390, 844), 1.0),
      const LayoutCase(Size(640, 300), 1.0),
    ],
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
