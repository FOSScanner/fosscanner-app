import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/draft_store.dart';

import '../support/home_menu.dart';
import '../support/layout_stability.dart';

class _Store implements DraftStore {
  _Store({Future<List<ScannedPage>>? loaded})
    : loaded = loaded ?? Future.value(const []);

  final Future<List<ScannedPage>> loaded;
  Object? saveError;

  @override
  Future<List<ScannedPage>> load() => loaded;

  @override
  Future<void> save(List<ScannedPage> pages) async {
    if (saveError case final error?) throw error;
  }

  @override
  Future<void> clear() async {}
}

class _CameraPicker extends ImagePickerPlatform {
  _CameraPicker({this.camera = true});

  final bool camera;

  /// While set, gallery selection stays open until it completes.
  Completer<List<XFile>>? gallery;

  @override
  bool supportsImageSource(ImageSource source) =>
      camera || source != ImageSource.camera;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) => gallery?.future ?? Future.value(const []);
}

final _thumbnail = find.byKey(const ValueKey('page_thumbnail_0'));
final _undo = find.widgetWithText(SnackBarAction, 'Undo');
final _camera = find.byType(FloatingActionButton);

/// Matrix entries at the default and the maximum supported text scale.
final _defaultAndLargeText = [
  for (final layoutCase in layoutMatrix)
    if (layoutCase.textScale != 1.3) layoutCase,
];

