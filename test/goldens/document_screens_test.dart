import 'dart:async';

import 'package:flutter/material.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:share_plus/share_plus.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/barcode_scan_screen.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/screens/page_preview_screen.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/widgets/draft_session_gate.dart';
import '../support/document_ui_fixtures.dart';
import '../support/layout_stability.dart';
import '../support/worker_isolates.dart';
import '../support/camera_platform.dart';

class _Picker extends ImagePickerPlatform {
  @override
  bool supportsImageSource(ImageSource source) => true;
  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

class _PendingShare implements SharePlatform {
  final result = Completer<ShareResult>();
  bool called = false;
  @override
  Future<ShareResult> share(ShareParams params) {
    called = true;
    return result.future;
  }
}

void goldenTest(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    final previous = debugDisableShadows;
    debugDisableShadows = false;
    try {
      await callback(tester);
    } finally {
      debugDisableShadows = previous;
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

void main() {
  late ImagePickerPlatform original;
  late Uint8List bytes;
  setUp(() async {
    original = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _Picker();
  });
  tearDown(() {
    ImagePickerPlatform.instance = original;
  });

  Future<void> prepare(WidgetTester tester) async {
    await tester.runAsync(loadGoldenFonts);
    bytes = (await tester.runAsync(syntheticDocument))!;
  }

  Future<void> finishFrame(WidgetTester tester) async {
    // Fixed time also freezes indeterminate progress at a reproducible frame.
    await tester.pump(const Duration(milliseconds: 200));
    for (final element in find.byType(Image).evaluate()) {
      await tester.runAsync(
        () => precacheImage((element.widget as Image).image, element),
      );
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  Future<void> capture(WidgetTester tester, String name) async {
    await finishFrame(tester);
    await expectLater(
      find.byKey(const Key('golden_capture')),
      matchesGoldenFile('baselines/$name.png'),
    );
  }

  Widget wrap(LayoutConfiguration layout, Widget child) => RepaintBoundary(
    key: const Key('golden_capture'),
    child: layout.wrap(child),
  );
  ScannerHomePage home(int count, {SharePlus? sharePlus}) => ScannerHomePage(
    sharePlus: sharePlus,
    searchablePdfEnabled: true,
    initialPages: [
      for (var i = 0; i < count; i++)
        ScannedPage(
          originalBytes: bytes,
          processedBytes: bytes,
          corners: fixtureCorners,
        ),
    ],
  );

  for (final layout in responsiveLayouts) {
    for (final count in [0, 8]) {
      goldenTest('home ${layout.name} $count pages', (tester) async {
        layout.apply(tester);
        await prepare(tester);
        await tester.pumpWidget(wrap(layout, home(count)));
        await tester.pumpAndSettle();
        await capture(tester, 'home_${layout.name}_$count');
      });
    }
    goldenTest('crop and filter ${layout.name}', (tester) async {
      layout.apply(tester);
      await prepare(tester);
      await tester.pumpWidget(
        wrap(
          layout,
          CornerAdjustScreen(
            originalBytes: bytes,
            operations: FixtureOperations(bytes),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await capture(tester, 'crop_${layout.name}');
      await tester.ensureVisible(find.text('Preview page'));
      await tester.tap(find.text('Preview page'));
      await tester.pumpAndSettle();
      await capture(tester, 'filter_${layout.name}');
    });
  }

  goldenTest(
    'wide preview remains useful through pending, updating, and failed states',
    (tester) async {
      const layout = LayoutConfiguration('wide', Size(900, 500));
      layout.apply(tester);
      await prepare(tester);
      final operations = FixtureOperations(bytes);
      await tester.pumpWidget(
        wrap(
          layout,
          CornerAdjustScreen(
            originalBytes: bytes,
            initialCorners: fixtureCorners,
            startWithAdjustments: true,
            operations: operations,
          ),
        ),
      );
      await finishFrame(tester);
      final preview = find.byKey(const Key('adjusted_page_preview'));
      expect(tester.getSize(preview).width, greaterThanOrEqualTo(280));
      expect(tester.getSize(preview).height, greaterThanOrEqualTo(240));
      await expectStableRects(tester, [preview], () async {
        final slider = tester.widget<Slider>(find.byType(Slider).first);
        slider.onChanged!(25);
        await capture(tester, 'filter_pending_wide');
        operations.previewState = PreviewFixtureState.updating;
        slider.onChangeEnd!(25);
        await capture(tester, 'filter_updating_wide');
        operations.pending.completeError(
          StateError('Synthetic preview failure'),
        );
        await capture(tester, 'filter_failed_wide');
      });
      expect(tester.getSize(preview).height, greaterThanOrEqualTo(240));
    },
  );

  goldenTest('options and saved page preview', (tester) async {
    final layout = responsiveLayouts.first;
    layout.apply(tester);
    await prepare(tester);
    await tester.pumpWidget(wrap(layout, home(100)));
    await finishFrame(tester);
    await tester.tap(find.byTooltip('PDF export options'));
    await capture(tester, 'export_options_large_text');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      wrap(layout, PagePreviewScreen(imageBytes: bytes, pageNumber: 100)),
    );
    await capture(tester, 'page_preview_large_text');
  });

  goldenTest('narrow export generating and cancelling statuses', (
    tester,
  ) async {
    final layout = responsiveLayouts.first;
    layout.apply(tester);
    await prepare(tester);
    const channel = MethodChannel('com.fosscanner.app/ocr');
    final gate = Completer<void>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'ensureTessdata') {
        await gate.future;
        return null;
      }
      throw StateError('Unexpected native call: ${call.method}');
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    try {
      await tester.pumpWidget(wrap(layout, home(100)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('PDF export options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Searchable text'));
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export PDF (100 pages)'));
      await capture(tester, 'export_generating_large_text');
      expect(find.text('Cancel').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await capture(tester, 'export_cancelling_large_text');
      expect(find.text('Cancelling PDF...'), findsOneWidget);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await tester.pumpAndSettle();
    }
  });

  goldenTest('narrow export opening share sheet', (tester) async {
    final layout = responsiveLayouts.first;
    layout.apply(tester);
    await prepare(tester);
    final share = _PendingShare();
    try {
      await tester.pumpWidget(
        wrap(layout, home(1, sharePlus: SharePlus.custom(share))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export PDF (1 page)'));
      await pumpUntil(tester, () => share.called, settle: false);
      await capture(tester, 'export_sharing_large_text');
      expect(find.text('Opening share sheet...'), findsOneWidget);
    } finally {
      if (!share.result.isCompleted) {
        share.result.complete(
          const ShareResult('', ShareResultStatus.dismissed),
        );
      }
      await tester.pumpAndSettle();
    }
  });

  goldenTest('saved page with landscape cutouts', (tester) async {
    const layout = LayoutConfiguration(
      'cutouts',
      Size(640, 300),
      density: 2,
      padding: FakeViewPadding(left: 38, right: 24, bottom: 20),
    );
    layout.apply(tester);
    await prepare(tester);
    await tester.pumpWidget(
      wrap(layout, PagePreviewScreen(imageBytes: bytes, pageNumber: 1)),
    );
    await capture(tester, 'page_preview_cutouts');
    final bounds = tester.getRect(find.byType(InteractiveViewer));
    expect(bounds.left, greaterThanOrEqualTo(38));
    expect(bounds.right, lessThanOrEqualTo(616));
    expect(bounds.bottom, lessThanOrEqualTo(280));
  });

  for (final fail in [false, true]) {
    goldenTest('draft session ${fail ? 'failure' : 'startup'}', (tester) async {
      const layout = LayoutConfiguration(
        'draft',
        Size(390, 844),
        textScaler: TextScaler.linear(2),
      );
      layout.apply(tester);
      await prepare(tester);
      await tester.pumpWidget(
        wrap(
          layout,
          DraftSessionGate(
            session: FixtureDraftSession(fail: fail),
            child: const SizedBox(),
          ),
        ),
      );
      await capture(tester, 'draft_${fail ? 'failure' : 'startup'}');
    });
  }

  goldenTest('barcode permission error on large-text phone', (tester) async {
    final layout = responsiveLayouts.first;
    layout.apply(tester);
    await prepare(tester);
    final originalCamera = CameraPlatform.instance;
    final camera = FixtureCameraPlatform();
    CameraPlatform.instance = camera;
    try {
      await tester.pumpWidget(wrap(layout, const BarcodeScanScreen()));
      await finishCameraAttempt(tester, camera);
      expect(find.text('Camera unavailable'), findsOneWidget);
      expect(find.text('Retry').hitTestable(), findsOneWidget);
      await capture(tester, 'barcode_camera_error');
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      CameraPlatform.instance = originalCamera;
      await camera.errors.close();
    }
  });

  goldenTest('barcode result on short large-text screen', (tester) async {
    const layout = LayoutConfiguration(
      'barcode',
      Size(640, 300),
      textScaler: TextScaler.linear(2),
    );
    layout.apply(tester);
    await prepare(tester);
    late ValueChanged<BarcodeScanResult> emit;
    await tester.pumpWidget(
      wrap(
        layout,
        BarcodeScanScreen(
          scanViewBuilder: (_, onScan) {
            emit = onScan;
            return const SizedBox();
          },
        ),
      ),
    );
    emit(
      const BarcodeScanResult(
        isValid: true,
        text: 'https://example.org/synthetic-document',
      ),
    );
    await capture(tester, 'barcode_result_landscape');
  });
}
