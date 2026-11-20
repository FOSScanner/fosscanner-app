import 'dart:ui' show SemanticsAction;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/draft_store.dart';

class _PickerPlatform extends ImagePickerPlatform {
  @override
  bool supportsImageSource(ImageSource source) => false;

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

class _DraftStore implements DraftStore {
  final saves = <List<ScannedPage>>[];

  @override
  Future<void> clear() async {}

  @override
  Future<List<ScannedPage>> load() async => const [];

  @override
  Future<void> save(List<ScannedPage> pages) async {
    saves.add(List.of(pages));
  }
}

class _UnreadableDraftStore extends _DraftStore {
  @override
  Future<List<ScannedPage>> load() async => throw const DraftRestoreException();
}

void main() {
  late ImagePickerPlatform originalPicker;
  late Uint8List imageBytes;

  setUp(() async {
    originalPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _PickerPlatform();
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPicker;
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('barcode button is visible only on supported native platforms', (
    tester,
  ) async {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpWidget(const MaterialApp(home: ScannerHomePage()));
      await tester.pump();

      expect(
        find.byTooltip('Scan QR/barcode'),
        platform == TargetPlatform.android || platform == TargetPlatform.iOS
            ? findsOneWidget
            : findsNothing,
        reason: '$platform',
      );
      await tester.pumpWidget(const SizedBox());
    }
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [const Size(390, 844), const Size(800, 320)]) {
    testWidgets('home grid respects body cutouts at $size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.view.padding = const FakeViewPadding(
        left: 38,
        right: 24,
        bottom: 20,
      );
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ScannerHomePage(
            initialPages: [
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
      final grid = tester.getRect(find.byType(GridView));
      expect(grid.left, greaterThanOrEqualTo(38));
      expect(grid.right, lessThanOrEqualTo(size.width - 24));
      expect(grid.bottom, lessThanOrEqualTo(size.height - 20));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('draft recovery actions remain reachable with short inset body', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 220);
    tester.view.padding = const FakeViewPadding(
      left: 38,
      right: 24,
      bottom: 20,
    );
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: ScannerHomePage(draftStore: _UnreadableDraftStore()),
      ),
    );
    await tester.pumpAndSettle();
    for (final label in ['Retry restoration', 'Discard saved draft']) {
      final action = find.text(label);
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      final rect = tester.getRect(action);
      expect(rect.left, greaterThanOrEqualTo(38));
      expect(rect.right, lessThanOrEqualTo(576));
      expect(rect.top, greaterThanOrEqualTo(kToolbarHeight));
      expect(rect.bottom, lessThanOrEqualTo(200));
      expect(action.hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('semantic reorder actions update and persist page order', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final store = _DraftStore();
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
    final first = page(1);
    final second = page(2);
    final third = page(3);

    await tester.pumpWidget(
      MaterialApp(
        home: ScannerHomePage(
          initialPages: [first, second, third],
          draftStore: store,
        ),
      ),
    );

    // Startup lost-picker recovery must release the document interaction lock.
    await tester.pump();
    final node = tester.getSemantics(
      find.byKey(const ValueKey('page_semantics_1')),
    );
    final actionIds = node.getSemanticsData().customSemanticsActionIds!;
    final actionLabels = actionIds
        .map((id) => CustomSemanticsAction.getAction(id)!.label)
        .toSet();
    expect(actionLabels, containsAll(<String>{'Move earlier', 'Move later'}));
    final moveEarlierId = actionIds.firstWhere(
      (id) => CustomSemanticsAction.getAction(id)!.label == 'Move earlier',
    );
    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.customAction,
      moveEarlierId,
    );
    await tester.pump();

    expect(store.saves.last, orderedEquals([second, first, third]));
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('page_semantics_0')))
          .getSemanticsData()
          .label,
      contains('Page 1 of 3'),
    );
    semantics.dispose();
  });
}
