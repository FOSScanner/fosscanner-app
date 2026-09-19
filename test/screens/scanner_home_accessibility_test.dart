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
