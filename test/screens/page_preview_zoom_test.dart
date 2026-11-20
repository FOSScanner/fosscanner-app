import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/screens/page_preview_screen.dart';

void main() {
  late Uint8List imageBytes;

  setUp(() async {
    final data = await rootBundle.load('assets/icon/icon.png');
    imageBytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  });

  Future<void> pumpPreview(
    WidgetTester tester, {
    bool disableAnimations = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: disableAnimations),
          child: child!,
        ),
        home: PagePreviewScreen(imageBytes: imageBytes, pageNumber: 3),
      ),
    );
    await tester.pumpAndSettle();
  }

  Matrix4 transform(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byType(InteractiveViewer))
      .transformationController!
      .value;

  Future<void> doubleTap(WidgetTester tester, Offset position) async {
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(position);
  }

  testWidgets('double-tap zooms in on the tapped point and back out', (
    tester,
  ) async {
    await pumpPreview(tester);
    final viewer = tester.getRect(find.byType(InteractiveViewer));
    final point = viewer.topLeft + const Offset(100, 150);
    expect(transform(tester).getMaxScaleOnAxis(), 1);

    await doubleTap(tester, point);
    await tester.pumpAndSettle();
    final zoomed = transform(tester);
    expect(zoomed.getMaxScaleOnAxis(), PagePreviewScreen.doubleTapScale);
    // The tapped point stays under the finger.
    final local = point - viewer.topLeft;
    final mapped = MatrixUtils.transformPoint(zoomed, local);
    expect(mapped.dx, closeTo(local.dx, 0.01));
    expect(mapped.dy, closeTo(local.dy, 0.01));

    await doubleTap(tester, point);
    await tester.pumpAndSettle();
    expect(transform(tester), Matrix4.identity());
    expect(tester.takeException(), isNull);
  });

  testWidgets('double-tap zoom is immediate with reduced motion', (
    tester,
  ) async {
    await pumpPreview(tester, disableAnimations: true);
    await doubleTap(tester, tester.getCenter(find.byType(InteractiveViewer)));
    // One frame, no animation.
    await tester.pump();
    expect(
      transform(tester).getMaxScaleOnAxis(),
      PagePreviewScreen.doubleTapScale,
    );
    expect(tester.hasRunningAnimations, isFalse);
    // Let the gesture arena's double-tap timer expire.
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });

  testWidgets('a single tap does not zoom', (tester) async {
    await pumpPreview(tester);
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pumpAndSettle();
    expect(transform(tester), Matrix4.identity());
  });
}
