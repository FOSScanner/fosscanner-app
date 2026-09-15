import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/widgets/corner_overlay.dart';

void main() {
  testWidgets('crop preview decodes a bounded image with source coordinates', (
    tester,
  ) async {
    final bytes = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.white, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(3000, 4000);
      picture.dispose();
      try {
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        image.dispose();
      }
    });
    const sourceSize = Size(3000, 4000);
    const corners = [
      Offset.zero,
      Offset(2999, 0),
      Offset(2999, 3999),
      Offset(0, 3999),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: CornerOverlay(
          imageBytes: bytes!,
          imageSize: sourceSize,
          corners: corners,
          onChanged: (_) {},
        ),
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    final size = await tester.runAsync(() async {
      // Start decoding outside the widget binding's fake async zone.
      await image.image.evict();
      final stream = image.image.resolve(ImageConfiguration.empty);
      final decoded = Completer<Size>();
      final listener = ImageStreamListener(
        (info, _) {
          if (!decoded.isCompleted) {
            decoded.complete(
              Size(info.image.width.toDouble(), info.image.height.toDouble()),
            );
          }
          info.dispose();
        },
        onError: (Object error, StackTrace? stack) {
          if (!decoded.isCompleted) decoded.completeError(error, stack);
        },
      );
      stream.addListener(listener);
      try {
        return await decoded.future.timeout(const Duration(seconds: 10));
      } finally {
        stream.removeListener(listener);
      }
    });

    expect(size!.longestSide, lessThanOrEqualTo(2048));
    expect(size.aspectRatio, closeTo(sourceSize.aspectRatio, .001));
    expect(
      tester.widget<CornerOverlay>(find.byType(CornerOverlay)).corners,
      corners,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
