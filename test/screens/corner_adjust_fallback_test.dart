import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/services/document_processor.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

const _fullBounds = [Offset.zero, Offset(99, 0), Offset(99, 79), Offset(0, 79)];
const _detectedCorners = [
  Offset(10, 8),
  Offset(89, 8),
  Offset(89, 71),
  Offset(10, 71),
];
const _notice = 'No page edges detected. Full image selected.';

class _Operations implements CornerAdjustOperations {
  _Operations(
    this.bytes, {
    this.detection,
    this.size = const Size(100, 80),
    this.nativeExport = false,
  });

  final Uint8List bytes;
  final List<Offset>? detection;
  final Size size;
  final bool nativeExport;
  final previewCorners = <List<Offset>>[];
  List<Offset>? exportCorners;
  var detectionCalls = 0;

  @override
  Future<Size> decodeSize(Uint8List imageBytes) async => size;

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async {
    detectionCalls++;
    return detection;
  }

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List imageBytes,
    List<Offset> corners,
  ) async {
    previewCorners.add(List.of(corners));
    return {for (final filter in PageFilter.values) filter: bytes};
  }

  @override
  Future<Uint8List> buildFinalPreview(
    Uint8List imageBytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async => imageBytes;

  @override
  Future<Uint8List> processForExport(
    Uint8List imageBytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async {
    exportCorners = List.of(corners);
    return nativeExport
        ? processDocument(
            imageBytes,
            corners,
            filter: filter,
            rotationQuarterTurns: rotationQuarterTurns,
            brightness: brightness,
            contrast: contrast,
          )
        : bytes;
  }
}

void main() {
  late Uint8List imageBytes;

  setUp(() async {
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  });

  Future<void> pumpEditor(
    WidgetTester tester,
    _Operations operations, {
    List<Offset>? initialCorners,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: CornerAdjustScreen(
          originalBytes: operations.bytes,
          initialCorners: initialCorners,
          operations: operations,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<ScannedPage> confirmPage(
    WidgetTester tester,
    _Operations operations,
  ) async {
    ScannedPage? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await Navigator.of(context).push<ScannedPage>(
                  MaterialPageRoute(
                    builder: (_) => CornerAdjustScreen(
                      originalBytes: operations.bytes,
                      operations: operations,
                    ),
                  ),
                );
              },
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    return result!;
  }

  final invalidDetections = <String, List<Offset>?>{
    'missing': null,
    'empty': const [],
    'incomplete': const [Offset.zero, Offset(99, 0), Offset(99, 79)],
    'duplicate': const [
      Offset.zero,
      Offset.zero,
      Offset(99, 79),
      Offset(0, 79),
    ],
    'non-finite': const [
      Offset.zero,
      Offset(double.infinity, 0),
      Offset(99, 79),
      Offset(0, 79),
    ],
  };

  for (final entry in invalidDetections.entries) {
    testWidgets('${entry.key} detection selects all valid image pixels', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final operations = _Operations(imageBytes, detection: entry.value);
        await pumpEditor(tester, operations);

        final overlay = tester.widget<CornerOverlay>(
          find.byType(CornerOverlay),
        );
        expect(overlay.corners, _fullBounds);
        expect(operations.previewCorners, isNotEmpty);
        expect(operations.previewCorners.first, _fullBounds);
        expect(find.text(_notice), findsOneWidget);
        expect(
          tester
              .getSemantics(find.text(_notice))
              .getSemanticsData()
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets('malformed saved corners use the same full-image fallback', (
    tester,
  ) async {
    final operations = _Operations(imageBytes);
    await pumpEditor(tester, operations, initialCorners: const [Offset.zero]);
    expect(operations.detectionCalls, 0);
    expect(operations.previewCorners.first, _fullBounds);
    expect(find.text(_notice), findsOneWidget);
  });

  testWidgets('the smallest supported image keeps its boundary pixels', (
    tester,
  ) async {
    final operations = _Operations(imageBytes, size: const Size(3, 3));
    await pumpEditor(tester, operations);
    expect(operations.previewCorners.first, const [
      Offset.zero,
      Offset(2, 0),
      Offset(2, 2),
      Offset(0, 2),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'valid detection remains unchanged and shows no fallback notice',
    (tester) async {
      final operations = _Operations(imageBytes, detection: _detectedCorners);
      await pumpEditor(tester, operations);
      expect(operations.detectionCalls, 1);
      expect(operations.previewCorners.first, _detectedCorners);
      expect(find.text(_notice), findsNothing);
    },
  );

  testWidgets('valid saved corners are preserved without running detection', (
    tester,
  ) async {
    final operations = _Operations(imageBytes);
    await pumpEditor(tester, operations, initialCorners: _detectedCorners);
    expect(operations.detectionCalls, 0);
    expect(operations.previewCorners.first, _detectedCorners);
    expect(find.text(_notice), findsNothing);
  });

  testWidgets('manual adjustment removes the full-image status', (
    tester,
  ) async {
    final operations = _Operations(imageBytes);
    await pumpEditor(tester, operations);
    // The overlay's parent Listener receives corner drags.
    await tester.dragFrom(
      tester.getCenter(find.byKey(const ValueKey('corner-handle-0'))),
      const Offset(30, 30),
    );
    await tester.pumpAndSettle();
    expect(find.text(_notice), findsNothing);
    expect(operations.previewCorners.last.first, isNot(Offset.zero));
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 568), const Size(640, 300)]) {
    testWidgets('fallback guidance fits $size with 200% text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpEditor(tester, _Operations(imageBytes), textScale: 2);
      expect(find.text(_notice), findsOneWidget);
      expect(find.text('Next').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('confirm exports and saves the full-image fallback corners', (
    tester,
  ) async {
    final operations = _Operations(imageBytes);
    final result = await confirmPage(tester, operations);
    expect(operations.exportCorners, _fullBounds);
    expect(result.corners, _fullBounds);
    expect(result.originalBytes, same(imageBytes));
  });

  testWidgets('accepting fallback retains content at all four image edges', (
    tester,
  ) async {
    final image = img.Image(width: 200, height: 160);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    img.fillRect(
      image,
      x1: 0,
      y1: 0,
      x2: 199,
      y2: 3,
      color: img.ColorRgb8(240, 0, 0),
    );
    img.fillRect(
      image,
      x1: 0,
      y1: 156,
      x2: 199,
      y2: 159,
      color: img.ColorRgb8(0, 0, 240),
    );
    img.fillRect(
      image,
      x1: 0,
      y1: 4,
      x2: 3,
      y2: 155,
      color: img.ColorRgb8(0, 240, 0),
    );
    img.fillRect(
      image,
      x1: 196,
      y1: 4,
      x2: 199,
      y2: 155,
      color: img.ColorRgb8(240, 240, 0),
    );
    final operations = _Operations(
      Uint8List.fromList(img.encodePng(image)),
      size: const Size(200, 160),
      nativeExport: true,
    );
    final result = await confirmPage(tester, operations);
    final output = img.decodeImage(result.processedBytes)!;
    expect((output.width, output.height), (199, 159));
    final top = output.getPixel(output.width ~/ 2, 1);
    final bottom = output.getPixel(output.width ~/ 2, output.height - 2);
    final left = output.getPixel(1, output.height ~/ 2);
    final right = output.getPixel(output.width - 2, output.height ~/ 2);
    expect(top.r, greaterThan(180));
    expect(top.g, lessThan(100));
    expect(top.b, lessThan(100));
    expect(bottom.b, greaterThan(180));
    expect(bottom.r, lessThan(100));
    expect(bottom.g, lessThan(100));
    expect(left.g, greaterThan(180));
    expect(left.r, lessThan(100));
    expect(left.b, lessThan(100));
    expect(right.r, greaterThan(180));
    expect(right.g, greaterThan(180));
    expect(right.b, lessThan(100));
  });
}
