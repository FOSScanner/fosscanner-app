import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/draft_store.dart';

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
  /// While set, gallery selection stays open until it completes.
  Completer<List<XFile>>? gallery;

  @override
  bool supportsImageSource(ImageSource source) => true;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) => gallery?.future ?? Future.value(const []);
}

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
}