void main() {
  late ImagePickerPlatform originalPicker;
  late Uint8List imageBytes;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _CameraPicker();
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  });

  tearDown(() => ImagePickerPlatform.instance = originalPicker);

  ScannedPage page() => ScannedPage(
    originalBytes: imageBytes,
    processedBytes: imageBytes,
    corners: const [],
  );

  void pressIconButton(WidgetTester tester, String tooltip) => tester
      .widget<IconButton>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(IconButton),
        ),
      )
      .onPressed!();

  /// Pumps the home page without settling, so a pending restore stays visible.
  Future<void> pumpHome(
    WidgetTester tester,
    LayoutCase layoutCase, {
    int pageCount = 0,
    DraftStore? store,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: withTextScale(layoutCase.textScale),
        home: ScannerHomePage(
          searchablePdfEnabled: true,
          draftStore: store ?? _Store(),
          initialPages: [for (var i = 0; i < pageCount; i++) page()],
        ),
      ),
    );
    await tester.pump();
  }

  // #149
  testLayoutMatrix(
    'a draft-save failure and its retry do not move the page grid',
    (tester, layoutCase) async {
      final store = _Store();
      await pumpHome(tester, layoutCase, pageCount: 4, store: store);
      await tester.pumpAndSettle();
      final anchors = {
        'grid': find.byType(GridView),
        'first card': find.byType(Card).first,
        'status slot': find.byKey(const Key('draft_status_slot')),
      };

      store.saveError = StateError('injected save failure');
      await expectStableRects(tester, anchors, () async {
        // Any edit saves the draft; this one swaps the first two pages.
        tester
            .widget<DragTarget<int>>(find.byType(DragTarget<int>).first)
            .onAcceptWithDetails!(
          DragTargetDetails<int>(data: 1, offset: Offset.zero),
        );
        await tester.pumpAndSettle();
        expect(find.text('Draft not saved'), findsOneWidget);
      }, reason: 'save failure');

      store.saveError = null;
      await expectStableRects(tester, anchors, () async {
        await tester.tap(find.byKey(const Key('retry_draft_save')));
        await tester.pumpAndSettle();
        expect(find.text('Draft not saved'), findsNothing);
      }, reason: 'retry');
      expect(tester.takeException(), isNull);
    },
  );

  testLayoutMatrix(
    'image intake help shares the status slot instead of moving the grid',
    (tester, layoutCase) async {
      final picker = _CameraPicker()..gallery = Completer<List<XFile>>();
      ImagePickerPlatform.instance = picker;
      await pumpHome(tester, layoutCase, pageCount: 4);
      await tester.pumpAndSettle();
      final anchors = {
        'grid': find.byType(GridView),
        'first card': find.byType(Card).first,
        'status slot': find.byKey(const Key('draft_status_slot')),
      };
      expect(find.text('Image intake help'), findsNothing);

      await expectStableRects(tester, anchors, () async {
        await tester.tap(find.byTooltip('Import from gallery'));
        await tester.pump();
        expect(find.text('Image intake help'), findsOneWidget);
      }, reason: 'selection in progress');

      await expectStableRects(tester, anchors, () async {
        picker.gallery!.complete(const []);
        await tester.pumpAndSettle();
        expect(find.text('Image intake help'), findsNothing);
      }, reason: 'selection finished');
      expect(tester.takeException(), isNull);
    },
  );

  // #151
  const appBarActions = {
    'QR button': 'Scan QR code or barcode',
    'gallery button': 'Import from gallery',
    'overflow button': 'More options',
  };
  Map<String, Finder> fixedControls({bool camera = true}) => {
    for (final entry in appBarActions.entries)
      entry.key: find.byTooltip(entry.value),
    if (camera) 'camera button': find.byType(FloatingActionButton),
  };

  testLayoutMatrix(
    'app-bar actions and the camera button stay put from 0 to 1 to 0 pages',
    (tester, layoutCase) async {
      final restore = Completer<List<ScannedPage>>();
      await pumpHome(tester, layoutCase, store: _Store(loaded: restore.future));
      expect(find.byKey(const Key('pdf_export_bar')), findsNothing);
      final controls = fixedControls();
      final camera = find.byType(FloatingActionButton);
      final emptyCamera = tester.getRect(camera);

      await expectStableRects(tester, fixedControls(camera: false), () async {
        restore.complete([page()]);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pdf_export_bar')), findsOneWidget);
      }, reason: '0 -> 1 page');
      // Before the first export bar was laid out, the camera button reserves
      // the bar's one-line height. Where this branch's bar label still wraps
      // (#152 gives the bar that fixed height) the button rises above the bar
      // once; every later empty/non-empty change keeps it in place.
      final bar = tester.getRect(find.byKey(const Key('pdf_export_bar')));
      expect(tester.getRect(camera).bottom, lessThanOrEqualTo(bar.top - 16));
      final oneLineBar =
          math.max(56, layoutCase.textScale * 14 * 1.43 + 32) + 16;
      if ((bar.height - oneLineBar).abs() < 0.5) {
        expect(tester.getRect(camera), emptyCamera);
      }

      // Deleting the last page shows Undo above the camera button; nothing
      // moves, and after Undo everything is still where it was.
      await expectStableRects(tester, controls, () async {
        await expectStableRects(tester, controls, () async {
          pressIconButton(tester, 'Delete page 1');
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('pdf_export_bar')), findsNothing);
        }, reason: 'delete');
        await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pdf_export_bar')), findsOneWidget);
      }, reason: 'delete + Undo');

      await expectStableRects(tester, controls, () async {
        await tapClearAllPages(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pdf_export_bar')), findsNothing);
      }, reason: 'clear');
      expect(tester.takeException(), isNull);
    },
  );

  testLayoutMatrix(
    'the camera button does not move when the deleted page is not undone',
    (tester, layoutCase) async {
      await pumpHome(tester, layoutCase, pageCount: 1);
      await tester.pumpAndSettle();
      await expectStableRects(tester, fixedControls(), () async {
        pressIconButton(tester, 'Delete page 1');
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 11));
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
      });
      expect(tester.takeException(), isNull);
    },
  );

  testLayoutMatrix('the empty-state title stays put when restoring ends', (
    tester,
    layoutCase,
  ) async {
    final restore = Completer<List<ScannedPage>>();
    await pumpHome(tester, layoutCase, store: _Store(loaded: restore.future));
    expect(find.text('Restoring draft…'), findsOneWidget);
    final title = find.byKey(const Key('empty_state_title'));
    final restoringTitle = tester.getRect(title);
    await expectStableRects(
      tester,
      {'icon': find.byKey(const Key('empty_state_icon'))},
      () async {
        restore.complete(const []);
        await tester.pumpAndSettle();
        expect(find.text('Ready to scan'), findsOneWidget);
      },
    );
    // The text differs, so only its height may: it starts at the same place
    // and spans the same width.
    final readyTitle = tester.getRect(title);
    expect(readyTitle.topLeft, restoringTitle.topLeft);
    expect(readyTitle.width, restoringTitle.width);
    expect(tester.takeException(), isNull);
  });

  // #153
  testLayoutMatrix(
    'the first thumbnail keeps its size from 1 to 2 pages',
    (tester, layoutCase) async {
      await pumpHome(tester, layoutCase, pageCount: 2);
      await tester.pumpAndSettle();
      pressIconButton(tester, 'Delete page 2');
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsOneWidget);
      await expectStableRects(tester, {'thumbnail': _thumbnail}, () async {
        await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
        await tester.pumpAndSettle();
        expect(find.byType(Card), findsNWidgets(2));
      });
      expect(tester.takeException(), isNull);
    },
    cases: _defaultAndLargeText,
  );

  testLayoutMatrix('pages 9 and 10 have thumbnails of the same size', (
    tester,
    layoutCase,
  ) async {
    await pumpHome(tester, layoutCase, pageCount: 10);
    await tester.pumpAndSettle();
    final first = tester.getSize(_thumbnail);
    final ninth = find.byKey(const ValueKey('page_thumbnail_8'));
    final tenth = find.byKey(const ValueKey('page_thumbnail_9'));
    for (final thumbnail in [ninth, tenth]) {
      await tester.scrollUntilVisible(thumbnail, 100);
      await tester.pumpAndSettle();
      expect(tester.getSize(thumbnail), first);
    }
    expect(tester.takeException(), isNull);
  }, cases: _defaultAndLargeText);

  testLayoutMatrix('a drop target keeps its thumbnail size', (
    tester,
    layoutCase,
  ) async {
    await pumpHome(tester, layoutCase, pageCount: 2);
    await tester.pumpAndSettle();
    // Near the top of the thumbnails, which every viewport shows.
    const inset = Offset(0, 16);
    final gesture = await tester.startGesture(
      tester.getRect(find.byKey(const ValueKey('page_thumbnail_1'))).topCenter +
          inset,
    );
    await expectStableRects(tester, {'thumbnail': _thumbnail}, () async {
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveTo(tester.getRect(_thumbnail).topCenter + inset);
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.position == DecorationPosition.foreground &&
              (widget.decoration as BoxDecoration).border != null,
        ),
        findsOneWidget,
        reason: 'the first card must be highlighted as the drop target',
      );
    });
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, cases: _defaultAndLargeText);

  // #156
  testLayoutMatrix(
    'Undo and the camera button keep their places from delete to expiry',
    (tester, layoutCase) async {
      await pumpHome(tester, layoutCase, pageCount: 1);
      await tester.pumpAndSettle();
      final camera = tester.getRect(_camera);
      pressIconButton(tester, 'Delete page 1');
      await tester.pump();
      // Undo is reachable while it slides in, and never over the button.
      await tester.pump(const Duration(milliseconds: 100));
      final undo = tester.getRect(_undo);
      expect(undo.bottom, lessThanOrEqualTo(camera.top));
      expect(tester.getRect(_camera), camera);
      await tester.pumpAndSettle();
      expect(tester.getRect(_undo), undo);
      expect(tester.getRect(_camera), camera);

      await tester.pump(const Duration(seconds: 6));
      expect(tester.getRect(_undo), undo);
      // Expiry: Undo fades out where it was, and the button stays below it.
      await tester.pump(const Duration(seconds: 4));
      for (var frame = 0; frame < 30 && _undo.evaluate().isNotEmpty; frame++) {
        expect(tester.getRect(_undo), undo, reason: 'exit frame $frame');
        expect(tester.getRect(_camera), camera, reason: 'exit frame $frame');
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(_undo, findsNothing);
      expect(tester.getRect(_camera), camera);
      expect(tester.takeException(), isNull);
    },
    cases: _defaultAndLargeText,
  );

  for (final camera in [true, false]) {
    testLayoutMatrix(
      'Undo appears in one place whether or not the last page was deleted '
      '(camera: $camera)',
      (tester, layoutCase) async {
        ImagePickerPlatform.instance = _CameraPicker(camera: camera);
        await pumpHome(tester, layoutCase, pageCount: 2);
        await tester.pumpAndSettle();
        expect(_camera, camera ? findsOneWidget : findsNothing);

        pressIconButton(tester, 'Delete page 2');
        await tester.pumpAndSettle();
        final undo = tester.getRect(_undo);
        await tester.pump(const Duration(seconds: 11));
        await tester.pumpAndSettle();
        expect(_undo, findsNothing);
        // Card actions ignore taps for a moment after Undo times out.
        await tester.pump(const Duration(milliseconds: 400));

        pressIconButton(tester, 'Delete page 1');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pdf_export_bar')), findsNothing);
        expect(tester.getRect(_undo), undo);

        await expectStableRects(tester, {'Undo': _undo}, () async {
          await tester.tap(_undo);
          await tester.pump();
        }, reason: 'Undo tapped');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pdf_export_bar')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      cases: _defaultAndLargeText,
    );
  }
}
